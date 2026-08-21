import Foundation
import SQLite3
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The **Ledger daemon** — commitments, in both directions, until discharged.
///
/// Area F names this daemon "Ledger"; the file is `Promise.swift` because `Ledger.swift` is
/// already the bitemporal *belief* ledger and two things called Ledger in one binary is how
/// you get a bug nobody can describe.
///
/// This is the daemon with the most prior art and the most consistent conclusion. Enron
/// speech-act commitment detection (ACL W11-0711), MSR domain-adapted commitment detection
/// (WSDM 2019), SIGIR 2020 email intent, meeting AID (arXiv 2303.16763), and the
/// Cortana/Outlook lineage at ~90% precision on "create task" — **all of them conclude
/// precision beats recall**, and Area F puts a number on it: *tune to P ≈ 0.9 even at
/// R = 0.5.* A commitment tracker that invents obligations is worse than none, because the
/// user has to check every item and then stops reading.
///
/// So every claim this daemon makes is checked in code before it is stored, and the checks
/// are the same three that the previous four stages arrived at independently:
///
///   1. **Verbatim.** The quoted promise must occur in the message. The model does not get
///      to paraphrase, because a paraphrase cannot be verified.
///   2. **Commissive.** The quote must contain a first-person commissive marker. "I'll send
///      it Tuesday" is a promise; "that sounds great" is not, however confidently labelled.
///   3. **Consistent.** The capture path already knows who wrote the message. If the model
///      says the promise is the writer's and `trust` says the message is someone else's —
///      or the reverse — **the disagreement is not resolved, it is dropped.**
///
/// Check 3 exists because of a message in this corpus reading *"She said - I'll see what I
/// can learn on my end!!!"*. It is `trust='self'`, it contains a textbook commissive, and the
/// person making the promise is not the writer. That is the tapback bug in a new costume: the
/// principal sent the bytes, someone else owns the meaning.
enum Promise {

    static func migrate(_ s: Store) {
        s.exec("""
        CREATE TABLE IF NOT EXISTS commitment(
          commit_id TEXT PRIMARY KEY,
          seq INTEGER NOT NULL REFERENCES events(seq) ON DELETE CASCADE,
          direction TEXT NOT NULL,            -- mine | theirs
          counterparty TEXT,
          quote TEXT NOT NULL,                -- verbatim span, checked against the message
          action TEXT NOT NULL,
          due_phrase TEXT,
          ts INTEGER NOT NULL,                -- when it was made
          status TEXT NOT NULL DEFAULT 'open',-- open | discharged | dropped
          detected_at TEXT NOT NULL,
          resolved_at TEXT
        ) STRICT;
        """)
        s.exec("CREATE UNIQUE INDEX IF NOT EXISTS ux_commit_span ON commitment(seq, quote);")
        s.exec("CREATE INDEX IF NOT EXISTS ix_commit_open ON commitment(status, ts DESC);")
    }

    /// First-person commissive markers. A promise is a speech act with a grammatical
    /// signature, and this is it — the same list the prefilter uses to choose candidates,
    /// reused as the gate on what the model claims, so a "commitment" with no commissive in
    /// it cannot be stored no matter how sure the model sounds.
    static let commissives = ["i'll ", "i will ", "ill ", "i can ", "i could ", "let me ",
                              "i'm going to ", "im going to ", "i am going to ",
                              "i promise", "i'd be happy to", "i shall ", "we'll ", "we will ",
                              "i'll get", "i'll send", "i'll let you", "i'll be "]

    static func hasCommissive(_ t: String) -> Bool {
        let low = " " + t.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") + " "
        return commissives.contains { low.contains($0) }
    }

    /// Loose enough to catch the phrasings the marker list misses, tight enough that the
    /// model is not reading the whole corpus. Same shape as the belief extractor's: target
    /// the disclosure directly rather than scanning 100k rows at 0.8s each.
    static func candidates(_ s: Store, limit: Int, days: Int) -> [(Int64, String, String, String, Int64)] {
        let since = nowMicros() - Int64(days) * 86_400_000_000
        let like = commissives.map { "lower(e.text) LIKE '%\($0.replacingOccurrences(of: "'", with: "''"))%'" }
            .joined(separator: " OR ")
        return s.rows("""
            SELECT e.seq, e.text, e.trust, coalesce(e.title,''), e.ts
            FROM events e
            LEFT JOIN commitment c ON c.seq = e.seq
            WHERE e.trust IN ('self','third_party')
              AND length(e.text) BETWEEN 20 AND 1200
              AND e.ts >= \(since) AND e.ts <= \(Connect.tsCeil)
              AND c.seq IS NULL
              AND e.source IN ('imessage','gmail','imap','iphone.whatsapp')
              AND (\(like))
            ORDER BY e.ts DESC LIMIT \(limit);
            """).compactMap { r in
            guard let q = Int64(r[0]), let ts = Int64(r[4]) else { return nil }
            return (q, r[1], r[2], r[3], ts)
        }
    }

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Generable
    struct Detected {
        @Guide(description: "True only when someone is promising to do a specific thing they have not done yet.")
        var isCommitment: Bool
        @Guide(description: "The promise, copied word for word from the message, exactly as written.")
        var quote: String
        @Guide(description: "What was promised, as a short phrase starting with a verb.")
        var action: String
        @Guide(description: "The words in the message that say when it is due, or empty if none are given.")
        var duePhrase: String
        @Guide(description: "True when the person who wrote this message is the one making the promise. False when they are reporting someone else's promise.")
        var writerIsPromiser: Bool
    }

    static let instructions = """
        You are shown one message. Decide whether it contains a promise: someone saying they
        will do a specific thing that has not been done yet.

        A promise is "I'll send it Tuesday", "let me look into that", "I'll call you back".
        It is not "that sounds great", "thanks so much", "I think we should meet", or a
        description of something already finished.

        If there is a promise, copy it out of the message word for word, exactly as written.
        Do not tidy it, do not rephrase it, do not complete it. Then say who is making it: the
        person who wrote this message, or someone else they are quoting.
        """
    static var promptHash: String { sha(instructions).prefix(16).description }
#endif

    /// One write path, shared by the daemon and the tests, so a test cannot pass against
    /// SQL the daemon does not actually run.
    @discardableResult
    static func store(_ s: Store, seq: Int64, direction: String, counterparty: String?,
                      quote: String, action: String, due: String?, ts: Int64) -> String {
        let id = "cmt_" + sha("\(seq)|\(quote)").prefix(16)
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(s.db, """
            INSERT INTO commitment(commit_id,seq,direction,counterparty,quote,action,
                                   due_phrase,ts,status,detected_at)
            VALUES(?,?,?,?,?,?,?,?, 'open', ?)
            ON CONFLICT(seq,quote) DO NOTHING;
            """, -1, &st, nil)
        s.bind(st, 1, String(id)); sqlite3_bind_int64(st, 2, seq)
        s.bind(st, 3, direction); s.bind(st, 4, counterparty)
        s.bind(st, 5, quote); s.bind(st, 6, action); s.bind(st, 7, due)
        sqlite3_bind_int64(st, 8, ts); s.bind(st, 9, Ledger.now())
        sqlite3_step(st)
        return String(id)
    }

    struct Report {
        var scanned = 0, detected = 0, stored = 0, failed = 0
        var rejectedQuote = 0, rejectedCommissive = 0, rejectedDirection = 0
        var judgeFailed = false, lastError = ""
        var samples: [(String, String, String)] = []
    }

    @available(macOS 26.0, *)
    static func run(_ s: Store, limit: Int, days: Int, verbose: Bool) async -> Report {
        var rep = Report()
        migrate(s)
        let items = candidates(s, limit: limit, days: days)
        guard !items.isEmpty else { return rep }

#if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            print("Foundation Models unavailable"); return rep
        }
        for (seq, text, trust, title, ts) in items {
            rep.scanned += 1
            do {
                let r = try await LanguageModelSession(instructions: instructions)
                    .respond(to: "Message:\n\(text.prefix(900))", generating: Detected.self)
                guard r.content.isCommitment else { continue }
                rep.detected += 1
                let quote = r.content.quote.trimmingCharacters(in: .whitespacesAndNewlines)

                // 1. verbatim — the model may not paraphrase what it cannot be checked on
                guard quote.count >= 6,
                      Connect.normalizeTerm(text).contains(Connect.normalizeTerm(quote))
                else { rep.rejectedQuote += 1; continue }
                // 2. commissive — a promise has a grammatical signature
                guard hasCommissive(quote) else { rep.rejectedCommissive += 1; continue }
                // 3. consistent — the capture path already knows who wrote this message, so
                //    the only thing left to establish is whether the writer is also the one
                //    promising. When they are not, the promise belongs to somebody being
                //    quoted and there is no reliable way to say who: dropped, not guessed.
                //    Trust is assigned by capture path and is never overridden by a model.
                guard r.content.writerIsPromiser else { rep.rejectedDirection += 1; continue }
                let direction = trust == "self" ? "mine" : "theirs"
                store(s, seq: seq, direction: direction,
                      counterparty: title.isEmpty ? nil : title, quote: quote,
                      action: r.content.action,
                      due: r.content.duePhrase.isEmpty ? nil : r.content.duePhrase, ts: ts)
                rep.stored += 1
                if rep.samples.count < 10 { rep.samples.append((direction, quote, r.content.action)) }
                if verbose { print("    \(direction)  \"\(quote.prefix(70))\"  → \(r.content.action.prefix(40))") }
            } catch {
                rep.failed += 1
                rep.lastError = (error as NSError).localizedDescription
                if verbose { print("    detect failed: \(rep.lastError)") }
                if rep.detected == 0 && rep.failed >= 3 { rep.judgeFailed = true; break }
            }
        }
#endif
        return rep
    }

    /// A hand-labelled set, authored independently of the detector.
    ///
    /// §2's retracted round is the reason this is authored rather than sampled: an eval whose
    /// ground truth comes from the thing being evaluated is not an eval. Every line below is
    /// either taken verbatim from this corpus or written to match its register, and labelled
    /// before the detector was pointed at it.
    ///
    /// The negatives are the interesting half. They are not random sentences — they are the
    /// near-misses that a keyword filter cannot separate from a promise: a *request* ("let me
    /// know if…"), a *denial* of ability ("I don't think I can make it"), a *relayed*
    /// permission ("my mom said I can take her car"), and a *hedge* ("I'll have to see if…").
    /// Each one contains a textbook commissive marker and none of them is a commitment.
    static let labelled: [(String, Bool)] = [
        ("That works great for me, I'll give you a call at this number then. Thanks!", true),
        ("I'll send over the deck tomorrow morning once I've cleaned up the last two slides.", true),
        ("let me look into that and get back to you by Friday", true),
        ("I will review it today", true),
        ("Wait let me reinstall it", true),
        ("I'll keep your application on file and will reach out should our plans change.", true),
        ("Hey, let me know if you'd like to reschedule for next week.", false),
        ("I dont think i can make it tn my parents are still not home from work", false),
        ("My mom said i can take her car", false),
        ("Ok i dont have a car rn so i'll have to see if i can use my moms car", false),
        ("Take a look on your phone and on a computer if you can.", false),
        ("thank you so much, I can use those photos", false),
    ]

    struct Eval { var tp = 0, fp = 0, fn = 0, tn = 0, failed = 0
        var precision: Double { tp + fp == 0 ? 0 : Double(tp) / Double(tp + fp) }
        var recall: Double { tp + fn == 0 ? 0 : Double(tp) / Double(tp + fn) }
    }

    @available(macOS 26.0, *)
    static func evaluate(verbose: Bool) async -> Eval {
        var e = Eval()
#if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return e }
        for (text, want) in labelled {
            do {
                let r = try await LanguageModelSession(instructions: instructions)
                    .respond(to: "Message:\n\(text)", generating: Detected.self)
                // The stored decision is the one under test, checks included — not the
                // model's raw flag. Measuring the flag alone would flatter the detector by
                // crediting it for answers the checks would have thrown away.
                let quote = r.content.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                let got = r.content.isCommitment
                    && quote.count >= 6
                    && Connect.normalizeTerm(text).contains(Connect.normalizeTerm(quote))
                    && hasCommissive(quote)
                    && r.content.writerIsPromiser
                switch (want, got) {
                case (true, true): e.tp += 1
                case (false, true): e.fp += 1
                case (true, false): e.fn += 1
                case (false, false): e.tn += 1
                }
                if verbose {
                    let mark = want == got ? "✓" : "✗"
                    print("    \(mark) want=\(want ? "commit " : "not    ") got=\(got ? "commit " : "not    ")  \(text.prefix(64))")
                }
            } catch { e.failed += 1 }
        }
#endif
        return e
    }

    struct Open {
        let id, direction, quote, action, due, who: String
        let ts: Int64
        var ageDays: Int { Int((nowMicros() - ts) / 86_400_000_000) }
    }

    static func open(_ s: Store, limit: Int, direction: String? = nil) -> [Open] {
        let dir = direction.map { " AND direction='\(Ledger.esc($0))'" } ?? ""
        return s.rows("""
            SELECT commit_id, direction, quote, action, coalesce(due_phrase,''),
                   coalesce(counterparty,''), ts
            FROM commitment WHERE status='open'\(dir)
            ORDER BY ts ASC LIMIT \(limit);
            """).map {
            Open(id: $0[0], direction: $0[1], quote: $0[2], action: $0[3], due: $0[4],
                 who: $0[5], ts: Int64($0[6]) ?? 0)
        }
    }

    static func resolve(_ s: Store, id: String, status: String) -> Bool {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(s.db, """
            UPDATE commitment SET status=?, resolved_at=? WHERE commit_id=? AND status='open';
            """, -1, &st, nil)
        s.bind(st, 1, status); s.bind(st, 2, Ledger.now()); s.bind(st, 3, id)
        sqlite3_step(st)
        return sqlite3_changes(s.db) > 0
    }
}
