// exo — Exocortex Phase 0: AX-tree capture -> SQLite/FTS5 -> one search box.
// Single-file Swift CLI. Build: see ../build/build.sh
//
// Design faithful to the Pass-4 dossier:
//   * AX tree primary (Area B): the actual text, correct reading order, cheap.
//   * External-content FTS5 + BM25 (Area D): index only, content read from `events`.
//   * STRICT schema + WAL + page_size 8192 (Area C).
//   * A real slice of the capture-exclusion list (Area L): password-manager bundle
//     ids are suppressed — we log THAT we suppressed, never WHAT.
//   * Content-hash dedup so idle screens don't fill the log.

import Foundation
import AppKit
import ApplicationServices
import SQLite3
import CryptoKit

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// Capture-exclusion denylist (Area L). Extend freely; ships as defaults, not hardcoded law.
let DENY: Set<String> = [
    "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword",
    "com.bitwarden.desktop", "com.apple.Passwords", "com.apple.keychainaccess",
    "com.dashlane.Dashlane", "com.lastpass.LastPass",
]

func sha(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}
func nowMicros() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000_000) }
func tzOffsetMinutes() -> Int64 { Int64(TimeZone.current.secondsFromGMT() / 60) }

func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

// MARK: - AX helpers
func axString(_ el: AXUIElement, _ attr: String) -> String? {
    var ref: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
       let s = ref as? String, !s.isEmpty { return s }
    return nil
}
func axChild(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
    var ref: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
       let r = ref, CFGetTypeID(r) == AXUIElementGetTypeID() {
        return (r as! AXUIElement)
    }
    return nil
}

struct Event {
    var source: String, app: String, bundle: String
    var title: String, role: String, text: String
    var hash: String {
        sha([source, bundle, title, role, text].joined(separator: "\u{1f}"))
    }
}

// MARK: - Store
final class Store {
    var db: OpaquePointer?
    init(_ path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let isNew = !FileManager.default.fileExists(atPath: path)
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            fatalError("cannot open \(path)")
        }
        if isNew { exec("PRAGMA page_size=8192;") }      // must precede first write
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA temp_store=MEMORY;")
        exec("PRAGMA foreign_keys=ON;")
        exec("""
        CREATE TABLE IF NOT EXISTS events(
          seq INTEGER PRIMARY KEY,
          ts INTEGER NOT NULL, ts_tz INTEGER NOT NULL,
          source TEXT NOT NULL, app TEXT, bundle_id TEXT,
          title TEXT, role TEXT, text TEXT,
          content_hash TEXT NOT NULL
        ) STRICT;
        """)
        exec("CREATE INDEX IF NOT EXISTS ix_events_ts ON events(ts);")
        exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
          app, title, text, content='events', content_rowid='seq'
        );
        """)
        exec("""
        CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN
          INSERT INTO events_fts(rowid, app, title, text)
          VALUES (new.seq, new.app, new.title, new.text);
        END;
        """)
    }
    func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let e = err {
            FileHandle.standardError.write("SQL error: \(String(cString: e))\n".data(using: .utf8)!)
            sqlite3_free(err)
        }
    }
    func lastHash() -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT content_hash FROM events ORDER BY seq DESC LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        return sqlite3_step(stmt) == SQLITE_ROW ? String(cString: sqlite3_column_text(stmt, 0)) : nil
    }
    @discardableResult
    func insert(_ e: Event) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "INSERT INTO events(ts,ts_tz,source,app,bundle_id,title,role,text,content_hash) VALUES(?,?,?,?,?,?,?,?,?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_int64(stmt, 1, nowMicros())
        sqlite3_bind_int64(stmt, 2, tzOffsetMinutes())
        bind(stmt, 3, e.source); bind(stmt, 4, e.app); bind(stmt, 5, e.bundle)
        bind(stmt, 6, e.title); bind(stmt, 7, e.role); bind(stmt, 8, e.text)
        bind(stmt, 9, e.hash)
        return sqlite3_step(stmt) == SQLITE_DONE
    }
    func bind(_ stmt: OpaquePointer?, _ i: Int32, _ s: String) {
        sqlite3_bind_text(stmt, i, (s as NSString).utf8String, -1, SQLITE_TRANSIENT)
    }
    func count() -> Int {
        var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
        sqlite3_prepare_v2(db, "SELECT count(*) FROM events;", -1, &stmt, nil)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }
    func checkpoint() { exec("PRAGMA wal_checkpoint(TRUNCATE);") }

    func search(_ query: String, limit: Int) -> [(seq: Int, ts: Int64, app: String, title: String, snip: String, score: Double)] {
        var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
        let sql = """
        SELECT e.seq, e.ts, e.app, e.title,
               snippet(events_fts, 2, '[', ']', '…', 12) AS snip,
               bm25(events_fts) AS score
        FROM events_fts JOIN events e ON e.seq = events_fts.rowid
        WHERE events_fts MATCH ?
        ORDER BY score LIMIT ?;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        bind(stmt, 1, query)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [(Int, Int64, String, String, String, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let seq = Int(sqlite3_column_int64(stmt, 0))
            let ts = sqlite3_column_int64(stmt, 1)
            let app = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let title = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let snip = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let score = sqlite3_column_double(stmt, 5)
            out.append((seq, ts, app, title, snip, score))
        }
        return out
    }
}

// MARK: - Capture
func captureTick() -> Event? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let bundle = app.bundleIdentifier ?? ""
    let appName = app.localizedName ?? bundle

    // Exclusion (Area L): record THAT we suppressed, never WHAT.
    if DENY.contains(bundle) {
        return Event(source: "exclusion.suppressed", app: appName, bundle: bundle,
                     title: "[suppressed: excluded app]", role: "", text: "")
    }

    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var title = ""
    if let win = axChild(axApp, kAXFocusedWindowAttribute) {
        title = axString(win, kAXTitleAttribute) ?? ""
    }
    var role = "", text = ""
    if let el = axChild(axApp, kAXFocusedUIElementAttribute) {
        role = axString(el, kAXRoleAttribute) ?? ""
        // prefer selected text, then value, then title/description
        text = axString(el, kAXSelectedTextAttribute)
            ?? axString(el, kAXValueAttribute)
            ?? axString(el, kAXDescriptionAttribute)
            ?? ""
        if text.count > 4000 { text = String(text.prefix(4000)) }  // cap runaway fields
    }

    // CGWindowList title fallback (needs Screen Recording for kCGWindowName; harmless if empty)
    if title.isEmpty,
       let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
        for w in infos where (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier {
            if let n = w[kCGWindowName as String] as? String, !n.isEmpty { title = n; break }
        }
    }

    if title.isEmpty && text.isEmpty { title = appName }  // never store a blank row
    return Event(source: "ax.focus", app: appName, bundle: bundle,
                 title: title, role: role, text: text)
}

// MARK: - Formatting
func localStamp(_ micros: Int64) -> String {
    let d = Date(timeIntervalSince1970: Double(micros) / 1_000_000)
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.timeZone = .current
    return f.string(from: d)
}

// MARK: - Main
let args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String, _ def: String) -> String {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return def
}
let dbPath = expand(opt("--db", "~/.exocortex/phase0.db"))
let cmd = args.first ?? "help"

switch cmd {
case "perms":
    let trusted = AXIsProcessTrusted()
    print("Accessibility trusted: \(trusted ? "YES" : "NO")")
    if !trusted {
        print("Grant it: System Settings > Privacy & Security > Accessibility,")
        print("then add the process running exo (your terminal, or the signed exo binary).")
    }

case "capture":
    let store = Store(dbPath)
    let interval = Double(opt("--interval", "2")) ?? 2
    let once = args.contains("--once")
    var last = store.lastHash()
    if !AXIsProcessTrusted() {
        FileHandle.standardError.write("warning: Accessibility not granted; run `exo perms`. Capturing app/title only.\n".data(using: .utf8)!)
    }
    func tick() {
        guard let e = captureTick() else { return }
        if e.hash == last { return }           // dedup identical consecutive states
        if store.insert(e) { last = e.hash
            print("· \(e.app) — \(e.title.prefix(60))") }
    }
    if once { tick(); store.checkpoint(); break }
    signal(SIGINT) { _ in exit(0) }
    print("capturing every \(interval)s -> \(dbPath)  (Ctrl-C to stop)")
    var n = 0
    while true { tick(); n += 1; if n % 30 == 0 { store.checkpoint() }
        Thread.sleep(forTimeInterval: interval) }

case "seed":
    // Prove the store+search pipeline headlessly, without any TCC grant.
    let store = Store(dbPath)
    let samples: [Event] = [
        Event(source:"ax.focus",app:"Xcode",bundle:"com.apple.dt.Xcode",title:"exo.swift — exocortex",role:"AXTextArea",text:"external-content FTS5 with bm25 ranking over the event log"),
        Event(source:"ax.focus",app:"Safari",bundle:"com.apple.Safari",title:"SQLite FTS5 documentation",role:"AXWebArea",text:"the snippet() function returns a fragment of text with matches delimited"),
        Event(source:"ax.focus",app:"Mail",bundle:"com.apple.mail",title:"Re: orrery accuracy figure",role:"AXTextArea",text:"planets only ever turn one way so cheap gears still hit arcminute precision"),
        Event(source:"ax.focus",app:"Notes",bundle:"com.apple.Notes",title:"belief version control",role:"AXTextArea",text:"what did 2025-me believe about the ledger — bitemporal supersede not delete"),
        Event(source:"exclusion.suppressed",app:"1Password",bundle:"com.1password.1password",title:"[suppressed: excluded app]",role:"",text:""),
    ]
    for e in samples { store.insert(e) }
    store.checkpoint()
    print("seeded \(samples.count) events -> \(dbPath) (total \(store.count()))")

case "search":
    let store = Store(dbPath)
    let limit = Int(opt("--limit", "8")) ?? 8
    var terms: [String] = []
    var i = 1                                   // skip the "search" subcommand
    while i < args.count {
        let a = args[i]
        if a == "--db" || a == "--limit" { i += 2; continue }   // skip flag + value
        if a.hasPrefix("--") { i += 1; continue }
        terms.append(a); i += 1
    }
    let q = terms.joined(separator: " ")
    guard !q.isEmpty else { print("usage: exo search <query>"); break }
    let rows = store.search(q, limit: limit)
    if rows.isEmpty { print("no matches for: \(q)"); break }
    for r in rows {
        print("[\(localStamp(r.ts))]  \(r.app) — \(r.title)")
        if !r.snip.isEmpty { print("    \(r.snip)") }
        print("    seq=\(r.seq)  bm25=\(String(format: "%.3f", r.score))")
    }

case "stats":
    let store = Store(dbPath)
    print("db: \(dbPath)")
    print("events: \(store.count())")

default:
    print("""
    exo — Exocortex Phase 0 (capture -> SQLite/FTS5 -> search)
      exo perms                 show/what to grant for Accessibility capture
      exo capture [--interval 2] [--once]   run the AX capture loop
      exo seed                  insert synthetic events (proves store+search, no TCC)
      exo search <query>        BM25 search over the log
      exo stats                 event count
      --db <path>               default ~/.exocortex/phase0.db
    """)
}
