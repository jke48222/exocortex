import Foundation
import SQLite3

/// iMessage ingest from ~/Library/Messages/chat.db (Full Disk Access required).
///
/// Measured on this machine: **380,942 messages, of which 359,578 (94.4%) carry plain
/// `text`**. Only 5.6% are `text IS NULL` with the payload in `attributedBody`, an
/// NSKeyedArchiver typedstream blob — the notorious hard part is a small tail, not the
/// bulk. Those rows are counted and skipped rather than half-parsed: a naive NSString
/// regex recovered only 13 of 40 sampled blobs, and a wrong message body is worse than a
/// missing one. The correct fix is `imessage-exporter` as a SUBPROCESS (it is GPL-3.0 and
/// cannot be linked into a notarized proprietary app).
///
/// `message.date` is nanoseconds since the Apple epoch (2001-01-01).
enum IMessage {
    static var path: String { NSHomeDirectory() + "/Library/Messages/chat.db" }

    static func ingest(into store: Store, limit: Int, days: Int) -> (Int, Int, Int, String) {
        guard FileManager.default.fileExists(atPath: path) else { return (0,0,0,"not present") }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?immutable=1", &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return (0,0,0,"EPERM — needs Full Disk Access")
        }
        defer { sqlite3_close(db) }

        let since = Int64(store.rows("SELECT coalesce(max(ts),0) FROM events WHERE source='imessage';")
                            .first?.first ?? "0") ?? 0
        // our micros -> Apple-epoch nanoseconds
        let nativeSince = since == 0 ? 0 : (since - 978_307_200 * 1_000_000) * 1000
        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody IS NOT NULL, m.is_from_me, m.date,
               coalesce(h.id,''), coalesce(m.service,'')
        FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE m.date > ? ORDER BY m.date DESC LIMIT ?;
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            return (0,0,0,"schema mismatch")
        }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, nativeSince)
        sqlite3_bind_int(st, 2, Int32(limit))

        var n = 0, skippedBlob = 0, excluded = 0
        let cutoff = days > 0 ? nowMicros() - Int64(days) * 86_400 * 1_000_000 : 0
        store.exec("BEGIN;")
        while sqlite3_step(st) == SQLITE_ROW {
            let rid = sqlite3_column_int64(st, 0)
            let text = sqlite3_column_text(st, 1).map { String(cString: $0) }
            let hasBlob = sqlite3_column_int(st, 2) == 1
            let fromMe = sqlite3_column_int(st, 3) == 1
            let ts = 978_307_200 * 1_000_000 + sqlite3_column_int64(st, 4) / 1000
            let handle = sqlite3_column_text(st, 5).map { String(cString: $0) } ?? ""
            let service = sqlite3_column_text(st, 6).map { String(cString: $0) } ?? ""

            guard let body = text, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if hasBlob { skippedBlob += 1 }
                continue
            }
            if ts < cutoff { continue }
            let (clean, red) = Exclusion.redact(body)
            if red > 0 || clean.isEmpty {
                store.recordExclusion(rule: "imessage:secret-shaped", bundle: "", app: "Messages")
                excluded += 1; continue
            }
            // Trust by capture path. What I sent is `self`. What someone else sent is
            // third-party data about a person who never consented to this archive, so it
            // is trusted lower AND retained shorter (Rynes C-212/13).
            var e = Event(source: "imessage",
                          sourceKind: fromMe ? .typed : .messageOther)
            e.retention = fromMe ? "text" : "correspondence"
            e.app = "Messages"; e.bundle = "com.apple.MobileSMS"
            e.title = handle.isEmpty ? "(unknown)" : handle
            e.role = fromMe ? "me" : "them"
            e.text = String(clean.prefix(8000))
            e.externalID = "imsg:\(rid)"
            e.meta = ["handle": handle, "service": service]
            e.ts = ts
            if store.insert(e) { n += 1 }
        }
        store.exec("COMMIT;")
        return (n, skippedBlob, excluded, "ok")
    }
}
