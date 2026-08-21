import Foundation
import SQLite3
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The **Historian** daemon — the week as a story, when it has one.
///
/// Area F: *Sunday · Opus-tier, narrative quality IS the product · failure mode is
/// narrativization — instruct "some weeks have no story; say so."* Two of those three
/// clauses are implemented differently here, deliberately, and the reasons are measured
/// rather than aesthetic:
///
/// **The input is the episode layer, not the raw week.** §6–§8 establish where the
/// on-device model breaks: judgement over long context fails (14/14 wrong verdicts, 38/40
/// confabulated links), description over short evidence works (0 bad quotes in §10, clean
/// episode lines in §8). A raw week is 1,000+ events of long context; a week of episodes is
/// a couple dozen short, already-cited lines. Feeding the Historian S2's output instead of
/// S0's is what Area F's "hierarchical map-reduce" means when it reaches the top level —
/// and it converts the task from the kind this model fails into the kind it passes.
///
/// **The model does not decide whether the week has a story.** The instruction "say so" is
/// still in the prompt, but §7 measured what schema-level escape hatches are worth here:
/// offered a `sharesSomethingSpecific: Bool` it could set to false, the model used it 0
/// times in 39. So the no-story decision is made by code, twice over: a week with fewer
/// than `minEpisodes` summarized episodes never reaches the model at all, and a reply whose
/// beats survive citation-checking fewer than `minBeats` times is recorded as story-less
/// regardless of how confident its headline sounds. A beat must name an episode that is
/// actually in the week — verified the same way §8 verifies episode lines against their
/// events.
///
/// **Where Area F says Opus-tier, this runs the on-device 3B, and that is a constraint
/// worth stating rather than hiding.** The corpus's one non-negotiable property (Extract.swift)
/// is that the text never leaves the machine; shipping a week of episodes to a cloud model
/// would quietly break it. So the harness — assembly, verification, the no-story default,
/// the Sunday trigger, cascade on deletion — is the durable part, and the model is the
/// swappable part. If a frontier-quality local model lands, one function changes.
enum Historian {

    /// Fewer summarized episodes than this and the week is structurally story-less —
    /// no model call is made. One episode is a day's work, not an arc.
    static let minEpisodes = 2
    /// Fewer verified beats than this and the week is recorded as story-less, whatever
    /// the model's headline claimed.
    static let minBeats = 2
    static let maxBeats = 6

    static func migrate(_ s: Store) {
        s.exec("""
        CREATE TABLE IF NOT EXISTS weekly_note(
          week TEXT PRIMARY KEY,              -- the Sunday the week ends on, ISO day
          start_day TEXT NOT NULL,
          headline TEXT NOT NULL,             -- '' when has_story = 0
          has_story INTEGER NOT NULL,
          episodes INTEGER NOT NULL,
          created_at TEXT NOT NULL
        ) STRICT;
        """)
        s.exec("""
        CREATE TABLE IF NOT EXISTS weekly_beat(
          week TEXT NOT NULL REFERENCES weekly_note(week) ON DELETE CASCADE,
          ord INTEGER NOT NULL,
          text TEXT NOT NULL,
          -- Same rule as episode_line.seq: a derived line with no checkable source is a
          -- line nobody can audit and nobody can delete. Beats cite episodes; episodes
          -- cite events; deletion cascades the whole chain.
          episode_id TEXT NOT NULL REFERENCES episode(episode_id) ON DELETE CASCADE,
          PRIMARY KEY (week, ord)
        ) STRICT;
        """)
    }

    // MARK: - the week

    /// Monday-to-Sunday, keyed by the Sunday it ends on, in the person's own calendar —
    /// the same 'localtime' rule §8 landed on after an evening event drifted into tomorrow.
    static func weekEnding(containing dayISO: String) -> (start: String, end: String)? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        guard let d = f.date(from: dayISO) else { return nil }
        let wd = Calendar.current.component(.weekday, from: d)   // 1 = Sunday
        let toSunday = wd == 1 ? 0 : 8 - wd
        let end = d.addingTimeInterval(Double(toSunday) * 86_400)
        let start = end.addingTimeInterval(-6 * 86_400)
        return (f.string(from: start), f.string(from: end))
    }

    static func isSunday(_ date: Date = Date()) -> Bool {
        Calendar.current.component(.weekday, from: date) == 1
    }

    struct WeekEpisode {
        let id, day, title: String
        let n: Int
        let lines: [(String, Int64)]
    }

    /// Only summarized episodes are offered as evidence — a beat has to point at something
    /// with words in it.
    static func episodes(_ s: Store, start: String, end: String) -> [WeekEpisode] {
        s.rows("""
            SELECT episode_id, day, coalesce(title,''), n_events
            FROM episode
            WHERE day BETWEEN '\(Ledger.esc(start))' AND '\(Ledger.esc(end))'
              AND coalesce(title,'') <> ''
            ORDER BY day, started_at;
            """).map {
            WeekEpisode(id: $0[0], day: $0[1], title: $0[2], n: Int($0[3]) ?? 0,
                        lines: Segment.lines(s, episode: $0[0]))
        }
    }

    // MARK: - verification

    static func normalizeID(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        })
    }

    /// A beat survives only when it cites an episode that is actually in the week. The
    /// model returns ids in whatever dress it likes — brackets, prefixes, case — so match
    /// on normalized form, against the offered set and nothing wider.
    static func verified(_ beats: [(text: String, from: String)],
                         offered: [String]) -> [(String, String)] {
        let byKey = Dictionary(uniqueKeysWithValues: offered.map { (normalizeID($0), $0) })
        var out: [(String, String)] = []
        for b in beats {
            guard out.count < maxBeats else { break }
            let t = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 8, let hit = byKey[normalizeID(b.from)] else { continue }
            out.append((t, hit))
        }
        return out
    }

    // MARK: - the model's one job

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Generable
    struct Beat {
        @Guide(description: "One thing that mattered this week, in a single plain sentence drawn from the episodes.")
        var text: String
        @Guide(description: "The id in square brackets of the episode this comes from.")
        var from: String
    }

    @available(macOS 26.0, *)
    @Generable
    struct WeekStory {
        @Guide(description: "A short headline naming what the week was about, in the person's own terms.")
        var headline: String
        @Guide(description: "The beats of the week in order, each traced to one episode.")
        var beats: [Beat]
    }

    /// The "say so" clause is kept because Area F names it verbatim — but §7 measured what
    /// it is worth (an escape hatch used 0/39), so nothing downstream trusts it. Code
    /// counts verified beats and decides.
    static let instructions = """
        You are shown one week of a person's life, already cut into titled episodes, each
        with a few cited lines about what happened.

        Write the story of the week: a short headline, then the beats that mattered, in
        order, at most six. One plain sentence per beat, and with each one give the id in
        square brackets of the episode it comes from. Only write what the episodes say.

        Do not invent an arc that is not there and do not pad. Some weeks have no story;
        when the episodes are routine, few beats — or none — is the right answer.
        """
    static var promptHash: String { sha(instructions).prefix(16).description }
#endif

    static func prompt(_ eps: [WeekEpisode]) -> String {
        var out = ""
        let f = DateFormatter(); f.dateFormat = "EEE"; f.timeZone = .current
        let g = DateFormatter(); g.dateFormat = "yyyy-MM-dd"; g.timeZone = .current
        for e in eps {
            let dayName = g.date(from: e.day).map { f.string(from: $0) } ?? e.day
            out += "[\(e.id)] \(dayName) \(e.day) — \(e.title) (\(e.n) events)\n"
            for (t, _) in e.lines.prefix(4) { out += "    · \(t.prefix(200))\n" }
        }
        return out
    }

    // MARK: - run

    /// What the model is shown, chosen in code — because a real week overflows the window.
    ///
    /// The first live week held **49 summarized episodes** (one heavy build day alone cut
    /// into 40), and 49 × 5 lines is far past the on-device window that §7 already hit
    /// ("Exceeded model context window size") with less. Area F's per-stage rule — under
    /// ~15–20k tokens of evidence — assumes a frontier window; this model's is smaller, and
    /// the honest response is *selection, stated out loud*, not truncation discovered later.
    ///
    /// Largest episodes first because event count is the one importance signal S1 produces
    /// that needs no model; capped per day so one enormous day cannot crowd the other six
    /// out of the story; then restored to chronological order, because a story is told in
    /// the order it happened. The read-out prints offered vs. existing so a selection is
    /// never mistaken for the whole week.
    static let maxOffered = 10
    static let maxPerDay = 3

    static func select(_ eps: [WeekEpisode]) -> [WeekEpisode] {
        var byDay: [String: [WeekEpisode]] = [:]
        for e in eps { byDay[e.day, default: []].append(e) }
        var picked: [WeekEpisode] = []
        for (_, dayEps) in byDay {
            picked += dayEps.sorted { $0.n > $1.n }.prefix(maxPerDay)
        }
        return picked.sorted { $0.n > $1.n }.prefix(maxOffered)
            .sorted { ($0.day, $0.id) < ($1.day, $1.id) }
    }

    struct Report {
        var week = "", start = "", episodes = 0, offered = 0
        var hasStory = false, headline = ""
        var beats: [(String, String)] = []
        var proposed = 0, uncited = 0
        var skippedStructurally = false
        var judgeFailed = false, lastError = ""
    }

    @available(macOS 26.0, *)
    static func run(_ s: Store, ending dayISO: String, verbose: Bool) async -> Report {
        var rep = Report()
        migrate(s)
        guard let (start, end) = weekEnding(containing: dayISO) else { return rep }
        rep.week = end; rep.start = start
        let eps = episodes(s, start: start, end: end)
        rep.episodes = eps.count

        // Gate 1 — structural. One episode is not an arc, and the model is never asked.
        guard eps.count >= minEpisodes else {
            rep.skippedStructurally = true
            persist(s, rep)
            return rep
        }
        let shown = select(eps)
        rep.offered = shown.count

#if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            rep.judgeFailed = true; rep.lastError = "Foundation Models unavailable"
            return rep
        }
        var attempts = 0
        while attempts < 3 {
            attempts += 1
            do {
                let r = try await LanguageModelSession(instructions: instructions)
                    .respond(to: prompt(shown), generating: WeekStory.self)
                rep.proposed = r.content.beats.count
                let ok = verified(r.content.beats.map { ($0.text, $0.from) },
                                  offered: shown.map(\.id))
                rep.uncited = rep.proposed - ok.count
                // Gate 2 — evidential. However confident the headline, a story is only as
                // real as the beats that survive citation checking.
                if ok.count >= minBeats {
                    rep.hasStory = true
                    rep.headline = r.content.headline.trimmingCharacters(in: .whitespacesAndNewlines)
                    rep.beats = ok
                }
                break
            } catch {
                rep.lastError = (error as NSError).localizedDescription
                if verbose { print("    historian failed: \(rep.lastError)") }
                // The same latching sanitizer outage every model-touching stage guards
                // against — see Contradict.scan. Three strikes, then say so out loud.
                if attempts >= 3 { rep.judgeFailed = true }
            }
        }
        if rep.judgeFailed { return rep }
#endif
        persist(s, rep)
        return rep
    }

    /// Replace, not append: re-running a week (more days segmented, better model) yields
    /// one note per week, always.
    static func persist(_ s: Store, _ rep: Report) {
        guard !rep.week.isEmpty else { return }
        s.exec("BEGIN;")
        s.exec("DELETE FROM weekly_beat WHERE week='\(Ledger.esc(rep.week))';")
        s.exec("DELETE FROM weekly_note WHERE week='\(Ledger.esc(rep.week))';")
        var st: OpaquePointer?
        sqlite3_prepare_v2(s.db, """
            INSERT INTO weekly_note(week,start_day,headline,has_story,episodes,created_at)
            VALUES(?,?,?,?,?,?);
            """, -1, &st, nil)
        s.bind(st, 1, rep.week); s.bind(st, 2, rep.start)
        s.bind(st, 3, rep.hasStory ? rep.headline : "")
        sqlite3_bind_int(st, 4, rep.hasStory ? 1 : 0)
        sqlite3_bind_int(st, 5, Int32(rep.episodes))
        s.bind(st, 6, Ledger.now())
        sqlite3_step(st); sqlite3_finalize(st)
        for (n, b) in rep.beats.enumerated() {
            sqlite3_prepare_v2(s.db,
                "INSERT INTO weekly_beat(week,ord,text,episode_id) VALUES(?,?,?,?);", -1, &st, nil)
            s.bind(st, 1, rep.week); sqlite3_bind_int(st, 2, Int32(n))
            s.bind(st, 3, b.0); s.bind(st, 4, b.1)
            sqlite3_step(st); sqlite3_finalize(st)
        }
        s.exec("COMMIT;")
    }

    // MARK: - the sidebars, code-built

    /// Everything else the week produced, drawn from the derived layer with no model in
    /// the loop. The Historian narrativizes episodes only; commitments, connections,
    /// contradictions and beliefs are already structured and are printed as they are.
    static func sidebars(_ s: Store, start: String, end: String) -> [String] {
        var out: [String] = []
        for r in s.rows("""
            SELECT action, quote FROM commitment
            WHERE status='discharged' AND substr(resolved_at,1,10) BETWEEN '\(Ledger.esc(start))' AND '\(Ledger.esc(end))'
            LIMIT 3;
            """) {
            out.append("kept: \(r[0]) — \"\(r[1].prefix(60))\"")
        }
        for r in s.rows("""
            SELECT coalesce(link,''), days_apart FROM connection
            WHERE surfaced_at IS NOT NULL AND substr(surfaced_at,1,10) BETWEEN '\(Ledger.esc(start))' AND '\(Ledger.esc(end))'
            ORDER BY serendipity DESC LIMIT 3;
            """) where !r[0].isEmpty {
            out.append("connected: \(r[0].prefix(90)) (\(r[1])d apart)")
        }
        for r in s.rows("""
            SELECT status FROM contradiction
            WHERE status <> 'open' AND reviewed_at IS NOT NULL
              AND substr(reviewed_at,1,10) BETWEEN '\(Ledger.esc(start))' AND '\(Ledger.esc(end))'
              AND resolution NOT LIKE 'auto:%'
            LIMIT 2;
            """) {
            out.append("settled a contradiction: \(r[0])")
        }
        for r in s.rows("""
            SELECT c.norm_text FROM belief b JOIN claim c USING(claim_id)
            WHERE b.sys_to IS NULL AND b.confidence_src IN ('explicit_statement','human_confirmed')
              AND substr(b.sys_from,1,10) BETWEEN '\(Ledger.esc(start))' AND '\(Ledger.esc(end))'
            LIMIT 2;
            """) {
            out.append("recorded a belief: \"\(r[0].prefix(70))\"")
        }
        return out
    }

    struct Stored {
        let week, start, headline: String
        let hasStory: Bool, episodes: Int
        let beats: [(String, String, String)]     // text, episode_id, day
    }

    static func note(_ s: Store, week: String) -> Stored? {
        guard let r = s.rows("""
            SELECT week, start_day, headline, has_story, episodes
            FROM weekly_note WHERE week='\(Ledger.esc(week))';
            """).first else { return nil }
        let beats = s.rows("""
            SELECT b.text, b.episode_id, e.day
            FROM weekly_beat b JOIN episode e ON e.episode_id = b.episode_id
            WHERE b.week='\(Ledger.esc(week))' ORDER BY b.ord;
            """).map { ($0[0], $0[1], $0[2]) }
        return Stored(week: r[0], start: r[1], headline: r[2],
                      hasStory: r[3] == "1", episodes: Int(r[4]) ?? 0, beats: beats)
    }
}
