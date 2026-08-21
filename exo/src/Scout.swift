import Foundation
import SQLite3
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The **Scout** daemon — standing questions, watching the stream.
///
/// Area F's spec is *nightly + new open question · SLM filter → frontier on survivors ·
/// primary failure mode is question rot — auto-expire after 60 d.* Half of that pipeline
/// cannot run here and the file says so up front: "frontier on survivors" means sending the
/// question out to a large model to actually research, and the corpus's non-negotiable
/// property is that nothing leaves the machine. What CAN run locally is the memory-side
/// Scout — the half no web service can be: **you wondered about something on the 3rd, and
/// something bearing on it crossed your stream on the 19th.** Registration, retrieval,
/// verification, rot.
///
/// The pieces are all reused, which is the point of having measured them:
///
///   * **Search keys are the question's rare terms** — §7's `corpusFrequency` over FTS5.
///     A question is prose, and FTS5's implicit-AND over ten words of prose matches
///     nothing; its *rare* terms are what discriminate. Measured on this corpus: `int8`
///     appears in 7 events and `rescore` in 16, while `what` appears in 3,865 — the split
///     chooses its own keys.
///   * **The model's claim is a verbatim quote, verified in code** — §10's gate. A hit is
///     stored only when the quoted span actually occurs in the event; the model that
///     confabulated 38 of 40 shared terms does not get to paraphrase here either.
///   * **Question rot is the lifecycle, enforced at scan time.** A question not answered
///     in 60 days expires automatically. Area F calls rot the failure mode that kills
///     Scout — stale questions accumulating forever, each one a standing source of noise —
///     and the fix is that expiry is not a suggestion: expired questions are not scanned,
///     full stop.
///
/// One guard that exists because of how this corpus is fed: the question itself is typed
/// into a terminal that Claude Code transcribes, so within a day the corpus contains the
/// registration ("exo wonder …") verbatim — and the question's best match would be itself.
/// A hit whose text contains the question is self-echo and is dropped.
enum Scout {

    /// Area F: auto-expire after 60 days.
    static let rotDays = 60
    /// Candidates offered to the model per question per scan, best BM25 first.
    static let maxCandidates = 8

    static func migrate(_ s: Store) {
        s.exec("""
        CREATE TABLE IF NOT EXISTS question(
          q_id TEXT PRIMARY KEY,
          text TEXT NOT NULL,
          asked_at TEXT NOT NULL,
          expires_at TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'open',   -- open | answered | expired
          answer TEXT, resolved_at TEXT,
          last_scanned_seq INTEGER NOT NULL DEFAULT 0
        ) STRICT;
        """)
        s.exec("""
        CREATE TABLE IF NOT EXISTS question_hit(
          q_id TEXT NOT NULL REFERENCES question(q_id) ON DELETE CASCADE,
          seq INTEGER NOT NULL REFERENCES events(seq) ON DELETE CASCADE,
          quote TEXT NOT NULL,                   -- verbatim span, verified against the event
          note TEXT,
          found_at TEXT NOT NULL,
          surfaced_at TEXT,
          PRIMARY KEY (q_id, seq)
        ) STRICT;
        """)
        s.exec("CREATE INDEX IF NOT EXISTS ix_qhit_fresh ON question_hit(surfaced_at, found_at DESC);")
    }

    // MARK: - lifecycle

    @discardableResult
    static func register(_ s: Store, text: String, askedAt: Date = Date()) -> String {
        migrate(s)
        let id = "qst_" + sha(text + ISO8601DateFormatter().string(from: askedAt)).prefix(12)
        let f = ISO8601DateFormatter()
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(s.db, """
            INSERT INTO question(q_id,text,asked_at,expires_at) VALUES(?,?,?,?);
            """, -1, &st, nil)
        s.bind(st, 1, String(id)); s.bind(st, 2, text)
        s.bind(st, 3, f.string(from: askedAt))
        s.bind(st, 4, f.string(from: askedAt.addingTimeInterval(Double(rotDays) * 86_400)))
        sqlite3_step(st)
        return String(id)
    }

    /// Rot, enforced. Runs first in every scan so an expired question is never scanned —
    /// not even the scan that expires it.
    @discardableResult
    static func expireRotted(_ s: Store, now: String = Ledger.now()) -> Int {
        s.exec("""
            UPDATE question SET status='expired', resolved_at='\(Ledger.esc(now))'
            WHERE status='open' AND expires_at < '\(Ledger.esc(now))';
            """)
        return sqlite3_changes(s.db) > 0 ? Int(sqlite3_changes(s.db)) : 0
    }

    static func answer(_ s: Store, id: String, text: String) -> Bool {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(s.db, """
            UPDATE question SET status='answered', answer=?, resolved_at=?
            WHERE q_id=? AND status='open';
            """, -1, &st, nil)
        s.bind(st, 1, text); s.bind(st, 2, Ledger.now()); s.bind(st, 3, id)
        sqlite3_step(st)
        return sqlite3_changes(s.db) > 0
    }

    struct Question {
        let id, text, askedAt, expiresAt: String
        let cursor: Int64
        var daysLeft: Int {
            let f = ISO8601DateFormatter()
            guard let e = f.date(from: expiresAt) else { return 0 }
            return max(0, Int(e.timeIntervalSince(Date()) / 86_400))
        }
    }

    static func open(_ s: Store) -> [Question] {
        s.rows("""
            SELECT q_id, text, asked_at, expires_at, last_scanned_seq
            FROM question WHERE status='open' ORDER BY asked_at;
            """).map {
            Question(id: $0[0], text: $0[1], askedAt: $0[2], expiresAt: $0[3],
                     cursor: Int64($0[4]) ?? 0)
        }
    }

    // MARK: - retrieval

    /// The question's rare terms, which are its search keys. Terms that appear nowhere
    /// find nothing and are skipped; terms that appear everywhere discriminate nothing and
    /// are skipped; what remains, lowest frequency first, is the query.
    static func searchKeys(_ s: Store, _ question: String,
                           ceiling: Int = 2000, limit: Int = 6) -> [(String, Int)] {
        var seen = Set<String>(), out: [(String, Int)] = []
        var cur = ""
        let joiners = Set("-./_".unicodeScalars)
        func flush() {
            let w = cur.trimmingCharacters(in: CharacterSet(charactersIn: "-./_"))
            cur = ""
            guard w.count >= 3, w.rangeOfCharacter(from: .letters) != nil,
                  !seen.contains(w) else { return }
            seen.insert(w)
            let f = Connect.corpusFrequency(s, w)
            if f >= 1 && f <= ceiling { out.append((w, f)) }
        }
        for u in question.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) || joiners.contains(u) {
                cur.unicodeScalars.append(u)
            } else { flush() }
        }
        flush()
        return Array(out.sorted { $0.1 < $1.1 }.prefix(limit))
    }

    struct Cand { let seq: Int64; let text, source, trust: String }

    /// BM25 over the question's keys, above the cursor, eligible text only, self-echo out.
    static func candidates(_ s: Store, _ q: Question, keys: [(String, Int)]) -> [Cand] {
        guard !keys.isEmpty else { return [] }
        let match = keys.map { "\"\($0.0.replacingOccurrences(of: "\"", with: ""))\"" }
            .joined(separator: " OR ")
        let rows = s.rows("""
            SELECT e.seq, coalesce(e.text,''), e.source, e.trust
            FROM events_fts f JOIN events e ON e.seq = f.rowid
            WHERE events_fts MATCH '\(Ledger.esc(match))'
              AND e.seq > \(q.cursor)
              AND e.ts BETWEEN \(Connect.tsFloor) AND \(Connect.tsCeil)
              AND \(Connect.eligibleSQL)
            ORDER BY bm25(events_fts) LIMIT \(maxCandidates * 3);
            """)
        let qNorm = Connect.normalizeTerm(q.text)
        var out: [Cand] = []
        for r in rows {
            guard out.count < maxCandidates, let seq = Int64(r[0]) else { continue }
            guard !Connect.looksAutomated(r[1]) else { continue }
            // Self-echo: the registration and any discussion OF the question contain the
            // question; a hit that contains the question is the question coming back.
            guard !Connect.normalizeTerm(r[1]).contains(qNorm) else { continue }
            out.append(Cand(seq: seq, text: r[1], source: r[2], trust: r[3]))
        }
        return out
    }

    // MARK: - the model's one job, gated the measured way

    /// Relevance is decided by rarity, in code — the model is never asked.
    ///
    /// The first sweep asked it: a `bears: Bool`, with instructions warning that "most
    /// passages that share a word with a question have nothing to say about it." It
    /// declined **8 of 8** — including the passage that reads *"the rescore improves
    /// retrieval"*, offered against the question *"what did the int8 rescore tier turn out
    /// to be good for."* That is the third sighting of the same animal: primed toward the
    /// cautious answer, this model gives it near-constantly — 14/14 `scope_difference` in
    /// §6, an escape hatch used 0/39 in §7, 8/8 "does not bear" here.
    ///
    /// So the decision moved into arithmetic that already existed. A question carries two
    /// bands of keys: **wide** (≤ 2,000 occurrences) for retrieval recall, and **tight**
    /// (≤ 60, §7's rarity ceiling) for relevance. A candidate bears on the question iff it
    /// contains a tight key. On the live sweep this separates perfectly with no model in
    /// the loop: the six rescore-saga transcripts all contain `int8`×7 or `rescore`×16 and
    /// pass; the NSBE group-chat tapbacks matched via `good`×1,595 and `did`×1,266 and
    /// fail; *"top-tier needs to mean ruthlessly prioritized"* matched `tier`×189 and
    /// fails. A question with no tight keys at all is reported as too broad to confirm
    /// sightings for, rather than guessed at — precision over recall, the daemon rule.
    static let tightCeiling = 60

    static func bearsOnQuestion(_ text: String, tightKeys: [String]) -> Bool {
        guard !tightKeys.isEmpty else { return false }
        let norm = " " + Connect.normalizeTerm(text) + " "
        return tightKeys.contains { norm.contains(" " + Connect.normalizeTerm($0) + " ") }
    }

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Generable
    struct Sighting {
        @Guide(description: "The span of the passage most about the question, copied word for word, exactly as written.")
        var quote: String
        @Guide(description: "One sentence on what the passage says about the question.")
        var note: String
    }

    static let instructions = """
        You are shown a question someone is holding open, and one passage from their
        records that bears on it.

        Copy the span of the passage most about the question, word for word, exactly as
        written. Do not tidy it, do not rephrase it, do not complete it. Then say in one
        sentence what it tells them about their question.
        """
    static var promptHash: String { sha(instructions).prefix(16).description }
#endif

    struct Report {
        var questions = 0, expired = 0, candidates = 0, judged = 0
        var stored = 0, rejectedQuote = 0, noTightKey = 0, broad = 0, failed = 0
        var judgeFailed = false, lastError = ""
    }

    @available(macOS 26.0, *)
    static func scan(_ s: Store, verbose: Bool) async -> Report {
        var rep = Report()
        migrate(s)
        rep.expired = expireRotted(s)
        let qs = open(s)
        rep.questions = qs.count
        guard !qs.isEmpty else { return rep }
        let maxSeq = Int64(s.scalar("SELECT coalesce(max(seq),0) FROM events;"))

#if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            rep.judgeFailed = true; rep.lastError = "Foundation Models unavailable"; return rep
        }
        for q in qs {
            let keys = searchKeys(s, q.text)
            let tight = keys.filter { $0.1 <= tightCeiling }.map(\.0)
            if tight.isEmpty {
                rep.broad += 1
                if verbose { print("  \(q.text.prefix(64))\n    no term rarer than \(tightCeiling) — too broad to confirm sightings; watching anyway") }
                continue    // the cursor holds: a later, sharper corpus may discriminate
            }
            let cands = candidates(s, q, keys: keys)
            rep.candidates += cands.count
            if verbose && !cands.isEmpty {
                print("  \(q.text.prefix(64))")
                print("    keys: \(keys.map { "\($0.0)×\($0.1)" }.joined(separator: " "))  tight: \(tight.joined(separator: " "))")
            }
            for c in cands {
                // Relevance, by construction. The model is not asked whether this bears —
                // see `bearsOnQuestion` for the 8-of-8 refusal that decided this.
                guard bearsOnQuestion(c.text, tightKeys: tight) else { rep.noTightKey += 1; continue }
                do {
                    let r = try await LanguageModelSession(instructions: instructions)
                        .respond(to: "QUESTION: \(q.text)\n\nPASSAGE (\(c.source)):\n\(c.text.prefix(700))",
                                 generating: Sighting.self)
                    rep.judged += 1
                    let quote = r.content.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                    // §10's gate, verbatim: the claim must be checkable, and a quote that
                    // is not in the passage is not a sighting however plausible the note.
                    guard quote.count >= 8,
                          Connect.normalizeTerm(c.text).contains(Connect.normalizeTerm(quote))
                    else { rep.rejectedQuote += 1; continue }
                    var st: OpaquePointer?
                    sqlite3_prepare_v2(s.db, """
                        INSERT INTO question_hit(q_id,seq,quote,note,found_at)
                        VALUES(?,?,?,?,?)
                        ON CONFLICT(q_id,seq) DO NOTHING;
                        """, -1, &st, nil)
                    s.bind(st, 1, q.id); sqlite3_bind_int64(st, 2, c.seq)
                    s.bind(st, 3, quote); s.bind(st, 4, r.content.note)
                    s.bind(st, 5, Ledger.now())
                    sqlite3_step(st); sqlite3_finalize(st)
                    if sqlite3_changes(s.db) > 0 { rep.stored += 1 }
                    if verbose { print("    ✓ [\(c.seq)] \"\(quote.prefix(70))\"") }
                } catch {
                    rep.failed += 1
                    rep.lastError = (error as NSError).localizedDescription
                    if rep.judged == 0 && rep.failed >= 3 { rep.judgeFailed = true; break }
                }
            }
            if rep.judgeFailed { break }
            // The cursor advances to the top of the corpus whether or not anything was
            // found: retrieval IS the filter, and what BM25 did not rank into the
            // candidate window was examined and not chosen, not skipped.
            s.exec("UPDATE question SET last_scanned_seq=\(maxSeq) WHERE q_id='\(Ledger.esc(q.id))';")
        }
#endif
        return rep
    }

    // MARK: - surfacing

    struct Fresh { let qid, question, quote, note, source, day: String; let seq: Int64 }

    static func forBrief(_ s: Store, limit: Int) -> [Fresh] {
        s.rows("""
            SELECT h.q_id, q.text, h.quote, coalesce(h.note,''), e.source,
                   strftime('%Y-%m-%d', e.ts/1000000, 'unixepoch', 'localtime'), h.seq
            FROM question_hit h
            JOIN question q ON q.q_id = h.q_id AND q.status='open'
            JOIN events e ON e.seq = h.seq
            WHERE h.surfaced_at IS NULL
            ORDER BY h.found_at DESC LIMIT \(limit);
            """).compactMap {
            guard let seq = Int64($0[6]) else { return nil }
            return Fresh(qid: $0[0], question: $0[1], quote: $0[2], note: $0[3],
                         source: $0[4], day: $0[5], seq: seq)
        }
    }

    static func markSurfaced(_ s: Store, _ pairs: [(String, Int64)]) {
        for (qid, seq) in pairs {
            s.exec("""
                UPDATE question_hit SET surfaced_at='\(Ledger.now())'
                WHERE q_id='\(Ledger.esc(qid))' AND seq=\(seq);
                """)
        }
    }
}
