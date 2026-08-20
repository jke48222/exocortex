#!/usr/bin/env python3
"""Read-only view of the exocortex store, plus the egress controls the bus needs.

Separated from server.py so the transport layer holds no SQL and the security layer holds
no protocol. Everything here is READ-ONLY on the events database: the bus is Tier 2 in the
PASS-4 Area L architecture, which has no write path and no network by construction, so
neither tier alone completes the lethal trifecta.
"""
import os, re, sqlite3, json, time, hashlib

DB = os.environ.get("EXO_DB", os.path.expanduser("~/.exocortex/phase1.db"))
AUDIT = os.environ.get("EXO_AUDIT", os.path.expanduser("~/.exocortex/audit.db"))

TRUST_ORDER = {"self": 0, "verified": 1, "third_party": 2, "untrusted": 3}


def connect():
    # immutable=1: the capture daemon may be mid-write, and the bus must never block it
    # nor read a torn page.
    return sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)


# ── egress sanitisation ───────────────────────────────────────────────────────────
# EchoLeak (CVE-2025-32711) exfiltrated M365 Copilot data zero-click via markdown image
# rendering, using REFERENCE-STYLE links specifically to dodge redaction. Anything that
# can cause a client to fetch a URL is stripped before memory leaves this process.
_IMG = re.compile(r"!\[[^\]]*\]\([^)]*\)")
_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
_REFLINK = re.compile(r"\[([^\]]*)\]\[[^\]]*\]")
_REFDEF = re.compile(r"^\s*\[[^\]]+\]:\s*\S+.*$", re.M)
_AUTOLINK = re.compile(r"<(https?://[^>]+)>")
_BARE = re.compile(r"https?://\S+")
_DATAURI = re.compile(r"data:[^\s;,]+;[^\s,]*,\S+", re.I)
_HTML = re.compile(r"<[^>]+>")
# Unicode tag block + zero-width + bidi: ASCII smuggling channels
_INVIS = re.compile(r"[\U000E0000-\U000E007F​-‏‪-‮⁦-⁩﻿]")


def sanitize(text):
    """Returns (clean_text, n_redactions)."""
    if not text:
        return "", 0
    n = 0
    for pat, repl in ((_IMG, "[image removed]"), (_REFDEF, ""), (_DATAURI, "[data-uri removed]")):
        text, k = pat.subn(repl, text)
        n += k
    text, k = _LINK.subn(r"\1", text); n += k
    text, k = _REFLINK.subn(r"\1", text); n += k
    text, k = _AUTOLINK.subn(r"[link removed]", text); n += k
    text, k = _BARE.subn("[link removed]", text); n += k
    text, k = _HTML.subn("", text); n += k
    text, k = _INVIS.subn("", text); n += k
    return text.strip(), n


def trust_allowed(min_trust):
    rank = TRUST_ORDER.get(min_trust, 1)
    return [t for t, r in TRUST_ORDER.items() if r <= rank]


def _fts_query(q):
    """FTS5 needs bare terms; user text may contain operators that raise."""
    terms = [t for t in re.findall(r"[A-Za-z0-9_]+", q) if t]
    return " OR ".join(terms) if terms else None


def recall(query, k=8, since=None, until=None, kinds=None, min_trust="verified", limit_chars=600):
    m = _fts_query(query)
    if not m:
        return []
    allowed = trust_allowed(min_trust)
    sql = f"""
      SELECT e.seq, e.ts, e.source, e.source_kind, e.trust, e.app, e.title,
             snippet(events_fts, 2, '', '', '…', 24) AS snip, e.text
      FROM events_fts JOIN events e ON e.seq = events_fts.rowid
      WHERE events_fts MATCH ? AND e.trust IN ({','.join('?' * len(allowed))})
    """
    args = [m] + allowed
    if since: sql += " AND e.ts >= ?"; args.append(int(since))
    if until: sql += " AND e.ts <= ?"; args.append(int(until))
    if kinds: sql += f" AND e.source IN ({','.join('?' * len(kinds))})"; args += list(kinds)
    sql += " ORDER BY bm25(events_fts) LIMIT ?"
    args.append(min(int(k), 50))                      # hard cap, contract §2
    out = []
    with connect() as c:
        for r in c.execute(sql, args):
            seq, ts, source, kind, trust, app, title, snip, full = r
            body, red = sanitize(snip or full or "")
            body = re.sub(r"\s+", " ", body).strip()
            # A 36-char oneline is what the Oracle Phone's split-flap board renders, so
            # it has to be readable prose. Many titles are directory slugs
            # ("-Users-jalenedusei-fun-project"), which are useless there — fall back to
            # the body text when the title looks like a path.
            t_ = (title or "").replace("\n", " ").strip()
            if not t_ or t_.startswith("-") or t_.count("-") >= 3 or "/" in t_:
                t_ = (body or "").replace("\n", " ").strip()
            one, _ = sanitize(t_)
            out.append({
                "id": f"ev_{seq}", "text": body[:limit_chars], "kind": "event",
                "occurred_at": iso(ts), "recorded_at": iso(ts),
                "trust": trust, "confidence": 1.0, "source_kind": kind,
                "episode_id": f"{source}:{seq}",
                "oneline": one[:36],                  # Oracle Phone's 36-char split-flap
                "redactions": red,
            })
    return out


def timeline(start, end, granularity="day", min_trust="verified"):
    fmt = {"day": "%Y-%m-%d", "week": "%Y-W%W", "month": "%Y-%m"}.get(granularity, "%Y-%m-%d")
    allowed = trust_allowed(min_trust)
    sql = f"""
      SELECT strftime('{fmt}', ts/1000000, 'unixepoch') AS period, source, count(*)
      FROM events WHERE ts >= ? AND ts <= ? AND trust IN ({','.join('?' * len(allowed))})
      GROUP BY period, source ORDER BY period
    """
    buckets = {}
    with connect() as c:
        for period, source, n in c.execute(sql, [int(start), int(end)] + allowed):
            b = buckets.setdefault(period, {"period": period, "count": 0, "items": []})
            b["count"] += n
            b["items"].append({"source": source, "count": n})
    return list(buckets.values())


def provenance(event_id):
    seq = int(str(event_id).replace("ev_", ""))
    with connect() as c:
        r = c.execute("""SELECT source, source_kind, ts, trust, app, bundle_id, meta
                         FROM events WHERE seq=?""", (seq,)).fetchone()
    if not r:
        return None
    source, kind, ts, trust, app, bundle, meta = r
    return {"episode_id": f"{source}:{seq}", "source_kind": kind, "captured_at": iso(ts),
            "capture_path": f"{app or ''} ({bundle or ''})".strip(), "trust": trust,
            "derived_from": [], "derived_to": []}


def beliefs_at(subject, as_of, include_superseded=False):
    """Point-in-time belief query over the bitemporal ledger.

    `sys_to IS NULL` selects the system's CURRENT record; the belief interval predicate
    selects what was held at `as_of`. Both are needed: the first answers "what does the
    system now say", the second "what did I believe then"."""
    sysc = "" if include_superseded else "AND b.sys_to IS NULL"
    sql = f"""
      SELECT c.norm_text, c.polarity, b.belief_from, b.belief_to, b.valid_from, b.valid_to,
             b.sys_from, b.confidence, b.confidence_src, b.change_reason, b.supersedes,
             (SELECT count(*) FROM belief_evidence e WHERE e.belief_id=b.belief_id)
      FROM belief b JOIN claim c ON c.claim_id=b.claim_id
      WHERE lower(c.subject) LIKE lower(?) {sysc}
        AND b.belief_from <= ? AND (b.belief_to IS NULL OR b.belief_to > ?)
      ORDER BY b.belief_from DESC LIMIT 50
    """
    out = []
    with connect() as c:
        try:
            rows = c.execute(sql, (f"%{subject}%", as_of, as_of)).fetchall()
        except sqlite3.OperationalError:
            return None                      # ledger tables not created yet
        for r in rows:
            text, pol, bf, bt, vf, vt, sf, conf, csrc, reason, sup, ev = r
            body, _ = sanitize(text)
            out.append({"text": body, "polarity": pol,
                        "belief_from": bf, "belief_to": bt,
                        "valid_from": vf, "valid_to": vt, "learned_at": sf,
                        "confidence": conf, "confidence_src": csrc,
                        "change_reason": reason, "superseded_by": sup,
                        "evidence_count": ev, "trust": "self"})
    return out


def belief_history(subject):
    sql = """
      SELECT c.norm_text, c.polarity, b.belief_from, b.belief_to, b.change_reason, b.confidence
      FROM belief b JOIN claim c ON c.claim_id=b.claim_id
      WHERE lower(c.subject) LIKE lower(?) AND b.sys_to IS NULL
      ORDER BY b.belief_from LIMIT 100
    """
    with connect() as c:
        try:
            rows = c.execute(sql, (f"%{subject}%",)).fetchall()
        except sqlite3.OperationalError:
            return None
    return [{"text": sanitize(r[0])[0], "polarity": r[1], "belief_from": r[2],
             "belief_to": r[3], "change_reason": r[4], "confidence": r[5]} for r in rows]


def stats():
    with connect() as c:
        n = c.execute("SELECT count(*) FROM events").fetchone()[0]
        by = dict(c.execute("SELECT trust, count(*) FROM events GROUP BY trust").fetchall())
        span = c.execute("SELECT min(ts), max(ts) FROM events WHERE ts>0").fetchone()
    return {"events": n, "by_trust": by,
            "span": [iso(span[0]), iso(span[1])] if span and span[0] else None}


def iso(micros):
    if not micros:
        return None
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(micros / 1_000_000))


# ── audit: append-only, hash-chained, in its OWN database ────────────────────────
# Never exposed as a tool. Handing an attacker the read log would tell them which
# canaries exist and what has already been exfiltrated (PASS-4 Area L).
def audit(purpose, tool, args, returned, redactions):
    os.makedirs(os.path.dirname(AUDIT), exist_ok=True)
    with sqlite3.connect(AUDIT) as c:
        c.execute("""CREATE TABLE IF NOT EXISTS log(
            id INTEGER PRIMARY KEY, at TEXT, purpose TEXT, tool TEXT, args TEXT,
            returned INTEGER, redactions INTEGER, prev_hash TEXT, hash TEXT)""")
        prev = c.execute("SELECT hash FROM log ORDER BY id DESC LIMIT 1").fetchone()
        prev = prev[0] if prev else "genesis"
        at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        payload = json.dumps([at, purpose, tool, args, returned, redactions, prev],
                             sort_keys=True)
        h = hashlib.blake2b(payload.encode(), digest_size=16).hexdigest()
        c.execute("INSERT INTO log(at,purpose,tool,args,returned,redactions,prev_hash,hash)"
                  " VALUES(?,?,?,?,?,?,?,?)",
                  (at, purpose, tool, json.dumps(args)[:400], returned, redactions, prev, h))
