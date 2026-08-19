import Foundation
import AppKit
import Carbon.HIToolbox

/// Capture-exclusion list (PASS-4 Area L). Enforced BEFORE content is read — filtering
/// after the fact means the plaintext already touched memory. Fails CLOSED: if the
/// frontmost app can't be identified, don't capture.
enum Exclusion {
    /// Ships as defaults, not hardcoded law — extend freely.
    static let denyBundles: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword",
        "com.bitwarden.desktop", "com.apple.Passwords", "com.apple.keychainaccess",
        "com.dashlane.Dashlane", "com.lastpass.LastPass",
        // banking / finance
        "com.moneymoney-app.retail", "com.ynab.YNAB",
    ]
    /// Third-party consent: default OFF for calls (PASS-4 Area B, 12 all-party states).
    static let callBundles: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.tinyspeck.slackmacgap", "com.apple.FaceTime",
    ]
    /// Private-browsing window titles. [Medium] — spoofable and localized; the durable
    /// fix is a browser extension signalling over a local socket (Phase 2).
    static let privateTitlePatterns = ["Private Browsing", "Incognito", "InPrivate"]

    /// High-entropy / key-shaped content that must never be indexed even if it reaches us.
    static let secretPatterns: [String] = [
        "-----BEGIN", "sk-", "AKIA", "ghp_", "xoxb-", "xoxp-", "ASIA",
    ]

    enum Verdict { case allow, deny(rule: String) }

    static func check(bundle: String?, title: String) -> Verdict {
        guard let b = bundle, !b.isEmpty else { return .deny(rule: "unidentified-app") }  // fail closed
        if denyBundles.contains(b) { return .deny(rule: "denylisted-app") }
        if callBundles.contains(b) { return .deny(rule: "call-app-default-off") }
        if privateTitlePatterns.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
            return .deny(rule: "private-browsing")
        }
        // system-wide secure text entry: a password field is focused SOMEWHERE
        if IsSecureEventInputEnabled() { return .deny(rule: "secure-input-active") }
        return .allow
    }

    /// Redact key-shaped substrings from text we do keep.
    static func redact(_ text: String) -> (String, Int) {
        var out = text, n = 0
        for pat in secretPatterns where out.contains(pat) {
            // drop the whole line containing the marker rather than a substring
            let kept = out.split(separator: "\n", omittingEmptySubsequences: false).filter {
                if $0.contains(pat) { n += 1; return false }
                return true
            }
            out = kept.joined(separator: "\n")
        }
        return (out, n)
    }
}
