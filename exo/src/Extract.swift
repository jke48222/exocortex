import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Claim extraction into the belief ledger, using Apple's on-device Foundation Model.
///
/// Area E's tiering put a ~3B on-device model in the always-on structured-extraction tier
/// and reserved larger models for the nightly batch. This is that tier: it ships with the
/// OS, needs no download, and — the property that actually matters for this corpus — the
/// text never leaves the machine.
///
/// Two findings from Area E shape the prompt:
///
///  * **Schema field names are prompt tokens.** A first pass whose `@Guide` said
///    "e.g. prefers, believes, ships_in" produced `ships_in` and `believes` for text about
///    choosing SQLite — the model copied the examples rather than choosing a relation.
///    Descriptions now say what a field *means*, never what values to pick.
///  * **Expect 60–75 F1 and design for correction.** Everything lands with confidence and
///    full provenance so a wrong claim is visible and cheap to remove, rather than
///    quietly becoming a belief.
///
/// Only `trust=self` events are eligible. A belief is *yours*; a model's assertion or a web
/// page's claim is not, and promoting untrusted text into the belief ledger is precisely
/// the memory-poisoning path the trust ladder exists to block.
enum Extract {

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Generable
    struct RawClaim {
        @Guide(description: "Who or what the statement is about. Use 'me' when the speaker is talking about themselves.")
        var subject: String
        @Guide(description: "The relationship, as a short snake_case verb phrase drawn from the statement's own wording.")
        var predicate: String
        @Guide(description: "What the subject stands in that relationship to.")
        var object: String
        @Guide(description: "False when the statement denies or rejects the relationship.")
        var affirmative: Bool
        @Guide(description: "How long this is likely to remain true: stable, seasonal, or volatile.")
        var volatility: String
        @Guide(description: "True only when the writer is expressing what they like, dislike, want, prefer, chose, decided, believe or think. False for a plain report of facts, times, weather or arrangements.")
        var expressesOpinion: Bool
        @Guide(description: "True only if this reveals something lasting about the writer as a person — their taste, values, habits, or how they see themselves — that would still be true a year from now even if every current project vanished. False for anything about a specific task, file, website, or piece of work.")
        var revealsCharacter: Bool
        @Guide(description: "The situation this holds in, or empty if it holds generally.")
        var scope: String
        @Guide(description: "A short restatement of the claim as a standalone sentence.")
        var summary: String
    }

    @available(macOS 26.0, *)
    @Generable
    struct RawClaimSet {
        @Guide(description: "Durable claims present in the text. Empty when the text contains none.")
        var claims: [RawClaim]
    }

    /// Balanced deliberately. An earlier version led with a long list of exclusions and
    /// the line "an empty list is the expected answer", and the model then returned empty
    /// for everything — including "i dont like the white box shadow rims", which is
    /// exactly the kind of standing preference this exists to capture. Leading with what
    /// TO extract, and gating the rest on an explicit opinion flag, recovers the positives
    /// without readmitting weather and logistics.
    /// The distinction that took three failed passes to name: a DIRECTIVE is not a
    /// disposition. "I want the etag to change" and "I want a digital brain that transforms
    /// how I work" are both "I want", and only the second says anything about the person.
    /// The first corpus this ran against was mostly instructions to an assistant, so 141 of
    /// 145 extracted claims were tasks. No amount of prompt-tightening turns a task into a
    /// belief; the fix is a discriminator on whether the statement outlives the work.
    static let instructions = """
        You extract lasting things about WHO THE WRITER IS: their taste, values, opinions,
        habits, and how they see themselves and other people.

        The test for every candidate claim: would this still be true and worth knowing a
        year from now, if every project they are currently working on disappeared?

        EXTRACT — these survive the test:
        - "I hate driving at night"
        - "I think loyalty matters more than talent"
        - "I've always been the one who plans things"
        - "I don't drink anymore"

        DO NOT EXTRACT — these are instructions or transient work, not character:
        - "I want the homepage title to change"    (a task)
        - "I like the software ones"               (about a work artifact)
        - "make the video shorter"                 (a command)
        - "arrive by 9:30", "tomorrow is sunny"    (logistics, weather)
        - anything about what someone else said

        The writer is "me". One proposition per claim; split conjunctions.
        Use the writer's own wording. Most messages contain nothing that survives the
        test, and an empty list is a good answer.
        """
    static var promptHash: String { sha(instructions).prefix(16).description }
#endif

    /// Candidate events: only what the principal actually wrote, long enough to state
    /// something, and not already extracted.
    static func candidates(_ s: Store, limit: Int, order: String = "e.seq DESC") -> [(Int64, String)] {
        s.rows("""
            SELECT e.seq, e.text FROM events e
            LEFT JOIN belief_evidence v ON v.seq = e.seq
            WHERE e.trust = 'self'
              AND length(e.text) BETWEEN 60 AND 2000
              AND v.seq IS NULL
              -- Beliefs live in deliberate writing. iMessage and calendar entries are
              -- overwhelmingly logistics ("arrive by 9:30", "tomorrow is sunny"), which is
              -- where the first pass found its weather forecasts.
              -- Self-expression lives in conversation, not in instructions to a tool.
              -- claudecode is excluded outright: 141 of the first 145 claims came from it
              -- and every one was a task request.
              AND e.source IN ('imessage','iphone.note','iphone.whatsapp','gmail','imap')
              -- Only 137 of 12,673 self events (1.1%) contain a first-person statement.
              -- Scanning the other 98.9% is the model reading logistics and correctly
              -- finding nothing, at ~0.7s each. Target the disclosure directly.
              AND (lower(e.text) LIKE '%i think %' OR lower(e.text) LIKE '%i feel %'
                OR lower(e.text) LIKE '%i believe%' OR lower(e.text) LIKE '%i hate %'
                OR lower(e.text) LIKE '%i love %'  OR lower(e.text) LIKE '%i prefer%'
                OR lower(e.text) LIKE '%i always%' OR lower(e.text) LIKE '%i never%'
                OR lower(e.text) LIKE '%i don''t like%' OR lower(e.text) LIKE '%i want to be%'
                OR lower(e.text) LIKE '%i care about%' OR lower(e.text) LIKE '%i''m the kind%')
              -- Claude Code stores slash commands, caveats and system reminders as
              -- type:user records. They are scaffolding the principal never wrote, and
              -- they dominated the first candidate pool.
              AND e.text NOT LIKE '<command-%'
              AND e.text NOT LIKE '<local-command-%'
              AND e.text NOT LIKE '%<system-reminder>%'
              AND e.text NOT LIKE 'Caveat:%'
              AND e.text NOT LIKE '%stdin%</command-'
            ORDER BY \(order) LIMIT \(limit);
            """).compactMap { r in
            guard let seq = Int64(r[0]) else { return nil }
            return (seq, r[1])
        }
    }

    struct Result { var scanned = 0, claims = 0, empty = 0, failed = 0, dropped = 0 }

    @available(macOS 26.0, *)
    static func run(_ s: Store, limit: Int, verbose: Bool,
                    order: String = "e.seq DESC") async -> Result {
        var out = Result()
#if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            print("Foundation Models unavailable on this machine"); return out
        }
        Ledger.migrate(s)
        let run = Ledger.startRun(s, model: "apple.foundation.ondevice", version: "os26",
                                  promptHash: promptHash, codeVersion: "extract-1")
        let items = candidates(s, limit: limit, order: order)
        guard !items.isEmpty else { print("no unextracted trust=self events"); return out }

        for (seq, text) in items {
            out.scanned += 1
            // A fresh session per item: a shared session accumulates prior events in its
            // context, so claims from one message start bleeding into the next.
            let session = LanguageModelSession(instructions: instructions)
            do {
                let r = try await session.respond(to: "Statement:\n\(text.prefix(1500))",
                                                  generating: RawClaimSet.self)
                if r.content.claims.isEmpty { out.empty += 1 }
                // Cap per event. One message about a slide deck produced ten near-identical
                // claims (slide-12 … slide-23); that is degenerate extraction, not ten
                // beliefs, and it drowns the review queue that makes the rest usable.
                var kept = 0
                for c in r.content.claims {
                    if kept >= 3 { out.dropped += 1; continue }
                    let subj = c.subject.trimmingCharacters(in: .whitespaces).lowercased()
                    let pred = c.predicate.trimmingCharacters(in: .whitespaces).lowercased()
                    guard !subj.isEmpty, !pred.isEmpty, !c.summary.isEmpty else { continue }
                    // `volatility` was extracted but never acted on, which is how weather
                    // forecasts became standing beliefs. A belief ledger is for what stays
                    // true; volatile facts belong in the event log, where they already are.
                    // The opinion flag is the real discriminator. Volatility alone was not
                    // enough: "tomorrow is sunny" came back tagged `seasonal`, not
                    // `volatile`, and so survived a volatility-only filter.
                    guard c.expressesOpinion, c.revealsCharacter else { out.dropped += 1; continue }
                    if c.volatility.lowercased().hasPrefix("vol") { out.dropped += 1; continue }
                    // Beliefs are the principal's. Claims about other people are
                    // third-party assertions, not things I believe.
                    guard subj == "me" || subj == "i" || subj.hasPrefix("me ") else {
                        out.dropped += 1; continue
                    }
                    let cid = Ledger.upsertClaim(s, subject: subj, predicate: pred,
                                                 object: c.object.isEmpty ? nil : c.object,
                                                 polarity: c.affirmative ? 1 : -1,
                                                 scope: c.scope.isEmpty ? nil : c.scope,
                                                 norm: c.summary)
                    // The event's own timestamp is when the belief was held — not now.
                    let when = s.rows("SELECT strftime('%Y-%m-%dT%H:%M:%SZ', ts/1000000, 'unixepoch') FROM events WHERE seq=\(seq);")
                        .first?.first ?? Ledger.now()
                    _ = Ledger.mindChange(s, from: nil, toClaim: cid, at: when,
                                          confidence: 0.6,
                                          confidenceSrc: "model_selfreport",
                                          runID: run, evidence: [seq])
                    out.claims += 1; kept += 1
                    if verbose { print("    [\(seq)] \(subj) · \(pred) · \(c.object) \(c.affirmative ? "" : "(negated)")") }
                }
            } catch {
                out.failed += 1
                if verbose { print("    [\(seq)] failed: \(String(describing: error).prefix(80))") }
            }
        }
#endif
        return out
    }
}
