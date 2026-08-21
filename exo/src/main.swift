import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox

// Line-buffer stdout. When output is redirected it is block-buffered by default, so a
// crash or a SIGTERM discards everything printed so far — which twice made a working
// command look like it had silently done nothing.
setvbuf(stdout, nil, _IOLBF, 0)

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
        // Skip any --flag, and its value too when the next token is not itself a flag.
        // A hardcoded flag list silently turned `--provider mlx` into the search term
        // "mlx" for every flag added after it was written.
        if a.hasPrefix("--") {
            let hasValue = i + 1 < args.count && !args[i + 1].hasPrefix("--")
            i += hasValue ? 2 : 1
            continue
        }
        out.append(a); i += 1
    }
    return out
}
func UInt8truncating(_ v: UInt64) -> UInt8 { UInt8(truncatingIfNeeded: v) }
func fmt(_ n: Int) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}
func shell(_ path: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
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

case "gmail-auth":
    let pos = positional()
    guard pos.count >= 2 else {
        print("""
        usage: exo gmail-auth <CLIENT_ID> <CLIENT_SECRET>

        Get these from Google Cloud Console (see SETUP-GMAIL.md). The critical step:
        set the OAuth consent screen's publishing status to "In production" and do NOT
        submit for verification — Testing status expires refresh tokens every 7 days.
        """)
        break
    }
    _ = Gmail.authorize(clientID: pos[0], clientSecret: pos[1])

case "gmail":
    let store = Store(dbPath)
    for (acct, n, skip, status) in Gmail.ingestAll(into: store,
            limit: Int(opt("--limit", "500")) ?? 500,
            query: opt("--query", "newer_than:30d"),
            only: opt("--account", "")) {
        print("  \(acct): +\(n) ingested · \(skip) skipped · \(status)")
    }
    store.checkpoint()
    print("total events now \(store.count())")

case "accounts":
    Gmail.migrateLegacy()
    let g = Gmail.accounts(), i = IMAP.accounts()
    print("gmail (OAuth):")
    if g.isEmpty { print("  (none) — run `exo gmail-auth <id> <secret>`") }
    for a in g { print("  \(a)") }
    print("imap (app-specific password):")
    if i.isEmpty { print("  (none) — run `exo imap-auth <email> <app-password>`") }
    for a in i { print("  \(a)  @ \(IMAP.get("host:\(a)") ?? "?")") }

case "iphone-auth":
    var list: [String] = []
    switch IPhone.probe() {
    case .denied:  IPhone.explainDenied(); break
    case .missing: print("no Backup folder at \(IPhone.backupRoot)"); break
    case .ok(let l) where l.isEmpty:
        print("Backup folder is readable but contains no backups.")
    case .ok(let l): list = l
    }
    guard !list.isEmpty else { break }
    let udid = opt("--udid", list.first!)
    print("backup: \(udid)")
    print("This backup is ENCRYPTED. Enter the backup password you set in Finder/iTunes.")
    print("It is read with echo off, passed to the decoder on stdin, and stored in the")
    print("login Keychain — it never appears in argv (visible to `ps`) or shell history.")
    guard let pw = IPhone.promptSecret("backup password: ") else { print("cancelled"); break }
    let (lines, err) = IPhone.run(mode: "verify", udid: udid, password: pw)
    var ok = false, device = ""
    for l in lines {
        if let d = l.data(using: .utf8),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            ok = (o["ok"] as? Bool) ?? false
            device = (o["device"] as? String) ?? ""
            if !ok { print("failed: \((o["error"] as? String) ?? "unknown")") }
        }
    }
    if !ok, lines.isEmpty { print("decoder produced no output. \(err.prefix(200))") }
    if ok {
        IPhone.kcSet("password:\(udid)", pw)
        IPhone.kcSet("udid", udid)
        print("verified \(device). Password stored in the login Keychain.")
        let (ls, _) = IPhone.run(mode: "list", udid: udid, password: pw)
        for l in ls where l.contains("sources") { print("  available: \(l)") }
    }

case "iphone-schema":
    guard let udid = IPhone.kcGet("udid") ?? IPhone.backups().first,
          let pw = IPhone.kcGet("password:\(udid)") else { print("run `exo iphone-auth`"); break }
    let (ls, er) = IPhone.run(mode: "schema", udid: udid, password: pw,
                              sources: opt("--sources", "safari"))
    for l in ls { print(l) }
    if ls.isEmpty { print(er.prefix(300)) }

case "iphone-discover":
    guard let udid = IPhone.kcGet("udid") ?? IPhone.backups().first,
          let pw = IPhone.kcGet("password:\(udid)") else {
        print("run `exo iphone-auth` first"); break
    }
    let (ls, _) = IPhone.run(mode: "discover", udid: udid, password: pw,
                             grep: opt("--grep", ""))
    for l in ls { print(l) }

case "iphone":
    let store = Store(dbPath)
    if case .denied = IPhone.probe() { IPhone.explainDenied(); break }
    let udid = opt("--udid", IPhone.kcGet("udid") ?? IPhone.backups().first ?? "")
    guard !udid.isEmpty else { print("no backup found in \(IPhone.backupRoot)"); break }
    guard let pw = IPhone.kcGet("password:\(udid)") else {
        print("not authorized — run `exo iphone-auth`"); break
    }
    let (n, skip, status) = IPhone.ingest(into: store, udid: udid, password: pw,
        sources: opt("--sources", "calls,contacts,calendar,voicemail,notes,safari,whatsapp,voicememo"),
        limit: Int(opt("--limit", "20000")) ?? 20000,
        verbose: flag("--verbose"))
    store.checkpoint()
    print("iphone: +\(n) ingested · \(skip) skipped · \(status)")
    print("total events now \(store.count())")

case "imap-auth":
    let pos = positional()
    guard pos.count >= 1 else {
        print("""
        usage: exo imap-auth <email> [--host imap.mail.me.com]
               (the password is prompted for, with echo off — passing it as an argument
                would put it in `ps` output and your shell history)

        iCloud has no API — it needs IMAP, and Apple requires an APP-SPECIFIC PASSWORD
        because your Apple ID has 2FA. Your normal password will be rejected.

        Generate one at: https://account.apple.com  ->  Sign-In and Security
                         ->  App-Specific Passwords  ->  +   (name it "exocortex")

        It looks like: abcd-efgh-ijkl-mnop
        Stored in the login Keychain, never in a file.
        """)
        break
    }
    // Accept a password argument for backwards compatibility, but prefer the prompt.
    let pw: String
    if pos.count >= 2 { pw = pos[1] }
    else {
        guard let p = IPhone.promptSecret("app-specific password for \(pos[0]): ") else {
            print("cancelled"); break
        }
        pw = p
    }
    let host = opt("--host", pos[0].lowercased().contains("icloud") || pos[0].lowercased().contains("me.com")
                   ? "imap.mail.me.com" : "imap.gmail.com")
    print("testing \(pos[0]) @ \(host):993 …")
    let probe = IMAP(host: host)
    guard probe.connect() else { print("could not connect to \(host):993"); break }
    if probe.login(pos[0], pw) {
        probe.close()
        IMAP.setCred(pos[0], password: pw, host: host)
        print("authorized \(pos[0]) — credential stored in the login Keychain.")
    } else {
        probe.close()
        print("LOGIN rejected. Use an APP-SPECIFIC password (account.apple.com ->")
        print("Sign-In and Security -> App-Specific Passwords), not your Apple ID password.")
    }

case "imap":
    let store = Store(dbPath)
    for (acct, n, skip, status) in IMAPIngest.run(into: store,
            only: opt("--account", ""),
            limit: Int(opt("--limit", "300")) ?? 300,
            days: Int(opt("--days", "30")) ?? 30) {
        print("  \(acct): +\(n) ingested · \(skip) skipped · \(status)")
    }
    store.checkpoint()
    print("total events now \(store.count())")

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
        limit: Int(opt("--limit", "20000")) ?? 20000, days: Int(opt("--days", "0")) ?? 0,
        rescan: flag("--rescan"))
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
    // Default ⌃⌥Space. Deliberately NOT:
    //   ⌘Space   Spotlight
    //   ⌥⌘Space  Finder search window
    //   ⌃⌘Space  Emoji & Symbols picker
    //   ⌥Space   inserts a NON-BREAKING SPACE in most text fields — it is a real
    //            character, so binding it silently corrupts typing.
    let keyMap: [String: UInt32] = ["space": UInt32(kVK_Space), "e": UInt32(kVK_ANSI_E),
                                    "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K),
                                    "m": UInt32(kVK_ANSI_M), "slash": UInt32(kVK_ANSI_Slash)]
    let spec0 = opt("--hotkey", "ctrl+opt+space").lowercased()
    var mods: UInt32 = 0
    for part in spec0.split(separator: "+") {
        switch part {
        case "ctrl", "control": mods |= UInt32(controlKey)
        case "opt", "option", "alt": mods |= UInt32(optionKey)
        case "cmd", "command": mods |= UInt32(cmdKey)
        case "shift": mods |= UInt32(shiftKey)
        default: break
        }
    }
    let keyName = spec0.split(separator: "+").last.map(String.init) ?? "space"
    let keyCode = keyMap[keyName] ?? UInt32(kVK_Space)
    if mods == 0 { mods = UInt32(controlKey) | UInt32(optionKey) }
    let regStatus = RegisterEventHotKey(keyCode, mods, hkID,
                                        GetApplicationEventTarget(), 0, &hotKeyRef)
    if regStatus != noErr {
        print("warning: could not register \(spec0) (status \(regStatus)) — it may already be taken.")
        print("         try e.g. --hotkey ctrl+opt+e")
    }
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
    print("everything-bar running.  \(spec0) to toggle · Esc to dismiss · Ctrl-C to quit")
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
        guard let session = EmbedMLX.Session(bits: bits) else {
            print("could not start the embedding sidecar"); break
        }
        defer { session.close() }
        var done = 0; let t0 = Date()
        while done < batch {
            let todo = store.unvectorized(provider: prov, limit: min(400, batch - done))
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
            let res = session.embed(pieces)
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

    let hits = store.search(q, limit: limit, minTrust: mt.isEmpty ? nil : mt,
                            includeCold: flag("--include-cold"))
    if hits.isEmpty { print("no matches for: \(q)"); break }
    for h in hits {
        print("[\(stamp(h.ts))] \(h.app) — \(h.title)")
        if !h.snip.isEmpty { print("    \(h.snip.replacingOccurrences(of: "\n", with: " "))") }
        print("    seq=\(h.seq) src=\(h.source) trust=\(h.trust) bm25=\(String(format: "%.2f", h.score))")
    }
    // S6's missing half. FSRS needs retrievals to strengthen against and this system had
    // never recorded one — two years of capture without a single row saying "you looked at
    // this". Surfacing counts as a retrieval on the Remembrance Agent's finding that seeing
    // the one-line result usually triggers the memory without opening anything.
    Decay.record(store, seqs: hits.map { Int64($0.seq) }, kind: "surfaced")
    store.checkpoint()

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

case "offsite-key":
    // Copies the offsite private key to the clipboard WITHOUT printing it, so it never
    // lands in scrollback, a log, or a terminal recording. exo's own clipboard capture
    // redacts age keys (verified), so copying it does not feed it back into the store.
    let raw = shell("/usr/bin/security",
                    ["find-generic-password", "-s", "exocortex.offsite", "-a", "age_identity", "-w"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { print("no offsite key found in the Keychain"); break }
    // `security` returns hex when the stored secret contains newlines
    let isHex = raw.allSatisfy { $0.isHexDigit } && raw.count % 2 == 0
    var key = raw
    if isHex {
        var bytes = [UInt8](); var i = raw.startIndex
        while i < raw.endIndex, let j = raw.index(i, offsetBy: 2, limitedBy: raw.endIndex) {
            bytes.append(UInt8(raw[i..<j], radix: 16) ?? 0); i = j
        }
        key = String(decoding: bytes, as: UTF8.self)
    }
    let pb = NSPasteboard.general
    pb.clearContents()
    // Mark it concealed so any well-behaved clipboard manager (and exo itself) skips it
    pb.declareTypes([NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"), .string], owner: nil)
    pb.setString(key, forType: .string)
    print("""
    Offsite private key copied to the clipboard. It was NOT printed.

      1. Paste it into your password manager now (name it "exocortex offsite key")
      2. Then clear the clipboard:   exo offsite-key --clear
      3. Delete the copy in Notes

    The Keychain keeps the working copy; the password manager is the off-machine
    backup. Without it, every iCloud snapshot is unreadable ciphertext.
    """)

case "offsite-key-clear":
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("", forType: .string)
    print("clipboard cleared")

case "offsite":
    let script = Paths.tool("offsite.sh") ?? ""
    if script.isEmpty { print(Paths.missing("offsite.sh")); break }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script]
    try? p.run(); p.waitUntilExit()

case "offsite-restore":
    let script = Paths.tool("offsite-restore.sh") ?? ""
    if script.isEmpty { print(Paths.missing("offsite-restore.sh")); break }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script] + positional()
    try? p.run(); p.waitUntilExit()

case "scan-secrets":
    // Retroactive audit using the SAME precise matcher as ingest, so the scan cannot flag
    // anything redaction wouldn't have caught.
    let store = Store(dbPath)
    var hits: [(Int64, String, String, String)] = []
    for r in store.rows("SELECT seq, source, coalesce(text,'') FROM events WHERE length(coalesce(text,''))>20;") {
        let found = Exclusion.findSecrets(r[2])
        if !found.isEmpty {
            hits.append((Int64(r[0]) ?? 0, r[1], found.joined(separator: ","), String(r[2].prefix(60))))
        }
    }
    print("scanned \(store.count()) events with \(Exclusion.secretRegexes.count) credential patterns\n")
    if hits.isEmpty {
        print("  ✅ no credentials found")
    } else {
        for h in hits.prefix(40) {
            print("  ⚠️  seq=\(h.0) [\(h.1)] \(h.2)")
            print("      \(h.3.replacingOccurrences(of: "\n", with: " "))")
        }
        print("\n  \(hits.count) event(s). Remove with: exo forget-secrets --apply")
    }

case "forget-secrets":
    let store = Store(dbPath)
    var doomed: [Int64] = []
    for r in store.rows("SELECT seq, coalesce(text,'') FROM events WHERE length(coalesce(text,''))>20;")
    where !Exclusion.findSecrets(r[1]).isEmpty {
        doomed.append(Int64(r[0]) ?? 0)
    }
    if doomed.isEmpty { print("nothing to remove"); break }
    guard flag("--apply") else {
        print("would remove \(doomed.count) event(s). Re-run with --apply to delete.")
        break
    }
    store.exec("BEGIN;")
    store.exec("DELETE FROM events WHERE seq IN (\(doomed.map(String.init).joined(separator: ",")));")
    store.exec("COMMIT;")
    store.exec("INSERT INTO events_fts(events_fts) VALUES('rebuild');")
    store.checkpoint()
    print("removed \(doomed.count) event(s) containing credentials · FTS index rebuilt")

case "extract":
    if #available(macOS 26.0, *) {
        let s = Store(dbPath)
        let lim = Int(opt("--limit", "50")) ?? 50
        let verbose = flag("--verbose")
        print("extracting claims from up to \(lim) trust=self events (on-device model)…")
        let t0 = Date()
        let r = await Extract.run(s, limit: lim, verbose: verbose,
                                  order: flag("--random") ? "RANDOM()" : "e.seq DESC")
        s.checkpoint()
        let dt = Date().timeIntervalSince(t0)
        if !r.aborted.isEmpty {
            print("on-device extraction stopped after \(r.failed) failures: \(r.aborted)")
            print("  Nothing was extracted. This is NOT an empty corpus — retry later.")
            break
        }
        print("""
          scanned \(r.scanned) · \(r.claims) kept · \(r.dropped) dropped (volatile/not-mine) · \(r.empty) with none · \(r.failed) failed
          \(String(format: "%.1f", dt))s (\(String(format: "%.1f", dt / Double(max(r.scanned,1))))s/event)
        """)
    } else { print("needs macOS 26+") }

case "beliefs":
    let s = Store(dbPath); Ledger.migrate(s)
    let subj = positional().joined(separator: " ")
    guard !subj.isEmpty else { print("usage: exo beliefs <subject> [--as-of ISO8601]"); break }
    let asOf = opt("--as-of", Ledger.now())
    let bs = Ledger.beliefsAt(s, subject: subj, asOf: asOf)
    if bs.isEmpty { print("no beliefs about '\(subj)' as of \(asOf.prefix(10))"); break }
    print("beliefs about '\(subj)' as of \(asOf.prefix(10)):\n")
    for b in bs {
        print("  \(b.polarity > 0 ? "✓" : "✗") \(b.text)")
        print("    held \(b.beliefFrom.prefix(10))..\(b.beliefTo?.prefix(10) ?? "now") · conf \(String(format: "%.2f", b.confidence)) (\(b.confSrc)) · \(b.evidence) evidence · \(b.reason)")
    }

case "belief-history":
    let s = Store(dbPath); Ledger.migrate(s)
    let subj = positional().joined(separator: " ")
    for b in Ledger.history(s, subject: subj) {
        print("  \(b.beliefFrom.prefix(10))..\(b.beliefTo?.prefix(10) ?? "now")  \(b.polarity > 0 ? "✓" : "✗") \(b.text)")
    }

case "tell":
    // Direct elicitation. Only 1.1% of this corpus contains first-person disclosure, and
    // almost all of that is operational ("I think we should meet Tuesday") rather than
    // character. People act on their beliefs; they rarely write them down. So the highest
    // confidence tier in the schema — explicit_statement — is populated by asking.
    let s = Store(dbPath); Ledger.migrate(s)
    let text = positional().joined(separator: " ")
    guard !text.isEmpty else { print("usage: exo tell \"I hate driving at night\""); break }
    let run = Ledger.startRun(s, model: "human", version: "-", promptHash: "-", codeVersion: "tell-1")
    let cid = Ledger.upsertClaim(s, subject: "me", predicate: "states", object: nil,
                                 polarity: text.lowercased().contains(" not ")
                                        || text.lowercased().contains("n't ") ? -1 : 1,
                                 scope: opt("--scope", "").isEmpty ? nil : opt("--scope", ""),
                                 norm: text)
    let id = Ledger.mindChange(s, from: nil, toClaim: cid, at: Ledger.now(),
                               confidence: 1.0, confidenceSrc: "explicit_statement",
                               runID: run, evidence: [])
    s.checkpoint()
    print("recorded as a belief (explicit_statement, confidence 1.00)")
    print("  \(id)  \(text)")

case "ask":
    // A short interview. Questions target the things a life-log cannot observe: values,
    // dispositions, and the reasons behind choices.
    let s = Store(dbPath); Ledger.migrate(s)
    let bank = [
        "What's something you believe about how you work best?",
        "What do you care about that most people around you don't?",
        "What's a decision you made that you'd defend even if it turned out badly?",
        "What kind of person do you try to be when things go wrong?",
        "What's something you used to believe and no longer do?",
        "What do you want the next five years to look like?",
        "What consistently annoys you that others seem fine with?",
        "What are you unusually good at, and how do you know?",
    ]
    let n = Int(opt("--n", "3")) ?? 3
    let run = Ledger.startRun(s, model: "human", version: "-", promptHash: "-", codeVersion: "ask-1")
    var recorded = 0
    print("Answer in a sentence or two. Press return on an empty line to skip.\n")
    for q in bank.shuffled().prefix(n) {
        print("  \(q)")
        print("  > ", terminator: "")
        guard let a = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty else {
            print("    (skipped)\n"); continue
        }
        // `scope` means the situation a belief holds IN. The interview question is
        // provenance, not scope — filing it here made every elicited belief look like it
        // held in a different situation, and `scope_difference` is one of the four
        // contradiction verdicts, so the detector would have read the interview script as
        // proof that nothing ever conflicts.
        let cid = Ledger.upsertClaim(s, subject: "me", predicate: "states", object: nil,
                                     polarity: 1, scope: nil, norm: a)
        _ = Ledger.mindChange(s, from: nil, toClaim: cid, at: Ledger.now(),
                              confidence: 1.0, confidenceSrc: "explicit_statement",
                              runID: run, evidence: [], elicitedBy: q)
        recorded += 1
        print("    recorded\n")
    }
    s.checkpoint()
    print("\(recorded) belief(s) recorded at the highest confidence tier.")

case "beliefs-review":
    // Area E is explicit that relation extraction lands around 60-75 F1 and that human
    // correction is a COMPONENT, not a fallback. Claims arrive unconfirmed
    // (confidence_src = model_selfreport) and only become confirmed beliefs here.
    let s = Store(dbPath); Ledger.migrate(s)
    let pending = s.rows("""
        SELECT b.belief_id, c.norm_text, c.subject, c.predicate, c.polarity, b.belief_from,
               (SELECT count(*) FROM belief_evidence e WHERE e.belief_id=b.belief_id)
        FROM belief b JOIN claim c ON c.claim_id=b.claim_id
        WHERE b.sys_to IS NULL AND b.confidence_src='model_selfreport'
        ORDER BY b.belief_from DESC LIMIT \(Int(opt("--limit","20")) ?? 20);
        """)
    if pending.isEmpty { print("nothing pending review"); break }
    print("\(pending.count) unconfirmed claim(s). These are NOT yet beliefs.\n")
    for p in pending {
        print("  \(p[4] == "1" ? "✓" : "✗") \(p[1])")
        print("      \(p[2]) · \(p[3]) · held from \(p[5].prefix(10)) · \(p[6]) evidence · id=\(p[0])")
    }
    print("""

      exo beliefs-confirm <id>     promote to a confirmed belief
      exo beliefs-reject <id>      remove it
      exo beliefs-reject --all-pending
    """)

case "beliefs-confirm":
    let s = Store(dbPath)
    guard let id = positional().first else { print("usage: exo beliefs-confirm <belief_id>"); break }
    s.exec("UPDATE belief SET confidence_src='human_confirmed', confidence=1.0 WHERE belief_id='\(id)';")
    print("confirmed \(id)")

case "beliefs-reject":
    let s = Store(dbPath)
    if flag("--all-pending") {
        let n = s.scalar("SELECT count(*) FROM belief WHERE confidence_src='model_selfreport';")
        s.exec("DELETE FROM belief_evidence WHERE belief_id IN (SELECT belief_id FROM belief WHERE confidence_src='model_selfreport');")
        s.exec("DELETE FROM belief WHERE confidence_src='model_selfreport';")
        print("rejected \(n) unconfirmed claim(s)")
    } else if let id = positional().first {
        s.exec("DELETE FROM belief_evidence WHERE belief_id='\(id)';")
        s.exec("DELETE FROM belief WHERE belief_id='\(id)';")
        print("rejected \(id)")
    } else { print("usage: exo beliefs-reject <id> | --all-pending") }

case "ledger-test":
    // The distinction the whole ledger exists to preserve, proven rather than asserted.
    let s = Store(dbPath); Ledger.migrate(s)
    // Wipe at BOTH ends. Running with leftovers from the previous invocation is not a
    // fresh fixture: the earlier run's rows satisfy the same point-in-time queries, and
    // the suite starts grading the union of every run it has ever done.
    func wipe() {
        let mine = "SELECT belief_id FROM belief b JOIN claim c USING(claim_id) WHERE c.subject='ledgertest'"
        s.exec("DELETE FROM contradiction WHERE belief_a IN (\(mine)) OR belief_b IN (\(mine));")
        s.exec("DELETE FROM belief_vec WHERE belief_id IN (\(mine));")
        s.exec("DELETE FROM belief_evidence WHERE belief_id IN (\(mine));")
        s.exec("DELETE FROM belief WHERE claim_id IN (SELECT claim_id FROM claim WHERE subject='ledgertest');")
        s.exec("DELETE FROM claim WHERE subject='ledgertest';")
    }
    wipe()
    let run = Ledger.startRun(s, model: "test", version: "1", promptHash: "-", codeVersion: "-")
    let P  = Ledger.upsertClaim(s, subject: "ledgertest", predicate: "ships_in",
                                object: "March", polarity: 1, scope: nil,
                                norm: "the project ships in March")
    let nP = Ledger.upsertClaim(s, subject: "ledgertest", predicate: "ships_in",
                                object: "March", polarity: -1, scope: nil,
                                norm: "the project does NOT ship in March")
    var pass = 0, fail = 0
    func chk(_ label: String, _ got: String, _ want: String) {
        if got == want { print("  ✅ \(label)"); pass += 1 }
        else { print("  ❌ \(label)\n       got:  \(got)\n       want: \(want)"); fail += 1 }
    }
    // `includeUnconfirmed` on purpose. What is under test here is the TEMPORAL machinery —
    // whether a re-extraction rewrites history and a change of mind does not. The review
    // gate is a separate policy, and letting it filter the fixture made check B fail for a
    // reason that had nothing to do with bitemporality: the re-extraction below is recorded
    // as `model_selfreport`, exactly the tier `beliefs` hides. The gate gets its own check
    // at the end instead of silently eating this one.
    func at(_ d: String) -> String {
        Ledger.beliefsAt(s, subject: "ledgertest", asOf: d, includeUnconfirmed: true)
            .map { ($0.polarity > 0 ? "P" : "notP") }.sorted().joined(separator: "+")
    }

    // 2025-03-01: I come to believe P.
    let b1 = Ledger.mindChange(s, from: nil, toClaim: P, at: "2025-03-01T00:00:00Z",
                               confidence: 0.7, confidenceSrc: "explicit_statement", runID: run)
    chk("after initial belief, 2025-06 says P", at("2025-06-01T00:00:00Z"), "P")

    // ── PATH A: I CHANGE MY MIND in 2026 ──
    _ = Ledger.mindChange(s, from: b1, toClaim: nP, at: "2026-01-15T00:00:00Z",
                          confidence: 0.85, confidenceSrc: "explicit_statement", runID: run)
    chk("A: 2026-06 now says notP",  at("2026-06-01T00:00:00Z"), "notP")
    chk("A: 2025-06 STILL says P",   at("2025-06-01T00:00:00Z"), "P")
    print("     ^ a change of mind must not rewrite what I believed in 2025")

    // ── PATH B: a better model re-reads the SAME 2025 moments ──
    let before = at("2025-06-01T00:00:00Z")
    guard let b3 = Ledger.reextraction(s, correcting: b1, toClaim: nP,
                                       confidence: 0.9, confidenceSrc: "model_selfreport",
                                       runID: run) else {
        print("  ❌ reextraction returned nil"); break
    }
    _ = b3
    chk("B: 2025-06 now says notP (was \(before))", at("2025-06-01T00:00:00Z"), "notP")
    print("     ^ a re-extraction MUST rewrite it: the old answer was the machine's error")

    // the belief interval itself must be untouched by path B
    let iv = s.rows("SELECT belief_from, coalesce(belief_to,'-') FROM belief WHERE change_reason='reextraction' ORDER BY sys_from DESC LIMIT 1;")
    chk("B: belief interval copied verbatim", iv.first.map { "\($0[0])|\($0[1])" } ?? "",
        "2025-03-01T00:00:00Z|2026-01-15T00:00:00Z")

    // and the machine remains auditable: what did the OLD extractor think?
    let old = Ledger.asKnownAt(s, subject: "ledgertest", asOf: "2025-06-01T00:00:00Z",
                               systemTime: "2020-01-01T00:00:00Z")
    chk("audit: before this run existed, nothing was known", String(old.count), "0")

    // …and the review gate, stated as its own claim rather than left to interfere with
    // the temporal checks above. That re-extraction was a model's guess, so `exo beliefs`
    // must not show it as something I believe.
    chk("gate: an unreviewed re-extraction is not a belief",
        String(Ledger.beliefsAt(s, subject: "ledgertest", asOf: "2025-06-01T00:00:00Z").count), "0")

    // Synthetic P / not-P pairs left in the real ledger are precisely what contradiction
    // detection is built to find. Leaving them behind would have the suite manufacturing
    // its own findings.
    wipe(); s.checkpoint()

    print("\n  \(pass) passed, \(fail) failed")

case "decay":
    // S6. `--apply` is required to change anything; the default is a dry run, exactly like
    // `exo retention`. The two are deliberately separate commands: retention DELETES on a
    // legal schedule, decay HIDES on a functional one, and a cold row survives both a
    // litigation hold and an explicit search.
    let s = Store(dbPath); Decay.migrate(s)
    let fl = Double(opt("--floor", "")) ?? Decay.floor
    let dr = Decay.run(s, apply: flag("--apply"), floor: fl,
                       limit: Int(opt("--limit", "200000")) ?? 200_000)
    s.checkpoint()
    print("R = exp(ln(0.9)·t/S), floor \(String(format: "%.2f", fl)), base stability \(Int(Decay.baseStability))d\n")
    let dtotal = max(1, dr.hist.reduce(0, +))
    for (i, n) in dr.hist.enumerated() where n > 0 {
        print(String(format: "  R %.1f..%.1f  %7d  %@", Double(i) / 10, Double(i) / 10 + 0.1, n,
                     String(repeating: "█", count: max(1, n * 42 / dtotal))))
    }
    print("""

      \(fmt(dr.considered)) considered · \(fmt(dr.immune)) immune (pinned, confirmed-belief evidence, open contradictions)
      \(fmt(dr.demoted)) to demote · \(fmt(dr.revived)) to revive\(flag("--apply") ? " — APPLIED" : "  (dry run; --apply to write)")
    """)
    if !dr.examples.isEmpty {
        print("\n  first few that would go cold:")
        for (q, rr, txt) in dr.examples {
            print(String(format: "    [%d] R=%.3f  %@", q, rr,
                         txt.replacingOccurrences(of: "\n", with: " ")))
        }
    }
    print("\n  Nothing is deleted. A cold row is still in the store, still under any hold,")
    print("  still returned by `exo search --include-cold`, and revived by being retrieved.")

case "pin":
    let s = Store(dbPath)
    guard let q = positional().first.flatMap(Int64.init) else {
        print("usage: exo pin <seq> [--off]"); break
    }
    Decay.pin(s, q, !flag("--off")); s.checkpoint()
    print("\(flag("--off") ? "unpinned" : "pinned") \(q) — pinned rows never decay")

case "segment":
    let s = Store(dbPath); Segment.migrate(s)
    var p = Segment.Params()
    p.day = opt("--day", "")
    p.window = Int(opt("--window", "5")) ?? 5
    p.k = Double(opt("--k", "")) ?? 1.0
    p.gapMinutes = Int(opt("--gap", "45")) ?? 45
    p.minEvents = Int(opt("--min-events", "3")) ?? 3
    let sources = "'claudecode','gmail','imessage','imap','iphone.note'"

    if flag("--histogram") {
        // Same discipline as the connection band: look at this corpus before picking a
        // threshold. Surprise scales differ between a day of one long build and a day of
        // scattered errands, which is why the cut is mean + k·sd rather than a constant.
        let day = p.day.isEmpty
            ? (s.rows("SELECT date(max(ts)/1000000,'unixepoch','localtime') FROM events WHERE ts < \(Connect.tsCeil);").first?.first ?? "")
            : p.day
        let its = Segment.items(s, day: day, sources: sources)
        guard its.count > 1 else { print("no vectorized eligible events on \(day)"); break }
        let (cuts, sur, threshold) = Segment.boundaries(its, p)
        print("\(day): \(its.count) eligible vectorized events · threshold \(String(format: "%.3f", threshold)) · \(cuts.count) episodes\n")
        var hist = [Int](repeating: 0, count: 12)
        for v in sur.dropFirst() { hist[min(11, max(0, Int(v * 20)))] += 1 }
        let total = max(1, hist.reduce(0, +))
        for (i, n) in hist.enumerated() where n > 0 {
            print(String(format: "  %.2f..%.2f  %5d  %@", Double(i) * 0.05, Double(i) * 0.05 + 0.05, n,
                         String(repeating: "█", count: max(1, n * 40 / total))))
        }
        print("")
        for (n, c) in cuts.enumerated() {
            let end = n + 1 < cuts.count ? cuts[n + 1] : its.count
            print(String(format: "  %@  %2d events  surprise %.3f  %@", stamp(its[c].ts), end - c,
                         sur[c], its[c].text.replacingOccurrences(of: "\n", with: " ").prefix(74).description))
        }
        break
    }

    if #available(macOS 26.0, *) {
        let t0 = Date()
        let r = await Segment.run(s, p, sources: sources, summarize: !flag("--no-summary"),
                                  verbose: flag("--verbose"))
        if r.judgeFailed {
            print("on-device summarization unavailable — \(r.failed) failures in a row:")
            print("  \(r.lastError)\n  Episodes were still cut. NOT a complete run.")
            Segment.persist(s, r.built, day: r.day); s.checkpoint(); break
        }
        Segment.persist(s, r.built, day: r.day); s.checkpoint()
        print("""
          \(r.day): \(r.events) events → \(r.episodes) episodes (threshold \(String(format: "%.3f", r.threshold)))
          \(r.summarized) summarized · \(r.failed) failed · \(r.lines) cited lines · \(r.uncited) dropped for citing outside the episode
          \(String(format: "%.1f", Date().timeIntervalSince(t0)))s
        """)
    } else { print("needs macOS 26+") }

case "day":
    let s = Store(dbPath); Segment.migrate(s)
    let day = opt("--day", "").isEmpty
        ? (s.rows("SELECT max(day) FROM episode;").first?.first ?? "")
        : opt("--day", "")
    let eps = Segment.forDay(s, day: day)
    if eps.isEmpty { print("no episodes for \(day.isEmpty ? "any day" : day) — run `exo segment`"); break }
    print("\n\(day)\n")
    for e in eps {
        print("  \(stamp(e.from).suffix(5))–\(stamp(e.to).suffix(5))  \(e.title.isEmpty ? "(unsummarized)" : e.title)  · \(e.n) events")
        for (t, q) in Segment.lines(s, episode: e.id) { print("      · \(t)  [\(q)]") }
        print("")
    }

case "brief":
    // S8 — the morning brief, and the only thing in this phase the principal actually sees.
    //
    // Area F's cap is the design: **at most 1-3 connections, because one false connection
    // destroys trust in all of them.** Everything upstream — the eligibility filter, hub
    // suppression, the rarity ceiling — exists to make three items worth reading. A brief
    // that pads itself to look busy is the failure mode, so when there is nothing it says
    // nothing, in one line.
    let s = Store(dbPath); Connect.migrate(s); Ledger.migrate(s)
    let n = Int(opt("--n", "3")) ?? 3
    Segment.migrate(s)
    let conns = Connect.forBrief(s, limit: n)
    let open = Contradict.open(s, limit: 3)
    let lastDay = s.rows("SELECT max(day) FROM episode;").first?.first ?? ""
    let eps = lastDay.isEmpty ? [] : Segment.forDay(s, day: lastDay).filter { !$0.title.isEmpty }
    let f = DateFormatter(); f.dateFormat = "EEEE d MMMM"
    print("\n\(f.string(from: Date()))\n")

    if !eps.isEmpty {
        print("  \(lastDay)")
        for e in eps {
            print("\n    \(e.title)  · \(e.n) events, \(stamp(e.from).suffix(5))–\(stamp(e.to).suffix(5))")
            // Two lines each. The episode holds up to five; a brief that prints all of them
            // is a transcript, and the point of a brief is that it is read.
            for (txt, q) in Segment.lines(s, episode: e.id).prefix(2) {
                print("      · \(txt.prefix(104))  [\(q)]")
            }
        }
        print("")
    }

    if conns.isEmpty && open.isEmpty && eps.isEmpty {
        print("  Nothing worth your attention. (Some weeks have no story.)\n")
        break
    }
    if !conns.isEmpty {
        print("  You've been here before")
        for c in conns {
            print("\n    \(c.link)")
            print("      \(c.dayA) · \(c.srcA) — \(c.textA.replacingOccurrences(of: "\n", with: " ").prefix(120))")
            print("      \(c.dayB) · \(c.srcB) — \(c.textB.replacingOccurrences(of: "\n", with: " ").prefix(120))")
            print("      \(c.daysApart) days apart · \(String(format: "%.2f", c.serendipity))")
        }
        print("")
    }
    if !open.isEmpty {
        print("  The ledger says you hold both of these at once")
        for o in open {
            print("\n    A  \(o.textA.prefix(110))")
            print("    B  \(o.textB.prefix(110))")
            print("       exo contra-resolve \(o.id) …")
        }
        print("")
    }
    // Marked only once shown. A brief that repeats itself is a brief you stop reading.
    if !flag("--peek") { Connect.markSurfaced(s, conns.map(\.id)); s.checkpoint() }

case "dream":
    // The nightly DAG, as far as it is built: S4 contradiction detection and S5 connection
    // discovery, then S8. Area F's full pipeline also has segmentation, hierarchical
    // summarization and FSRS decay in front of these; those are not here, and the runner
    // says so rather than implying a complete night's work.
    if #available(macOS 26.0, *) {
        let s = Store(dbPath); Connect.migrate(s); Ledger.migrate(s)
        let t0 = Date()
        var p = Connect.Params()
        p.anchors = Int(opt("--anchors", "500")) ?? 500
        p.sinceDays = Int(opt("--since", "0")) ?? 0

        Segment.migrate(s)
        print("S1+S2  episodes")
        var sp = Segment.Params()
        sp.day = opt("--day", "")
        let sr = await Segment.run(s, sp,
                    sources: "'claudecode','gmail','imessage','imap','iphone.note'",
                    summarize: true, verbose: false)
        if sr.judgeFailed { print("    unavailable: \(sr.lastError)") }
        else {
            Segment.persist(s, sr.built, day: sr.day)
            print("    \(sr.day): \(sr.events) events → \(sr.episodes) episodes · \(sr.lines) cited lines · \(sr.uncited) uncited dropped")
        }

        print("S4  contradictions")
        let c4 = await Contradict.scan(s, includeUnconfirmed: false,
                                       limit: 2000, minSim: Contradict.minSim,
                                       maxSim: Contradict.maxSim, verbose: false)
        if c4.judgeFailed { print("    unavailable: \(c4.lastError)") }
        else { print("    \(c4.candidates) overlapping pair(s) · \(c4.judged) judged · \(c4.recorded) new") }

        print("S5  connections")
        let c5 = await Connect.run(s, p, judgeLimit: Int(opt("--judge", "25")) ?? 25, verbose: false)
        if c5.judgeFailed { print("    unavailable: \(c5.lastError)") }
        else {
            print("    \(fmt(c5.scanned)) neighbour pairs · \(c5.candidates) candidates · \(c5.grounded) share a rare term · \(c5.kept) kept")
        }
        print("S6  decay")
        let d6 = Decay.run(s, apply: true, floor: Decay.floor, limit: 500_000)
        print("    \(fmt(d6.considered)) considered · \(fmt(d6.immune)) immune · \(fmt(d6.demoted)) demoted · \(fmt(d6.revived)) revived")

        s.checkpoint()
        print("\n\(String(format: "%.0f", Date().timeIntervalSince(t0)))s. EM-LLM's graph refinement of S1 boundaries is not built yet, and neither is EM-LLM's graph refinement of S1's boundaries.")
        print("Run `exo brief` for the morning read-out.")
    } else { print("needs macOS 26+") }

case "connect":
    let s = Store(dbPath); Connect.migrate(s)
    var p = Connect.Params()
    p.anchors = Int(opt("--anchors", "200")) ?? 200
    p.sinceDays = Int(opt("--since", "0")) ?? 0
    p.k = Int(opt("--k", "40")) ?? 40
    p.minDays = Int(opt("--min-days", "30")) ?? 30
    p.minSim = Double(opt("--min-sim", "")) ?? p.minSim
    p.maxSim = Double(opt("--max-sim", "")) ?? p.maxSim
    p.requireDifferentSource = flag("--cross-source-only")
    p.dims = Int(opt("--dims", "0")) ?? 0
    p.hubMax = Int(opt("--hub-max", "3")) ?? 3
    p.perAnchor = Int(opt("--per-anchor", "1")) ?? 1
    Connect.rarityCeiling = Int(opt("--rarity", "60")) ?? 60

    if flag("--histogram") {
        // Calibration before commitment. Area F quotes 0.85 and 0.55-0.80, but those bands
        // were measured on a different embedding model, and §6 already found one place where
        // a quoted band did not transfer. Look at this corpus first.
        let t0 = Date()
        let (c, scanned, hist) = Connect.candidates(s, p)
        print("index width \(Connect.storedBits(s)) bits, scoring on \(p.dims > 0 ? String(p.dims) : "all") dims")
        print("scanned \(fmt(scanned)) chunk-neighbour pairs from \(p.anchors) anchors in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        print("post-filter candidates in [\(p.minSim), \(p.maxSim)]: \(c.count)\n")
        print("int8 cosine distribution of everything that passed Δt≥\(p.minDays)d\(p.requireDifferentSource ? " + different-source" : ""):")
        let total = max(1, hist.reduce(0, +))
        for (i, n) in hist.enumerated() where n > 0 {
            let lo = Double(i) * 0.1 - 1.0
            let bar = String(repeating: "█", count: max(1, n * 46 / total))
            print(String(format: "  %+.1f..%+.1f  %7d  %5.1f%%  %@", lo, lo + 0.1, n,
                         Double(n) * 100 / Double(total), bar))
        }
        for c in c.prefix(12) {
            print(String(format: "\n  %.3f  %dd  %@ / %@", c.sim, c.daysApart, c.srcA, c.srcB))
            print("    A: \(c.textA.replacingOccurrences(of: "\n", with: " ").prefix(96))")
            print("    B: \(c.textB.replacingOccurrences(of: "\n", with: " ").prefix(96))")
        }
        break
    }

    if #available(macOS 26.0, *) {
        let t0 = Date()
        let r = await Connect.run(s, p, judgeLimit: Int(opt("--judge", "40")) ?? 40,
                                  verbose: flag("--verbose"))
        s.checkpoint()
        if r.judgeFailed {
            print("on-device judging unavailable — \(r.failed) calls failed in a row:")
            print("  \(r.lastError)")
            print("  \(r.candidates) candidate(s) went unjudged. NOT a clean bill of health.")
            break
        }
        print("""
          \(fmt(r.scanned)) neighbour pairs scanned · \(r.candidates) survived the filters
          \(r.grounded) share a rare term · \(r.ungrounded) share nothing specific
          \(r.judged) described · \(r.failed) failed · \(r.kept) kept
          \(String(format: "%.1f", Date().timeIntervalSince(t0)))s
        """)
    } else { print("needs macOS 26+") }

case "contradictions":
    let s = Store(dbPath); Ledger.migrate(s)
    if flag("--scan") {
        if #available(macOS 26.0, *) {
            let t0 = Date()
            let r = await Contradict.scan(s,
                        includeUnconfirmed: flag("--include-unconfirmed"),
                        limit: Int(opt("--limit", "2000")) ?? 2000,
                        minSim: Double(opt("--min-sim", "")) ?? Contradict.minSim,
                        maxSim: Double(opt("--max-sim", "")) ?? Contradict.maxSim,
                        verbose: flag("--verbose"))
            s.checkpoint()
            if r.embedFailed {
                print("embedding sidecar unavailable — cannot score candidates.")
                print("  \(r.candidates) pair(s) went unjudged. This is NOT a clean bill of health.")
                break
            }
            if r.judgeFailed {
                print("on-device classification unavailable — \(r.failed) calls failed in a row:")
                print("  \(r.lastError)")
                print("  Usually the text sanitizer every request is screened by rather than the")
                print("  language model: SensitiveContentAnalysisML 15 -> ModelManagerError 1013.")
                print("  It latches system-wide and outlives the process, and `availability`")
                print("  keeps reporting `.available` while it does. Nothing was judged —")
                print("  this is NOT a clean bill of health. Retry later; if it persists,")
                print("  restarting the machine reloads the sanitizer.")
                break
            }
            print("""
              \(r.candidates) overlapping pair(s) · \(r.filtered) unrelated · \(r.duplicates) near-duplicate
              \(r.judged) judged · \(r.failed) failed · \(r.framingFailed) unframed · \(r.recorded) new · \(r.escalated) escalated
              \(String(format: "%.1f", Date().timeIntervalSince(t0)))s
            """)
            let byVerdict = Dictionary(grouping: r.findings, by: { $0.verdict })
                .mapValues(\.count).sorted { $0.key < $1.key }
            if !byVerdict.isEmpty {
                print("  verdicts: " + byVerdict.map { "\($0.key)=\($0.value)" }.joined(separator: " · "))
            }
        } else { print("needs macOS 26+") }
    }
    let open = Contradict.open(s, limit: Int(opt("--show", "20")) ?? 20)
    if open.isEmpty {
        print("\nnothing open. (scope_difference, both_true and extraction_error close on detection;")
        print(" only genuine_change reaches this queue, because only it needs a decision.)")
        break
    }
    print("\n\(open.count) open contradiction(s) — the ledger says you hold both at once:\n")
    for o in open {
        print("  \(o.id)   sim \(String(format: "%.2f", o.sim))")
        print("    A (\(o.fromA.prefix(10)))  \(o.textA)")
        print("    B (\(o.fromB.prefix(10)))  \(o.textB)")
        if !o.reason.isEmpty { print("    → \(o.reason)") }
        if !o.discriminator.isEmpty { print("    ⋯ separated by: \(o.discriminator)") }
        print("")
    }
    print("""
      exo contra-resolve <id> genuine_change              close the earlier belief where the later begins
      exo contra-resolve <id> scope_difference            both stand; they hold in different situations
      exo contra-resolve <id> both_true                   both stand; they never actually conflicted
      exo contra-resolve <id> extraction_error --retract <belief_id>
    """)

case "contra-resolve":
    let s = Store(dbPath); Ledger.migrate(s)
    let pos = positional()
    guard pos.count >= 2 else {
        print("usage: exo contra-resolve <contra_id> <verdict> [--retract <belief_id>]"); break
    }
    let retracting = opt("--retract", "").isEmpty ? nil : opt("--retract", "")
    switch Contradict.resolve(s, contraID: pos[0], verdict: pos[1], retracting: retracting) {
    case .ok(let note): s.checkpoint(); print("\(pos[1]): \(note)")
    case .failed(let why): print("not resolved — \(why)")
    }

case "decay-test":
    let s = Store(dbPath); Decay.migrate(s); Ledger.migrate(s)
    var pass = 0, fail = 0
    func chk(_ label: String, _ got: String, _ want: String) {
        if got == want { print("  ✅ \(label)"); pass += 1 }
        else { print("  ❌ \(label)\n       got:  \(got)\n       want: \(want)"); fail += 1 }
    }

    // ── the curve ──
    chk("R = 0.9 at exactly one stability",
        String(format: "%.4f", Decay.retrievability(daysSince: 60, stability: 60)), "0.9000")
    chk("R = 1 at zero elapsed",
        String(format: "%.4f", Decay.retrievability(daysSince: 0, stability: 60)), "1.0000")
    chk("R falls monotonically",
        String(Decay.retrievability(daysSince: 200, stability: 60)
             < Decay.retrievability(daysSince: 100, stability: 60)), "true")
    chk("R never reaches zero — decay hides, it does not erase",
        String(Decay.retrievability(daysSince: 36500, stability: 60) > 0), "true")

    // The spacing effect: rescuing a nearly-forgotten memory is worth more than
    // re-reading a fresh one. A flat multiplier gets this exactly backwards.
    let gainFresh = Decay.strengthen(stability: 60, retrievability: 0.99, weight: 0.6) - 60
    let gainFaded = Decay.strengthen(stability: 60, retrievability: 0.31, weight: 0.6) - 60
    chk("a faded memory gains more from retrieval than a fresh one",
        String(gainFaded > gainFresh * 5), "true")
    chk("opening is worth more than merely surfacing",
        String((Decay.weights["opened"] ?? 0) > (Decay.weights["surfaced"] ?? 0)), "true")

    // ── the pass, on a fixture aged past the floor ──
    let marker = "decaytest"
    s.exec("DELETE FROM events WHERE source='\(marker)';")
    // 800 days, not 400. At the base stability of 60 days, R < 0.30 needs
    // t/S > ln(0.30)/ln(0.9) = 11.4, i.e. **686 days untouched** — nearly two years. The
    // first version of this test used 400 days, where R is still 0.495, and failed against
    // perfectly correct code.
    let old = nowMicros() - 800 * 86_400_000_000
    for i in 0..<3 {
        s.exec("""
            INSERT INTO events(ts,ts_tz,source,source_kind,trust,retention,text,content_hash,ingested_at)
            VALUES(\(old + Int64(i)), 0, '\(marker)', 'own_file', 'self', 'text',
                   'decay fixture note \(i) about nothing in particular', 'dk\(i)', \(old + Int64(i)));
            """)
    }
    let seqs = s.rows("SELECT seq FROM events WHERE source='\(marker)' ORDER BY seq;").compactMap { Int64($0[0]) }
    guard seqs.count == 3 else { print("  ❌ fixture: \(seqs.count) events"); break }
    Decay.pin(s, seqs[2], true)

    _ = Decay.run(s, apply: true, floor: Decay.floor, limit: 500_000)
    func tier(_ q: Int64) -> String {
        s.rows("SELECT coalesce(tier,'hot') FROM memory_state WHERE seq=\(q);").first?.first ?? "hot"
    }
    chk("an 800-day-untouched row goes cold (the floor is ~686d at S=60)", tier(seqs[0]), "cold")
    chk("a pinned row never does", tier(seqs[2]), "hot")
    chk("going cold does not delete the row",
        String(s.scalar("SELECT count(*) FROM events WHERE seq=\(seqs[0]);")), "1")
    chk("…nor its text",
        String(s.scalar("SELECT count(*) FROM events WHERE seq=\(seqs[0]) AND length(text)>10;")), "1")
    chk("…nor its FTS entry, so an explicit search still finds it",
        String(s.search("decay fixture", limit: 5, minTrust: nil, includeCold: true)
                .contains { Int64($0.seq) == seqs[0] }), "true")
    chk("but the default search hides it",
        String(s.search("decay fixture", limit: 5, minTrust: nil, includeCold: false)
                .contains { Int64($0.seq) == seqs[0] }), "false")

    // Retrieval revives. Demotion has to be reversible or it is deletion with extra steps.
    Decay.record(s, seqs: [seqs[0]], kind: "opened")
    chk("retrieving a cold row brings it back", tier(seqs[0]), "hot")
    chk("…and it is stronger than it was",
        String(Decay.state(s, seqs[0]).stability > Decay.baseStability), "true")

    // Evidence under a CONFIRMED belief is immune; an unreviewed guess is not.
    let run = Ledger.startRun(s, model: "test", version: "1", promptHash: "-", codeVersion: "-")
    let cid = Ledger.upsertClaim(s, subject: "decaytest", predicate: "states", object: nil,
                                 polarity: 1, scope: nil, norm: "a confirmed belief for the decay test")
    let bid = Ledger.mindChange(s, from: nil, toClaim: cid, at: Ledger.now(), confidence: 1.0,
                                confidenceSrc: "human_confirmed", runID: run, evidence: [seqs[1]])
    s.exec("UPDATE memory_state SET tier='hot' WHERE seq=\(seqs[1]);")
    _ = Decay.run(s, apply: true, floor: Decay.floor, limit: 500_000)
    chk("evidence under a confirmed belief is immune", tier(seqs[1]), "hot")
    print("     ^ demoting it would leave a belief whose provenance you cannot see")

    s.exec("DELETE FROM belief_evidence WHERE belief_id='\(bid)';")
    s.exec("DELETE FROM belief WHERE belief_id='\(bid)';")
    s.exec("DELETE FROM claim WHERE subject='decaytest';")
    s.exec("DELETE FROM events WHERE source='\(marker)';")
    s.checkpoint()
    print("\n  \(pass) passed, \(fail) failed")

case "segment-test":
    let s = Store(dbPath); Segment.migrate(s)
    var pass = 0, fail = 0
    func chk(_ label: String, _ got: String, _ want: String) {
        if got == want { print("  ✅ \(label)"); pass += 1 }
        else { print("  ❌ \(label)\n       got:  \(got)\n       want: \(want)"); fail += 1 }
    }
    let t0: Int64 = 1_750_000_000_000_000
    func mk(_ i: Int, _ v: [Double], minutesIn: Int) -> Segment.Item {
        Segment.Item(seq: Int64(1000 + i), ts: t0 + Int64(minutesIn) * 60_000_000,
                     source: "t", text: "note \(i)", vec: v)
    }
    let A: [Double] = [1, 0, 0], B: [Double] = [0, 1, 0], C: [Double] = [0, 0, 1]

    // The centroid is the whole point of measuring surprise this way.
    let alternating = [A, B, A, B, A, B].enumerated().map { mk($0.offset, $0.element, minutesIn: $0.offset) }
    let sAlt = Segment.surprise(alternating, window: 5)
    let pairwise = (1..<alternating.count).map { 1 - Segment.cos(alternating[$0].vec, alternating[$0 - 1].vec) }
    chk("alternating topics look maximally surprising pairwise",
        String(format: "%.2f", pairwise.max() ?? 0), "1.00")
    chk("…but against a running centroid they are one episode",
        String(sAlt.dropFirst(2).allSatisfy { $0 < 0.6 }), "true")

    // A genuine switch still registers.
    var switching = (0..<6).map { mk($0, A, minutesIn: $0) }
    switching += (6..<12).map { mk($0, C, minutesIn: $0) }
    let sSwitch = Segment.surprise(switching, window: 5)
    chk("a real topic switch peaks", String(sSwitch[6] > 0.9), "true")
    var p2 = Segment.Params(); p2.minEvents = 3; p2.k = 1.0
    chk("…and becomes a boundary", String(Segment.boundaries(switching, p2).idx.contains(6)), "true")

    // A long pause is a boundary whatever the content says.
    var paused = (0..<4).map { mk($0, A, minutesIn: $0) }
    paused += (4..<8).map { mk($0, A, minutesIn: 200 + $0) }
    chk("a 3-hour gap cuts even when the topic never changed",
        String(Segment.boundaries(paused, p2).idx.contains(4)), "true")

    // Runs shorter than minEvents are not episodes.
    let eps = Segment.build(switching, p2)
    chk("no episode is shorter than minEvents",
        String(eps.allSatisfy { $0.items.count >= p2.minEvents }), "true")
    chk("and every event still lands in one",
        String(eps.reduce(0) { $0 + $1.items.count }), String(switching.count))

    // ── persistence, citation integrity, cascade ──
    let marker = "segmenttest"
    s.exec("DELETE FROM events WHERE source='\(marker)';")
    let now = nowMicros()
    for i in 0..<3 {
        s.exec("""
            INSERT INTO events(ts,ts_tz,source,source_kind,trust,retention,text,content_hash)
            VALUES(\(now + Int64(i) * 60_000_000), 0, '\(marker)', 'own_file', 'self',
                   'text', 'segment fixture note \(i)', 'sg\(i)');
            """)
    }
    let seqs = s.rows("SELECT seq FROM events WHERE source='\(marker)' ORDER BY seq;").compactMap { Int64($0[0]) }
    guard seqs.count == 3 else { print("  ❌ fixture: \(seqs.count) events"); break }
    var ep = Segment.Episode(id: "epi_segmenttest",
                             items: seqs.enumerated().map {
                                 Segment.Item(seq: $0.element, ts: now, source: marker,
                                              text: "x", vec: A)
                             }, peak: 0.5)
    ep.title = "fixture"
    ep.lines = [("first thing", seqs[0]), ("second thing", seqs[1])]
    Segment.persist(s, [ep], day: "2026-01-01")
    chk("lines persist with their citations",
        String(Segment.lines(s, episode: ep.id).count), "2")

    // Area F: a derived artifact must carry provenance back to source spans so deletion can
    // cascade, and it must be built in rather than retrofitted. Retention deletes events; a
    // day's read-out quoting text that no longer exists is worse than no read-out.
    s.exec("DELETE FROM events WHERE seq=\(seqs[0]);")
    chk("deleting a cited event removes the line that cited it",
        String(Segment.lines(s, episode: ep.id).count), "1")
    chk("…and its membership in the episode",
        String(s.scalar("SELECT count(*) FROM episode_event WHERE seq=\(seqs[0]);")), "0")

    s.exec("DELETE FROM events WHERE source='\(marker)';")
    s.exec("DELETE FROM episode WHERE episode_id='epi_segmenttest';")
    s.checkpoint()
    print("\n  \(pass) passed, \(fail) failed")

case "connect-test":
    // Everything here is deterministic. The model's contribution to S5 is one sentence of
    // prose about a term it was handed, and a test that pinned that would be testing this
    // week's weights. What must not drift is which pairs are eligible, what counts as a
    // grounded link, and that a connection cannot outlive the events it was drawn from.
    let s = Store(dbPath); Connect.migrate(s)
    var pass = 0, fail = 0
    func chk(_ label: String, _ got: String, _ want: String) {
        if got == want { print("  ✅ \(label)"); pass += 1 }
        else { print("  ❌ \(label)\n       got:  \(got)\n       want: \(want)"); fail += 1 }
    }

    // ── automation detection ──
    let padded = "New option: Acrylic Glass. Same deal — one free Photo Tile every month."
        + String(repeating: "\u{200C} ", count: 6)
    chk("ZWNJ padding is caught (and Character iteration would not see it)",
        String(Connect.looksAutomated(padded)), "true")
    let buried = "Do you know Hawk Junebug? Yes, connect: "
        + String(repeating: "filler words to push the marker past six hundred characters. ", count: 14)
        + "Unsubscribe here."
    chk("a marker at char \(buried.count - 17) is still caught",
        String(Connect.looksAutomated(buried)), "true")
    chk("Cyrillic homoglyphs in Latin prose are caught",
        String(Connect.looksAutomated("Нellο! Emily Сartеr here with Amazon's Remote Recruitment Team. Your experience caught our attention and we would like to discuss a role with you today.")),
        "true")
    chk("ordinary prose is not",
        String(Connect.looksAutomated("The selector missed because the menu had already closed, so the aria-label had flipped back to Open menu before the click landed.")),
        "false")

    // ── the link has to be in both notes, and rare ──
    var cache: [String: Int] = [:]
    let noteA = "The selector missed because the menu had already closed — the aria-label flipped back to \"Open menu\" before the click landed."
    let noteB = "My click opened the search panel instead, matching the first aria-label on the page rather than the one I wanted."
    let shared = Connect.sharedRareTerms(s, noteA, noteB, cache: &cache)
    chk("a genuinely shared rare identifier is found",
        String(shared.contains { $0.0 == "aria-label" }), "true")
    chk("…and hyphens survive tokenization, so it is one term not two",
        String(Connect.sharedRareTerms(s, "aria-label", "aria-label", cache: &cache).first?.0 ?? "-"),
        "aria-label")
    let generic = Connect.sharedRareTerms(s,
        "This is about the build and the work and the design of the project overall.",
        "The work on the build continued and the design of the project changed.", cache: &cache)
    chk("words two work logs share by being work logs are not a link",
        String(generic.isEmpty), "true")

    // ── the model is shown the term, not the top of the note ──
    let long = String(repeating: "preamble that is not about anything in particular. ", count: 20)
        + "then finally the webgpu backend refused to compile the shader."
    chk("the prompt window centres on the term",
        String(Connect.window(long, around: "webgpu", radius: 40).contains("webgpu")), "true")
    chk("…and a term that is absent falls back to the head rather than crashing",
        String(Connect.window(long, around: "nonexistent", radius: 40).isEmpty), "false")

    // ── persistence, and the promise that a connection dies with its evidence ──
    let marker = "connecttest"
    func wipe() {
        s.exec("DELETE FROM events WHERE source='\(marker)';")   // connections cascade
    }
    wipe()
    let now = nowMicros()
    for i in 0..<2 {
        s.exec("""
            INSERT INTO events(ts,ts_tz,source,source_kind,trust,retention,text,content_hash)
            VALUES(\(now - Int64(i) * 60 * 86_400_000_000), 0, '\(marker)', 'own_file', 'self',
                   'text', 'synthetic note \(i) about the webgpu backend', 'ct\(i)');
            """)
    }
    let seqs = s.rows("SELECT seq FROM events WHERE source='\(marker)' ORDER BY seq;").compactMap { Int64($0[0]) }
    guard seqs.count == 2 else { print("  ❌ fixture: expected 2 events, got \(seqs.count)"); break }
    let cand = Connect.Cand(a: seqs[0], b: seqs[1], sim: 0.7, daysApart: 60,
                            srcA: marker, srcB: marker, textA: "a", textB: "b",
                            fullA: "a", fullB: "b", tsA: now, tsB: now - 60 * 86_400_000_000)
    let finding = Connect.Finding(cand: cand, link: "webgpu — test", relevance: 1,
                                  unexpectedness: 0.5, serendipity: 0.5)
    Connect.record(s, finding)
    Connect.record(s, finding)
    chk("a re-run does not duplicate the connection",
        String(s.scalar("SELECT count(*) FROM connection WHERE seq_a=\(seqs[0]) AND seq_b=\(seqs[1]);")), "1")

    let brief1 = Connect.forBrief(s, limit: 10).filter { $0.srcA == marker }
    chk("an unsurfaced connection reaches the brief", String(brief1.count), "1")
    Connect.markSurfaced(s, brief1.map(\.id))
    chk("and never reaches it twice",
        String(Connect.forBrief(s, limit: 10).filter { $0.srcA == marker }.count), "0")

    // Area F: "every derived artifact must carry provenance pointers back to source spans so
    // deletion can cascade. Retrofit is impossible; build it in at S3." Retention deletes
    // events; if the connections drawn from them survived, a purge would leave the brief
    // quoting text that no longer exists.
    s.exec("DELETE FROM events WHERE seq=\(seqs[0]);")
    chk("deleting an event deletes the connections drawn from it",
        String(s.scalar("SELECT count(*) FROM connection WHERE seq_a=\(seqs[0]) OR seq_b=\(seqs[0]);")), "0")

    wipe(); s.checkpoint()
    print("\n  \(pass) passed, \(fail) failed")

case "contra-test":
    // Stages 1 and 4 are deterministic, so they are asserted rather than described. The
    // classifier is not: it is a model, and a test that pins its output would only be
    // testing today's weights. What must never drift is which pairs are *offered* to it,
    // and what a verdict does to the ledger afterwards.
    let s = Store(dbPath); Ledger.migrate(s)
    let SUBJ = "contratest"
    // Beliefs and findings only. Claims are content-addressed and shared across cases —
    // deleting them here orphaned every belief created afterwards, and the whole run went
    // from a failed assertion to an index-out-of-range trap four checks in.
    func reset() {
        let mine = "SELECT belief_id FROM belief b JOIN claim c USING(claim_id) WHERE c.subject='\(SUBJ)'"
        s.exec("DELETE FROM contradiction WHERE belief_a IN (\(mine));")
        s.exec("DELETE FROM belief_vec WHERE belief_id IN (\(mine));")
        s.exec("DELETE FROM belief_evidence WHERE belief_id IN (\(mine));")
        s.exec("DELETE FROM belief WHERE claim_id IN (SELECT claim_id FROM claim WHERE subject='\(SUBJ)');")
    }
    func resetAll() { reset(); s.exec("DELETE FROM claim WHERE subject='\(SUBJ)';") }
    resetAll()
    let run = Ledger.startRun(s, model: "test", version: "1", promptHash: "-", codeVersion: "-")
    let P = Ledger.upsertClaim(s, subject: SUBJ, predicate: "works_best", object: "alone",
                               polarity: 1, scope: nil, norm: "I work best alone")
    let nP = Ledger.upsertClaim(s, subject: SUBJ, predicate: "works_best", object: "alone",
                                polarity: -1, scope: nil, norm: "I do not work best alone")
    var pass = 0, fail = 0
    func chk(_ label: String, _ got: String, _ want: String) {
        if got == want { print("  ✅ \(label)"); pass += 1 }
        else { print("  ❌ \(label)\n       got:  \(got)\n       want: \(want)"); fail += 1 }
    }
    func cands() -> [Contradict.Pair] {
        Contradict.candidates(s, includeUnconfirmed: true, limit: 100)
            .filter { $0.subjA == SUBJ && $0.subjB == SUBJ }
    }
    /// A missing candidate is a failed assertion, not a crash — subscripting the empty
    /// array turned the first fixture bug into a trap that hid every check after it.
    func onlyPair(_ where_: String) -> Contradict.Pair? {
        let c = cands()
        if c.count == 1 { return c[0] }
        print("  ❌ \(where_): expected 1 candidate pair, got \(c.count)"); fail += 1
        return nil
    }
    func at(_ d: String) -> String {
        Ledger.beliefsAt(s, subject: SUBJ, asOf: d, includeUnconfirmed: true)
            .map { $0.polarity > 0 ? "P" : "notP" }.sorted().joined(separator: "+")
    }
    func mk(_ claim: String, _ from: String) -> String {
        Ledger.mindChange(s, from: nil, toClaim: claim, at: from,
                          confidence: 0.9, confidenceSrc: "explicit_statement", runID: run)
    }

    // ── stage 1: which pairs are even offered ──
    var b1 = mk(P, "2025-01-01T00:00:00Z")
    var b2 = mk(nP, "2025-06-01T00:00:00Z")
    chk("overlapping P / not-P is a candidate", String(cands().count), "1")
    chk("…and it is flagged structural, not left to the embedding",
        cands().first.map { String($0.structural) } ?? "-", "true")
    chk("the ledger really does assert both at once", at("2025-09-01T00:00:00Z"), "P+notP")
    print("     ^ that simultaneity IS the contradiction; the rest is deciding why")

    // Non-overlap. Close b1 before b2 begins and drop the succession link, so the ONLY
    // thing excluding this pair is the interval test.
    s.exec("UPDATE belief SET belief_to='2025-06-01T00:00:00Z' WHERE belief_id='\(b1)';")
    s.exec("UPDATE belief SET supersedes=NULL WHERE belief_id='\(b2)';")
    chk("non-overlapping intervals are evolution, not contradiction", String(cands().count), "0")

    // ── stage 4: what a verdict does to the ledger ──
    reset()
    b1 = mk(P, "2025-01-01T00:00:00Z"); b2 = mk(nP, "2025-06-01T00:00:00Z")
    guard let pairA = onlyPair("genuine_change setup") else { break }
    Contradict.record(s, Contradict.Finding(pair: pairA, verdict: "genuine_change",
                                            reason: "-", discriminator: ""), detector: "test")
    Contradict.record(s, Contradict.Finding(pair: pairA, verdict: "genuine_change",
                                            reason: "-", discriminator: ""), detector: "test")
    chk("a re-scan does not duplicate the finding",
        String(s.scalar("SELECT count(*) FROM contradiction WHERE belief_a='\(pairA.a)' AND belief_b='\(pairA.b)';")), "1")
    let cid = s.rows("SELECT contra_id FROM contradiction WHERE belief_a='\(pairA.a)';")[0][0]

    if case .failed(let why) = Contradict.resolve(s, contraID: cid, verdict: "genuine_change", retracting: nil) {
        print("  ❌ genuine_change: \(why)"); fail += 1
    } else {
        chk("genuine_change: after the boundary, only the later belief", at("2025-09-01T00:00:00Z"), "notP")
        chk("genuine_change: BEFORE it, the earlier belief still answers", at("2025-03-01T00:00:00Z"), "P")
        print("     ^ I really did believe P in March; resolving a contradiction must not erase that")
    }
    chk("a resolved pair is never offered again", String(cands().count), "0")

    // Two beliefs recorded in the SAME SECOND. Found by a live fixture, not by the checks
    // above: eight `exo tell`s in a shell loop all landed on one ISO timestamp, and
    // `genuine_change` then failed with "intervals may not overlap" — which was both wrong
    // (they overlap completely; that is why it was flagged) and unactionable.
    reset()
    let tie = "2025-04-01T12:00:00Z"
    _ = mk(P, tie); _ = mk(nP, tie)
    if let pairT = onlyPair("same-instant setup") {
        Contradict.record(s, Contradict.Finding(pair: pairT, verdict: "genuine_change",
                                                reason: "-", discriminator: ""), detector: "test")
        let cidT = s.rows("SELECT contra_id FROM contradiction WHERE belief_a='\(pairT.a)';")[0][0]
        if case .failed(let why) = Contradict.resolve(s, contraID: cidT, verdict: "genuine_change",
                                                      retracting: nil) {
            chk("same-instant beliefs: refused, and the reason names the tie",
                String(why.contains("same instant")), "true")
        } else {
            print("  ❌ same-instant beliefs: resolved when it should have refused"); fail += 1
        }
        chk("same-instant beliefs: nothing was changed", at("2025-09-01T00:00:00Z"), "P+notP")
    }

    // extraction_error — the machine misread one side; it was never believed at all.
    reset()
    b1 = mk(P, "2025-01-01T00:00:00Z"); b2 = mk(nP, "2025-06-01T00:00:00Z")
    guard let pairB = onlyPair("extraction_error setup") else { break }
    Contradict.record(s, Contradict.Finding(pair: pairB, verdict: "genuine_change",
                                            reason: "-", discriminator: ""), detector: "test")
    let cid2 = s.rows("SELECT contra_id FROM contradiction WHERE belief_a='\(pairB.a)';")[0][0]
    _ = Contradict.resolve(s, contraID: cid2, verdict: "extraction_error", retracting: b2)
    chk("extraction_error: the retracted side stops answering", at("2025-09-01T00:00:00Z"), "P")
    chk("extraction_error: the row is closed, not deleted",
        String(s.scalar("SELECT count(*) FROM belief WHERE belief_id='\(b2)' AND sys_to IS NOT NULL;")), "1")
    chk("extraction_error: the belief INTERVAL is untouched",
        s.rows("SELECT belief_from, coalesce(belief_to,'-') FROM belief WHERE belief_id='\(b2)';")
            .first.map { "\($0[0])|\($0[1])" } ?? "", "2025-06-01T00:00:00Z|-")
    print("     ^ a retraction moves the SYSTEM record. It does not claim I stopped believing it —")
    print("       it claims I never did, and the audit trail has to survive saying so")

    // both_true — the detector was over-eager. Nothing may change.
    reset()
    b1 = mk(P, "2025-01-01T00:00:00Z"); b2 = mk(nP, "2025-06-01T00:00:00Z")
    guard let pairC = onlyPair("both_true setup") else { break }
    Contradict.record(s, Contradict.Finding(pair: pairC, verdict: "genuine_change",
                                            reason: "-", discriminator: ""), detector: "test")
    let cid3 = s.rows("SELECT contra_id FROM contradiction WHERE belief_a='\(pairC.a)';")[0][0]
    _ = Contradict.resolve(s, contraID: cid3, verdict: "both_true", retracting: nil)
    chk("both_true: both beliefs still stand", at("2025-09-01T00:00:00Z"), "P+notP")
    print("     ^ three of the four verdicts must leave the ledger alone, or the review")
    print("       queue is a deletion queue wearing a disguise")

    // ── stage 2, only if the sidecar is present ──
    reset()
    let U1 = Ledger.upsertClaim(s, subject: SUBJ, predicate: "states", object: nil, polarity: 1,
                                scope: nil, norm: "I hate driving at night")
    let U2 = Ledger.upsertClaim(s, subject: SUBJ, predicate: "states", object: nil, polarity: 1,
                                scope: nil, norm: "I think loyalty matters more than talent")
    _ = mk(U1, "2025-01-01T00:00:00Z"); _ = mk(U2, "2025-02-01T00:00:00Z")
    let bandPairs = cands()
    if bandPairs.count != 1 {
        print("  ❌ band: expected 1 candidate pair, got \(bandPairs.count)"); fail += 1
    } else if let scored = Contradict.score(s, bandPairs), let only = scored.first {
        chk("band: two unrelated beliefs score below \(Contradict.minSim) (got \(String(format: "%.3f", only.sim)))",
            String(only.sim < Contradict.minSim), "true")
    } else {
        // Distinguished from "no candidates" on purpose: a filter that fails closed and
        // reports nothing looks exactly like a clean ledger.
        print("  ⏭  band: embedding sidecar unavailable, stage 2 not exercised")
    }

    resetAll(); s.checkpoint()
    print("\n  \(pass) passed, \(fail) failed")

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
      exo bar [--hotkey ctrl+opt+space]
                                    everything-bar floating search
      exo fs [--seconds N]          watch the home dir via FSEvents (resumable)
      exo gmail-auth <id> <secret>  one-time OAuth (see SETUP-GMAIL.md)
      exo accounts                  list connected mail accounts
      exo iphone-auth               unlock an encrypted iPhone backup (prompts)
      exo iphone [--sources ...]    ingest calls/notes/safari/whatsapp
      exo imap-auth <email>         connect iCloud/other IMAP (prompts)
      exo imap [--days 30]          ingest IMAP mail
      exo gmail [--query "newer_than:30d"] [--account x]
                                    ingest Gmail (restricted scope, personal-use exempt)
      exo browser [--days N]        Safari/Chrome/Brave/Edge history (needs FDA)
      exo imessage [--days N] [--rescan]
                                    iMessage chat.db (needs FDA); --rescan re-reads all
      exo capture [--interval 2] [--once]
                                    AX-tree + clipboard capture loop
      exo search <query> [--hybrid] [--min-trust verified] [--limit N]
      exo embed [--provider mlx|nl] embed rows that lack a vector
      exo bench [--bits 256]        measure brute-force scan throughput
      (search: --bits 1024 default; --rescore N enables the int8 tier, currently
       measured WORSE than binary-only — see RESULTS.md)
      exo retention [--apply]       run scheduled expiry (dry-run by default)
      exo hold on|off [--reason ..] litigation hold: suspend ALL expiry
      exo offsite-key               copy the offsite key to the clipboard (never printed)
      exo offsite-key-clear         clear the clipboard afterwards
      exo offsite                   encrypted snapshot -> iCloud Drive
      exo offsite-restore [path]    restore the newest offsite snapshot
      exo scan-secrets              audit the store for key-shaped content
      exo forget-secrets            delete anything scan-secrets finds
      exo extract [--limit N]       extract claims into the belief ledger
      exo beliefs <subject> [--as-of D]
      exo tell "<statement>"        record a belief directly (highest confidence)
      exo ask [--n 3]               short interview; the corpus cannot observe values
      exo beliefs-review            unconfirmed claims awaiting a human
      exo beliefs-confirm <id> / beliefs-reject <id>
      exo belief-history <subject>
      exo ledger-test               prove the mind-change / re-extraction split
      exo stats                     counts, trust mix, exclusions, policy
      exo seed                      synthetic events, no permissions needed

      --db <path>                   default ~/.exocortex/phase1.db
    """)
}
