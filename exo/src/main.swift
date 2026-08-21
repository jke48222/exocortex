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
