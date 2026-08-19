import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox

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
func UInt8truncating(_ v: UInt64) -> UInt8 { UInt8(truncatingIfNeeded: v) }
func fmt(_ n: Int) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
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

case "browser":
    let store = Store(dbPath)
    let rep = Browser.ingest(into: store, limit: Int(opt("--limit", "20000")) ?? 20000,
                             days: Int(opt("--days", "0")) ?? 0)
    store.checkpoint()
    if rep.isEmpty { print("no browser history found") }
    for (name, n, status) in rep {
        print("  \(name.padding(toLength: 8, withPad: " ", startingAt: 0)) +\(n)  \(status)")
    }
    print("total events now \(store.count())")

case "imessage":
    let store = Store(dbPath)
    let (n, blob, excl, status) = IMessage.ingest(into: store,
        limit: Int(opt("--limit", "20000")) ?? 20000, days: Int(opt("--days", "0")) ?? 0)
    store.checkpoint()
    print("imessage: +\(n) ingested · \(blob) skipped (attributedBody typedstream) · \(excl) excluded · \(status)")
    if blob > 0 {
        print("  note: those \(blob) rows need `imessage-exporter` as a subprocess (GPL-3.0,")
        print("        cannot be linked). Skipped rather than half-parsed — a naive NSString")
        print("        regex recovered only 13 of 40 sampled blobs.")
    }
    print("total events now \(store.count())")

case "fs":
    let store = Store(dbPath)
    let secs = Double(opt("--seconds", "20")) ?? 20
    print("watching \(NSHomeDirectory()) for \(Int(secs))s (FSEvents, resumable)…")
    let n = FileEvents.watch(store: store, seconds: secs)
    store.checkpoint()
    print("fs: +\(n) events · total \(store.count())")

case "bar":
    // Non-activating floating panel on a global hotkey. Registered via Carbon
    // RegisterEventHotKey, which — unlike an NSEvent global monitor — needs no
    // Accessibility grant.
    let store = Store(dbPath)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)          // no Dock icon, no menu bar takeover
    let bar = BarController(store: store)
    bar.build()

    var hotKeyRef: EventHotKeyRef?
    var hkID = EventHotKeyID(signature: OSType(0x45584f43), id: 1)   // 'EXOC'
    // ⌥Space — deliberately not ⌘Space (Spotlight) or ⌥⌘Space (Finder search)
    RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), hkID,
                        GetApplicationEventTarget(), 0, &hotKeyRef)
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                             eventKind: UInt32(kEventHotKeyPressed))
    let ctx = Unmanaged.passUnretained(bar).toOpaque()
    InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
        guard let userData else { return noErr }
        let b = Unmanaged<BarController>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async { b.toggle() }
        return noErr
    }, 1, &spec, ctx, nil)

    let prefill = opt("--query", "")
    if !prefill.isEmpty {
        bar.field.stringValue = prefill
        bar.runSearch()
    }
    print("everything-bar running.  ⌥Space to toggle · Esc to dismiss · Ctrl-C to quit")
    print("  \(store.count()) events indexed")
    bar.show()
    app.run()

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

case "embed":
    let store = Store(dbPath)
    let bits = Int(opt("--bits", "1024")) ?? 1024
    let useMLX = opt("--provider", "mlx") == "mlx"
    if useMLX {
        // real semantic embeddings via the MLX sidecar
        let prov = Embed.qwenProvider
        let batch = Int(opt("--limit", "2000")) ?? 2000
        var done = 0; let t0 = Date()
        while done < batch {
            let todo = store.unvectorized(provider: prov, limit: min(64, batch - done))
            if todo.isEmpty { break }
            // one vector per CHUNK, not per document
            var pieces: [(Int64, String)] = []
            var owner: [Int: (Int64, Int)] = [:]          // synthetic id -> (seq, chunk)
            var synth = 0
            for (seq, text) in todo {
                for (ci, c) in Chunker.chunks(text).enumerated() {
                    pieces.append((Int64(synth), c)); owner[synth] = (seq, ci); synth += 1
                }
            }
            let res = EmbedMLX.embed(pieces, bits: bits)
            store.exec("BEGIN;")
            var covered = Set<Int64>()
            for r in res where r.vec.count == bits / 8 {
                if let (seq, ci) = owner[Int(r.id)] {
                    store.putVector(seq: seq, chunk: ci, provider: prov, bits: bits,
                                    vec: r.vec, i8: r.i8.isEmpty ? nil : r.i8)
                    covered.insert(seq)
                }
            }
            for (id, _) in todo where !covered.contains(id) {
                store.putVector(seq: id, chunk: 0, provider: prov, bits: bits,
                                vec: [UInt8](repeating: 0, count: bits/8))
            }
            store.exec("COMMIT;")
            done += todo.count
            FileHandle.standardError.write("  \(done) embedded…\r".data(using: .utf8)!)
        }
        let dt = Date().timeIntervalSince(t0)
        print("\nembedded \(done) rows via \(prov) at \(bits) bits in \(String(format: "%.1f", dt))s"
            + (dt > 0 && done > 0 ? "  ·  \(String(format: "%.1f", Double(done)/dt))/s" : ""))
        break
    }
    let batch = Int(opt("--limit", "5000")) ?? 5000
    guard Embed.vector("warmup") != nil else { print("embedding provider unavailable"); break }
    let t0 = Date(); var n = 0, failed = 0
    while true {
        let todo = store.unvectorized(provider: Embed.provider, limit: 500)
        if todo.isEmpty || n >= batch { break }
        store.exec("BEGIN;")
        for (seq, text) in todo {
            if let b = Embed.embedBinary(text, bits: bits) {
                store.putVector(seq: seq, provider: Embed.provider, bits: bits, vec: b); n += 1
            } else {
                // store a zero vector so we do not retry forever
                store.putVector(seq: seq, provider: Embed.provider, bits: bits,
                                vec: [UInt8](repeating: 0, count: bits/8)); failed += 1
            }
        }
        store.exec("COMMIT;")
    }
    let dt = Date().timeIntervalSince(t0)
    print("embedded \(n) rows (\(failed) empty) at \(bits) bits in \(String(format: "%.1f", dt))s"
        + (dt > 0 ? "  ·  \(Int(Double(n)/dt))/s" : ""))

case "diag":
    // Isolate WHERE retrieval loses the answer: Hamming vs cosine, both over the FULL
    // chunk set, computed in Swift. Python cosine over the same data ranks the gold
    // chunk 1/2015, so any divergence here is the Swift side's.
    let store = Store(dbPath)
    let bits = Int(opt("--bits", "1024")) ?? 1024
    let pos = positional()
    guard pos.count >= 2, let goldSeq = Int64(pos[0]) else { print("usage: exo diag <goldSeq> <query…>"); break }
    let q = pos.dropFirst().joined(separator: " ")
    let (idx, owner, i8s) = store.loadVectors(provider: Embed.qwenProvider, bits: bits)
    guard let qr = EmbedMLX.embed([(0, q)], bits: bits).first else { print("query embed failed"); break }
    print("chunks=\(idx.count)  i8 present=\(i8s.filter{ !$0.isEmpty }.count)  qvec=\(qr.vec.count)B  qi8=\(qr.i8.count)")

    // (a) Hamming over everything
    let ham = idx.search(qr.vec, k: idx.count)
    var hamRank = -1
    for (r, (cid, _)) in ham.enumerated() where owner[Int(cid)] == goldSeq { hamRank = r + 1; break }

    // (b) cosine over everything
    var qn = 0.0; for x in qr.i8 { qn += Double(x)*Double(x) }; qn = qn.squareRoot() + 1e-9
    var scored: [(Int, Double)] = []
    for ci in 0..<i8s.count {
        let v = i8s[ci]; if v.isEmpty { continue }
        let n = min(v.count, qr.i8.count)
        var dot = 0.0, vn = 0.0
        for i in 0..<n { let a = Double(v[i]), b = Double(qr.i8[i]); dot += a*b; vn += a*a }
        scored.append((ci, dot / ((vn.squareRoot() + 1e-9) * qn)))
    }
    scored.sort { $0.1 > $1.1 }
    var cosRank = -1
    for (r, (ci, _)) in scored.enumerated() where owner[ci] == goldSeq { cosRank = r + 1; break }

    print("gold seq=\(goldSeq)")
    print("  Hamming rank over all chunks : \(hamRank)")
    print("  cosine  rank over all chunks : \(cosRank)")
    if let f = scored.first { print("  top cosine chunk owner=\(owner[f.0]) score=\(String(format: "%.4f", f.1))") }
    // int8 magnitude sanity — L2-normalizing 1024 dims then x127 can round most to zero
    if let g = scored.first(where: { owner[$0.0] == goldSeq }) {
        let v = i8s[g.0]
        let nz = v.filter { $0 != 0 }.count
        let mx = v.map { abs(Int($0)) }.max() ?? 0
        print("  gold chunk i8: nonzero=\(nz)/\(v.count)  max|v|=\(mx)")
    }

case "bench":
    // The measurement PASS-4 Area D said was missing: is brute-force binary scan fast
    // enough that a life-scale index needs no ANN structure at all?
    let bits = Int(opt("--bits", "256")) ?? 256
    let stride = bits / 8
    print("binary brute-force scan — Apple M5 Pro, \(bits)-bit vectors (\(stride) B each)\n")
    print("  vectors        size    1-thread   GB/s   parallel    GB/s  speedup")
    print("  ──────────────────────────────────────────────────────────────────────")
    var seed: UInt64 = 0x243F6A8885A308D3
    func rnd() -> UInt64 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed }
    for n in [1_000_000, 10_000_000, 91_000_000] {
        var idx = VectorIndex(bits: bits)
        idx.reserve(n)
        var buf = [UInt8](repeating: 0, count: stride)
        for i in 0..<n {
            for w in 0..<(stride/8) {
                let r = rnd()
                for b in 0..<8 { buf[w*8+b] = UInt8truncating(r >> (UInt64(b)*8)) }
            }
            idx.add(id: Int64(i), vector: buf)
        }
        let q = buf
        let cores = ProcessInfo.processInfo.activeProcessorCount
        _ = idx.scanOnly(q); _ = idx.scanOnlyParallel(q, shards: cores)   // warm
        var s1 = Double.infinity, sp = Double.infinity
        for _ in 0..<3 {
            var t = Date(); _ = idx.scanOnly(q)
            s1 = min(s1, Date().timeIntervalSince(t) * 1000)
            t = Date(); _ = idx.scanOnlyParallel(q, shards: cores)
            sp = min(sp, Date().timeIntervalSince(t) * 1000)
        }
        let gb = Double(n * stride) / 1_073_741_824.0
        print(String(format: "  %11@  %6.2f GB  %8.1f  %7.1f  %8.1f  %6.1f  %5.1fx",
                     fmt(n) as NSString, gb, s1, gb/(s1/1000), sp, gb/(sp/1000), s1/sp))
    }
    print("\n  best of 3 after warm passes; scan only, no top-k bookkeeping")
    print("  parallel = DispatchQueue.concurrentPerform across \(ProcessInfo.processInfo.activeProcessorCount) logical cores")

case "search":
    let store = Store(dbPath)
    let q = positional().joined(separator: " ")
    guard !q.isEmpty else { print("usage: exo search <query> [--min-trust verified]"); break }
    let mt = opt("--min-trust", "")
    let limit = Int(opt("--limit", "8")) ?? 8

    if flag("--hybrid") {
        // BM25 ∪ vector, fused by RRF(k=60). Rank-only fusion so a future embedding-model
        // swap needs no recalibration.
        let bits = Int(opt("--bits", "1024")) ?? 1024
        let prov = opt("--provider", "mlx") == "mlx" ? Embed.qwenProvider : Embed.provider
        var (idx, owner, i8s) = store.loadVectors(provider: prov, bits: bits)
        if idx.count == 0 { (idx, owner, i8s) = store.loadVectors(provider: Embed.provider, bits: bits) }
        let qres: EmbedMLX.Result? = (prov == Embed.qwenProvider)
            ? EmbedMLX.embed([(0, q)], bits: bits).first : nil
        let qvec: [UInt8]? = qres?.vec ?? Embed.embedBinary(q, bits: bits)
        guard idx.count > 0, let qv = qvec else {
            print("no vectors yet — run `exo embed` first"); break
        }
        let lex = store.search(q, limit: 50, minTrust: mt.isEmpty ? nil : mt).map { $0.seq }
        // TIER 1 — binary Hamming scan over CHUNKS produces an over-fetched shortlist.
        // TIER 2 — that shortlist is re-ranked against int8 chunk vectors, then chunks
        // collapse to their parent event by best score. Area D §7.1: binary alone
        // preserves ~96% only with this step.
        let mult = Int(opt("--rescore", "10")) ?? 10   // ON: +0.10 Recall@1 on the controlled eval
        let want = 50
        let shortN = mult > 0 ? min(want * mult, idx.count) : want
        let shortlist = idx.search(qv, k: shortN)
        var vecHits: [Int] = []
        if mult > 0, let qi8 = qres?.i8, !qi8.isEmpty {
            // COSINE, not raw dot. int8 vectors have varying norms after rounding and
            // clipping, so an unnormalized dot systematically favours high-magnitude
            // chunks — which ranked WORSE than the binary scan it was meant to refine.
            var qn = 0.0
            for x in qi8 { qn += Double(x) * Double(x) }
            qn = (qn.squareRoot()) + 1e-9
            var bySeq: [Int64: Double] = [:]
            for (cid, _) in shortlist {
                let ci = Int(cid)
                guard ci < i8s.count else { continue }
                let v = i8s[ci]; if v.isEmpty { continue }
                let n = min(v.count, qi8.count)
                var dot = 0.0, vn = 0.0
                for i in 0..<n {
                    let a = Double(v[i]), b = Double(qi8[i])
                    dot += a * b; vn += a * a
                }
                let cos = dot / ((vn.squareRoot() + 1e-9) * qn)
                let seq = owner[ci]
                if cos > (bySeq[seq] ?? -.infinity) { bySeq[seq] = cos }
            }
            vecHits = bySeq.sorted { $0.value > $1.value }.prefix(want).map { Int($0.key) }
        }
        if vecHits.isEmpty {
            var seen = Set<Int>()
            for (cid, _) in shortlist {
                let ci = Int(cid); guard ci < owner.count else { continue }
                let s = Int(owner[ci])
                if seen.insert(s).inserted { vecHits.append(s) }
                if vecHits.count >= want { break }
            }
        }
        let fused = RRF.fuse([lex, vecHits]).prefix(limit)
        let meta = store.byIDs(fused.map { Int64($0.0) })
        print("hybrid: \(lex.count) lexical ∪ \(vecHits.count) vector over \(idx.count) vectors (shortlist \(shortlist.count) → int8 rescore) → RRF k=60\n")
        for (id, score) in fused {
            guard let m = meta[Int64(id)] else { continue }
            let inL = lex.firstIndex(of: id).map { "bm25#\($0+1)" } ?? "—"
            let inV = vecHits.firstIndex(of: id).map { "vec#\($0+1)" } ?? "—"
            print("[\(stamp(m.0))] \(m.1) — \(m.2)")
            print("    \(m.3.replacingOccurrences(of: "\n", with: " ").prefix(120))")
            print("    seq=\(id) trust=\(m.4) rrf=\(String(format: "%.4f", score))  \(inL) \(inV)")
        }
        break
    }

    let hits = store.search(q, limit: limit, minTrust: mt.isEmpty ? nil : mt)
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
      exo bar                       everything-bar: ⌥Space floating search
      exo fs [--seconds N]          watch the home dir via FSEvents (resumable)
      exo browser [--days N]        Safari/Chrome/Brave/Edge history (needs FDA)
      exo imessage [--days N]       iMessage chat.db (needs FDA)
      exo capture [--interval 2] [--once]
                                    AX-tree + clipboard capture loop
      exo search <query> [--hybrid] [--min-trust verified] [--limit N]
      exo embed [--provider mlx|nl] embed rows that lack a vector
      exo bench [--bits 256]        measure brute-force scan throughput
      (search: --bits 1024 default; --rescore N enables the int8 tier, currently
       measured WORSE than binary-only — see RESULTS.md)
      exo retention [--apply]       run scheduled expiry (dry-run by default)
      exo hold on|off [--reason ..] litigation hold: suspend ALL expiry
      exo stats                     counts, trust mix, exclusions, policy
      exo seed                      synthetic events, no permissions needed

      --db <path>                   default ~/.exocortex/phase1.db
    """)
}
