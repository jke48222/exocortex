import Foundation
import SQLite3

/// The bitemporal belief ledger — Phase 3, and the portfolio's actual differentiator.
///
/// PASS-4 Area E's reframe is what makes this tractable: **belief time is just valid time,
/// one level of reification up.** The object-level fact `P` has a valid time (when P was
/// true in the world). The belief `believes(me, P)` is a *different* fact, whose valid time
/// IS the belief interval. So this needs two axes at two levels, not three axes at one, and
/// every query stays ordinary SQL:2011 bitemporality.
///
/// Three time axes on each row:
///   valid_*   when the claim was true in the WORLD
///   belief_*  when I HELD the belief          <- the axis this whole project exists for
///   sys_*     when this ROW was the system's live answer
///
/// The critical rule, and the reason `change_reason` is NOT NULL and the two writes are
/// separate functions: **a change of mind and a re-extraction are semantically opposite and
/// look identical in a naive schema.**
///
///   * change of mind — new evidence in 2026 says ¬P. The 2025 belief was REAL. Close its
///     belief interval; `beliefs_at('X','2025-03-01')` must still answer P.
///   * re-extraction — a better model re-reads the SAME 2025 moments and says I actually
///     believed ¬P. The belief interval is UNCHANGED; what moved is the system's record.
///     `beliefs_at('X','2025-03-01')` must now answer ¬P, because the old answer was a
///     transcription error.
///
/// Conflating them silently destroys the premise, and you would not notice for a year.
enum Ledger {

    static func migrate(_ s: Store) {
        s.exec("""
        CREATE TABLE IF NOT EXISTS extraction_run(
          run_id TEXT PRIMARY KEY, model_id TEXT NOT NULL, model_version TEXT NOT NULL,
          prompt_hash TEXT NOT NULL, code_version TEXT NOT NULL, started_at TEXT NOT NULL
        ) STRICT;
        """)
        s.exec("""
        CREATE TABLE IF NOT EXISTS claim(
          claim_id TEXT PRIMARY KEY,
          subject TEXT NOT NULL, predicate TEXT NOT NULL, object TEXT,
          polarity INTEGER NOT NULL DEFAULT 1,     -- +1 = P, -1 = not-P
          scope TEXT,                              -- 'at work' | 'for side projects' | NULL
          norm_text TEXT NOT NULL
        ) STRICT;
        """)
        s.exec("CREATE INDEX IF NOT EXISTS ix_claim_subj ON claim(subject, predicate);")
        s.exec("""
        CREATE TABLE IF NOT EXISTS belief(
          belief_id TEXT PRIMARY KEY,
          claim_id TEXT NOT NULL REFERENCES claim(claim_id),
          holder TEXT NOT NULL DEFAULT 'me',
          valid_from TEXT, valid_to TEXT,
          belief_from TEXT NOT NULL, belief_to TEXT,
          sys_from TEXT NOT NULL, sys_to TEXT,
          confidence REAL NOT NULL,
          confidence_src TEXT NOT NULL,            -- model_selfreport|evidence_freq|
                                                   -- explicit_statement|human_confirmed
          run_id TEXT REFERENCES extraction_run(run_id),
          supersedes TEXT REFERENCES belief(belief_id),
          change_reason TEXT NOT NULL              -- mind_change|reextraction|human_edit|initial
        ) STRICT;
        """)
        s.exec("CREATE INDEX IF NOT EXISTS ix_belief_asof ON belief(claim_id, belief_from, belief_to) WHERE sys_to IS NULL;")
        s.exec("CREATE INDEX IF NOT EXISTS ix_belief_holder ON belief(holder, belief_from DESC) WHERE sys_to IS NULL;")
        s.exec("""
        CREATE TABLE IF NOT EXISTS belief_evidence(
          belief_id TEXT NOT NULL REFERENCES belief(belief_id),
          seq INTEGER NOT NULL REFERENCES events(seq) ON DELETE CASCADE,
          role TEXT NOT NULL,                      -- supports|contradicts|contextualizes
          weight REAL NOT NULL DEFAULT 1.0,
          PRIMARY KEY (belief_id, seq, role)
        ) STRICT;
        """)
        s.exec("""
        CREATE TABLE IF NOT EXISTS contradiction(
          contra_id TEXT PRIMARY KEY,
          belief_a TEXT NOT NULL REFERENCES belief(belief_id),
          belief_b TEXT NOT NULL REFERENCES belief(belief_id),
          detector TEXT NOT NULL, score REAL NOT NULL,
          status TEXT NOT NULL DEFAULT 'open',      -- open|genuine_change|scope_difference|
                                                    -- extraction_error|both_true
          reviewed_at TEXT
        ) STRICT;
        """)
    }

    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
    static func id(_ prefix: String) -> String { "\(prefix)_\(UUID().uuidString.prefix(12).lowercased())" }

    // MARK: - claims

    @discardableResult
    static func upsertClaim(_ s: Store, subject: String, predicate: String, object: String?,
                            polarity: Int, scope: String?, norm: String) -> String {
        // Content-addressed so the same proposition is one row, however often it is seen.
        let cid = "clm_" + sha([subject, predicate, object ?? "", String(polarity), scope ?? ""]
                                .joined(separator: "\u{1f}")).prefix(16)
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(s.db, """
            INSERT OR IGNORE INTO claim(claim_id,subject,predicate,object,polarity,scope,norm_text)
            VALUES(?,?,?,?,?,?,?);
            """, -1, &st, nil)
        s.bind(st, 1, String(cid)); s.bind(st, 2, subject); s.bind(st, 3, predicate)
        s.bind(st, 4, object); sqlite3_bind_int(st, 5, Int32(polarity))
        s.bind(st, 6, scope); s.bind(st, 7, norm)
        sqlite3_step(st)
        return String(cid)
    }

    // MARK: - the two write paths, deliberately separate

    /// Path A — I CHANGED MY MIND.
    /// The old row stays the system's live answer; only its BELIEF interval closes. A
    /// point-in-time query before `at` must still return the old belief, because I really
    /// did hold it then.
    @discardableResult
    static func mindChange(_ s: Store, from oldBeliefID: String?, toClaim claimID: String,
                           at: String, confidence: Double, confidenceSrc: String,
                           runID: String?, evidence: [Int64] = []) -> String {
        let new = id("blf")
        s.exec("BEGIN;")
        if let old = oldBeliefID {
            var st: OpaquePointer?
            sqlite3_prepare_v2(s.db,
                "UPDATE belief SET belief_to=? WHERE belief_id=? AND sys_to IS NULL;", -1, &st, nil)
            s.bind(st, 1, at); s.bind(st, 2, old); sqlite3_step(st); sqlite3_finalize(st)
        }
        insert(s, id: new, claim: claimID, beliefFrom: at, beliefTo: nil,
               confidence: confidence, src: confidenceSrc, runID: runID,
               supersedes: oldBeliefID, reason: oldBeliefID == nil ? "initial" : "mind_change")
        link(s, new, evidence)
        s.exec("COMMIT;")
        return new
    }

    /// Path B — A BETTER MODEL RE-READ THE SAME MOMENTS.
    /// The belief interval is copied VERBATIM; only the system record moves. A point-in-time
    /// query now returns the corrected belief, because the previous answer was the machine's
    /// error, not something I ever believed.
    @discardableResult
    static func reextraction(_ s: Store, correcting oldBeliefID: String, toClaim claimID: String,
                             confidence: Double, confidenceSrc: String,
                             runID: String?, evidence: [Int64] = []) -> String? {
        let rows = s.rows("SELECT belief_from, coalesce(belief_to,''), holder FROM belief WHERE belief_id='\(oldBeliefID)' AND sys_to IS NULL;")
        guard let r = rows.first else { return nil }
        let new = id("blf")
        s.exec("BEGIN;")
        var st: OpaquePointer?
        sqlite3_prepare_v2(s.db, "UPDATE belief SET sys_to=? WHERE belief_id=? AND sys_to IS NULL;", -1, &st, nil)
        s.bind(st, 1, now()); s.bind(st, 2, oldBeliefID); sqlite3_step(st); sqlite3_finalize(st)
        insert(s, id: new, claim: claimID,
               beliefFrom: r[0], beliefTo: r[1].isEmpty ? nil : r[1],   // copied verbatim
               confidence: confidence, src: confidenceSrc, runID: runID,
               supersedes: oldBeliefID, reason: "reextraction")
        link(s, new, evidence)
        s.exec("COMMIT;")
        return new
    }

    private static func insert(_ s: Store, id: String, claim: String,
                               beliefFrom: String, beliefTo: String?,
                               confidence: Double, src: String, runID: String?,
                               supersedes: String?, reason: String) {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(s.db, """
            INSERT INTO belief(belief_id,claim_id,holder,belief_from,belief_to,sys_from,
                               confidence,confidence_src,run_id,supersedes,change_reason)
            VALUES(?,?, 'me', ?,?,?,?,?,?,?,?);
            """, -1, &st, nil)
        s.bind(st, 1, id); s.bind(st, 2, claim)
        s.bind(st, 3, beliefFrom); s.bind(st, 4, beliefTo); s.bind(st, 5, now())
        sqlite3_bind_double(st, 6, confidence)
        s.bind(st, 7, src); s.bind(st, 8, runID); s.bind(st, 9, supersedes); s.bind(st, 10, reason)
        sqlite3_step(st)
    }

    private static func link(_ s: Store, _ beliefID: String, _ seqs: [Int64]) {
        for seq in seqs {
            var st: OpaquePointer?
            sqlite3_prepare_v2(s.db,
                "INSERT OR IGNORE INTO belief_evidence(belief_id,seq,role) VALUES(?,?,'supports');",
                -1, &st, nil)
            s.bind(st, 1, beliefID); sqlite3_bind_int64(st, 2, seq)
            sqlite3_step(st); sqlite3_finalize(st)
        }
    }

    // MARK: - queries

    struct Belief {
        let id, text, reason, confSrc: String
        let polarity: Int
        let beliefFrom: String, beliefTo: String?
        let confidence: Double
        let evidence: Int
    }

    /// "What did I believe about X on date D?"  — the query the project exists for.
    static func beliefsAt(_ s: Store, subject: String, asOf: String,
                          includeSuperseded: Bool = false) -> [Belief] {
        let sysClause = includeSuperseded ? "" : "AND b.sys_to IS NULL"
        let sql = """
        SELECT b.belief_id, c.norm_text, c.polarity, b.belief_from,
               coalesce(b.belief_to,''), b.confidence, b.confidence_src, b.change_reason,
               (SELECT count(*) FROM belief_evidence e WHERE e.belief_id=b.belief_id)
        FROM belief b JOIN claim c ON c.claim_id=b.claim_id
        WHERE lower(c.subject) LIKE lower('%\(subject.replacingOccurrences(of: "'", with: "''"))%')
          \(sysClause)
          AND b.belief_from <= '\(asOf)'
          AND (b.belief_to IS NULL OR b.belief_to > '\(asOf)')
        ORDER BY b.belief_from DESC;
        """
        return s.rows(sql).map {
            Belief(id: $0[0], text: $0[1], reason: $0[7], confSrc: $0[6],
                   polarity: Int($0[2]) ?? 1, beliefFrom: $0[3],
                   beliefTo: $0[4].isEmpty ? nil : $0[4],
                   confidence: Double($0[5]) ?? 0, evidence: Int($0[8]) ?? 0)
        }
    }

    /// "How did my view of X evolve?" — every belief interval, in order.
    static func history(_ s: Store, subject: String) -> [Belief] {
        let sql = """
        SELECT b.belief_id, c.norm_text, c.polarity, b.belief_from,
               coalesce(b.belief_to,''), b.confidence, b.confidence_src, b.change_reason,
               (SELECT count(*) FROM belief_evidence e WHERE e.belief_id=b.belief_id)
        FROM belief b JOIN claim c ON c.claim_id=b.claim_id
        WHERE lower(c.subject) LIKE lower('%\(subject.replacingOccurrences(of: "'", with: "''"))%')
          AND b.sys_to IS NULL
        ORDER BY b.belief_from;
        """
        return s.rows(sql).map {
            Belief(id: $0[0], text: $0[1], reason: $0[7], confSrc: $0[6],
                   polarity: Int($0[2]) ?? 1, beliefFrom: $0[3],
                   beliefTo: $0[4].isEmpty ? nil : $0[4],
                   confidence: Double($0[5]) ?? 0, evidence: Int($0[8]) ?? 0)
        }
    }

    /// "What did the OLD extractor think I believed?" — audit the machine, not yourself.
    /// Nobody builds this, and it is the check that makes re-extraction trustworthy.
    static func asKnownAt(_ s: Store, subject: String, asOf: String, systemTime: String) -> [Belief] {
        let sql = """
        SELECT b.belief_id, c.norm_text, c.polarity, b.belief_from,
               coalesce(b.belief_to,''), b.confidence, b.confidence_src, b.change_reason,
               (SELECT count(*) FROM belief_evidence e WHERE e.belief_id=b.belief_id)
        FROM belief b JOIN claim c ON c.claim_id=b.claim_id
        WHERE lower(c.subject) LIKE lower('%\(subject.replacingOccurrences(of: "'", with: "''"))%')
          AND b.belief_from <= '\(asOf)' AND (b.belief_to IS NULL OR b.belief_to > '\(asOf)')
          AND b.sys_from <= '\(systemTime)'
          AND (b.sys_to IS NULL OR b.sys_to > '\(systemTime)')
        ORDER BY b.belief_from DESC;
        """
        return s.rows(sql).map {
            Belief(id: $0[0], text: $0[1], reason: $0[7], confSrc: $0[6],
                   polarity: Int($0[2]) ?? 1, beliefFrom: $0[3],
                   beliefTo: $0[4].isEmpty ? nil : $0[4],
                   confidence: Double($0[5]) ?? 0, evidence: Int($0[8]) ?? 0)
        }
    }

    static func startRun(_ s: Store, model: String, version: String,
                         promptHash: String, codeVersion: String) -> String {
        let rid = id("run")
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(s.db, """
            INSERT INTO extraction_run(run_id,model_id,model_version,prompt_hash,code_version,started_at)
            VALUES(?,?,?,?,?,?);
            """, -1, &st, nil)
        s.bind(st, 1, rid); s.bind(st, 2, model); s.bind(st, 3, version)
        s.bind(st, 4, promptHash); s.bind(st, 5, codeVersion); s.bind(st, 6, now())
        sqlite3_step(st)
        return rid
    }
}
