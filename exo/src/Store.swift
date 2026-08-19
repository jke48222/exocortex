import Foundation
import SQLite3
import CryptoKit

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func sha(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}
func nowMicros() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000_000) }
func tzOffsetMinutes() -> Int64 { Int64(TimeZone.current.secondsFromGMT() / 60) }
func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

/// Channel -> trust. Mirrors mcp-bus CONTRACT.md §1 exactly: trust is assigned by the
/// CAPTURE PATH, never by a model and never by a caller. The store and the bus speak
/// the same vocabulary so `min_trust` can be enforced end to end.
enum SourceKind: String {
    case typed, voiceSelf = "voice_self"
    case ownNote = "own_note", ownCalendar = "own_calendar", ownFile = "own_file"
    case screenCoach = "screen_coach"
    case emailKnown = "email_known"
    case emailUnknown = "email_unknown", web, ocr, transcriptOther = "transcript_other"
    case modelOutput = "model_output"

    var trust: String {
        switch self {
        case .typed, .voiceSelf: return "self"
        case .ownNote, .ownCalendar, .ownFile, .screenCoach: return "verified"
        case .emailKnown: return "third_party"
        case .emailUnknown, .web, .ocr, .transcriptOther, .modelOutput: return "untrusted"
        }
    }
}

/// Retention classes, sized to the 228 GB budget in PASS-4 §3.
/// The policy is written to the DB with an effective date the first time the store is
/// created, and expiry runs on a schedule from day one. That is the FRCP 37(e) defense:
/// routine, documented, good-faith operation predating any dispute. A policy added later
/// is spoliation.
struct RetentionClass {
    let name: String, ttlDays: Int?, note: String
    static let all: [RetentionClass] = [
        .init(name: "text",        ttlDays: nil, note: "extracted text — kept forever; ~6 GB/decade, cheaper than the vectors it generates"),
        .init(name: "raw_frame",   ttlDays: 21,  note: "pixel frames — rolling cache, not an archive (228 GB budget)"),
        .init(name: "sensitive",   ttlDays: 30,  note: "T3: health, finance, legal — separate DEK in Phase 2"),
        .init(name: "third_party", ttlDays: 14,  note: "identifiable third parties — shortest of all (Rynes C-212/13)"),
    ]
}

struct Event {
    var source: String
    var sourceKind: SourceKind
    var retention: String = "text"
    var app: String = "", bundle: String = ""
    var title: String = "", role: String = "", text: String = ""
    var externalID: String? = nil
    var meta: [String: String] = [:]
    var ts: Int64 = nowMicros()

    var trust: String { sourceKind.trust }
    var metaJSON: String {
        (try? String(data: JSONSerialization.data(withJSONObject: meta), encoding: .utf8)) ?? "{}"
    }
    var hash: String {
        sha([source, bundle, title, role, text, externalID ?? ""].joined(separator: "\u{1f}"))
    }
}

final class Store {
    var db: OpaquePointer?

    init(_ path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let isNew = !FileManager.default.fileExists(atPath: path)
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
        else { fatalError("cannot open \(path)") }
        if isNew { exec("PRAGMA page_size=8192;") }     // must precede first write
        for p in ["journal_mode=WAL", "synchronous=NORMAL", "temp_store=MEMORY",
                  "foreign_keys=ON", "auto_vacuum=NONE", "wal_autocheckpoint=4000",
                  "busy_timeout=5000"] { exec("PRAGMA \(p);") }
        migrate()
        if isNew { seedPolicy() }
    }

    func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let e = err {
            FileHandle.standardError.write("SQL: \(String(cString: e))\n".data(using: .utf8)!)
            sqlite3_free(err)
        }
    }
    func bind(_ st: OpaquePointer?, _ i: Int32, _ s: String?) {
        if let s { sqlite3_bind_text(st, i, (s as NSString).utf8String, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(st, i) }
    }
    func scalar(_ sql: String) -> Int {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS events(
          seq INTEGER PRIMARY KEY,
          ts INTEGER NOT NULL, ts_tz INTEGER NOT NULL,
          source TEXT NOT NULL, source_kind TEXT NOT NULL,
          trust TEXT NOT NULL, retention TEXT NOT NULL,
          app TEXT, bundle_id TEXT, title TEXT, role TEXT, text TEXT,
          external_id TEXT, meta TEXT,
          content_hash TEXT NOT NULL
        ) STRICT;
        """)
        exec("CREATE INDEX IF NOT EXISTS ix_events_ts ON events(ts);")
        exec("CREATE INDEX IF NOT EXISTS ix_events_ret ON events(retention, ts);")
        exec("CREATE UNIQUE INDEX IF NOT EXISTS ux_events_ext ON events(source, external_id) WHERE external_id IS NOT NULL;")
        exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
          app, title, text, content='events', content_rowid='seq');
        """)
        exec("""
        CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN
          INSERT INTO events_fts(rowid, app, title, text) VALUES (new.seq, new.app, new.title, new.text);
        END;
        """)
        // external-content FTS5 needs an explicit delete hook or the index drifts on purge
        exec("""
        CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN
          INSERT INTO events_fts(events_fts, rowid, app, title, text)
          VALUES('delete', old.seq, old.app, old.title, old.text);
        END;
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS retention_policy(
          class TEXT PRIMARY KEY, ttl_days INTEGER, note TEXT NOT NULL,
          effective_from TEXT NOT NULL) STRICT;
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS purge_receipt(
          id INTEGER PRIMARY KEY, at INTEGER NOT NULL, class TEXT NOT NULL,
          rows_deleted INTEGER NOT NULL, cutoff_ts INTEGER NOT NULL,
          hold_active INTEGER NOT NULL) STRICT;
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS litigation_hold(
          id INTEGER PRIMARY KEY CHECK(id=1), active INTEGER NOT NULL,
          changed_at INTEGER NOT NULL, reason TEXT) STRICT;
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS ingest_cursor(
          source TEXT NOT NULL, key TEXT NOT NULL, position TEXT NOT NULL,
          updated_at INTEGER NOT NULL, PRIMARY KEY(source, key)) STRICT;
        """)
        // exclusion hits record THAT, never WHAT
        exec("""
        CREATE TABLE IF NOT EXISTS exclusion_hit(
          id INTEGER PRIMARY KEY, at INTEGER NOT NULL, rule TEXT NOT NULL,
          bundle_id TEXT, app TEXT) STRICT;
        """)
    }

    private func seedPolicy() {
        let today = ISO8601DateFormatter().string(from: Date())
        for c in RetentionClass.all {
            var st: OpaquePointer?; defer { sqlite3_finalize(st) }
            sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO retention_policy(class,ttl_days,note,effective_from) VALUES(?,?,?,?);", -1, &st, nil)
            bind(st, 1, c.name)
            if let t = c.ttlDays { sqlite3_bind_int(st, 2, Int32(t)) } else { sqlite3_bind_null(st, 2) }
            bind(st, 3, c.note); bind(st, 4, today)
            sqlite3_step(st)
        }
        exec("INSERT OR IGNORE INTO litigation_hold(id,active,changed_at,reason) VALUES(1,0,\(nowMicros()),'initial');")
    }

    // MARK: writes
    @discardableResult
    func insert(_ e: Event) -> Bool {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        let sql = """
        INSERT OR IGNORE INTO events
          (ts,ts_tz,source,source_kind,trust,retention,app,bundle_id,title,role,text,external_id,meta,content_hash)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return false }
        sqlite3_bind_int64(st, 1, e.ts); sqlite3_bind_int64(st, 2, tzOffsetMinutes())
        bind(st, 3, e.source); bind(st, 4, e.sourceKind.rawValue)
        bind(st, 5, e.trust);  bind(st, 6, e.retention)
        bind(st, 7, e.app);    bind(st, 8, e.bundle)
        bind(st, 9, e.title);  bind(st, 10, e.role); bind(st, 11, e.text)
        bind(st, 12, e.externalID); bind(st, 13, e.metaJSON); bind(st, 14, e.hash)
        return sqlite3_step(st) == SQLITE_DONE && sqlite3_changes(db) > 0
    }

    func recordExclusion(rule: String, bundle: String, app: String = "") {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(db, "INSERT INTO exclusion_hit(at,rule,bundle_id,app) VALUES(?,?,?,?);", -1, &st, nil)
        sqlite3_bind_int64(st, 1, nowMicros()); bind(st, 2, rule); bind(st, 3, bundle); bind(st, 4, app)
        sqlite3_step(st)
    }

    func cursor(_ source: String, _ key: String) -> String? {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(db, "SELECT position FROM ingest_cursor WHERE source=? AND key=?;", -1, &st, nil)
        bind(st, 1, source); bind(st, 2, key)
        return sqlite3_step(st) == SQLITE_ROW ? String(cString: sqlite3_column_text(st, 0)) : nil
    }
    func setCursor(_ source: String, _ key: String, _ pos: String) {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(db, "INSERT INTO ingest_cursor(source,key,position,updated_at) VALUES(?,?,?,?) ON CONFLICT(source,key) DO UPDATE SET position=excluded.position, updated_at=excluded.updated_at;", -1, &st, nil)
        bind(st, 1, source); bind(st, 2, key); bind(st, 3, pos)
        sqlite3_bind_int64(st, 4, nowMicros()); sqlite3_step(st)
    }

    func lastHash() -> String? {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(db, "SELECT content_hash FROM events ORDER BY seq DESC LIMIT 1;", -1, &st, nil)
        return sqlite3_step(st) == SQLITE_ROW ? String(cString: sqlite3_column_text(st, 0)) : nil
    }
    /// Generic read helper so the CLI layer never touches raw sqlite3.
    func rows(_ sql: String) -> [[String]] {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        var out: [[String]] = []
        let n = sqlite3_column_count(st)
        while sqlite3_step(st) == SQLITE_ROW {
            var r: [String] = []
            for i in 0..<n { r.append(sqlite3_column_text(st, i).map { String(cString: $0) } ?? "") }
            out.append(r)
        }
        return out
    }

    func count() -> Int { scalar("SELECT count(*) FROM events;") }
    func checkpoint() { exec("PRAGMA wal_checkpoint(TRUNCATE);") }

    // MARK: search
    struct Hit { let seq: Int, ts: Int64, app, title, snip, trust, source: String, score: Double }
    func search(_ q: String, limit: Int, minTrust: String?) -> [Hit] {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        let order = ["self": 0, "verified": 1, "third_party": 2, "untrusted": 3]
        let filter = minTrust.flatMap { order[$0] }.map { rank -> String in
            let allowed = order.filter { $0.value <= rank }.keys.map { "'\($0)'" }.joined(separator: ",")
            return " AND e.trust IN (\(allowed))"
        } ?? ""
        let sql = """
        SELECT e.seq, e.ts, e.app, e.title,
               snippet(events_fts, 2, '[', ']', '…', 12), e.trust, e.source, bm25(events_fts)
        FROM events_fts JOIN events e ON e.seq = events_fts.rowid
        WHERE events_fts MATCH ?\(filter) ORDER BY bm25(events_fts) LIMIT ?;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        bind(st, 1, q); sqlite3_bind_int(st, 2, Int32(limit))
        var out: [Hit] = []
        while sqlite3_step(st) == SQLITE_ROW {
            func s(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
            out.append(Hit(seq: Int(sqlite3_column_int64(st, 0)), ts: sqlite3_column_int64(st, 1),
                           app: s(2), title: s(3), snip: s(4), trust: s(5), source: s(6),
                           score: sqlite3_column_double(st, 7)))
        }
        return out
    }
}
