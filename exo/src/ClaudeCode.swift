import Foundation

/// Claude Code transcript ingest — the highest-value source in the fleet and it costs
/// ZERO permissions: ~/.claude/projects/<slug>/<session>.jsonl is in your own home dir.
/// Measured on this machine: 1,209 files, 1.6 GB, ~53 MB/day over the last week.
///
/// Schema verified on disk 2026-08-19: record `type` ∈ {user, assistant, ai-title,
/// last-prompt, custom-title, mode, queue-operation, attachment, system}; message.content
/// blocks ∈ {text, thinking, tool_use, tool_result, fallback}.
///
/// We ingest only `user` and `assistant` text blocks. tool_use/tool_result are the bulk of
/// the bytes and almost none of the meaning; `thinking` is model internals. Skipping them
/// is the auto-remember filter applied at ingest rather than after.
enum ClaudeCode {
    static var root: String { expand("~/.claude/projects") }

    static func sessionFiles() -> [URL] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var out: [URL] = []
        for d in dirs {
            let p = (root as NSString).appendingPathComponent(d)
            guard let fs = try? fm.contentsOfDirectory(atPath: p) else { continue }
            for f in fs where f.hasSuffix(".jsonl") {
                out.append(URL(fileURLWithPath: (p as NSString).appendingPathComponent(f)))
            }
        }
        return out
    }

    /// Returns (ingested, skipped, redactedLines).
    static func ingest(into store: Store, limitFiles: Int?, since: Date?) -> (Int, Int, Int) {
        var ingested = 0, skipped = 0, redacted = 0
        var files = sessionFiles()
        if let since {
            files = files.filter {
                let m = (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) ?? nil
                return (m ?? .distantPast) >= since
            }
        }
        files.sort { $0.path < $1.path }
        if let n = limitFiles { files = Array(files.prefix(n)) }

        for f in files {
            let key = f.lastPathComponent
            let prevCount = Int(store.cursor("claudecode", key) ?? "0") ?? 0
            guard let data = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let lines = data.split(separator: "\n", omittingEmptySubsequences: true)
            if lines.count <= prevCount { continue }              // nothing new; resume cheaply

            for line in lines.dropFirst(prevCount) {
                guard let d = line.data(using: .utf8),
                      let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      let type = o["type"] as? String,
                      type == "user" || type == "assistant" else { skipped += 1; continue }

                guard let msg = o["message"] as? [String: Any] else { skipped += 1; continue }
                // content is either a string or an array of typed blocks
                var text = ""
                if let s = msg["content"] as? String { text = s }
                else if let blocks = msg["content"] as? [[String: Any]] {
                    text = blocks.compactMap { b -> String? in
                        guard (b["type"] as? String) == "text" else { return nil }   // drop tool_*/thinking
                        return b["text"] as? String
                    }.joined(separator: "\n")
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { skipped += 1; continue }

                let (clean, nred) = Exclusion.redact(text)
                redacted += nred
                guard !clean.isEmpty else { skipped += 1; continue }

                // Trust by capture path: what YOU typed is `self`; what the MODEL said is
                // `model_output` -> untrusted. "Never store an unverified model assertion
                // as fact" (PASS-4 Area H).
                let kind: SourceKind = (type == "user") ? .typed : .modelOutput
                var meta: [String: String] = [:]
                for k in ["sessionId", "cwd", "gitBranch", "version", "parentUuid", "uuid"] {
                    if let v = o[k] as? String { meta[k] = v }
                }
                let ts = (o["timestamp"] as? String).flatMap {
                    ISO8601DateFormatter.withMillis.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
                }
                let proj = f.deletingLastPathComponent().lastPathComponent

                var e = Event(source: "claudecode", sourceKind: kind)
                e.app = "Claude Code"; e.bundle = "com.anthropic.claude-code"
                e.title = proj
                e.role = type
                e.text = String(clean.prefix(20_000))
                e.externalID = o["uuid"] as? String
                e.meta = meta
                if let ts { e.ts = Int64(ts.timeIntervalSince1970 * 1_000_000) }
                if store.insert(e) { ingested += 1 } else { skipped += 1 }
            }
            store.setCursor("claudecode", key, String(lines.count))
        }
        return (ingested, skipped, redacted)
    }
}

extension ISO8601DateFormatter {
    static let withMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
