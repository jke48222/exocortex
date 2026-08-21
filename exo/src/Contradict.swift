import Foundation
import SQLite3
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Contradiction detection — S4 of the dream cycle, and the one surface in this project
/// that *pushes*.
///
/// PASS-4 Area E's finding is the entire design: **most detected contradictions are context
/// changes.** A system that pings you daily about fake contradictions gets muted in a
/// fortnight, and a muted feature is a deleted feature. So the output is never "these
/// disagree" — it is one of four verdicts, and three of them mean *nothing is wrong*.
///
/// Four stages, cheapest first:
///
///   1. **SQL** — pairs whose BELIEF INTERVALS OVERLAP. This is the gate that only a
///      bitemporal ledger can offer, and it is doing most of the work: if I believed P in
///      2024 and not-P in 2026, that is evolution and there is nothing to review. A
///      contradiction is the ledger asserting I hold P and not-P *at the same moment*.
///   2. **Similarity band** — are the two statements even about the same thing? Measured,
///      not assumed; see `band` below for the numbers and the one that failed.
///   3. **Four-way classification** — on-device, and the four verdicts are a `@Generable`
///      enum, so a fifth answer is unrepresentable rather than merely discouraged.
///   4. **Human confirmation** — `exo contra-resolve`. Stages 1–3 fill a queue; only a
///      person changes the ledger.
enum Contradict {

    // MARK: - stage 2 calibration
    //
    // Area E specifies a DeBERTa NLI filter here. There isn't one on this machine, so the
    // first attempt used `NLEmbedding` — free, on-device, already linked. **It does not
    // work**, and the measurement is worth keeping:
    //
    //     pair type                       NLEmbedding      Qwen3 int8@256
    //     contradictory, same topic       -0.13 … 0.13     0.69 … 0.75
    //     same topic, different scope      0.01            0.60
    //     unrelated                       -0.26 … -0.19    0.43 … 0.46
    //
    // NLEmbedding puts real contradictions *inside* the unrelated range — no threshold
    // separates them, at any value. The retrieval stack's own Qwen3 vectors separate
    // cleanly with a 0.135 margin, so the filter reuses them and the sidecar protocol is
    // unchanged.
    //
    // The surprise: **the int8 rescore tier separates better than full float** (0.135 vs
    // 0.090 margin). Truncating 1024 dims to 256 drops dimensions that were contributing
    // noise to short sentences. The tier built for retrieval rescoring turns out to be the
    // right resolution for comparing beliefs; the 256-bit BINARY tier is not — it collapses
    // the scope case (0.398) onto unrelated (0.391) and would filter out real findings.
    static let minSim = 0.55        // below: not about the same thing
    static let maxSim = 0.95        // above: a near-duplicate, which is not a disagreement

    struct Pair {
        let a, b: String            // belief ids, a < b
        let textA, textB: String
        let subjA, predA, subjB, predB: String
        let objA, objB: String
        let polA, polB: Int
        let scopeA, scopeB: String
        let fromA, fromB: String
        let toA, toB: String
        var sim: Double = 0
        /// Same proposition asserted both ways. No embedding can talk us out of this one —
        /// but only when the triple actually names a proposition.
        ///
        /// A non-empty object is required, and that requirement is the whole point.
        /// Elicitation records everything as (me, states, NULL): with the object dropped,
        /// "I hate driving at night" and "I don't drink anymore" share a subject and a
        /// predicate and differ in polarity, so every negated `exo tell` would fast-path
        /// past the similarity band and reach the model as a suspected contradiction with
        /// every positive one. A degenerate triple carries no proposition, so the text has
        /// to be judged on its own and the band stays in charge.
        var structural: Bool {
            polA != polB && subjA == subjB && predA == predB
                && !objA.isEmpty && objA == objB
        }
        var earlier: String { fromA <= fromB ? a : b }
        var later: String { fromA <= fromB ? b : a }
    }

    // MARK: - stage 1: SQL candidates

    /// Pairs the ledger currently asserts SIMULTANEOUSLY.
    ///
    /// Every clause here is a way of saying "this is not a contradiction":
    ///   * different claims — the same claim held twice is not a disagreement with itself
    ///   * both system-live — a superseded row is what the machine *used* to think
    ///   * neither supersedes the other — that succession is already recorded
    ///   * belief intervals overlap — otherwise it is a change over time
    ///   * valid intervals overlap when both are bounded — "ships in March 2025" and "does
    ///     not ship in March 2026" are two facts about different years, not a conflict
    ///   * not already resolved — a verdict is final until new evidence supersedes a row
    static func candidates(_ s: Store, includeUnconfirmed: Bool, limit: Int) -> [Pair] {
        let conf = includeUnconfirmed ? "" :
            "AND a.confidence_src <> 'model_selfreport' AND b.confidence_src <> 'model_selfreport'"
        let sql = """
        SELECT a.belief_id, b.belief_id, ca.norm_text, cb.norm_text,
               ca.subject, ca.predicate, cb.subject, cb.predicate,
               coalesce(ca.object,''), coalesce(cb.object,''),
               ca.polarity, cb.polarity,
               coalesce(ca.scope,''), coalesce(cb.scope,''),
               a.belief_from, b.belief_from,
               coalesce(a.belief_to,''), coalesce(b.belief_to,'')
        FROM belief a
        JOIN belief b ON b.belief_id > a.belief_id AND b.holder = a.holder
        JOIN claim ca ON ca.claim_id = a.claim_id
        JOIN claim cb ON cb.claim_id = b.claim_id
        WHERE a.sys_to IS NULL AND b.sys_to IS NULL
          AND a.claim_id <> b.claim_id
          AND coalesce(a.supersedes,'') <> b.belief_id
          AND coalesce(b.supersedes,'') <> a.belief_id
          \(conf)
          -- belief-time overlap: '' is an open interval, and sorts below every ISO date,
          -- so it is compared as the maximum rather than the minimum.
          AND a.belief_from < coalesce(b.belief_to, '9999')
          AND b.belief_from < coalesce(a.belief_to, '9999')
          -- valid-time overlap, only when BOTH sides are bounded. Unbounded means "no
          -- claim about when", which cannot rule a pair out.
          AND NOT (a.valid_to IS NOT NULL AND b.valid_from IS NOT NULL
                   AND a.valid_to <= b.valid_from)
          AND NOT (b.valid_to IS NOT NULL AND a.valid_from IS NOT NULL
                   AND b.valid_to <= a.valid_from)
          AND NOT EXISTS (SELECT 1 FROM contradiction k
                          WHERE k.belief_a = a.belief_id AND k.belief_b = b.belief_id
                            AND k.status <> 'open')
        LIMIT \(limit);
        """
        // Spelled out rather than passed inline: a 16-argument initializer built from
        // subscripts makes the type-checker give up ("unable to type-check this expression
        // in reasonable time"), and it fails as a hard error, not a warning.
        var out: [Pair] = []
        for r in s.rows(sql) {
            let pa: Int = Int(r[10]) ?? 1
            let pb: Int = Int(r[11]) ?? 1
            out.append(Pair(a: r[0], b: r[1], textA: r[2], textB: r[3],
                            subjA: r[4], predA: r[5], subjB: r[6], predB: r[7],
                            objA: r[8], objB: r[9],
                            polA: pa, polB: pb,
                            scopeA: r[12], scopeB: r[13],
                            fromA: r[14], fromB: r[15], toA: r[16], toB: r[17]))
        }
        return out
    }

    // MARK: - stage 2: similarity band

    /// Embed every belief text that the candidate set touches, cache it, and score pairs.
    ///
    /// Cached on `text_hash` so a nightly re-scan pays the model-load cost once and the
    /// per-belief cost never again. Returns `nil` when the sidecar is unavailable, which
    /// the caller reports rather than silently treating as "no contradictions" — a filter
    /// that fails closed and stays quiet is indistinguishable from a clean bill of health.
    static func score(_ s: Store, _ pairs: [Pair]) -> [Pair]? {
        guard !pairs.isEmpty else { return [] }
        var need: [String: String] = [:]                 // belief_id -> text
        for p in pairs { need[p.a] = p.textA; need[p.b] = p.textB }

        var vecs: [String: [Int8]] = [:]
        var missing: [(String, String)] = []
        for (bid, text) in need {
            let h = sha(text).prefix(16).description
            let hit = s.rows("""
                SELECT i8 FROM belief_vec
                WHERE belief_id='\(Ledger.esc(bid))' AND text_hash='\(h)'
                  AND provider='\(Embed.qwenProvider)';
                """).first?.first
            if let hex = hit { vecs[bid] = unhex(hex).map { Int8(bitPattern: $0) } }
            else { missing.append((bid, text)) }
        }

        if !missing.isEmpty {
            guard let session = EmbedMLX.Session(bits: 256) else { return nil }
            defer { session.close() }
            let order = missing.enumerated().map { (Int64($0.offset), $0.element.1) }
            let out = session.embed(order)
            guard !out.isEmpty else { return nil }
            for r in out where !r.i8.isEmpty {
                let (bid, text) = missing[Int(r.id)]
                vecs[bid] = r.i8
                var st: OpaquePointer?
                sqlite3_prepare_v2(s.db, """
                    INSERT OR REPLACE INTO belief_vec(belief_id,provider,dim,text_hash,i8)
                    VALUES(?,?,?,?,?);
                    """, -1, &st, nil)
                s.bind(st, 1, bid); s.bind(st, 2, Embed.qwenProvider)
                sqlite3_bind_int(st, 3, Int32(r.i8.count))
                s.bind(st, 4, sha(text).prefix(16).description)
                s.bind(st, 5, hex(r.i8.map { UInt8(bitPattern: $0) }))
                sqlite3_step(st); sqlite3_finalize(st)
            }
        }

        return pairs.map { p in
            var q = p
            if let x = vecs[p.a], let y = vecs[p.b] { q.sim = cosine(x, y) }
            return q
        }
    }

    /// Uncached, one batch, order preserved. Used for the per-pair questions, which are
    /// regenerated on every scan and so have nothing worth caching.
    static func embedTexts(_ texts: [String]) -> [[Int8]]? {
        guard !texts.isEmpty else { return [] }
        guard let session = EmbedMLX.Session(bits: 256) else { return nil }
        defer { session.close() }
        let out = session.embed(texts.enumerated().map { (Int64($0.offset), $0.element) })
        guard !out.isEmpty else { return nil }
        var byID = [Int64: [Int8]]()
        for r in out { byID[r.id] = r.i8 }
        return (0..<texts.count).map { byID[Int64($0)] ?? [] }
    }

    static func cosine(_ x: [Int8], _ y: [Int8]) -> Double {
        let n = min(x.count, y.count)
        guard n > 0 else { return 0 }
        var dot = 0.0, nx = 0.0, ny = 0.0
        for i in 0..<n {
            let a = Double(x[i]), b = Double(y[i])
            dot += a * b; nx += a * a; ny += b * b
        }
        guard nx > 0, ny > 0 else { return 0 }
        return dot / (nx.squareRoot() * ny.squareRoot())
    }

    private static func hex(_ b: [UInt8]) -> String {
        b.map { String(format: "%02x", $0) }.joined()
    }
    private static func unhex(_ h: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(h.count / 2)
        var i = h.startIndex
        while i < h.endIndex, let j = h.index(i, offsetBy: 2, limitedBy: h.endIndex) {
            out.append(UInt8(h[i..<j], radix: 16) ?? 0); i = j
        }
        return out
    }

    // MARK: - stage 3: four-way classification

#if canImport(FoundationModels)
    /// The four verdicts as a type. Area E's rule is *"default to SCOPE when uncertain"* —
    /// but the prior failure mode in this codebase was a `@Guide` description listing
    /// example values and the model copying them. An enum sidesteps that entirely: the case
    /// names are the schema, not a suggestion inside a description, and a fifth answer is
    /// not representable.
    @available(macOS 26.0, *)
    @Generable
    enum Verdict: String {
        case genuine_change
        case scope_difference
        case extraction_error
        case both_true
    }

    @available(macOS 26.0, *)
    @Generable
    struct Judgement {
        @Guide(description: "Which of the four relationships holds between the two statements.")
        var verdict: Verdict
        @Guide(description: "One sentence, referring to what the two statements actually say, explaining the choice.")
        var reason: String
        @Guide(description: "The situation the FIRST statement holds in. Empty unless the two hold in different situations.")
        var situationA: String
        @Guide(description: "The situation the SECOND statement holds in, which must be a different situation from the first. Empty unless the two hold in different situations.")
        var situationB: String
    }

    /// Above this, the model gave the two statements the SAME question — see `sameQuestion`.
    static let questionIdentity = 0.95

    /// A SEPARATE call, and separate is the whole point.
    ///
    /// Folding these two fields into `Judgement` looked like a free saving — one model call
    /// instead of two — and it destroyed the signal. Asked in isolation what question each
    /// statement answers, the model wrote *the identical sentence twice* for "I work best
    /// completely alone" / "I do my best work surrounded by other people": qsim 1.000. Asked
    /// as part of the four-way prompt, it wrote questions that already contained its verdict
    /// — "…when working with others" — and qsim fell to 0.830, below the threshold, so the
    /// test never fired.
    ///
    /// The judgement contaminates the description when one call has to do both. Describing
    /// has to be the model's only job for the description to be worth anything.
    @available(macOS 26.0, *)
    @Generable
    struct Framing {
        @Guide(description: "The question about the person that the FIRST statement answers.")
        var questionA: String
        @Guide(description: "The question about the person that the SECOND statement answers.")
        var questionB: String
    }

    static let framingInstructions = """
        You are given two statements a person wrote about themselves.
        For each statement on its own, write the question about the person that it answers.
        Describe only. Do not compare the two statements and do not say whether they agree.
        """

    /// One field, split in two, is what makes this work.
    ///
    /// The first version asked for a single `discriminator` — "the thing that tells the
    /// situations apart" — and got **zero** `genuine_change` verdicts on a fixture built
    /// around a head-on contradiction. "I work best completely alone" against "I do my best
    /// work surrounded by other people" came back `scope_difference`, discriminator:
    /// **"work environment"**. That is the topic the two statements *share*, offered as the
    /// thing that separates them. The model was labelling the axis of disagreement and
    /// calling it a scope, and one free-text field let it.
    ///
    /// Asking for situation A and situation B *separately* removes the room to do that:
    /// "work environment" cannot be filled in twice, and writing "when alone" against "when
    /// with others" is visibly a contradiction rather than a context. Anything that still
    /// gets through is caught in `scan`, where an unjustified `scope_difference` is
    /// escalated to the human queue instead of being quietly closed.
    ///
    /// The prior still leans toward the harmless answer, as Area E requires — a feature that
    /// pings you daily about fake contradictions gets muted in a fortnight. But leaning is
    /// not the same as never answering, and the first prompt could not answer at all.
    static let instructions = """
        Two statements were recorded as things the same person believed at the same time.
        Decide how they relate.

        Start by asking: could one reasonable person hold both of these at once?

        both_true        — yes, easily. They are about different things, or they are two
                           parts of one nuanced position.
        scope_difference — yes, but only because each holds in a DIFFERENT SITUATION: a
                           different place, role, job, relationship, time of day, or kind of
                           work. You must be able to name situation A and situation B
                           separately, and they must be different situations. The topic the
                           two statements are both about is not a situation.
        genuine_change   — no. They are about the same thing, they disagree, and no
                           situation makes both true at once. The person changed their mind.
        extraction_error — one of them is garbled, is about someone else, or is not a belief
                           at all. The machine misread something.

        Prefer scope_difference over genuine_change whenever you can name the two
        situations. When you cannot name them, do not choose scope_difference.
        """
    static var promptHash: String { sha(instructions).prefix(16).description }

    /// The one signal in this pipeline that the model produces reliably and then ignores.
    ///
    /// Asked to *judge* whether two statements conflict, the on-device model says no almost
    /// every time: a first fixture returned `scope_difference` for 14 of 14 pairs, including
    /// "I work best completely alone" against "I do my best work surrounded by other
    /// people". Splitting the scope into two named situations did not help — it simply
    /// restated each statement as its own situation ("working alone" / "working with
    /// others"), which is a tautology, and any pair can be scoped that way.
    ///
    /// Asked instead to *describe* what each statement is about, it is accurate. On that
    /// same pair it wrote the identical question twice — "What is the best environment for
    /// the person to work in" — and then still answered "compatible". So the decomposition
    /// is sound and only the judgement is broken, and the judgement is the part we can do
    /// here instead: two statements answering the same question with different answers is a
    /// contradiction, by definition rather than by opinion.
    ///
    /// Measured question similarity on a labelled set (Qwen3 int8@256):
    ///
    ///     changed mind, same question      1.000       ← caught
    ///     changed mind, reframed            0.556      ← missed
    ///     genuine scope difference          0.746, 0.829
    ///     unrelated                         0.583, 0.789
    ///
    /// Only identity separates, and it separates by a mile — 1.000 against a next-highest
    /// of 0.829. Everything below it overlaps and stays with the model's own verdict. That
    /// is **P = 1.0, R = 0.5** on this set, which is deliberately the shape Area E asks for:
    /// *"false positives destroy it — tune to P ≈ 0.9 even at R = 0.5."* Half of real
    /// contradictions go unfound, and that is a fair price for a queue that is worth
    /// opening. The missing half is what the research's DeBERTa NLI stage would buy, and
    /// there is no NLI model on this machine.
    static func sameQuestion(_ qsim: Double) -> Bool { qsim >= questionIdentity }
#endif

    struct Finding {
        let pair: Pair
        let verdict: String
        let reason: String
        let discriminator: String
    }

    struct Report {
        var candidates = 0, filtered = 0, duplicates = 0, judged = 0, failed = 0
        var recorded = 0, escalated = 0, framingFailed = 0
        var findings: [Finding] = []
        var embedFailed = false
        /// Neither of these means "no contradictions found". Both mean the scan did not
        /// happen, and the caller has to say so out loud — a stage that fails closed and
        /// stays quiet is indistinguishable from a clean ledger, which is the one lie this
        /// feature cannot afford to tell.
        var judgeFailed = false
        var lastError = ""
    }

    @available(macOS 26.0, *)
    static func scan(_ s: Store, includeUnconfirmed: Bool, limit: Int,
                     minSim: Double, maxSim: Double, verbose: Bool) async -> Report {
        var rep = Report()
        Ledger.migrate(s)
        let cands = candidates(s, includeUnconfirmed: includeUnconfirmed, limit: limit)
        rep.candidates = cands.count
        guard !cands.isEmpty else { return rep }

        guard let scored = score(s, cands) else { rep.embedFailed = true; return rep }

        var keep: [Pair] = []
        for p in scored {
            if p.structural { keep.append(p); continue }
            if p.sim > maxSim { rep.duplicates += 1; continue }
            if p.sim < minSim { rep.filtered += 1; continue }
            keep.append(p)
        }
        guard !keep.isEmpty else { return rep }

#if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            print("Foundation Models unavailable — stages 1–2 only")
            return rep
        }
        func promptFor(_ p: Pair) -> String {
            let scopeNote = (p.scopeA.isEmpty && p.scopeB.isEmpty) ? "" :
                "\n(Recorded situations — A: \(p.scopeA.isEmpty ? "none" : p.scopeA); B: \(p.scopeB.isEmpty ? "none" : p.scopeB))"
            return """
                A (\(p.fromA.prefix(10))): \(p.textA)
                B (\(p.fromB.prefix(10))): \(p.textB)\(scopeNote)
                """
        }

        // 3a — ALL the framing calls, then ALL the judgement calls: two passes, rather than
        // two interleaved calls per pair.
        //
        // Each `LanguageModelSession` carries its own instruction prefix, and grouping by
        // instruction keeps one prefix hot for a whole pass instead of alternating between
        // two. Area F flags the same effect from the other side — "minimum cacheable prefix
        // is 512 tokens on Opus 5 … 4096 on Haiku 4.5, a real trap for the map stage."
        //
        // Stated as reasoning, not as a measurement: the interleaved version was timed at
        // 590 s for 14 pairs against ~48 s expected, but that run turned out to be sitting
        // inside the sanitizer outage handled below, so it measured a broken machine rather
        // than a cold cache. **The speedup from this ordering is unverified.** Isolated
        // calls are 0.8 s (framing) and 1.7 s (judgement).
        //
        // Fresh session PER PAIR within a pass, still: a shared session accumulates the
        // previous pairs in context and the verdicts start agreeing with each other.
        var framings: [Framing?] = []
        for p in keep {
            framings.append(try? await LanguageModelSession(instructions: framingInstructions)
                .respond(to: promptFor(p), generating: Framing.self).content)
        }
        rep.framingFailed = framings.filter { $0 == nil }.count

        var judged: [(Pair, Judgement, Framing?)] = []
        for (i, p) in keep.enumerated() {
            do {
                let r = try await LanguageModelSession(instructions: instructions)
                    .respond(to: promptFor(p), generating: Judgement.self)
                rep.judged += 1
                judged.append((p, r.content, framings[i]))
            } catch {
                rep.failed += 1
                rep.lastError = (error as NSError).localizedDescription
                if verbose { print("    judge failed: \(rep.lastError)") }
                // Every `respond` is screened by a text sanitizer that loads separately from
                // the language model, and when that backend dies —
                //   SensitiveContentAnalysisML error 15 → ModelManagerError 1013
                // — it stays dead SYSTEM-WIDE, not just for this process: a freshly built
                // binary hit it on its first call, in 0.0 s, after the first process
                // tripped it. And `SystemLanguageModel.default.availability` still answers
                // `.available` throughout, so the guard at the top of this function cannot
                // catch it — the only evidence is the calls failing.
                //
                // Left to run, 14 pairs ground through 333 s of instant failures and printed
                // "0 judged", which reads like a quiet ledger rather than a broken one.
                // Give up on the pass instead, and let the caller say so out loud.
                if rep.judged == 0 && rep.failed >= 3 { rep.judgeFailed = true; break }
            }
        }
        if rep.judgeFailed { return rep }

        // 3b — one batched embedding pass over the questions, so the *identity* test can be
        // measured rather than asked for. See `sameQuestion`.
        let qtexts = judged.flatMap { [$0.2?.questionA ?? "", $0.2?.questionB ?? ""] }
        let qvecs = embedTexts(qtexts)

        // 3c — the decision. The model's verdict stands unless it gave both statements the
        // same question, which it will not act on itself.
        for (i, (p, j, fr)) in judged.enumerated() {
            var verdict = j.verdict.rawValue
            let sA = j.situationA.trimmingCharacters(in: .whitespacesAndNewlines)
            let sB = j.situationB.trimmingCharacters(in: .whitespacesAndNewlines)
            var disc = (sA.isEmpty && sB.isEmpty) ? "" : "A: \(sA) · B: \(sB)"
            var qsim = Double.nan
            if let v = qvecs, fr != nil, v.count > 2 * i + 1, !v[2 * i].isEmpty, !v[2 * i + 1].isEmpty {
                qsim = cosine(v[2 * i], v[2 * i + 1])
            }
            if !qsim.isNaN, sameQuestion(qsim), verdict != "extraction_error" {
                verdict = "genuine_change"
                disc = "same question, different answers — \(fr?.questionA ?? "")"
                rep.escalated += 1
            } else if verdict == "scope_difference",
                      sA.isEmpty || sB.isEmpty || sA.lowercased() == sB.lowercased() {
                // Backstop, kept because it costs nothing: a scope difference nobody can
                // describe is not one. In practice the model always fills both fields, so
                // the question test above is what actually catches these.
                verdict = "genuine_change"
                disc = "escalated: claimed a scope difference without naming two situations"
                rep.escalated += 1
            }
            let f = Finding(pair: p, verdict: verdict, reason: j.reason, discriminator: disc)
            rep.findings.append(f)
            if record(s, f, detector: "qwen3-int8+afm-4way+qid") { rep.recorded += 1 }
            if verbose {
                let q = qsim.isNaN ? " qsim=—" : " qsim=\(String(format: "%.3f", qsim))"
                print("    \(f.verdict)  sim=\(String(format: "%.3f", p.sim))\(q)  \(f.reason.prefix(76))")
            }
        }
#endif
        return rep
    }

    // MARK: - stage 4 persistence

    /// Idempotent by pair. A nightly scan that re-finds the same open pair updates its
    /// score and leaves the row alone; the unique index makes duplicate rows impossible
    /// rather than merely unlikely.
    @discardableResult
    static func record(_ s: Store, _ f: Finding, detector: String) -> Bool {
        let p = f.pair
        let cid = "ctr_" + sha([p.a, p.b].joined(separator: "\u{1f}")).prefix(16)
        let before = s.scalar("SELECT count(*) FROM contradiction WHERE contra_id='\(cid)';")
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(s.db, """
            INSERT INTO contradiction(contra_id,belief_a,belief_b,detector,score,status,
                                      sim,detected_at,reason,discriminator)
            VALUES(?,?,?,?,?, 'open', ?,?,?,?)
            ON CONFLICT(belief_a,belief_b) DO UPDATE SET
              sim=excluded.sim, score=excluded.score, detected_at=excluded.detected_at,
              reason=excluded.reason, discriminator=excluded.discriminator
            WHERE contradiction.status='open';
            """, -1, &st, nil)
        s.bind(st, 1, String(cid)); s.bind(st, 2, p.a); s.bind(st, 3, p.b)
        s.bind(st, 4, detector)
        // The score is what the queue sorts by: a structural contradiction outranks
        // anything the classifier merely suspects.
        sqlite3_bind_double(st, 5, p.structural ? 1.0 : p.sim)
        sqlite3_bind_double(st, 6, p.sim)
        s.bind(st, 7, Ledger.now()); s.bind(st, 8, f.reason); s.bind(st, 9, f.discriminator)
        // Only genuine_change is a finding worth surfacing; the other three are recorded
        // pre-resolved so the same pair is never judged twice.
        sqlite3_step(st)
        if f.verdict != "genuine_change" {
            resolveQuiet(s, contraID: String(cid), status: f.verdict)
        }
        return before == 0
    }

    private static func resolveQuiet(_ s: Store, contraID: String, status: String) {
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(s.db, """
            UPDATE contradiction SET status=?, reviewed_at=?, resolution='auto: nothing to change'
            WHERE contra_id=? AND status='open';
            """, -1, &st, nil)
        s.bind(st, 1, status); s.bind(st, 2, Ledger.now()); s.bind(st, 3, contraID)
        sqlite3_step(st)
    }

    // MARK: - resolution

    enum Outcome { case ok(String), failed(String) }

    /// The only place a verdict touches the ledger, and the split is the point: two of the
    /// four verdicts mean the ledger was wrong, and two mean it was right and the *detector*
    /// was over-eager. Marking a pair `both_true` must leave both beliefs standing —
    /// otherwise the review queue quietly becomes a deletion queue.
    static func resolve(_ s: Store, contraID: String, verdict: String,
                        retracting: String?) -> Outcome {
        let rows = s.rows("""
            SELECT belief_a, belief_b, status FROM contradiction
            WHERE contra_id='\(Ledger.esc(contraID))';
            """)
        guard let r = rows.first else { return .failed("no contradiction \(contraID)") }
        let (a, b) = (r[0], r[1])
        var note = ""

        switch verdict {
        case "genuine_change":
            let order = s.rows("""
                SELECT belief_id, belief_from FROM belief
                WHERE belief_id IN ('\(Ledger.esc(a))','\(Ledger.esc(b))') AND sys_to IS NULL
                ORDER BY belief_from;
                """)
            guard order.count == 2 else { return .failed("both beliefs must still be live") }
            // Same instant, no earlier one. Timestamps are ISO8601 to the second, so any two
            // beliefs recorded in the same second — every answer in one `exo ask` sitting,
            // for instance — tie. There is genuinely no boundary to place: you cannot have
            // changed your mind between two things you wrote down simultaneously, and
            // closing an interval at its own start would record a belief held for zero time.
            // Say which verdicts DO apply rather than failing with a guess.
            guard order[0][1] != order[1][1] else {
                return .failed("""
                    both beliefs start at the same instant (\(order[0][1])), so neither
                        succeeded the other. A change of mind needs a before and an after.
                        Use `extraction_error --retract <belief_id>` if one of them is wrong,
                        or re-record the older one with its real date.
                    """)
            }
            guard Ledger.closeAsSucceeded(s, earlier: order[0][0], later: order[1][0]) else {
                return .failed("could not close \(order[0][0]) — it is already closed before \(order[1][0]) begins")
            }
            note = "closed \(order[0][0]) at the start of \(order[1][0])"

        case "extraction_error":
            guard let bad = retracting else {
                return .failed("say which side was misread: --retract <belief_id>")
            }
            guard bad == a || bad == b else { return .failed("\(bad) is not part of this pair") }
            guard Ledger.retract(s, belief: bad) else { return .failed("\(bad) is not live") }
            note = "retracted \(bad); its system record closed, its belief interval untouched"

        case "scope_difference", "both_true":
            note = "both beliefs stand"

        default:
            return .failed("verdict must be genuine_change | scope_difference | extraction_error | both_true")
        }

        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(s.db, """
            UPDATE contradiction SET status=?, reviewed_at=?, resolution=? WHERE contra_id=?;
            """, -1, &st, nil)
        s.bind(st, 1, verdict); s.bind(st, 2, Ledger.now())
        s.bind(st, 3, note); s.bind(st, 4, contraID)
        sqlite3_step(st)
        return .ok(note)
    }

    // MARK: - queue

    struct Open {
        let id, textA, textB, fromA, fromB, reason, discriminator: String
        let sim, score: Double
    }

    static func open(_ s: Store, limit: Int) -> [Open] {
        s.rows("""
            SELECT k.contra_id, ca.norm_text, cb.norm_text,
                   a.belief_from, b.belief_from,
                   coalesce(k.reason,''), coalesce(k.discriminator,''),
                   coalesce(k.sim,0), k.score
            FROM contradiction k
            JOIN belief a ON a.belief_id=k.belief_a JOIN claim ca ON ca.claim_id=a.claim_id
            JOIN belief b ON b.belief_id=k.belief_b JOIN claim cb ON cb.claim_id=b.claim_id
            WHERE k.status='open'
            ORDER BY k.score DESC LIMIT \(limit);
            """).map {
            Open(id: $0[0], textA: $0[1], textB: $0[2], fromA: $0[3], fromB: $0[4],
                 reason: $0[5], discriminator: $0[6],
                 sim: Double($0[7]) ?? 0, score: Double($0[8]) ?? 0)
        }
    }
}
