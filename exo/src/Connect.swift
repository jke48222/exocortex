import Foundation
import SQLite3
#if canImport(FoundationModels)
import FoundationModels
#endif

/// S5 — connection discovery. "What else is connected to this?"
///
/// PASS-4 Area F calls S5's scaling argument the whole ballgame, and the arithmetic is why:
/// **all-pairs over five years is 3.7 × 10¹⁰ pairs.** Nothing that touches a model can run
/// over that, and nothing that runs over that is worth what it costs. The shape that works
/// is two-stage — cheap ANN candidates behind hard filters, then a model on the few hundred
/// survivors — and the reframe that makes it affordable at all is that **the unit of work is
/// yesterday, not the corpus.** Each night connects one day to everything before it.
///
/// The bands come from iOtA (Lewis, Knoblich & Poe 2018) by way of Area F: an **NREM** pass
/// at high similarity for abstract gist, and a **REM** pass in a lower band for links that
/// are maximally distant in time and source. Area F's numbers are 0.85 and 0.55–0.80; the
/// numbers actually used here are measured on this corpus, because those were quoted for a
/// different embedding model and `exo bench-connect` exists to find out.
///
/// The hard filters are not an optimization, they are the feature. Area F is explicit that
/// **at most 1–3 connections ship per morning, because one false connection destroys trust
/// in all of them.** Everything here is built to throw candidates away:
///
///   * **Δt ≥ 30 days** — two messages from the same afternoon are the same thought, not a
///     connection. This one filter removes most of what similarity finds.
///   * **different source** — a link between two Chrome pages is a browsing session. A link
///     between a Chrome page and an iMessage from last year is a memory.
///   * **not already linked** — a pair surfaces once, ever.
///   * **the band** — above it is a near-duplicate, below it is noise.
enum Connect {

    /// Chunk-level neighbours, event-level findings.
    ///
    /// A 20,000-character document is 25 vectors, and without collapsing them a single
    /// document pair would arrive 25 times over and fill a queue capped at three.
    struct Cand {
        let a, b: Int64                 // event seq, a < b
        var sim: Double
        let daysApart: Int
        let srcA, srcB: String
        let textA, textB: String        // display / prompt copy, truncated
        let fullA, fullB: String        // whole note, for the groundedness check
        let tsA, tsB: Int64
    }

    // MARK: - schema

    static func migrate(_ s: Store) {
        s.exec("""
        CREATE TABLE IF NOT EXISTS connection(
          conn_id TEXT PRIMARY KEY,
          -- ON DELETE CASCADE is the point, not decoration. Area F: "every derived artifact
          -- must carry provenance pointers back to source spans so deletion can cascade.
          -- Retrofit is impossible; build it in." When retention purges an event, the
          -- connections drawn from it go with it, and `foreign_keys=ON` is set at open.
          seq_a INTEGER NOT NULL REFERENCES events(seq) ON DELETE CASCADE,
          seq_b INTEGER NOT NULL REFERENCES events(seq) ON DELETE CASCADE,
          sim REAL NOT NULL, days_apart INTEGER NOT NULL,
          relevance REAL, unexpectedness REAL, serendipity REAL,
          link TEXT,                         -- the model's account of what joins them
          detected_at TEXT NOT NULL,
          surfaced_at TEXT,                  -- NULL = never shown in a brief
          verdict TEXT                       -- NULL | useful | not_useful
        ) STRICT;
        """)
        s.exec("CREATE UNIQUE INDEX IF NOT EXISTS ux_conn_pair ON connection(seq_a, seq_b);")
        s.exec("CREATE INDEX IF NOT EXISTS ix_conn_queue ON connection(surfaced_at, serendipity DESC);")
    }

    // MARK: - stage 1: candidates

    /// Timestamps outside this are junk, and the corpus has both ends: `min(ts)` is
    /// 1969-12-31 and `max(ts)` is 2031-12-31. A 1969 row is 57 years from everything, so
    /// it passes the Δt filter against the entire corpus and would dominate every scan.
    static let tsFloor: Int64 = 946_684_800_000_000        // 2000-01-01
    static var tsCeil: Int64 { nowMicros() + 86_400_000_000 }

    struct Params {
        var anchors = 200               // most recent vectorized events to connect FROM
        var sinceDays = 0               // 0 = ignore dates, take the newest `anchors`
        var k = 40                      // Hamming shortlist per anchor chunk
        var minDays = 30
        var minSim = 0.55
        var maxSim = 0.92
        /// Whether a pair must cross sources. **Default off, and that is a measured
        /// reversal of Area F.** "Different modality" assumes a corpus with several rich
        /// modalities; this one has exactly one — 4,259 eligible claudecode work logs
        /// against 1,212 mostly-automated emails and 507 messages — so requiring a crossing
        /// forced every single candidate to be gmail-to-claudecode, i.e. a marketing email
        /// paired with real work. Allowing same-source immediately surfaced two debugging
        /// sessions 48 days apart that had hit the same aria-label race, which is exactly
        /// the "this reminded me of that" the stage exists for. Crossing sources still
        /// counts — it feeds unexpectedness — but it no longer decides eligibility.
        var requireDifferentSource = false
        /// int8 dimensions to score on, 0 = whatever is stored. §6 found that truncating to
        /// 256 separates *better* than full width for single sentences; these are 900-char
        /// chunks, which is a different regime, so it is a knob and `--histogram` decides it
        /// rather than the earlier result being assumed to transfer.
        var dims = 0
        /// Drop any target that turns up as a neighbour of more than this many anchors.
        /// See `hub suppression` below — this is the filter the eligibility SQL cannot be.
        var hubMax = 3
        /// One connection per anchor event. The same cap, and for the same reason, as the
        /// belief extractor's three-claims-per-event: without it, six near-identical
        /// "your voice pack has finished training" notifications produced six separate
        /// findings against one message, and a queue capped at three fills with one thought.
        var perAnchor = 1
    }

    /// What is even eligible to be one end of a connection.
    ///
    /// The first run against the real corpus returned, as its twelve best findings, twelve
    /// pieces of infrastructure: a Claude.ai sign-in email matched to the Claude.ai sign-in
    /// URL at 0.911, a Drive share notification matched to the Drive URL, and four separate
    /// pairings of a marketing email with the string
    /// `Base directory for this skill: /private/tmp/...`.
    ///
    /// None of Area F's filters touch that, and they cannot: a login email and a login URL
    /// genuinely are different sources, genuinely months apart, and genuinely about the same
    /// thing. The candidates were not wrong. **Similarity search over a life-log finds the
    /// corpus's hubs, and a life-log's hubs are its boilerplate** — the same text repeated
    /// hundreds of times is the nearest neighbour of everything near it.
    ///
    /// Measured on this corpus, which is why the cuts are this specific:
    ///
    ///   * `browser.*` is **21,523 of 21,616 bare URLs (99.6%)** — and a third of the whole
    ///     vector index. A URL is not a memory. Still searchable, never connectable.
    ///   * `gmail` is **34% marketing-padded (the U+034F filler HTML mail uses), 31%
    ///     unsubscribe-bearing, 17% utm-tagged.** Automated mail is most of the mailbox.
    ///   * `claudecode` repeats scaffolding the principal never wrote —
    ///     `[Request interrupted by user]` ×59, `<local-command-caveat>` ×45, `continue` ×35.
    ///
    /// This is the same lesson as the belief extractor's, in a different costume: there,
    /// 141 of the first 145 claims were task directives. **The corpus does not contain what
    /// you assume in the proportions you assume**, and the fix is an eligibility filter
    /// written against what is actually in it.
    static let eligibleSQL = """
          e.text IS NOT NULL AND length(e.text) >= 120
          AND e.source NOT LIKE 'browser.%'
          AND e.text NOT LIKE 'http%'
          -- tool scaffolding the principal never wrote
          AND e.text NOT LIKE '<command-%'
          AND e.text NOT LIKE '<local-command-%'
          AND e.text NOT LIKE '%<system-reminder>%'
          AND e.text NOT LIKE 'Caveat:%'
          AND e.text NOT LIKE '%[Request interrupted by user]%'
          AND e.text NOT LIKE 'Base directory for this skill:%'
          AND e.text NOT LIKE '%<tool-use-id>%'
          AND e.text NOT LIKE '%<output-file>%'
          -- Commercial SMS, identified by its sender rather than its words. A 5-6 digit
          -- handle is a short code: by definition a business, never a person. 189 rows,
          -- and they were producing findings like "Tyler, The Creator: the 2026 lineup is
          -- here" paired with the same campaign's next blast.
          -- S6: a cold row is not a candidate. Demotion that changes nothing downstream is
          -- theatre; this is one of the three places it bites.
          AND NOT EXISTS (SELECT 1 FROM memory_state m WHERE m.seq = e.seq AND m.tier = 'cold')
          AND NOT (e.source LIKE 'imessage%'
                   AND (e.title GLOB '[0-9][0-9][0-9][0-9][0-9]'
                     OR e.title GLOB '[0-9][0-9][0-9][0-9][0-9][0-9]'))
        """

    /// Bulk mail and commercial SMS, detected by structure rather than by substring.
    ///
    /// The SQL above is a prefilter over 100k rows and has to stay cheap, so it only removes
    /// what a `LIKE` can see. This runs on the few hundred surviving candidates, where it can
    /// afford to look at shape — which matters, because the substring list kept losing:
    /// it excluded U+034F padding and missed **501 gmail rows padded with U+200C and 48 with
    /// U+200B**, and "The training of your voice pack has completed" carries no unsubscribe
    /// link, no utm tag and no padding at all.
    ///
    /// A run of invisible characters is the giveaway no bulk mailer can avoid — it is the
    /// preheader spacer every HTML template emits, and nobody types four zero-width
    /// characters in a row.
    static func looksAutomated(_ t: String) -> Bool {
        // **`unicodeScalars`, not `Character`.** Iterating a Swift String yields grapheme
        // clusters, and U+200C ZWNJ / U+200D ZWJ are exactly the scalars whose job is to
        // glue a cluster together — so `Character` comparison never sees a bare ZWNJ and
        // this returned false for every padded mail in the corpus. Confirmed against the
        // bytes: the padding is `E2808C 20 E2808C 20 …`, alternating ZWNJ and space.
        let invisible: Set<Unicode.Scalar> = ["\u{034F}", "\u{200B}", "\u{200C}", "\u{200D}",
                                              "\u{2002}", "\u{2003}", "\u{2007}", "\u{200A}",
                                              "\u{FEFF}", "\u{00AD}", "\u{00A0}"]
        var run = 0
        for u in t.unicodeScalars {
            if invisible.contains(u) {
                run += 1
                if run >= 4 { return true }
            } else if u != " " {
                run = 0                     // spaces between pads do not break the run
            }
        }
        let low = t.lowercased()
        for marker in ["unsubscribe", "view in browser", "view this email", "no-reply",
                       "noreply", "utm_", "reply stop", "txt stop", "text stop",
                       "stop to opt", "opt out", "verification code", "sign in to",
                       "manage preferences", "you are receiving this", "privacy policy"]
        where low.contains(marker) { return true }
        // Link dumps: a message that is mostly URLs is a notification, not a thought.
        // Cyrillic homoglyphs inside otherwise-Latin prose. "Нellο! Emily Сartеr here with
        // Amazon's Remote Recruitment Team" uses Н, ο, С and е from Cyrillic and Greek to
        // slip filters; no honest English message mixes scripts this way, and the pair of
        // such messages 82 days apart was scoring 0.838.
        var latin = 0, cyrillicOrGreek = 0
        for u in t.unicodeScalars {
            switch u.value {
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            case 0x0370...0x03FF, 0x0400...0x04FF: cyrillicOrGreek += 1
            default: break
            }
        }
        if latin > 40 && cyrillicOrGreek > 0 && Double(cyrillicOrGreek) / Double(latin) < 0.25 {
            return true
        }
        let words = t.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard words.count >= 8 else { return true }
        let links = words.filter { $0.hasPrefix("http") }.count
        return Double(links) / Double(words.count) > 0.25
    }

    /// The width actually in the database, not a constant. The corpus was embedded at
    /// **1024** after §4 raised the default, and a hardcoded 256 here loaded zero vectors
    /// and reported "0 scanned" — which looks exactly like a corpus with no neighbours.
    static func storedBits(_ s: Store) -> Int {
        s.scalar("SELECT bits FROM vectors WHERE provider='\(Embed.qwenProvider)' LIMIT 1;")
    }

    /// Two-tier, exactly as the retrieval path does it: a binary Hamming scan picks the
    /// shortlist, then the int8 tier decides the band. §6 measured that int8@256 is the
    /// accurate tier for comparing short texts and that binary@256 is not, so the binary
    /// pass is used only to choose WHICH pairs to score, never to score them.
    static func candidates(_ s: Store, _ p: Params) -> (cands: [Cand], scanned: Int, hist: [Int]) {
        var hist = [Int](repeating: 0, count: 20)          // sim histogram, 0.1 buckets
        let bits = storedBits(s)
        guard bits > 0 else { return ([], 0, hist) }
        let (idx, owner, i8s) = s.loadVectors(provider: Embed.qwenProvider, bits: bits)
        guard idx.count > 0 else { return ([], 0, hist) }

        // Metadata for every ELIGIBLE vectorized event, read once. Anything absent from
        // this map is invisible to both ends of every pair — the filter is applied by
        // omission rather than by a check at each of ten thousand comparisons.
        var ts: [Int64: Int64] = [:], src: [Int64: String] = [:]
        for r in s.rows("""
            SELECT DISTINCT e.seq, e.ts, e.source FROM events e
            JOIN vectors v ON v.seq = e.seq
            WHERE e.ts BETWEEN \(tsFloor) AND \(tsCeil) AND \(eligibleSQL);
            """) {
            guard let q = Int64(r[0]) else { continue }
            ts[q] = Int64(r[1]) ?? 0; src[q] = r[2]
        }

        let anchorSQL = p.sinceDays > 0
            ? "AND e.ts >= \(nowMicros() - Int64(p.sinceDays) * 86_400_000_000)"
            : ""
        let anchors = s.rows("""
            SELECT DISTINCT e.seq, e.ts FROM events e JOIN vectors v ON v.seq = e.seq
            WHERE e.ts BETWEEN \(tsFloor) AND \(tsCeil) AND \(eligibleSQL) \(anchorSQL)
            ORDER BY e.ts DESC LIMIT \(p.anchors);
            """).compactMap { Int64($0[0]) }
        guard !anchors.isEmpty else { return ([], 0, hist) }
        let anchorSet = Set(anchors)

        // ordinal ranges per event, so an anchor's chunks are found without a scan
        var chunksOf: [Int64: [Int]] = [:]
        for (ord, seq) in owner.enumerated() where anchorSet.contains(seq) {
            chunksOf[seq, default: []].append(ord)
        }

        // Best pair wins: chunk-level neighbours collapse to one row per event pair.
        var best: [String: Cand] = [:]
        var scanned = 0
        for a in anchors {
            guard let tsA = ts[a], let srcA = src[a] else { continue }
            for ord in chunksOf[a] ?? [] {
                let query = Array(idx.data[(ord * idx.stride)..<((ord + 1) * idx.stride)])
                for (hitOrd, _) in idx.search(query, k: p.k) {
                    let b = owner[Int(hitOrd)]
                    guard b != a, let tsB = ts[b], let srcB = src[b] else { continue }
                    scanned += 1
                    let days = Int(abs(tsA - tsB) / 86_400_000_000)
                    guard days >= p.minDays else { continue }
                    guard !p.requireDifferentSource || srcA != srcB else { continue }
                    var x = i8s[ord], y = i8s[Int(hitOrd)]
                    guard !x.isEmpty, !y.isEmpty else { continue }
                    if p.dims > 0 && x.count > p.dims {
                        x = Array(x.prefix(p.dims)); y = Array(y.prefix(p.dims))
                    }
                    let sim = Contradict.cosine(x, y)
                    let bucket = min(19, max(0, Int((sim + 1) / 0.1)))
                    hist[bucket] += 1
                    guard sim >= p.minSim, sim <= p.maxSim else { continue }
                    let key = a < b ? "\(a)|\(b)" : "\(b)|\(a)"
                    if let prev = best[key], prev.sim >= sim { continue }
                    best[key] = Cand(a: min(a, b), b: max(a, b), sim: sim, daysApart: days,
                                     srcA: a < b ? srcA : srcB, srcB: a < b ? srcB : srcA,
                                     textA: "", textB: "", fullA: "", fullB: "",
                                     tsA: a < b ? tsA : tsB, tsB: a < b ? tsB : tsA)
                }
            }
        }

        // ── hub suppression ──
        //
        // The eligibility SQL can only remove boilerplate it has been told the shape of, and
        // there is always more: "The training of your voice pack X has been successfully
        // completed" carries no unsubscribe link, no utm tag and no marketing padding, so it
        // passes every pattern — and six near-identical copies of it each produced their own
        // finding against the same message.
        //
        // The structural property is the one to filter on, and it needs no patterns at all:
        // **a document that is the nearest neighbour of many different anchors is a hub, not
        // a memory.** That is document-frequency, the same intuition as IDF, applied to
        // neighbours instead of terms — and unlike a pattern list it keeps working on
        // boilerplate nobody has seen yet.
        var targetFreq: [Int64: Int] = [:]
        for c in best.values {
            // credit the end that is NOT the anchor
            targetFreq[anchorSet.contains(c.a) ? c.b : c.a, default: 0] += 1
        }
        let hubs = Set(targetFreq.filter { $0.value > p.hubMax }.keys)

        // Best pair per anchor, hubs removed.
        var byAnchor: [Int64: [Cand]] = [:]
        for c in best.values {
            let target = anchorSet.contains(c.a) ? c.b : c.a
            guard !hubs.contains(target) else { continue }
            byAnchor[anchorSet.contains(c.a) ? c.a : c.b, default: []].append(c)
        }
        let capped = byAnchor.values.flatMap { $0.sorted { $0.sim > $1.sim }.prefix(p.perAnchor) }

        // Drop anything already on the books, then fill in text for what survives.
        var out: [Cand] = []
        for var c in capped {
            if s.scalar("SELECT count(*) FROM connection WHERE seq_a=\(c.a) AND seq_b=\(c.b);") > 0 { continue }
            // The automation test reads the WHOLE text; only the display copy is truncated.
            // A LinkedIn digest carries its "unsubscribe" at character 4,068 of 5,272, so
            // testing the 600-char prefix cleared every bulk mail in the corpus.
            let t = s.rows("SELECT seq, coalesce(text,'') FROM events WHERE seq IN (\(c.a),\(c.b));")
            var byID: [Int64: String] = [:]
            for r in t { byID[Int64(r[0]) ?? 0] = r[1] }
            guard let ta = byID[c.a], let tb = byID[c.b], ta.count > 40, tb.count > 40 else { continue }
            guard !looksAutomated(ta), !looksAutomated(tb) else { continue }
            c = Cand(a: c.a, b: c.b, sim: c.sim, daysApart: c.daysApart,
                     srcA: c.srcA, srcB: c.srcB,
                     textA: String(ta.prefix(600)), textB: String(tb.prefix(600)),
                     fullA: ta, fullB: tb, tsA: c.tsA, tsB: c.tsB)
            out.append(c)
        }
        return (out.sorted { $0.sim > $1.sim }, scanned, hist)
    }

    // MARK: - stage 2: what actually connects them

    /// A term this common is not a connection.
    ///
    /// Set by looking at what came out, not by picking a round number. At 1,000 — nominally
    /// 1% of 100k events — the links were `desktop`×619, `links`×404, `quote`×339,
    /// `fresh`×289: words two long work logs share by being work logs. The terms that read
    /// as actual recall sit two orders of magnitude lower — `turbopack`×5, `vital-signs`×6,
    /// `initials`×16, `innovative`×19, `aria-label`×20, `painted`×31, `scroll-driven`×38.
    ///
    /// 60 keeps all of those and cuts the generic ones. It also cuts `tinacms`×154, which was
    /// a genuine link — that is the precision-over-recall trade Area F asks for, taken
    /// knowingly: *one false connection destroys trust in all of them*, and a missed true one
    /// costs a morning's mild interest.
    static var rarityCeiling = 60

    /// Lowercase, keep only letters and digits, collapse to single spaces.
    static func normalizeTerm(_ s: String) -> String {
        var out = "", lastSpace = true
        for u in s.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) {
                out.unicodeScalars.append(u); lastSpace = false
            } else if !lastSpace {
                out.append(" "); lastSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// FTS5 already indexes every event, so document frequency is a query, not a scan.
    static func corpusFrequency(_ s: Store, _ term: String) -> Int {
        let clean = normalizeTerm(term)
        guard clean.count >= 3 else { return Int.max }
        return s.scalar("SELECT count(*) FROM events_fts WHERE events_fts MATCH '\"\(clean)\"';")
    }

    /// The link, computed instead of asked for.
    ///
    /// Three measurements pointed here, and the conclusion is the same one §6 reached about
    /// contradictions, arrived at by the same road. Asked what two notes have in common, the
    /// on-device model:
    ///
    ///   1. answered with a bare category — "work", "the condition", "the remote", "Mark";
    ///   2. pushed to name something specific, named something real from **one** note and
    ///      asserted it was in both. Verified directly against the rows: `content/site.json`
    ///      and `Turbopack` each occur in note B and nowhere in note A. **38 of 40
    ///      confabulated**, confidently;
    ///   3. given a schema-level escape hatch — a `sharesSomethingSpecific: Bool` it could
    ///      set false — **used it zero times out of 39.** That is a negative result against
    ///      Area F, which expects an `unsupported_fields` hatch to *measurably reduce
    ///      confabulation*. Here it changed nothing whatsoever.
    ///
    /// So the terms are extracted directly: intersect the two notes, keep what is rare in the
    /// corpus, and the link is grounded **by construction** rather than by a check that has
    /// to catch a confident wrong answer. Rarity is doing the work, and it is document
    /// frequency for the third time in this file — hub suppression for documents, the ceiling
    /// for a proposed term, and now term selection itself.
    static func sharedRareTerms(_ s: Store, _ a: String, _ b: String,
                                cache: inout [String: Int], limit: Int = 4) -> [(String, Int)] {
        func terms(_ t: String) -> Set<String> {
            var out = Set<String>(), cur = ""
            let joiners = Set("-./_".unicodeScalars)
            func flush() {
                let w = cur.trimmingCharacters(in: CharacterSet(charactersIn: "-./_"))
                if w.count >= 4, w.rangeOfCharacter(from: .letters) != nil { out.insert(w) }
                cur = ""
            }
            for u in t.lowercased().unicodeScalars {
                // `-`, `.`, `/`, `_` stay inside a token, so `aria-label` and
                // `content/site.json` survive as one identifier rather than four words.
                if CharacterSet.alphanumerics.contains(u) || joiners.contains(u) {
                    cur.unicodeScalars.append(u)
                } else { flush() }
            }
            flush()
            return out
        }
        let shared = terms(a).intersection(terms(b))
        guard !shared.isEmpty else { return [] }
        var scored: [(String, Int)] = []
        for term in shared {
            let f: Int
            if let hit = cache[term] { f = hit } else { f = corpusFrequency(s, term); cache[term] = f }
            if f > 0 && f <= rarityCeiling { scored.append((term, f)) }
        }
        return Array(scored.sorted { $0.1 < $1.1 }.prefix(limit))
    }

#if canImport(FoundationModels)
    /// Describe, then rate — and in that order, for the reason §6.3 measured: asked to judge
    /// and describe in one breath, the model writes a description that already contains its
    /// verdict. Here the description is asked for first *within the same schema*, which is
    /// weaker than a separate call but is what a per-pair budget allows; the ratings are
    /// treated as soft evidence and the arithmetic is done in code.
    /// Describe-only, and it is handed the term rather than asked for it.
    ///
    /// See `sharedRareTerms` for why. Everything the model was previously asked to DECIDE is
    /// now decided in code; what is left is the one thing §6 established it does well —
    /// writing a sentence about something it has been given. It cannot confabulate the link,
    /// because it is not the one choosing it.
    @available(macOS 26.0, *)
    @Generable
    struct Judgement {
        @Guide(description: "One sentence: what happened with the given term in the first note, and what happened with it in the second.")
        var account: String
        @Guide(description: "Whether someone who wrote both notes would be surprised to see them put side by side, rather than finding it obvious.")
        var surprising: Bool
    }

    /// Area F scores on **serendipity = relevance × unexpectedness**, and the product is the
    /// point: a link that is obviously relevant is something you already knew, and a link
    /// that is merely surprising is noise. Only the pair that is both is worth a morning.
    static let instructions = """
        You are shown two notes the same person wrote weeks or months apart, and one term
        that appears in both of them.

        Say in one sentence what happened with that term in the first note, and what happened
        with it in the second. Refer only to what the notes actually say.

        Then say whether someone who wrote both would find the pairing surprising, or whether
        it is the obvious thing they would expect.
        """
    static var promptHash: String { sha(instructions).prefix(16).description }
#endif

    struct Finding {
        let cand: Cand
        let link: String
        let relevance, unexpectedness, serendipity: Double
    }

    struct Report {
        var anchors = 0, scanned = 0, candidates = 0, judged = 0, failed = 0
        var kept = 0, grounded = 0, ungrounded = 0, hist: [Int] = []
        var findings: [Finding] = []
        var judgeFailed = false
        var lastError = ""
    }

    @available(macOS 26.0, *)
    static func run(_ s: Store, _ p: Params, judgeLimit: Int, verbose: Bool) async -> Report {
        var rep = Report()
        migrate(s)
        let (cands, scanned, hist) = candidates(s, p)
        rep.scanned = scanned; rep.candidates = cands.count; rep.hist = hist
        guard !cands.isEmpty else { return rep }

#if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            print("Foundation Models unavailable — stage 1 only"); return rep
        }
        // The link is computed before any model call, and a pair with no genuinely shared
        // rare term never reaches the model at all. That ordering is the whole point: the
        // expensive, unreliable stage now only ever sees pairs that are already grounded.
        var freqCache: [String: Int] = [:]
        var grounded: [(Cand, [(String, Int)])] = []
        for c in cands {
            let terms = sharedRareTerms(s, c.fullA, c.fullB, cache: &freqCache)
            if terms.isEmpty { rep.ungrounded += 1; continue }
            grounded.append((c, terms))
        }
        rep.grounded = grounded.count
        guard !grounded.isEmpty else { return rep }

        for (c, terms) in grounded.prefix(judgeLimit) {
            let term = terms[0].0
            let others = terms.dropFirst().map(\.0).joined(separator: ", ")
            let prompt = """
                SHARED TERM: \(term)\(others.isEmpty ? "" : "  (also shared: \(others))")

                NOTE 1 (\(c.srcA), \(stampDay(c.tsA))): \(window(c.fullA, around: term))

                NOTE 2 (\(c.srcB), \(stampDay(c.tsB))): \(window(c.fullB, around: term))
                """
            do {
                let r = try await LanguageModelSession(instructions: instructions)
                    .respond(to: prompt, generating: Judgement.self)
                rep.judged += 1

                // Relevance is 1 by construction — the term is in both notes and rare in the
                // corpus, both verified — so what remains to score is how far apart the two
                // ends are. Unexpectedness is computed, not asked for: the model's own
                // "surprising" flag answered the same way for almost everything, so it is one
                // term of three rather than the whole factor.
                let rarest = Double(terms[0].1)
                let rarityTerm = min(1.0, max(0.2, 1.0 - log10(max(1.0, rarest)) / 3.0))
                let timeTerm = min(1.0, Double(c.daysApart) / 180.0)
                let crossTerm = c.srcA != c.srcB ? 1.0 : 0.75
                let distinctness = min(1.0, max(0.0, (p.maxSim - c.sim) / (p.maxSim - p.minSim)))
                let modelTerm = r.content.surprising ? 1.0 : 0.7
                let unexpectedness = (0.35 * timeTerm + 0.25 * distinctness
                                      + 0.2 * modelTerm + 0.2 * rarityTerm) * crossTerm
                let ser = 1.0 * unexpectedness
                let f = Finding(cand: c, link: "\(term) — \(r.content.account)",
                                relevance: 1.0, unexpectedness: unexpectedness, serendipity: ser)
                rep.findings.append(f)
                record(s, f)
                rep.kept += 1
                if verbose {
                    print("    \(String(format: "%.2f", ser))  sim=\(String(format: "%.2f", c.sim)) \(c.daysApart)d  \(c.srcA)/\(c.srcB)  [\(term)×\(terms[0].1)] \(r.content.account.prefix(64))")
                }
            } catch {
                rep.failed += 1
                rep.lastError = (error as NSError).localizedDescription
                if verbose { print("    judge failed: \(rep.lastError)") }
                // Same latching sanitizer outage as Contradict.scan — see the note there.
                if rep.judged == 0 && rep.failed >= 3 { rep.judgeFailed = true; break }
            }
        }
#endif
        return rep
    }

    /// The text AROUND the shared term, not the head of the note.
    ///
    /// The prompt used to carry the first 500 characters of each note, while the term was
    /// found anywhere in the full text — so the model was handed a term and a passage that
    /// did not contain it, and duly wrote *"in the first note, 'vital-signs' is not
    /// mentioned"*. It was right. Show it the part being talked about.
    static func window(_ text: String, around term: String, radius: Int = 220) -> String {
        let hay = text.lowercased()
        guard let r = hay.range(of: term.lowercased()) else { return String(text.prefix(2 * radius)) }
        let lo = hay.index(r.lowerBound, offsetBy: -radius, limitedBy: hay.startIndex) ?? hay.startIndex
        let hi = hay.index(r.upperBound, offsetBy: radius, limitedBy: hay.endIndex) ?? hay.endIndex
        let clip = String(text[lo..<hi]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (lo > hay.startIndex ? "…" : "") + clip + (hi < hay.endIndex ? "…" : "")
    }

    static func stampDay(_ micros: Int64) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: Double(micros) / 1_000_000))
    }

    @discardableResult
    static func record(_ s: Store, _ f: Finding) -> Bool {
        let id = "cnn_" + sha("\(f.cand.a)|\(f.cand.b)").prefix(16)
        var st: OpaquePointer?; defer { sqlite3_finalize(st) }
        sqlite3_prepare_v2(s.db, """
            INSERT INTO connection(conn_id,seq_a,seq_b,sim,days_apart,relevance,
                                   unexpectedness,serendipity,link,detected_at)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(seq_a,seq_b) DO NOTHING;
            """, -1, &st, nil)
        s.bind(st, 1, String(id))
        sqlite3_bind_int64(st, 2, f.cand.a); sqlite3_bind_int64(st, 3, f.cand.b)
        sqlite3_bind_double(st, 4, f.cand.sim)
        sqlite3_bind_int(st, 5, Int32(f.cand.daysApart))
        sqlite3_bind_double(st, 6, f.relevance); sqlite3_bind_double(st, 7, f.unexpectedness)
        sqlite3_bind_double(st, 8, f.serendipity)
        s.bind(st, 9, f.link); s.bind(st, 10, Ledger.now())
        return sqlite3_step(st) == SQLITE_DONE
    }

    /// The morning's allowance. Area F: **at most 1–3**, and never one that has been shown
    /// before — a brief that repeats itself is a brief you stop reading.
    struct Surfaced {
        let id, link, srcA, srcB, textA, textB, dayA, dayB: String
        let sim, serendipity: Double
        let daysApart: Int
    }

    static func forBrief(_ s: Store, limit: Int) -> [Surfaced] {
        s.rows("""
            SELECT c.conn_id, coalesce(c.link,''), a.source, b.source,
                   substr(coalesce(a.text,''),1,180), substr(coalesce(b.text,''),1,180),
                   strftime('%Y-%m-%d', a.ts/1000000, 'unixepoch'),
                   strftime('%Y-%m-%d', b.ts/1000000, 'unixepoch'),
                   c.sim, c.serendipity, c.days_apart
            FROM connection c
            JOIN events a ON a.seq=c.seq_a JOIN events b ON b.seq=c.seq_b
            WHERE c.surfaced_at IS NULL AND c.serendipity > 0
            ORDER BY c.serendipity DESC, c.sim DESC
            LIMIT \(limit);
            """).map {
            Surfaced(id: $0[0], link: $0[1], srcA: $0[2], srcB: $0[3],
                     textA: $0[4], textB: $0[5], dayA: $0[6], dayB: $0[7],
                     sim: Double($0[8]) ?? 0, serendipity: Double($0[9]) ?? 0,
                     daysApart: Int($0[10]) ?? 0)
        }
    }

    static func markSurfaced(_ s: Store, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        let list = ids.map { "'\(Ledger.esc($0))'" }.joined(separator: ",")
        s.exec("UPDATE connection SET surfaced_at='\(Ledger.now())' WHERE conn_id IN (\(list));")
    }
}
