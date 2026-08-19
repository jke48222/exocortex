import Foundation
import Security

/// Gmail ingest.
///
/// `gmail.readonly` is a RESTRICTED scope, but a solo dev reading their own mailbox does
/// **not** need a CASA security assessment — Google's own restricted-scope docs exempt the
/// case where "you are the only user of your app or ... a few users, all of whom are known
/// personally to you".
///
/// The trap, and it is the single most actionable finding in PASS-4 Area B: leaving the
/// OAuth consent screen in **Testing** status expires refresh tokens after **7 days**, so
/// an all-day logger silently dies every week. Set the app to **In production** and simply
/// never submit it for verification. You keep a one-click "unverified app" interstitial and
/// gain non-expiring refresh tokens.
///
/// Tokens live in the login Keychain, not a dotfile — a refresh token for a mailbox is
/// exactly the sort of credential the threat model says never to leave lying in plaintext.
enum Gmail {
    static let scope = "https://www.googleapis.com/auth/gmail.readonly"
    static let service = "exocortex.gmail"

    // MARK: Keychain
    static func keychainSet(_ account: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func keychainGet(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: HTTP
    static func post(_ url: String, _ form: [String: String]) -> [String: Any]? {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
                         .joined(separator: "&").data(using: .utf8)
        var result: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: r) { d, _, _ in
            if let d { result = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 30)
        return result
    }
    static func get(_ url: String, token: String) -> [String: Any]? {
        var r = URLRequest(url: URL(string: url)!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var result: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: r) { d, _, _ in
            if let d { result = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 30)
        return result
    }

    // MARK: OAuth (loopback redirect — the flow Google recommends for desktop apps)
    static func authorize(clientID: String, clientSecret: String) -> Bool {
        let listener = try? SimpleHTTP(port: 0)
        guard let listener else { print("could not open a loopback port"); return false }
        let redirect = "http://127.0.0.1:\(listener.port)"
        let auth = "https://accounts.google.com/o/oauth2/v2/auth"
            + "?client_id=\(clientID)&redirect_uri=\(redirect)"
            + "&response_type=code&scope=\(scope.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"
            + "&access_type=offline&prompt=consent"
        print("opening your browser to authorize…")
        print("  if it does not open, paste this:\n  \(auth)\n")
        Process.launchedProcess(launchPath: "/usr/bin/open", arguments: [auth])
        guard let code = listener.awaitCode(timeout: 180) else {
            print("timed out waiting for the redirect"); return false
        }
        guard let tok = post("https://oauth2.googleapis.com/token", [
            "code": code, "client_id": clientID, "client_secret": clientSecret,
            "redirect_uri": redirect, "grant_type": "authorization_code"]) else {
            print("token exchange failed"); return false
        }
        guard let refresh = tok["refresh_token"] as? String else {
            print("no refresh_token returned. If you have authorized before, revoke access at")
            print("https://myaccount.google.com/permissions and retry — Google only issues one")
            print("on first consent unless prompt=consent forces it.")
            return false
        }
        keychainSet("refresh_token", refresh)
        keychainSet("client_id", clientID)
        keychainSet("client_secret", clientSecret)
        print("authorized. refresh token stored in the login Keychain.")
        return true
    }

    static func accessToken() -> String? {
        guard let rt = keychainGet("refresh_token"),
              let cid = keychainGet("client_id"),
              let cs = keychainGet("client_secret") else { return nil }
        let r = post("https://oauth2.googleapis.com/token", [
            "refresh_token": rt, "client_id": cid, "client_secret": cs,
            "grant_type": "refresh_token"])
        if let err = r?["error"] as? String {
            print("token refresh failed: \(err)")
            if err == "invalid_grant" {
                print("  This is the Testing-status trap: refresh tokens expire after 7 days")
                print("  unless the OAuth app's publishing status is 'In production'.")
            }
            return nil
        }
        return r?["access_token"] as? String
    }

    // MARK: ingest
    static func decodeB64URL(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        guard let d = Data(base64Encoded: t) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
    /// Walk the MIME tree for the first text/plain part.
    static func plainText(_ payload: [String: Any]) -> String {
        if let mime = payload["mimeType"] as? String, mime == "text/plain",
           let body = payload["body"] as? [String: Any], let data = body["data"] as? String {
            return decodeB64URL(data)
        }
        for p in (payload["parts"] as? [[String: Any]]) ?? [] {
            let t = plainText(p)
            if !t.isEmpty { return t }
        }
        return ""
    }

    static func ingest(into store: Store, limit: Int, query: String) -> (Int, Int, String) {
        guard let token = accessToken() else { return (0, 0, "not authorized — run `exo gmail-auth`") }
        var me = ""
        if let p = get("https://gmail.googleapis.com/gmail/v1/users/me/profile", token: token) {
            me = (p["emailAddress"] as? String ?? "").lowercased()
        }
        var ingested = 0, skipped = 0, pageToken: String? = nil
        outer: repeat {
            var url = "https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=100"
            if !query.isEmpty { url += "&q=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            if let pt = pageToken { url += "&pageToken=\(pt)" }
            guard let page = get(url, token: token) else { break }
            let msgs = (page["messages"] as? [[String: Any]]) ?? []
            if msgs.isEmpty { break }
            store.exec("BEGIN;")
            for m in msgs {
                guard let id = m["id"] as? String else { continue }
                if ingested + skipped >= limit { store.exec("COMMIT;"); break outer }
                guard let full = get("https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full",
                                     token: token),
                      let payload = full["payload"] as? [String: Any] else { skipped += 1; continue }
                var hdr: [String: String] = [:]
                for h in (payload["headers"] as? [[String: Any]]) ?? [] {
                    if let n = h["name"] as? String, let v = h["value"] as? String {
                        hdr[n.lowercased()] = v
                    }
                }
                let from = (hdr["from"] ?? "").lowercased()
                let body = plainText(payload)
                let text = body.isEmpty ? (full["snippet"] as? String ?? "") : body
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { skipped += 1; continue }
                let (clean, red) = Exclusion.redact(text)
                if red > 0 || clean.isEmpty {
                    store.recordExclusion(rule: "gmail:secret-shaped", bundle: "", app: "Gmail")
                    skipped += 1; continue
                }
                // trust by capture path: mine is self; a known correspondent is
                // third_party; anything else is untrusted and cannot influence a tool call
                let fromMe = !me.isEmpty && from.contains(me)
                let kind: SourceKind = fromMe ? .typed : .emailKnown
                var e = Event(source: "gmail", sourceKind: kind)
                e.retention = fromMe ? "text" : "correspondence"
                e.app = "Gmail"; e.bundle = "com.google.Gmail"
                e.title = hdr["subject"] ?? "(no subject)"
                e.role = fromMe ? "me" : "them"
                e.text = String(clean.prefix(12_000))
                e.externalID = "gmail:\(id)"
                e.meta = ["from": hdr["from"] ?? "", "to": hdr["to"] ?? ""]
                if let ims = full["internalDate"] as? String, let ms = Int64(ims) { e.ts = ms * 1000 }
                if store.insert(e) { ingested += 1 } else { skipped += 1 }
            }
            store.exec("COMMIT;")
            pageToken = page["nextPageToken"] as? String
        } while pageToken != nil && ingested + skipped < limit
        return (ingested, skipped, "ok")
    }
}

/// Minimal loopback listener for the OAuth redirect. No dependencies, one request.
final class SimpleHTTP {
    let fd: Int32
    let port: UInt16
    init(port p: UInt16) throws {
        // local copy: referencing self.fd inside the closures below would capture `self`
        // before `port` is initialized, which Swift rejects
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw NSError(domain: "sock", code: 1) }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = p.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(sock, 1) == 0 else { close(sock); throw NSError(domain: "bind", code: 2) }
        var actual = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        fd = sock
        port = UInt16(bigEndian: actual.sin_port)
    }
    func awaitCode(timeout: TimeInterval) -> String? {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let client = accept(fd, nil, nil)
        guard client >= 0 else { close(fd); return nil }
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(client, &buf, buf.count)
        let req = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
        let ok = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<h2>exocortex: authorized</h2><p>You can close this tab.</p>"
        _ = ok.withCString { write(client, $0, strlen($0)) }
        close(client); close(fd)
        guard let r = req.range(of: "code="), let line = req.split(separator: " ").dropFirst().first
        else { return nil }
        _ = r
        guard let q = line.split(separator: "?").dropFirst().first else { return nil }
        for pair in q.split(separator: "&") where pair.hasPrefix("code=") {
            return String(pair.dropFirst(5)).removingPercentEncoding
        }
        return nil
    }
}
