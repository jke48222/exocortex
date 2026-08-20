import Foundation
import Network
import Security

/// Minimal IMAP4rev1 client over TLS — enough to read mail, nothing more.
///
/// iCloud has no Gmail-style API, so IMAP is the path (PASS-4 Area B: "IMAP+IDLE as the
/// universal fallback"). Apple requires an **app-specific password** because the Apple ID
/// has 2FA; the account password will not work.
///
/// Credentials go in the login Keychain, never a dotfile and never argv — an app-specific
/// password grants full mailbox access, and anything in argv is visible to `ps`.
final class IMAP {
    let host: String, port: UInt16
    private var conn: NWConnection!
    private var buf = Data()
    private var tag = 0
    private let q = DispatchQueue(label: "imap")

    init(host: String, port: UInt16 = 993) { self.host = host; self.port = port }

    // MARK: keychain
    static let service = "exocortex.imap"
    static func setCred(_ email: String, password: String, host: String) {
        for (k, v) in ["pw:\(email)": password, "host:\(email)": host] {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: service,
                                       kSecAttrAccount as String: k]
            SecItemDelete(base as CFDictionary)
            var add = base
            add[kSecValueData as String] = Data(v.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
        var list = accounts()
        if !list.contains(email) { list.append(email) }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: "accounts"]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(list.joined(separator: ",").utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
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
    static func accounts() -> [String] {
        (get("accounts") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: transport
    func connect(timeout: TimeInterval = 20) -> Bool {
        let tls = NWProtocolTLS.Options()
        let params = NWParameters(tls: tls)
        conn = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: params)
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        conn.stateUpdateHandler = { st in
            switch st {
            case .ready: ok = true; sem.signal()
            case .failed, .cancelled: ok = false; sem.signal()
            default: break
            }
        }
        conn.start(queue: q)
        _ = sem.wait(timeout: .now() + timeout)
        guard ok else { return false }
        _ = readUntil { $0.contains("\r\n") }        // server greeting
        return true
    }

    private func readChunk(timeout: TimeInterval) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var got = false
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, done, _ in
            if let d, !d.isEmpty { self.buf.append(d); got = true }
            if done { got = false }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        return got
    }
    /// Read until `done` is satisfied by the accumulated text.
    private func readUntil(timeout: TimeInterval = 30, _ done: (String) -> Bool) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let s = String(decoding: buf, as: UTF8.self)
            if done(s) { buf.removeAll(); return s }
            if !readChunk(timeout: 5) { break }
        }
        let s = String(decoding: buf, as: UTF8.self); buf.removeAll(); return s
    }

    @discardableResult
    func send(_ cmd: String, timeout: TimeInterval = 30) -> String {
        tag += 1
        let t = String(format: "a%03d", tag)
        let line = "\(t) \(cmd)\r\n"
        conn.send(content: line.data(using: .utf8), completion: .contentProcessed { _ in })
        return readUntil(timeout: timeout) { s in
            s.contains("\r\n\(t) OK") || s.contains("\r\n\(t) NO") || s.contains("\r\n\(t) BAD")
                || s.hasPrefix("\(t) OK") || s.hasPrefix("\(t) NO") || s.hasPrefix("\(t) BAD")
        }
    }
    func close() { conn?.cancel() }

    // MARK: IMAP
    /// LOGIN with literal-safe quoting.
    func login(_ user: String, _ pass: String) -> Bool {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\")
                                     .replacingOccurrences(of: "\"", with: "\\\"") }
        let r = send("LOGIN \"\(esc(user))\" \"\(esc(pass))\"")
        return r.contains(" OK")
    }
    func select(_ mailbox: String) -> Bool { send("SELECT \"\(mailbox)\"").contains(" OK") }

    /// UIDs of messages since a date (IMAP date format: 01-Jan-2026).
    func searchSince(_ days: Int) -> [Int] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "dd-MMM-yyyy"
        let since = f.string(from: Date().addingTimeInterval(-Double(days) * 86_400))
        let r = send("UID SEARCH SINCE \(since)")
        guard let line = r.split(separator: "\r\n").first(where: { $0.hasPrefix("* SEARCH") })
        else { return [] }
        return line.dropFirst("* SEARCH".count).split(separator: " ").compactMap { Int($0) }
    }

    struct Msg { var uid: Int; var from = "", to = "", subject = "", date = "", body = "" }

    /// Fetch headers + the text body for one UID. Two round trips keeps parsing simple and
    /// avoids the literal-continuation ambiguity of combining them.
    func fetch(uid: Int) -> Msg? {
        var m = Msg(uid: uid)
        let h = send("UID FETCH \(uid) (BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE)])")
        for raw in h.split(separator: "\r\n") {
            let l = String(raw)
            let low = l.lowercased()
            if low.hasPrefix("from:") { m.from = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            if low.hasPrefix("to:") { m.to = String(l.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            if low.hasPrefix("subject:") { m.subject = String(l.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
            if low.hasPrefix("date:") { m.date = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        }
        let b = send("UID FETCH \(uid) (BODY.PEEK[TEXT])")
        // strip the IMAP framing: first line is the * n FETCH ... {len} header
        var lines = b.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        if !lines.isEmpty, lines[0].hasPrefix("*") { lines.removeFirst() }
        lines.removeAll { $0.hasPrefix("a0") || $0 == ")" }
        m.body = lines.joined(separator: "\n")
        return m
    }
}

enum IMAPIngest {
    /// RFC 2822 date -> micros. Falls back to now.
    static func parseDate(_ s: String) -> Int64 {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z",
                    "EEE, d MMM yyyy HH:mm:ss zzz"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return Int64(d.timeIntervalSince1970 * 1_000_000) }
        }
        return nowMicros()
    }

    static func run(into store: Store, only: String, limit: Int, days: Int) -> [(String, Int, Int, String)] {
        let list = only.isEmpty ? IMAP.accounts() : [only]
        guard !list.isEmpty else { return [("(none)", 0, 0, "no IMAP account — run `exo imap-auth`")] }
        var out: [(String, Int, Int, String)] = []
        for email in list {
            guard let pw = IMAP.get("pw:\(email)") else {
                out.append((email, 0, 0, "no stored password")); continue
            }
            let host = IMAP.get("host:\(email)") ?? "imap.mail.me.com"
            let c = IMAP(host: host)
            guard c.connect() else { out.append((email, 0, 0, "connect failed: \(host):993")); continue }
            defer { c.close() }
            guard c.login(email, pw) else {
                out.append((email, 0, 0, "LOGIN rejected — use an app-specific password, not your Apple ID password"))
                continue
            }
            guard c.select("INBOX") else { out.append((email, 0, 0, "SELECT INBOX failed")); continue }
            let uids = c.searchSince(days).suffix(limit)     // newest
            var n = 0, skip = 0
            store.exec("BEGIN;")
            for uid in uids {
                guard let m = c.fetch(uid: uid) else { skip += 1; continue }
                let body = m.body.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = body.isEmpty ? m.subject : body
                if text.isEmpty { skip += 1; continue }
                let (clean, red) = Exclusion.redact(text)
                if red > 0 || clean.isEmpty {
                    store.recordExclusion(rule: "imap:secret-shaped", bundle: "", app: "Mail")
                    skip += 1; continue
                }
                let fromMe = m.from.lowercased().contains(email.lowercased())
                var e = Event(source: "imap", sourceKind: fromMe ? .typed : .emailKnown)
                e.retention = fromMe ? "text" : "correspondence"
                e.app = "Mail"; e.bundle = "com.apple.mail"
                e.title = m.subject.isEmpty ? "(no subject)" : m.subject
                e.role = fromMe ? "me" : "them"
                e.text = String(clean.prefix(12_000))
                e.externalID = "imap:\(email):\(uid)"
                e.meta = ["from": m.from, "to": m.to, "account": email, "host": host]
                e.ts = parseDate(m.date)
                if store.insert(e) { n += 1 } else { skip += 1 }
            }
            store.exec("COMMIT;")
            out.append((email, n, skip, "ok"))
        }
        return out
    }
}
