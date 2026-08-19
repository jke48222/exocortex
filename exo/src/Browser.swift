import Foundation
import SQLite3

/// Browser history. Requires Full Disk Access — and note Chrome's profile directory
/// became TCC-protected in the macOS 26/27 era, which invalidates every pre-2025 guide
/// that treats `History` as a free read (PASS-4 Area B, EPERM confirmed empirically).
///
/// Always opened `?immutable=1`: the browser holds a WAL lock, and a naive open either
/// blocks or reads a torn state.
///
/// Trust is `web` -> untrusted. You chose to visit the page; you did not author it.
enum Browser {
    struct Src { let name, path, sql: String; let epoch: (Int64) -> Int64 }

    /// Chrome: microseconds since 1601-01-01. Safari: seconds since 2001-01-01.
    static func sources() -> [Src] {
        let h = NSHomeDirectory()
        var out: [Src] = []
        let safari = "\(h)/Library/Safari/History.db"
        if FileManager.default.fileExists(atPath: safari) {
            out.append(Src(name: "safari", path: safari, sql: """
                SELECT v.id, i.url, coalesce(v.title,''), v.visit_time
                FROM history_visits v JOIN history_items i ON i.id = v.history_item
                WHERE v.visit_time > ? ORDER BY v.visit_time DESC LIMIT ?;
                """, epoch: { Int64(Double($0) + 978_307_200) * 1_000_000 }))
        }
        for (n, p) in [("chrome", "Google/Chrome"), ("brave", "BraveSoftware/Brave-Browser"),
                       ("edge", "Microsoft Edge")] {
            let path = "\(h)/Library/Application Support/\(p)/Default/History"
            if FileManager.default.fileExists(atPath: path) {
                out.append(Src(name: n, path: path, sql: """
                    SELECT v.id, u.url, coalesce(u.title,''), v.visit_time
                    FROM visits v JOIN urls u ON u.id = v.url
                    WHERE v.visit_time > ? ORDER BY v.visit_time DESC LIMIT ?;
                    """, epoch: { ($0 - 11_644_473_600_000_000) }))
            }
        }
        return out
    }

    static func ingest(into store: Store, limit: Int, days: Int) -> [(String, Int, String)] {
        var report: [(String, Int, String)] = []
        for s in sources() {
            var db: OpaquePointer?
            let uri = "file:\(s.path)?immutable=1"
            guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
                report.append((s.name, 0, "EPERM — needs Full Disk Access")); sqlite3_close(db); continue
            }
            defer { sqlite3_close(db) }
            // resume from the newest visit already stored for this source
            let since = Int64(store.rows("SELECT coalesce(max(ts),0) FROM events WHERE source='browser.\(s.name)';")
                                .first?.first ?? "0") ?? 0
            // convert our micros back into the browser's native clock
            let nativeSince: Int64 = s.name == "safari"
                ? Int64(Double(since) / 1_000_000 - 978_307_200)
                : (since + 11_644_473_600_000_000)
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, s.sql, -1, &st, nil) == SQLITE_OK else {
                report.append((s.name, 0, "schema mismatch")); continue
            }
            sqlite3_bind_int64(st, 1, since == 0 ? 0 : nativeSince)
            sqlite3_bind_int(st, 2, Int32(limit))
            var n = 0
            let cutoff = days > 0 ? nowMicros() - Int64(days) * 86_400 * 1_000_000 : 0
            store.exec("BEGIN;")
            while sqlite3_step(st) == SQLITE_ROW {
                let vid = sqlite3_column_int64(st, 0)
                let url = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
                let title = sqlite3_column_text(st, 2).map { String(cString: $0) } ?? ""
                let ts = s.epoch(sqlite3_column_int64(st, 3))
                if ts < cutoff { continue }
                if url.isEmpty || url.hasPrefix("chrome://") || url.hasPrefix("about:") { continue }
                // never index a URL that looks like it carries a credential or token
                let (cleanURL, red) = Exclusion.redact(url)
                if red > 0 || cleanURL.isEmpty {
                    store.recordExclusion(rule: "url:secret-shaped", bundle: "", app: s.name); continue
                }
                var e = Event(source: "browser.\(s.name)", sourceKind: .web)
                e.app = s.name.capitalized
                e.title = title.isEmpty ? url : title
                e.text = url
                e.externalID = "\(s.name):\(vid)"
                e.ts = ts
                if store.insert(e) { n += 1 }
            }
            store.exec("COMMIT;")
            sqlite3_finalize(st)
            report.append((s.name, n, "ok"))
        }
        return report
    }
}
