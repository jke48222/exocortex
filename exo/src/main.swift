import Foundation
import AppKit
import ApplicationServices

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ n: String, _ d: String) -> String {
    if let i = args.firstIndex(of: n), i + 1 < args.count { return args[i + 1] }
    return d
}
func flag(_ n: String) -> Bool { args.contains(n) }
func positional() -> [String] {
    var out: [String] = []; var i = 1
    while i < args.count {
        let a = args[i]
        if ["--db", "--limit", "--interval", "--files", "--days", "--min-trust", "--reason"].contains(a) { i += 2; continue }
        if a.hasPrefix("--") { i += 1; continue }
        out.append(a); i += 1
    }
    return out
}
func stamp(_ micros: Int64) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = .current
    return f.string(from: Date(timeIntervalSince1970: Double(micros) / 1_000_000))
}

let dbPath = expand(opt("--db", "~/.exocortex/phase1.db"))
let cmd = args.first ?? "help"

switch cmd {

case "perms":
    print("Accessibility trusted: \(AXIsProcessTrusted() ? "YES" : "NO")")
    print("Claude Code transcripts: \(FileManager.default.fileExists(atPath: ClaudeCode.root) ? "found" : "not found") (no permission needed)")
    if !AXIsProcessTrusted() {
        print("\nGrant Accessibility: System Settings > Privacy & Security > Accessibility")
    }

case "ingest":
    // Phase 1 headline source: zero permissions, highest volume.
    let store = Store(dbPath)
    let files = Int(opt("--files", "0")).flatMap { $0 > 0 ? $0 : nil }
    let days = Int(opt("--days", "0")).flatMap { $0 > 0 ? $0 : nil }
    let since = days.map { Date().addingTimeInterval(-Double($0) * 86_400) }
    let t0 = Date()
    let (n, skip, red) = ClaudeCode.ingest(into: store, limitFiles: files, since: since)
    store.checkpoint()
    let dt = Date().timeIntervalSince(t0)
    print("claudecode: +\(n) ingested, \(skip) skipped, \(red) secret-shaped lines redacted")
    print("  \(String(format: "%.1f", dt))s · total events now \(store.count())")

case "capture":
    let store = Store(dbPath)
    let interval = Double(opt("--interval", "2")) ?? 2
    var last = store.lastHash()
    var pbChange = -1   // sentinel: force the first tick to evaluate the clipboard
    if !AXIsProcessTrusted() {
        FileHandle.standardError.write("warning: Accessibility not granted (run `exo perms`)\n".data(using: .utf8)!)
    }
    func tick() {
        if let e = Capture.focus(store: store), e.hash != last {
            if store.insert(e) { last = e.hash; print("· \(e.source)  \(e.app) — \(e.title.prefix(52))") }
        }
        if let c = Capture.clipboard(store: store, lastChange: &pbChange), store.insert(c) {
            print("· clipboard  \(c.text.prefix(52).replacingOccurrences(of: "\n", with: " "))")
        }
    }
    if flag("--once") { tick(); store.checkpoint(); break }
    signal(SIGINT) { _ in exit(0) }
    print("capturing every \(interval)s -> \(dbPath)  (Ctrl-C to stop)")
    var i = 0
    while true { tick(); i += 1; if i % 30 == 0 { store.checkpoint() }; Thread.sleep(forTimeInterval: interval) }

case "search":
    let store = Store(dbPath)
    let q = positional().joined(separator: " ")
    guard !q.isEmpty else { print("usage: exo search <query> [--min-trust verified]"); break }
    let mt = opt("--min-trust", "")
    let hits = store.search(q, limit: Int(opt("--limit", "8")) ?? 8, minTrust: mt.isEmpty ? nil : mt)
    if hits.isEmpty { print("no matches for: \(q)"); break }
    for h in hits {
        print("[\(stamp(h.ts))] \(h.app) — \(h.title)")
        if !h.snip.isEmpty { print("    \(h.snip.replacingOccurrences(of: "\n", with: " "))") }
        print("    seq=\(h.seq) src=\(h.source) trust=\(h.trust) bm25=\(String(format: "%.2f", h.score))")
    }

case "retention":
    let store = Store(dbPath)
    let dry = !flag("--apply")
    print("litigation hold: \(Retention.holdActive(store) ? "ACTIVE — all expiry suspended" : "inactive")")
    print(dry ? "mode: DRY RUN (pass --apply to delete)\n" : "mode: APPLY\n")
    for r in Retention.run(store, dryRun: dry) {
        let ttl = r.ttl.map { "\($0)d" } ?? "forever"
        let what = r.skipped ? "would delete" : "deleted"
        print("  \(r.cls.padding(toLength: 12, withPad: " ", startingAt: 0)) ttl=\(ttl.padding(toLength: 8, withPad: " ", startingAt: 0)) \(what) \(r.deleted)")
    }

case "hold":
    let store = Store(dbPath)
    let on = positional().first == "on"
    Retention.setHold(store, on, reason: opt("--reason", "manual"))
    print("litigation hold \(on ? "ENABLED — retention expiry suspended" : "released")")

case "stats":
    let store = Store(dbPath)
    func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
    print("db: \(dbPath)")
    print("events: \(store.count())")

    print("\nby source and trust:")
    for r in store.rows("SELECT source, trust, count(*) FROM events GROUP BY source, trust ORDER BY count(*) DESC;") {
        print("  \(pad(r[0], 22)) trust=\(pad(r[1], 13)) \(r[2])")
    }

    print("\nexclusion hits (records THAT, never WHAT):")
    let ex = store.rows("SELECT rule, coalesce(nullif(app,''),'?'), count(*) FROM exclusion_hit GROUP BY rule, app ORDER BY count(*) DESC;")
    if ex.isEmpty { print("  (none yet)") }
    for r in ex { print("  \(pad(r[0], 32)) \(pad(r[1], 16)) \(r[2])") }

    print("\nretention policy (effective date is the FRCP 37(e) defense):")
    for r in store.rows("SELECT class, coalesce(ttl_days,-1), effective_from FROM retention_policy ORDER BY class;") {
        let ttl = r[1] == "-1" ? "forever" : "\(r[1])d"
        print("  \(pad(r[0], 12)) ttl=\(pad(ttl, 9)) effective \(r[2].prefix(10))")
    }
    let receipts = store.rows("SELECT count(*), coalesce(sum(rows_deleted),0) FROM purge_receipt;")
    if let r = receipts.first { print("\npurge receipts: \(r[0]) runs, \(r[1]) rows deleted") }
    print("litigation hold: \(Retention.holdActive(store) ? "ACTIVE" : "inactive")")

case "seed":
    let store = Store(dbPath)
    var samples: [Event] = []
    func mk(_ src: String, _ k: SourceKind, _ app: String, _ title: String, _ text: String) -> Event {
        var e = Event(source: src, sourceKind: k); e.app = app; e.title = title; e.text = text; return e
    }
    samples.append(mk("ax.focus", .ocr, "Xcode", "Store.swift — exocortex", "external-content FTS5 with bm25 ranking over the event log"))
    samples.append(mk("claudecode", .typed, "Claude Code", "fun-project", "belief version control needs the mind-change vs re-extraction distinction"))
    samples.append(mk("claudecode", .modelOutput, "Claude Code", "fun-project", "planets only ever turn one way so cheap gears still hit arcminute precision"))
    samples.append(mk("clipboard", .ocr, "Safari", "clipboard", "snippet() returns a fragment of text with matches delimited"))
    for s in samples { store.insert(s) }
    store.checkpoint()
    print("seeded \(samples.count) events (total \(store.count()))")

default:
    print("""
    exo — Exocortex Phase 1 (capture fleet -> SQLite/FTS5 -> search)

      exo perms                     what's granted
      exo ingest [--days N] [--files N]
                                    ingest Claude Code transcripts (zero permissions)
      exo capture [--interval 2] [--once]
                                    AX-tree + clipboard capture loop
      exo search <query> [--min-trust verified] [--limit N]
      exo retention [--apply]       run scheduled expiry (dry-run by default)
      exo hold on|off [--reason ..] litigation hold: suspend ALL expiry
      exo stats                     counts, trust mix, exclusions, policy
      exo seed                      synthetic events, no permissions needed

      --db <path>                   default ~/.exocortex/phase1.db
    """)
}
