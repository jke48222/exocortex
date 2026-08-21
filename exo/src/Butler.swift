import Foundation
import SQLite3
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The **Butler** daemon — who is this person, and what is outstanding with them.
///
/// Area F argues this is a real gap rather than a crowded category. The pre-meeting briefing
/// space — Oliv, Gong, Clari, Chorus, Avoma, Sybill, Capsule — is **entirely CRM-scoped sales
/// tooling**: it sees only the work-relationship slice, has **no episodic substrate**
/// (*they summarize; they don't remember*), and optimizes for pipeline metrics. A Butler on a
/// consolidated life log can say *"you promised her the doc three weeks ago and never sent
/// it"*, which is unreachable from CRM data. That sentence is the whole thesis, and it needs
/// the Ledger daemon underneath it — which is why this is built after commitments and not
/// before.
///
/// ## The trigger does not exist in this corpus, and that is a finding rather than a bug
///
/// Area F specifies **calendar T−30**: fire half an hour before a meeting, brief on whoever
/// is attending. Measured here:
///
///   * **0 of 1,334 calendar events carry any attendee data** — `meta` is `{}` on every row.
///   * Every upcoming entry is a public holiday: Labor Day, Rosh Hashanah, Yom Kippur,
///     Columbus Day, Halloween. It is a **subscribed holiday feed**, not a personal calendar.
///   * **3 of 686 contacts have a phone number and 1 has an email** — the iPhone ingest read
///     `ABPerson` name fields and never followed `ABMultiValue`, so the name↔handle join a
///     calendar trigger would need does not exist either.
///
/// So the scheduler is unreachable and the *dossier* — the part that carries the value — is
/// not. This runs on demand against a person, and the T−30 wrapper is a small amount of work
/// waiting on data the store does not have. Saying that plainly is better than shipping a
/// timer that silently never fires.
///
/// ## The dossier problem
///
/// Area F's named failure mode: *cap at 5 bullets, lead with unresolved commitments both
/// directions.* A briefing that prints everything known about a person is not a briefing, it
/// is a file, and the reader stops opening it. So `maxBullets` is a hard cap and the ordering
/// below is a priority, not a layout: what you owe comes first because it is the thing people
/// actually forget, and volume statistics come last because they are the thing that is always
/// available and rarely matters.
enum Butler {

    static let maxBullets = 5

    struct Person {
        let handle: String          // the identifier that actually appears on events
        let display: String         // a name if one could be resolved, else the handle
        let messages: Int
        let first, last: String     // ISO days
        var daysSinceLast: Int
    }

    /// Resolve a query to somebody the store has actually seen.
    ///
    /// Handles first, because they are what events are keyed by and an exact match is never
    /// ambiguous. Names are tried second and are weak *here* for a measured reason — the
    /// contact rows carry names with no numbers — so a name only resolves when it appears in
    /// a conversation title, which happens for group chats and mail.
    static func resolve(_ s: Store, _ query: String) -> [Person] {
        let q = Ledger.esc(query)
        let rows = s.rows("""
            SELECT e.title, count(*) n,
                   min(strftime('%Y-%m-%d', e.ts/1000000,'unixepoch')),
                   max(strftime('%Y-%m-%d', e.ts/1000000,'unixepoch')),
                   max(e.ts)
            FROM events e
            WHERE e.title IS NOT NULL AND e.title <> '' AND e.title <> '(unknown)'
              AND e.source IN ('imessage','iphone.whatsapp','gmail','imap','iphone.call')
              AND (e.title = '\(q)' OR lower(e.title) LIKE lower('%\(q)%'))
              AND e.ts BETWEEN \(Connect.tsFloor) AND \(Connect.tsCeil)
            GROUP BY e.title ORDER BY n DESC LIMIT 8;
            """)
        return rows.compactMap { r in
            guard let lastTs = Int64(r[4]) else { return nil }
            return Person(handle: r[0], display: r[0], messages: Int(r[1]) ?? 0,
                          first: r[2], last: r[3],
                          daysSinceLast: Int((nowMicros() - lastTs) / 86_400_000_000))
        }
    }

    struct Bullet { let priority: Int, text: String }

    /// The dossier, in priority order, capped.
    ///
    /// Every bullet is drawn from a row that exists. Nothing here is generated prose except
    /// the optional last-topic line, which is a description of messages the model is shown —
    /// the one job §10 measured it doing reliably.
    static func brief(_ s: Store, person: Person) -> [String] {
        var bullets: [Bullet] = []
        let h = Ledger.esc(person.handle)

        // 1 and 2 — unresolved commitments, mine first. This is the ordering Area F asks for
        // and the reason the daemon waited on the Ledger daemon to exist.
        for c in Promise.open(s, limit: 5).filter({ $0.who == person.handle }) {
            let age = c.ageDays
            if c.direction == "mine" {
                bullets.append(Bullet(priority: 0,
                    text: "You owe them: \(c.action)\(c.due.isEmpty ? "" : " (\(c.due))") — promised \(age) days ago, still open."))
            } else {
                bullets.append(Bullet(priority: 1,
                    text: "They owe you: \(c.action)\(c.due.isEmpty ? "" : " (\(c.due))") — said \(age) days ago."))
            }
        }

        // 3 — a cadence break. Only worth a bullet when it is unusual for THIS relationship:
        // "we last spoke 40 days ago" means nothing without knowing the normal gap.
        let spanDays = max(1, daysBetween(person.first, person.last))
        let typicalGap = Double(spanDays) / Double(max(1, person.messages)) * 30
        if person.daysSinceLast > 21 && Double(person.daysSinceLast) > typicalGap * 3 {
            bullets.append(Bullet(priority: 2,
                text: "Quiet for \(person.daysSinceLast) days — long for you two."))
        }

        // 4 — what was last actually said, verbatim rather than characterized.
        // `imessage.reaction` is excluded, and that exclusion is load-bearing. Tapbacks
        // carry `is_from_me=1` because you sent the reaction, while the words quoted inside
        // them are the other person's — an earlier phase found 10,927 of them mis-stored as
        // things the principal wrote. Without this the most recent "message" from somebody is
        // routinely `Laughed at "is this thing on?"`, which is you, quoting them, about
        // nothing.
        //
        // A bare link is excluded for a duller reason: "They last said:
        // https://www.tiktok.com/t/ZTDDwda32/" is true and tells the reader nothing.
        if let lastMsg = s.rows("""
            SELECT substr(replace(coalesce(text,''), char(10), ' '),1,150), e.trust
            FROM events e WHERE e.title='\(h)' AND length(coalesce(e.text,'')) > 15
              AND e.source NOT IN ('imessage.reaction')
              AND e.text NOT LIKE 'http%'
              AND e.text GLOB '*[a-zA-Z]*[a-zA-Z]*[a-zA-Z]*[a-zA-Z]*'
              AND e.ts BETWEEN \(Connect.tsFloor) AND \(Connect.tsCeil)
            ORDER BY e.ts DESC LIMIT 1;
            """).first, !lastMsg[0].isEmpty {
            let who = lastMsg[1] == "self" ? "You" : "They"
            bullets.append(Bullet(priority: 3, text: "\(who) last said: \"\(lastMsg[0])\""))
        }

        // 5 — longevity, last because it is always available and rarely the point.
        bullets.append(Bullet(priority: 4,
            text: "\(fmtInt(person.messages)) messages, \(person.first) to \(person.last)."))

        return bullets.sorted { $0.priority < $1.priority }.prefix(maxBullets).map(\.text)
    }

    static func daysBetween(_ a: String, _ b: String) -> Int {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        guard let x = f.date(from: a), let y = f.date(from: b) else { return 1 }
        return max(1, Int(y.timeIntervalSince(x) / 86_400))
    }

    static func fmtInt(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
