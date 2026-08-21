import Foundation
import SQLite3
#if canImport(FoundationModels)
import FoundationModels
#endif

/// S1 and S2 of the dream cycle — cut the day into episodes, then say what happened in each.
///
/// **The neuroscience is the spec.** Event Segmentation Theory (Zacks 2007) says people carve
/// experience at moments of *prediction error*: the boundary is not the clock, it is the
/// instant the next thing stops following from the last. EM-LLM (arXiv 2407.09450) is the
/// computational form — Bayesian surprise, then graph-theoretic refinement, then temporal
/// contiguity.
///
/// Surprise here is measured against a **running centroid of the recent past**, not against
/// the single previous event. That is the difference between "is this different from the last
/// thing?" and "is this different from what I have been doing?", and only the second is
/// prediction error. A stream that alternates between two topics has a high pairwise distance
/// at every step and no boundaries at all; against a centroid it correctly reads as one
/// episode.
///
/// The graph-theoretic refinement pass is **not built** — see the note on `boundaries`.
///
/// S2 is **hierarchical map-reduce, never refine.** Area F is explicit: refine is strictly
/// sequential and compounds drift, so a long episode summarized by folding one event at a time
/// ends up describing its own last few events. Map over groups, reduce once.
///
/// And every line of every summary **carries the `seq` it came from.** Generative Agents'
/// reflection cites record IDs, and Area F flags it as *"the part most people drop, and it's
/// what makes the derived layer auditable."* It is also what makes deletion cascade: a summary
/// whose provenance is a vibe cannot be un-written when its source expires.
enum Segment {

    static func migrate(_ s: Store) {
        s.exec("""
        CREATE TABLE IF NOT EXISTS episode(
          episode_id TEXT PRIMARY KEY,
          day TEXT NOT NULL,
          started_at INTEGER NOT NULL, ended_at INTEGER NOT NULL,
          n_events INTEGER NOT NULL,
          sources TEXT NOT NULL,
          title TEXT, summary TEXT,
          peak_surprise REAL NOT NULL,
          created_at TEXT NOT NULL
        ) STRICT;
        """)
        s.exec("CREATE INDEX IF NOT EXISTS ix_episode_day ON episode(day, started_at);")
        s.exec("""
        CREATE TABLE IF NOT EXISTS episode_event(
          episode_id TEXT NOT NULL REFERENCES episode(episode_id) ON DELETE CASCADE,
          seq INTEGER NOT NULL REFERENCES events(seq) ON DELETE CASCADE,
          PRIMARY KEY (episode_id, seq)
        ) STRICT;
        """)
        s.exec("""
        CREATE TABLE IF NOT EXISTS episode_line(
          episode_id TEXT NOT NULL REFERENCES episode(episode_id) ON DELETE CASCADE,
          ord INTEGER NOT NULL,
          text TEXT NOT NULL,
          -- The citation is NOT NULL on purpose. A derived line with no source is a line
          -- nobody can check and nobody can delete.
          seq INTEGER NOT NULL REFERENCES events(seq) ON DELETE CASCADE,
          PRIMARY KEY (episode_id, ord)
        ) STRICT;
        """)
    }

    struct Params {
        var day = ""                    // ISO day; empty = the most recent day with events
        var window = 5                  // events in the running centroid
        var k = 1.0                     // boundary at mean + k·sd of surprise
        var gapMinutes = 45             // a long pause is a boundary whatever the content says
        var minEvents = 3               // episodes shorter than this are merged forward
        var maxEvents = 60
    }

    struct Item {
        let seq: Int64, ts: Int64
        let source, text: String
        let vec: [Double]
    }

    /// One vector per event: the mean of its chunks, from the int8 rescore tier.
    static func items(_ s: Store, day: String, sources: String) -> [Item] {
        let bits = Connect.storedBits(s)
        guard bits > 0 else { return [] }
        let rows = s.rows("""
            SELECT e.seq, e.ts, e.source, substr(coalesce(e.text,''),1,1200), hex(v.i8)
            FROM events e JOIN vectors v ON v.seq = e.seq
            -- 'localtime', because a day is the person's day. Without it an evening event
            -- lands in tomorrow's episode list and the brief opens with something that
            -- happened before yesterday's dinner.
            WHERE date(e.ts/1000000,'unixepoch','localtime') = '\(Ledger.esc(day))'
              AND e.source IN (\(sources))
              AND \(Connect.eligibleSQL)
            ORDER BY e.ts, e.seq, v.chunk;
            """)
        // Chunks arrive adjacent; fold them into one mean vector per event.
        var out: [Item] = []
        var curSeq: Int64 = -1, acc: [Double] = [], n = 0
        var curTs: Int64 = 0, curSrc = "", curText = ""
        func flush() {
            guard curSeq >= 0, n > 0 else { return }
            out.append(Item(seq: curSeq, ts: curTs, source: curSrc, text: curText,
                            vec: acc.map { $0 / Double(n) }))
        }
        for r in rows {
            guard let seq = Int64(r[0]) else { continue }
            let v = hexToI8(r[4]).map(Double.init)
            guard !v.isEmpty else { continue }
            if seq != curSeq {
                flush()
                // The same bulk-mail and commercial-SMS test the connection stage uses. It
                // lives in Swift rather than in `eligibleSQL` because it reads structure —
                // runs of invisible padding, mixed scripts, URL density — and without it the
                // day's episodes open with "New option: Acrylic Glass".
                if Connect.looksAutomated(r[3]) { curSeq = -1; acc = []; n = 0; continue }
                curSeq = seq; curTs = Int64(r[1]) ?? 0; curSrc = r[2]; curText = r[3]
                acc = v; n = 1
            } else {
                if acc.count == v.count { for i in 0..<acc.count { acc[i] += v[i] } }
                n += 1
            }
        }
        flush()
        return out
    }

    /// `vectors.i8` is a BLOB; `Store.rows` hands back text. SQLite renders a BLOB read as
    /// text by reinterpreting its bytes, which loses any that are not valid UTF-8 — so the
    /// column is read as hex in SQL and decoded here.
    static func hexToI8(_ h: String) -> [Int8] {
        var out = [Int8](); out.reserveCapacity(h.count / 2)
        var i = h.startIndex
        while i < h.endIndex, let j = h.index(i, offsetBy: 2, limitedBy: h.endIndex) {
            out.append(Int8(bitPattern: UInt8(h[i..<j], radix: 16) ?? 0)); i = j
        }
        return out
    }

    static func cos(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count); guard n > 0 else { return 0 }
        var d = 0.0, na = 0.0, nb = 0.0
        for i in 0..<n { d += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return d / (na.squareRoot() * nb.squareRoot())
    }

    /// Surprise at each position: distance from the running centroid of the preceding window.
    static func surprise(_ items: [Item], window: Int) -> [Double] {
        var out = [Double](repeating: 0, count: items.count)
        guard items.count > 1 else { return out }
        for i in 1..<items.count {
            let lo = max(0, i - window)
            var c = [Double](repeating: 0, count: items[i].vec.count)
            var n = 0
            for j in lo..<i where items[j].vec.count == c.count {
                for d in 0..<c.count { c[d] += items[j].vec[d] }
                n += 1
            }
            guard n > 0 else { continue }
            for d in 0..<c.count { c[d] /= Double(n) }
            out[i] = 1 - cos(items[i].vec, c)
        }
        return out
    }

    /// Boundary indices — the positions that START a new episode.
    ///
    /// Adaptive rather than absolute: the threshold is the day's own mean plus `k` standard
    /// deviations, because surprise scales differ between a day of one long build and a day
    /// of scattered errands. A fixed cutoff calibrated on one would over- or under-segment
    /// the other.
    ///
    /// **EM-LLM's graph-theoretic refinement is not implemented.** After surprise-based
    /// boundaries it maximizes modularity over the similarity graph to shift each boundary to
    /// its locally best position. What is here is the surprise pass plus temporal contiguity;
    /// the refinement would move boundaries by an event or two, and is not worth its
    /// complexity until the summaries built on top are good enough for that to be the
    /// limiting factor.
    static func boundaries(_ items: [Item], _ p: Params) -> (idx: [Int], sur: [Double], threshold: Double) {
        let sur = surprise(items, window: p.window)
        guard items.count > p.minEvents else { return ([0], sur, 0) }
        let scored = Array(sur.dropFirst())
        let mean = scored.reduce(0, +) / Double(max(1, scored.count))
        let varr = scored.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, scored.count))
        let threshold = mean + p.k * varr.squareRoot()

        var cuts: [Int] = [0]
        for i in 1..<items.count {
            let gapped = (items[i].ts - items[i - 1].ts) > Int64(p.gapMinutes) * 60_000_000
            let surprising = sur[i] > threshold
            guard gapped || surprising else { continue }
            // Temporal contiguity: do not cut into a run shorter than minEvents unless the
            // clock forces it. A boundary every other event is not a segmentation.
            if let last = cuts.last, i - last < p.minEvents, !gapped { continue }
            cuts.append(i)
        }
        // Split anything that ran away, so one long build is not a single 400-event episode
        // the summarizer cannot see the whole of.
        var out: [Int] = []
        for (n, c) in cuts.enumerated() {
            out.append(c)
            let end = n + 1 < cuts.count ? cuts[n + 1] : items.count
            var at = c + p.maxEvents
            while at < end { out.append(at); at += p.maxEvents }
        }
        return (out, sur, threshold)
    }

    struct Episode {
        let id: String
        let items: [Item]
        var title = "", summary = ""
        var lines: [(String, Int64)] = []
        let peak: Double
    }

    static func build(_ items: [Item], _ p: Params) -> [Episode] {
        let (rawCuts, sur, _) = boundaries(items, p)
        // Merge runs shorter than minEvents into their neighbour. A stretch of one event is
        // not an episode, and left alone they arrive as singleton "episodes" holding a single
        // stray notification — which then gets its own line in the day's read-out.
        var cuts: [Int] = []
        for (n, c) in rawCuts.enumerated() {
            let end = n + 1 < rawCuts.count ? rawCuts[n + 1] : items.count
            if end - c < p.minEvents, !cuts.isEmpty { continue }   // fold into the previous
            cuts.append(c)
        }
        // A short FIRST run has no previous to fold into, so it borrows the next boundary.
        if cuts.count > 1, (cuts[1] - cuts[0]) < p.minEvents { cuts.removeFirst() }
        var out: [Episode] = []
        for (n, c) in cuts.enumerated() {
            let end = n + 1 < cuts.count ? cuts[n + 1] : items.count
            guard end - c >= p.minEvents else { continue }
            let slice = Array(items[c..<end])
            let peak = slice.indices.map { sur[c + $0] }.max() ?? 0
            out.append(Episode(id: "epi_" + sha("\(slice[0].seq)|\(slice.count)").prefix(16),
                               items: slice, peak: peak))
        }
        return out
    }

    // MARK: - S2

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Generable
    struct Line {
        @Guide(description: "One thing that happened, in a single plain sentence.")
        var text: String
        @Guide(description: "The number shown in brackets at the start of the note this came from.")
        var from: Int
    }

    @available(macOS 26.0, *)
    @Generable
    struct Recap {
        @Guide(description: "A short phrase naming what this stretch of time was about.")
        var title: String
        @Guide(description: "The things that happened, at most five, each traced to the note it came from.")
        var lines: [Line]
    }

    /// Area F's rule for every stage: *"under ~15–20k tokens of evidence per prompt,
    /// instruction and schema at both top and bottom."* The bottom repetition is the part
    /// that is easy to skip and is doing real work — a long evidence block otherwise pushes
    /// the instruction out of the model's effective attention, and it starts summarizing the
    /// last note instead of the episode.
    static let mapInstructions = """
        You are given numbered notes from one stretch of a person's day, in order.

        Write down what happened. One plain sentence per thing, at most five, and after each
        one give the number of the note it came from. Only write things the notes actually
        say. Do not add advice, do not guess at motives, and do not write a sentence you
        cannot point at a note for.

        Then name the stretch in a short phrase — what it was about, not how it went.
        """
#endif

    static func mapPrompt(_ items: [Item], budget: Int = 9000) -> String {
        var out = "", used = 0
        for it in items {
            let body = it.text.replacingOccurrences(of: "\n", with: " ")
            let take = String(body.prefix(max(120, budget / max(1, items.count))))
            let line = "[\(it.seq)] (\(it.source)) \(take)\n"
            if used + line.count > budget { break }
            out += line; used += line.count
        }
        return out
    }

    struct Report {
        var day = "", events = 0, episodes = 0, summarized = 0, failed = 0
        var lines = 0, uncited = 0, threshold = 0.0
        var judgeFailed = false, lastError = ""
        var built: [Episode] = []
    }

    @available(macOS 26.0, *)
    static func run(_ s: Store, _ p: Params, sources: String, summarize: Bool,
                    verbose: Bool) async -> Report {
        var rep = Report()
        migrate(s)
        let day = p.day.isEmpty
            ? (s.rows("SELECT date(max(ts)/1000000,'unixepoch','localtime') FROM events WHERE ts < \(Connect.tsCeil);").first?.first ?? "")
            : p.day
        rep.day = day
        let its = items(s, day: day, sources: sources)
        rep.events = its.count
        guard its.count > 1 else { return rep }

        let (_, _, threshold) = boundaries(its, p)
        rep.threshold = threshold
        var eps = build(its, p)
        rep.episodes = eps.count

#if canImport(FoundationModels)
        if summarize {
            guard case .available = SystemLanguageModel.default.availability else {
                print("Foundation Models unavailable — S1 only"); rep.built = eps; return rep
            }
            for i in eps.indices {
                let allowed = Set(eps[i].items.map(\.seq))
                let prompt = """
                    \(mapPrompt(eps[i].items))
                    Write down what happened in these notes, one plain sentence per thing, at
                    most five, each followed by the number of the note it came from. Only what
                    the notes say. Then name the stretch in a short phrase.
                    """
                do {
                    let r = try await LanguageModelSession(instructions: mapInstructions)
                        .respond(to: prompt, generating: Recap.self)
                    eps[i].title = r.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    // A citation to a note outside this episode is not a citation. Checked
                    // rather than trusted, for the same reason S5's shared term is: the model
                    // will produce a plausible number, and a derived layer nobody can trace
                    // back is worse than no derived layer.
                    for l in r.content.lines {
                        let t = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { continue }
                        if allowed.contains(Int64(l.from)) {
                            eps[i].lines.append((t, Int64(l.from))); rep.lines += 1
                        } else { rep.uncited += 1 }
                    }
                    eps[i].summary = eps[i].lines.map(\.0).joined(separator: " ")
                    rep.summarized += 1
                    if verbose {
                        print("    \(eps[i].items.count)ev  \(eps[i].title.prefix(60))")
                        for (t, q) in eps[i].lines { print("       · \(t.prefix(88)) [\(q)]") }
                    }
                } catch {
                    rep.failed += 1
                    rep.lastError = (error as NSError).localizedDescription
                    if verbose { print("    recap failed: \(rep.lastError)") }
                    if rep.summarized == 0 && rep.failed >= 3 { rep.judgeFailed = true; break }
                }
            }
        }
#endif
        rep.built = eps
        return rep
    }

    static func persist(_ s: Store, _ eps: [Episode], day: String) {
        migrate(s)
        s.exec("BEGIN;")
        for e in eps {
            let srcs = Array(Set(e.items.map(\.source))).sorted().joined(separator: ",")
            var st: OpaquePointer?
            sqlite3_prepare_v2(s.db, """
                INSERT INTO episode(episode_id,day,started_at,ended_at,n_events,sources,
                                    title,summary,peak_surprise,created_at)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(episode_id) DO UPDATE SET
                  title=excluded.title, summary=excluded.summary;
                """, -1, &st, nil)
            s.bind(st, 1, e.id); s.bind(st, 2, day)
            sqlite3_bind_int64(st, 3, e.items.first?.ts ?? 0)
            sqlite3_bind_int64(st, 4, e.items.last?.ts ?? 0)
            sqlite3_bind_int(st, 5, Int32(e.items.count))
            s.bind(st, 6, srcs); s.bind(st, 7, e.title); s.bind(st, 8, e.summary)
            sqlite3_bind_double(st, 9, e.peak); s.bind(st, 10, Ledger.now())
            sqlite3_step(st); sqlite3_finalize(st)

            for it in e.items {
                sqlite3_prepare_v2(s.db,
                    "INSERT OR IGNORE INTO episode_event(episode_id,seq) VALUES(?,?);", -1, &st, nil)
                s.bind(st, 1, e.id); sqlite3_bind_int64(st, 2, it.seq)
                sqlite3_step(st); sqlite3_finalize(st)
            }
            s.exec("DELETE FROM episode_line WHERE episode_id='\(Ledger.esc(e.id))';")
            for (n, l) in e.lines.enumerated() {
                sqlite3_prepare_v2(s.db,
                    "INSERT INTO episode_line(episode_id,ord,text,seq) VALUES(?,?,?,?);", -1, &st, nil)
                s.bind(st, 1, e.id); sqlite3_bind_int(st, 2, Int32(n))
                s.bind(st, 3, l.0); sqlite3_bind_int64(st, 4, l.1)
                sqlite3_step(st); sqlite3_finalize(st)
            }
        }
        s.exec("COMMIT;")
    }

    struct Stored { let id, title, day: String; let n: Int; let from, to: Int64 }

    static func forDay(_ s: Store, day: String) -> [Stored] {
        s.rows("""
            SELECT episode_id, coalesce(title,''), day, n_events, started_at, ended_at
            FROM episode WHERE day='\(Ledger.esc(day))' ORDER BY started_at;
            """).map {
            Stored(id: $0[0], title: $0[1], day: $0[2], n: Int($0[3]) ?? 0,
                   from: Int64($0[4]) ?? 0, to: Int64($0[5]) ?? 0)
        }
    }

    static func lines(_ s: Store, episode: String) -> [(String, Int64)] {
        s.rows("SELECT text, seq FROM episode_line WHERE episode_id='\(Ledger.esc(episode))' ORDER BY ord;")
            .map { ($0[0], Int64($0[1]) ?? 0) }
    }
}
