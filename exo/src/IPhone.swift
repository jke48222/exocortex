import Foundation
import Security

/// Encrypted iOS backup ingest, via the `tools/iphone.py` sidecar.
///
/// An encrypted backup holds call history, Notes, iOS Safari history and WhatsApp — data
/// that never touches the Mac and is therefore genuinely new, not a duplicate of the
/// existing sources. Everything, including the file manifest, is AES-encrypted under class
/// keys wrapped in the BackupKeyBag, so nothing is readable without the backup password.
///
/// The password is read with **echo disabled** and handed to the sidecar on **stdin**.
/// It never appears in argv — which `ps` exposes to every process on the machine — and
/// never in shell history. It is stored in the login Keychain and nowhere else.
enum IPhone {
    static let service = "exocortex.iphone"
    static var backupRoot: String {
        NSHomeDirectory() + "/Library/Application Support/MobileSync/Backup"
    }

    /// Prompt without echoing. `getpass(3)` reads from /dev/tty, so it works even when
    /// stdout is redirected, and never leaks the value anywhere observable.
    static func promptSecret(_ label: String) -> String? {
        guard let c = getpass(label) else { return nil }
        let s = String(cString: c)
        return s.isEmpty ? nil : s
    }

    static func kcSet(_ key: String, _ v: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(v.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func kcGet(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var o: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &o) == errSecSuccess,
              let d = o as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    enum Access { case ok([String]), denied, missing }

    /// Distinguish "no backups" from "not permitted to look".
    ///
    /// `MobileSync/Backup` is TCC-protected, and `contentsOfDirectory` reports a denial
    /// the same way it reports an empty directory once the error is swallowed — which
    /// produced a "no iOS backups found" message for a directory that plainly contained
    /// one. `opendir` exposes the real errno.
    static func probe() -> Access {
        guard FileManager.default.fileExists(atPath: backupRoot) else { return .missing }
        errno = 0
        guard let d = opendir(backupRoot) else {
            return (errno == EPERM || errno == EACCES) ? .denied : .missing
        }
        closedir(d)
        let all = (try? FileManager.default.contentsOfDirectory(atPath: backupRoot)) ?? []
        return .ok(all.filter { !$0.hasPrefix(".") && $0.contains("-") })
    }

    static func backups() -> [String] {
        if case .ok(let l) = probe() { return l }
        return []
    }

    /// One place to explain a TCC denial, because the fix is never obvious from the error.
    static func explainDenied() {
        print("""
        Cannot read \(backupRoot)

        The folder exists, but macOS denied access. iPhone backups live behind
        Full Disk Access, and the grant belongs to whichever app is RUNNING exo —
        your terminal — not to exo itself.

        Grant it:
          System Settings > Privacy & Security > Full Disk Access
          + and add your terminal app (Terminal, iTerm, Ghostty, Warp, VS Code…)
          then QUIT AND REOPEN the terminal — the grant only applies to a fresh launch.

        Or grant it to the binary directly by dragging this file into that list:
          \(URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path)
        """)
    }

    static func scriptPath() -> String? { Paths.tool("iphone.py") }

    /// Run the sidecar, feeding the password on stdin. Returns (stdoutLines, stderrText).
    static func run(mode: String, udid: String, password: String,
                    sources: String = "", limit: Int = 20000,
                    grep: String = "") -> ([String], String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        guard let script = scriptPath() else { return ([], Paths.missing("iphone.py")) }
        var args = ["python3", script, mode, "--udid", udid,
                    "--path", backupRoot, "--limit", String(limit)]
        if !sources.isEmpty { args += ["--sources", sources] }
        if !grep.isEmpty { args += ["--grep", grep] }
        p.arguments = args
        let inP = Pipe(), outP = Pipe(), errP = Pipe()
        p.standardInput = inP; p.standardOutput = outP; p.standardError = errP
        do { try p.run() } catch { return ([], "could not start sidecar: \(error)") }
        inP.fileHandleForWriting.write(Data((password + "\n").utf8))
        try? inP.fileHandleForWriting.close()
        let o = outP.fileHandleForReading.readDataToEndOfFile()
        let e = errP.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: o, as: UTF8.self).split(separator: "\n").map(String.init),
                String(decoding: e, as: UTF8.self))
    }

    static func ingest(into store: Store, udid: String, password: String,
                       sources: String, limit: Int, verbose: Bool = false) -> (Int, Int, String) {
        let (lines, err) = run(mode: "extract", udid: udid, password: password,
                               sources: sources, limit: limit)
        // The sidecar reports per-source counts and decrypt failures on stderr. Swallowing
        // it made five of eight sources fail silently and look like empty data.
        if verbose, !err.isEmpty {
            FileHandle.standardError.write(("--- sidecar ---\n" + err + "\n").data(using: .utf8)!)
        }
        var n = 0, skip = 0
        store.exec("BEGIN;")
        for line in lines {
            guard let d = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            else { skip += 1; continue }
            if let ok = o["ok"] as? Bool, ok == false {
                store.exec("COMMIT;")
                return (0, 0, (o["error"] as? String) ?? "failed")
            }
            guard let kind = o["kind"] as? String,
                  let text = o["text"] as? String, !text.isEmpty else { skip += 1; continue }
            let (clean, red) = Exclusion.redact(text)
            if red > 0 || clean.isEmpty {
                store.recordExclusion(rule: "iphone:secret-shaped", bundle: "", app: "iPhone")
                skip += 1; continue
            }
            // Trust by capture path, as everywhere else. The sidecar decides `mine` from
            // the source's own semantics (ZISFROMME, ZORIGINATED, …) rather than exo
            // guessing from a meta key that only some sources set.
            let mine = (o["mine"] as? Bool) ?? false
            let sensitive = (o["sensitive"] as? Bool) ?? false
            var e = Event(source: "iphone.\(kind)", sourceKind: mine ? .typed : .messageOther)
            // Health is medical data. It goes on the T3 `sensitive` class (30 days) rather
            // than being kept forever alongside ordinary notes — PASS-4 Area L tiers
            // health, finance and legal separately for exactly this reason.
            e.retention = sensitive ? "sensitive" : (mine ? "text" : "correspondence")
            e.app = "iPhone"; e.bundle = "com.apple.MobileBackup"
            e.title = (o["title"] as? String) ?? kind
            e.role = mine ? "me" : "them"
            e.text = String(clean.prefix(8000))
            e.externalID = "iphone:\(kind):\(sha(text + String(describing: o["ts"] ?? "")))"
            if let ts = o["ts"] as? NSNumber, ts.int64Value > 0 { e.ts = ts.int64Value }
            if let m = o["meta"] as? [String: Any] {
                e.meta = m.mapValues { String(describing: $0) }
            }
            if store.insert(e) { n += 1 } else { skip += 1 }
        }
        store.exec("COMMIT;")
        return (n, skip, err.contains("warn") ? "ok (warnings: \(err.split(separator: "\n").count))" : "ok")
    }
}
