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
    ///
    /// `AGE-SECRET-KEY-` is first for a reason. The offsite backup is encrypted to an age
    /// key, and a user who sensibly copies that key into Notes creates a loop: Notes is an
    /// ingested source, so the key lands in the database, and the database is what gets
    /// encrypted and shipped offsite — putting the key to the backup inside the backup.
    /// Caught before it happened, but only because someone went looking.
    static let secretPatterns: [String] = [
        "AGE-SECRET-KEY-", "AGE-PLUGIN-",
        "-----BEGIN",                       // PEM: RSA/OPENSSH/PGP private keys, certs
        "sk-", "sk_live_", "rk_live_",      // OpenAI, Stripe
        "AKIA", "ASIA",                     // AWS access key ids
        "ghp_", "gho_", "ghu_", "ghs_", "github_pat_",
        "glpat-",                           // GitLab
        "xoxb-", "xoxp-", "xoxa-", "xoxr-", // Slack
        "AIza", "ya29.",                    // Google API key / OAuth token
        "hf_", "npm_", "dop_v1_", "shpat_", "SG.",
        "aws_secret_access_key", "BEGIN PGP PRIVATE",
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

    /// Precise credential patterns: a prefix AND the high-entropy body that follows it.
    ///
    /// A bare-substring list is uselessly imprecise. `ASIA` matches the word "Asia",
    /// `sk-` matches "task-", `SG.` matches any sentence ending in an abbreviation, and
    /// `hf_` matched 3,737 events across calendars and WhatsApp. Scanning the real store
    /// with substrings flagged 4,861 events, essentially all false positives — deleting
    /// them would have destroyed real data to remove secrets that were never there.
    /// Each pattern below requires the documented shape and length of the actual token.
    static let secretRegexes: [(String, String)] = [
        ("age private key",   #"AGE-SECRET-KEY-1[0-9A-Z]{50,}"#),
        ("age plugin key",    #"AGE-PLUGIN-[A-Z0-9-]{20,}"#),
        ("PEM private key",   #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("AWS access key",    #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("GitHub token",      #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b"#),
        ("GitHub PAT",        #"\bgithub_pat_[A-Za-z0-9_]{50,}"#),
        ("GitLab token",      #"\bglpat-[A-Za-z0-9_\-]{20,}"#),
        ("OpenAI key",        #"\bsk-(?:proj-)?[A-Za-z0-9_\-]{32,}"#),
        ("Stripe key",        #"\b(?:sk|rk)_live_[A-Za-z0-9]{24,}"#),
        ("Google API key",    #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        ("Google OAuth",      #"\bya29\.[0-9A-Za-z_\-]{30,}"#),
        ("Slack token",       #"\bxox[baprs]-[0-9A-Za-z\-]{20,}"#),
        ("HuggingFace token", #"\bhf_[A-Za-z0-9]{34}\b"#),
        ("npm token",         #"\bnpm_[A-Za-z0-9]{36}\b"#),
        ("SendGrid key",      #"\bSG\.[A-Za-z0-9_\-]{22}\.[A-Za-z0-9_\-]{43}\b"#),
        ("DigitalOcean",      #"\bdop_v1_[a-f0-9]{64}\b"#),
        ("Shopify token",     #"\bshpat_[a-fA-F0-9]{32}\b"#),
        ("private key assign",#"(?i)aws_secret_access_key\s*[=:]\s*\S{20,}"#),
    ]

    private static let compiled: [(String, NSRegularExpression)] = secretRegexes.compactMap {
        guard let r = try? NSRegularExpression(pattern: $0.1) else { return nil }
        return ($0.0, r)
    }

    /// Returns the labels of every credential type found in `text`.
    static func findSecrets(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return compiled.compactMap { label, rx in
            rx.firstMatch(in: text, range: range) != nil ? label : nil
        }
    }

    /// Drop whole lines containing a credential, rather than the whole record: a single
    /// key pasted into a long note should not cost the note.
    static func redact(_ text: String) -> (String, Int) {
        guard !findSecrets(text).isEmpty else { return (text, 0) }
        var n = 0
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let s = String(line)
            if !findSecrets(s).isEmpty { n += 1; return false }
            return true
        }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), n)
    }
}
