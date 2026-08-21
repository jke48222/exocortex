import Foundation
import SQLite3

/// S6 — engineered forgetting.
///
/// Area F gives three converging arguments and they point the same way: **functional**
/// (transience is regularization — a memory that keeps everything cannot generalize),
/// **economic** (every stale row is a distractor in every future query), and **legal**
/// (GDPR Art. 17, where deleting a row is insufficient once its content has propagated into
/// summaries and embeddings). Mechanism: **FSRS applied to memory strength, not to review
/// scheduling** — `R = exp(ln(0.9)·t/S)`; retrieval strengthens, disuse demotes to cold
/// storage, and **nothing is ever hard-deleted.**
///
/// ## Decay is not retention, and conflating them would be a serious mistake
///
/// This repo already deletes data on a schedule: `Retention` enforces TTLs by class and is
/// the FRCP 37(e) defense — routine, documented, predating any dispute. That mechanism is
/// **legal** and it **destroys**.
///
/// Decay is neither. It is **functional** and it **hides**. A cold row is fully present: it
/// survives a litigation hold, it is returned by an explicit search, it can be revived by
/// being used, and its bytes never move. The two must not be merged even though both are
/// "the system forgetting things", because a decay pass that deleted would be spoliation
/// dressed as housekeeping, and a retention pass that only hid would be a compliance
/// failure. They are kept in separate files, with separate commands, on purpose.
///
/// ## The signal problem, stated honestly
///
/// FSRS needs retrievals to strengthen against, and **this system had never recorded one.**
/// Two years of capture and not a single row saying "you looked at this." So `access` is
/// new here, and what counts as a retrieval is a judgement call worth naming: a row
/// *surfaced* in a search result strengthens weakly, and a row *opened* strengthens fully.
/// The Remembrance Agent's finding argues the weak signal is real — Rhodes found that seeing
/// the one-line result usually triggers the memory without opening anything, so surfacing is
/// a retrieval even when nothing is clicked. Until the bar reports opens, most weight lands
/// on the weak signal, and every number below should be read with that in mind.
enum Decay {

    /// Default stability, in days, for a row that has never been retrieved.
    ///
    /// At `t = S` retrievability is exactly 0.9 by construction, so this is "how long before
    /// an untouched memory has decayed 10%". 60 days is deliberately generous: the cost of
    /// demoting something useful is a missed connection, and the cost of keeping something
    /// useless is one distractor among a hundred thousand.
    static let baseStability = 60.0
    /// Below this, a row goes cold.
    ///
    /// Worth doing the arithmetic rather than reading the number: `R < 0.30` needs
    /// `t/S > ln(0.30)/ln(0.9) = 11.4`, so at the base stability nothing goes cold until it
    /// has sat untouched for **686 days — nearly two years.** That is the intended
    /// aggressiveness. A single search resets the clock and raises `S`, so anything you have
    /// looked at even once this decade stays hot.
    static let floor = 0.30

    static func migrate(_ s: Store) {
        // The decay clock. `events.ts` is when the thing HAPPENED; this is when the store
        // received it, and only the second one measures neglect.
        //
        // The first run against the real corpus demoted 2,533 rows and every single one came
        // from the iPhone backup — 951 WhatsApp messages, 799 calendar entries, 686 calls,
        // and the samples were "Sydney Holt's Birthday" and "moms birthday". Their `ts` is
        // years old; they had been in this store for a week. Nothing had been neglected.
        //
        // Existing rows are backfilled to the migration moment rather than left to fall back
        // on `ts`, because the honest statement about a row whose arrival was never recorded
        // is "the clock starts when we started measuring". That makes the FIRST decay pass on
        // a backfilled corpus demote nothing, which is the correct answer and not a bug.
        let cols = s.rows("SELECT name FROM pragma_table_info('events');").compactMap { $0.first }
        if !cols.contains("ingested_at") {
            s.exec("ALTER TABLE events ADD COLUMN ingested_at INTEGER;")
        }
        s.exec("UPDATE events SET ingested_at = \(nowMicros()) WHERE ingested_at IS NULL;")
        s.exec("""
        CREATE TABLE IF NOT EXISTS memory_state(
          seq INTEGER PRIMARY KEY REFERENCES events(seq) ON DELETE CASCADE,
          stability REAL NOT NULL,
          last_access TEXT,
          accesses INTEGER NOT NULL DEFAULT 0,
          tier TEXT NOT NULL DEFAULT 'hot',       -- hot | cold
          pinned INTEGER NOT NULL DEFAULT 0,
          demoted_at TEXT
        ) STRICT;
        """)
        s.exec("CREATE INDEX IF NOT EXISTS ix_mem_tier ON memory_state(tier, seq);")
        s.exec("""
        CREATE TABLE IF NOT EXISTS access(
          seq INTEGER NOT NULL REFERENCES events(seq) ON DELETE CASCADE,
          at TEXT NOT NULL,
          kind TEXT NOT NULL                      -- surfaced | opened
        ) STRICT;
        """)
        s.exec("CREATE INDEX IF NOT EXISTS ix_access_seq ON access(seq, at);")
    }

    // MARK: - the curve

    /// `R = exp(ln(0.9) · t / S)` — Area F's form verbatim. At `t = S`, `R = 0.9`.
    static func retrievability(daysSince t: Double, stability S: Double) -> Double {
        guard S > 0 else { return 0 }
        return exp(log(0.9) * t / max(0.0001, S))
    }

    /// The spacing effect, which is the whole reason FSRS beats a fixed half-life.
    ///
    /// Stability grows by more when the thing retrieved was *nearly forgotten*: recalling
    /// something at R = 0.35 is a far stronger signal that it matters than recalling
    /// something you read an hour ago. A flat multiplier would give a row that is touched
    /// constantly unbounded stability while a row rescued from the edge gains the same
    /// little as everything else — exactly backwards.
    static func strengthen(stability S: Double, retrievability R: Double, weight: Double) -> Double {
        S * (1 + weight * (1 - R))
    }

    static let weights: [String: Double] = ["surfaced": 0.6, "opened": 2.0]

    // MARK: - accesses

    /// Recorded for every row a search returns. Cheap enough to be unconditional: one insert
    /// per hit, and the whole point is that the signal exists at all.
    static func record(_ s: Store, seqs: [Int64], kind: String) {
        guard !seqs.isEmpty else { return }
        migrate(s)
        let now = Ledger.now()
        s.exec("BEGIN;")
        for q in seqs {
            var st: OpaquePointer?
            sqlite3_prepare_v2(s.db, "INSERT INTO access(seq,at,kind) VALUES(?,?,?);", -1, &st, nil)
            sqlite3_bind_int64(st, 1, q); s.bind(st, 2, now); s.bind(st, 3, kind)
            sqlite3_step(st); sqlite3_finalize(st)

            // Strengthen, and revive: being retrieved is the one thing that brings a cold
            // row back. Demotion has to be reversible or it is deletion with extra steps.
            let cur = state(s, q)
            let newS = strengthen(stability: cur.stability,
                                  retrievability: cur.retrievability,
                                  weight: weights[kind] ?? 0.6)
            sqlite3_prepare_v2(s.db, """
                INSERT INTO memory_state(seq,stability,last_access,accesses,tier)
                VALUES(?,?,?,1,'hot')
                ON CONFLICT(seq) DO UPDATE SET
                  stability=excluded.stability, last_access=excluded.last_access,
                  accesses=memory_state.accesses+1, tier='hot', demoted_at=NULL;
                """, -1, &st, nil)
            sqlite3_bind_int64(st, 1, q); sqlite3_bind_double(st, 2, newS); s.bind(st, 3, now)
            sqlite3_step(st); sqlite3_finalize(st)
        }
        s.exec("COMMIT;")
    }

    struct State {
        let stability: Double, retrievability: Double
        let tier: String, pinned: Bool, accesses: Int
    }

    /// A row with no `memory_state` is not an error — it is simply one that has never been
    /// touched, and it decays from its own timestamp at the base stability.
    static func state(_ s: Store, _ seq: Int64) -> State {
        let r = s.rows("""
            SELECT coalesce(m.stability, \(baseStability)),
                   coalesce(m.last_access, strftime('%Y-%m-%dT%H:%M:%SZ', coalesce(e.ingested_at, e.ts)/1000000, 'unixepoch')),
                   coalesce(m.tier,'hot'), coalesce(m.pinned,0), coalesce(m.accesses,0)
            FROM events e LEFT JOIN memory_state m ON m.seq = e.seq WHERE e.seq = \(seq);
            """).first
        guard let r else { return State(stability: baseStability, retrievability: 1,
                                        tier: "hot", pinned: false, accesses: 0) }
        let S = Double(r[0]) ?? baseStability
        let days = daysSince(iso: r[1])
        return State(stability: S, retrievability: retrievability(daysSince: days, stability: S),
                     tier: r[2], pinned: r[3] == "1", accesses: Int(r[4]) ?? 0)
    }

    static func daysSince(iso: String) -> Double {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return 0 }
        return max(0, Date().timeIntervalSince(d) / 86_400)
    }

    // MARK: - the pass

    /// What must never decay, and why each one is on the list.
    ///
    /// Area F names three: **commitments until discharged, contradictions until resolved,
    /// anything pinned.** All three are now reachable — the commitment clause was written
    /// against a table that did not exist yet, and the Ledger daemon is what filled it.
    ///
    /// Evidence for a *confirmed* belief is added to the list. An unreviewed model guess is
    /// not a belief, so it is not protected; a belief the principal confirmed is the most
    /// load-bearing thing in the store, and demoting the evidence under it would leave a
    /// belief whose provenance you cannot see.
    static let immuneSQL = """
        SELECT seq FROM memory_state WHERE pinned = 1
        UNION
        -- A promise you have not kept is the last thing that should quietly go cold.
        SELECT seq FROM commitment WHERE status = 'open'
        UNION
        SELECT e.seq FROM belief_evidence e
          JOIN belief b ON b.belief_id = e.belief_id
         WHERE b.sys_to IS NULL AND b.confidence_src <> 'model_selfreport'
        UNION
        SELECT e.seq FROM belief_evidence e
          JOIN contradiction k ON k.status = 'open'
         WHERE e.belief_id IN (k.belief_a, k.belief_b)
        """

    struct Report {
        var considered = 0, demoted = 0, revived = 0, immune = 0
        var hist = [Int](repeating: 0, count: 10)
        var examples: [(Int64, Double, String)] = []
    }

    static func run(_ s: Store, apply: Bool, floor: Double, limit: Int) -> Report {
        migrate(s)
        var rep = Report()
        let immune = Set(s.rows(immuneSQL).compactMap { Int64($0[0]) })
        rep.immune = immune.count

        let rows = s.rows("""
            SELECT e.seq,
                   coalesce(m.stability, \(baseStability)),
                   coalesce(m.last_access, strftime('%Y-%m-%dT%H:%M:%SZ', coalesce(e.ingested_at, e.ts)/1000000, 'unixepoch')),
                   coalesce(m.tier,'hot'),
                   substr(coalesce(e.text,''),1,70)
            FROM events e LEFT JOIN memory_state m ON m.seq = e.seq
            WHERE e.ts BETWEEN \(Connect.tsFloor) AND \(Connect.tsCeil)
            LIMIT \(limit);
            """)
        var toDemote: [Int64] = [], toRevive: [Int64] = []
        for r in rows {
            guard let seq = Int64(r[0]) else { continue }
            rep.considered += 1
            let S = Double(r[1]) ?? baseStability
            let R = retrievability(daysSince: daysSince(iso: r[2]), stability: S)
            rep.hist[min(9, max(0, Int(R * 10)))] += 1
            let isImmune = immune.contains(seq)
            if isImmune { continue }
            if R < floor && r[3] == "hot" {
                toDemote.append(seq)
                if rep.examples.count < 8 { rep.examples.append((seq, R, r[4])) }
            } else if R >= floor && r[3] == "cold" {
                toRevive.append(seq)
            }
        }
        rep.demoted = toDemote.count; rep.revived = toRevive.count
        guard apply else { return rep }

        // Demotion writes a tier, never a DELETE. The row, its text, its vectors and its FTS
        // entry all stay exactly where they were.
        func setTier(_ seqs: [Int64], _ tier: String) {
            guard !seqs.isEmpty else { return }
            s.exec("BEGIN;")
            for q in seqs {
                var st: OpaquePointer?
                sqlite3_prepare_v2(s.db, """
                    INSERT INTO memory_state(seq,stability,tier,demoted_at)
                    VALUES(?, \(baseStability), ?, ?)
                    ON CONFLICT(seq) DO UPDATE SET tier=excluded.tier, demoted_at=excluded.demoted_at;
                    """, -1, &st, nil)
                sqlite3_bind_int64(st, 1, q); s.bind(st, 2, tier)
                s.bind(st, 3, tier == "cold" ? Ledger.now() : nil)
                sqlite3_step(st); sqlite3_finalize(st)
            }
            s.exec("COMMIT;")
        }
        setTier(toDemote, "cold"); setTier(toRevive, "hot")
        return rep
    }

    static func pin(_ s: Store, _ seq: Int64, _ on: Bool) {
        migrate(s)
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(s.db, """
            INSERT INTO memory_state(seq,stability,pinned,tier) VALUES(?, \(baseStability), ?, 'hot')
            ON CONFLICT(seq) DO UPDATE SET pinned=excluded.pinned,
              tier=CASE WHEN excluded.pinned=1 THEN 'hot' ELSE memory_state.tier END;
            """, -1, &st, nil)
        sqlite3_bind_int64(st, 1, seq); sqlite3_bind_int(st, 2, on ? 1 : 0)
        sqlite3_step(st)
    }

    /// The SQL fragment every candidate pool uses to skip cold rows. Demotion that changes
    /// nothing downstream is theatre — this is where it bites.
    static let hotOnlySQL = """
          NOT EXISTS (SELECT 1 FROM memory_state m WHERE m.seq = e.seq AND m.tier = 'cold')
        """
}
