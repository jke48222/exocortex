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

    static func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: backupRoot)) ?? [])
            .filter { !$0.hasPrefix(".") }
    }

    static func scriptPath() -> String {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/iphone.py").path
    }

    /// Run the sidecar, feeding the password on stdin. Returns (stdoutLines, stderrText).
    static func run(mode: String, udid: String, password: String,
                    sources: String = "", limit: Int = 20000) -> ([String], String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["python3", scriptPath(), mode, "--udid", udid,
                    "--path", backupRoot, "--limit", String(limit)]
        if !sources.isEmpty { args += ["--sources", sources] }
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
                       sources: String, limit: Int) -> (Int, Int, String) {
        let (lines, err) = run(mode: "extract", udid: udid, password: password,
                               sources: sources, limit: limit)
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
            // Trust by capture path. Notes and calls I made are mine; a WhatsApp message
            // someone else sent, or a call they placed, is third-party data on the shorter
            // correspondence class.
            let mine = (o["meta"] as? [String: Any]).flatMap { $0["from_me"] as? Bool } ?? (kind == "note")
            var e = Event(source: "iphone.\(kind)", sourceKind: mine ? .typed : .messageOther)
            e.retention = mine ? "text" : "correspondence"
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
