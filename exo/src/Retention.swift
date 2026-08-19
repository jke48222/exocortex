import Foundation
import SQLite3

/// Scheduled retention expiry with purge receipts.
///
/// This is the FRCP 37(e) defense and it is architectural, not legal: the rule allows
/// adverse-inference sanctions only on a finding of "intent to deprive", and the committee
/// note says reasonable steps "does not call for perfection". Routine, documented,
/// good-faith operation of a system that predates any dispute is the defense. The SAME
/// deletion performed after a duty to preserve attaches is spoliation.
///
/// So: the policy is written with an effective date at store creation, expiry runs on a
/// schedule, every purge writes a receipt, and a litigation hold suspends ALL classes
/// atomically and is itself recorded.
enum Retention {
    static func holdActive(_ s: Store) -> Bool {
        s.scalar("SELECT active FROM litigation_hold WHERE id=1;") == 1
    }

    static func setHold(_ s: Store, _ on: Bool, reason: String) {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(s.db, "UPDATE litigation_hold SET active=?, changed_at=?, reason=? WHERE id=1;", -1, &st, nil)
        sqlite3_bind_int(st, 1, on ? 1 : 0); sqlite3_bind_int64(st, 2, nowMicros())
        s.bind(st, 3, reason); sqlite3_step(st)
    }

    struct Result { let cls: String; let deleted: Int; let ttl: Int?; let skipped: Bool }

    @discardableResult
    static func run(_ s: Store, dryRun: Bool) -> [Result] {
        let hold = holdActive(s)
        var out: [Result] = []
        var st: OpaquePointer?
        sqlite3_prepare_v2(s.db, "SELECT class, ttl_days FROM retention_policy ORDER BY class;", -1, &st, nil)
        var rows: [(String, Int?)] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let c = String(cString: sqlite3_column_text(st, 0))
            let t = sqlite3_column_type(st, 1) == SQLITE_NULL ? nil : Int(sqlite3_column_int(st, 1))
            rows.append((c, t))
        }
        sqlite3_finalize(st)

        for (cls, ttl) in rows {
            guard let ttl else { out.append(Result(cls: cls, deleted: 0, ttl: nil, skipped: false)); continue }
            let cutoff = nowMicros() - Int64(ttl) * 86_400 * 1_000_000
            let n = countExpired(s, cls, cutoff)
            if hold || dryRun {
                out.append(Result(cls: cls, deleted: n, ttl: ttl, skipped: true)); continue
            }
            if n > 0 {
                var d: OpaquePointer?; defer { sqlite3_finalize(d) }
                sqlite3_prepare_v2(s.db, "DELETE FROM events WHERE retention=? AND ts<?;", -1, &d, nil)
                s.bind(d, 1, cls); sqlite3_bind_int64(d, 2, cutoff)
                sqlite3_step(d)
            }
            receipt(s, cls: cls, deleted: n, cutoff: cutoff, hold: hold)
            out.append(Result(cls: cls, deleted: n, ttl: ttl, skipped: false))
        }
        return out
    }

    private static func countExpired(_ s: Store, _ cls: String, _ cutoff: Int64) -> Int {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(s.db, "SELECT count(*) FROM events WHERE retention=? AND ts<?;", -1, &st, nil)
        s.bind(st, 1, cls); sqlite3_bind_int64(st, 2, cutoff)
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
    }

    private static func receipt(_ s: Store, cls: String, deleted: Int, cutoff: Int64, hold: Bool) {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(s.db, "INSERT INTO purge_receipt(at,class,rows_deleted,cutoff_ts,hold_active) VALUES(?,?,?,?,?);", -1, &st, nil)
        sqlite3_bind_int64(st, 1, nowMicros()); s.bind(st, 2, cls)
        sqlite3_bind_int(st, 3, Int32(deleted)); sqlite3_bind_int64(st, 4, cutoff)
        sqlite3_bind_int(st, 5, hold ? 1 : 0); sqlite3_step(st)
    }
}
