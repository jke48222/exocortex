#!/usr/bin/env python3
"""
Encrypted iOS backup reader — sidecar for exo.

An encrypted backup is the richest single source available: call history, contacts,
calendar, voicemail, Notes, Safari, WhatsApp, voice-memo titles, photo metadata and Health
— most of which never touches the Mac. All of it is AES-encrypted per-file under class keys
wrapped in the BackupKeyBag, so nothing, not even the file manifest, is readable without the
backup password.

THE PASSWORD IS READ FROM STDIN, NEVER FROM ARGV. Anything in argv is visible to `ps` for
every process on the machine and lands in shell history. exo prompts with echo disabled,
pipes it here, and stores it in the login Keychain.

Paths are RESOLVED FROM THE MANIFEST, not hardcoded. Hardcoding is what made Safari look
absent: iOS 27 moved history to Library/Safari/Profiles/<UUID>/History.db, and a fixed path
silently reported "not present" rather than "I looked in the wrong place".

Modes: verify · discover · list · extract
"""
import sys, os, json, argparse, sqlite3, tempfile, shutil, plistlib, gzip, re

APPLE_EPOCH = 978307200


def log(**kw):
    print(json.dumps(kw), file=sys.stderr, flush=True)


def out(**kw):
    print(json.dumps(kw), flush=True)


# label -> (domain substring, path regex). Resolved against the real manifest.
SOURCES = {
    "calls":     ("HomeDomain", r"Library/CallHistoryDB/CallHistory\.storedata$"),
    "contacts":  ("HomeDomain", r"Library/AddressBook/AddressBook\.sqlitedb$"),
    "calendar":  ("HomeDomain", r"Library/Calendar/Calendar\.sqlitedb$"),
    "voicemail": ("HomeDomain", r"Library/Voicemail/voicemail\.db$"),
    "sms":       ("HomeDomain", r"Library/SMS/sms\.db$"),
    "notes":     ("group.com.apple.notes", r"NoteStore\.sqlite$"),
    "safari":    ("mobilesafari", r"Library/Safari/Profiles/.*/History\.db$"),
    "whatsapp":  ("net.whatsapp", r"ChatStorage\.sqlite$"),
    "voicememo": ("VoiceMemos", r"Recordings/CloudRecordings\.db$"),
    "photos":    ("CameraRollDomain", r"Media/PhotoData/Photos\.sqlite$"),
    # Health is deliberately NOT in the default set. It is medical data; exo files it under
    # the `sensitive` retention class (30 days) and it must be asked for by name.
    "health":    ("HealthDomain", r"Health/healthdb_secure\.sqlite$"),
}
DEFAULT_SOURCES = "calls,contacts,calendar,voicemail,notes,safari,whatsapp,voicememo"


def open_backup(udid, password, path):
    from iOSbackup import iOSbackup
    return iOSbackup(udid=udid, cleartextpassword=password, backuproot=path)


def manifest(b):
    try:
        return b.getBackupFilesList()
    except Exception as e:
        log(warn=f"manifest: {e}")
        return []


def resolve_all(files, label):
    """Every manifest entry matching this source, not just the first.

    Safari on iOS 27 keeps one History.db per profile and several are empty; taking the
    first match reported 0 rows and looked like an extraction failure rather than a
    wrong-file choice."""
    dom_sub, pat = SOURCES[label]
    rx = re.compile(pat, re.I)
    hits = []
    for f in files:
        rel, dom = f.get("relativePath") or "", f.get("domain") or ""
        if dom_sub.lower() in dom.lower() and rx.search(rel):
            hits.append((dom, rel))
    return hits


def resolve(files, label):
    h = resolve_all(files, label)
    return h[0] if h else (None, None)


def fetch(b, rel, tmp, tag):
    try:
        info = b.getFileDecryptedCopy(relativePath=rel, targetName=f"{tag}.db",
                                      targetFolder=tmp)
        return info["decryptedFilePath"] if info else None
    except Exception as e:
        log(warn=f"{tag}: decrypt failed: {str(e)[:90]}")
        return None


def rows(dbpath, sql):
    try:
        c = sqlite3.connect(f"file:{dbpath}?mode=ro", uri=True)
        c.text_factory = lambda b: b.decode("utf-8", "replace")
        return c.execute(sql).fetchall()
    except Exception as e:
        log(warn=f"{os.path.basename(dbpath)}: {type(e).__name__} {str(e)[:90]}")
        return []


def apple_us(v):
    """Apple-epoch seconds (or nanoseconds) -> unix microseconds."""
    if not v:
        return 0
    v = float(v)
    if v > 1e17:          # nanoseconds
        v /= 1e9
    return int((v + APPLE_EPOCH) * 1_000_000)


def note_body(blob):
    """ZICNOTEDATA.ZDATA is gzipped protobuf. The note text is stored as length-prefixed
    UTF-8 inside; a full protobuf parse is unnecessary to recover it readably."""
    try:
        raw = gzip.decompress(blob)
    except Exception:
        return None
    # strip protobuf framing bytes, keep printable runs
    text = raw.decode("utf-8", "ignore")
    text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]+", "\n", text)
    lines = [l.strip() for l in text.split("\n")]
    keep = [l for l in lines if len(l) >= 3 and sum(c.isalnum() or c.isspace() for c in l) / len(l) > 0.7]
    body = "\n".join(keep).strip()
    return body or None


def extract(b, files, label, tmp, limit, emit):
    candidates = resolve_all(files, label)
    if not candidates:
        log(warn=f"{label}: not present in this backup")
        return 0
    # Try every candidate and keep the first that actually yields rows. A source can have
    # several files (Safari profiles, Reminders stores) of which most are empty.
    total = 0
    for idx, (dom, rel) in enumerate(candidates[:6]):
        p = fetch(b, rel, tmp, f"{label}{idx}")
        if not p:
            continue
        got = _extract_one(label, p, limit, emit)
        total += got
        if got:
            break
    if not total and len(candidates) > 1:
        log(warn=f"{label}: {len(candidates)} candidate files, none yielded rows")
    return total


def _extract_one(label, p, limit, emit):
    n = 0

    if label == "calls":
        for zd, addr, dur, orig, ans in rows(p, f"""
                SELECT ZDATE, ZADDRESS, ZDURATION, ZORIGINATED, ZANSWERED
                FROM ZCALLRECORD ORDER BY ZDATE DESC LIMIT {limit}"""):
            who = addr or "?"
            d = "outgoing" if orig else "incoming"
            emit(kind="call", ts=apple_us(zd), mine=bool(orig),
                 title=f"Call {d}: {who}",
                 text=f"{d} call with {who}, {int(dur or 0)}s, "
                      f"{'answered' if ans else 'not answered'}",
                 meta={"handle": who, "direction": d, "seconds": int(dur or 0)})
            n += 1

    elif label == "contacts":
        for first, last, org, note in rows(p, f"""
                SELECT First, Last, Organization, Note FROM ABPerson LIMIT {limit}"""):
            name = " ".join(x for x in (first, last) if x).strip()
            if not name and not org:
                continue
            body = " · ".join(x for x in (name, org, note) if x)
            emit(kind="contact", ts=0, mine=True, title=name or org, text=body,
                 meta={"organization": org or ""})
            n += 1

    elif label == "calendar":
        for title, notes, start, loc in rows(p, f"""
                SELECT summary, description, start_date, NULL
                FROM CalendarItem ORDER BY start_date DESC LIMIT {limit}"""):
            if not title:
                continue
            emit(kind="calendar", ts=apple_us(start), mine=True, title=title,
                 text=" · ".join(x for x in (title, notes) if x), meta={})
            n += 1

    elif label == "voicemail":
        for date, sender, dur in rows(p, f"""
                SELECT date, sender, duration FROM voicemail
                ORDER BY date DESC LIMIT {limit}"""):
            emit(kind="voicemail", ts=int((date or 0) * 1_000_000), mine=False,
                 title=f"Voicemail from {sender or '?'}",
                 text=f"voicemail from {sender or 'unknown'}, {int(dur or 0)}s",
                 meta={"handle": sender or ""})
            n += 1

    elif label == "notes":
        for t, cd, blob in rows(p, f"""
                SELECT o.ZTITLE, o.ZCREATIONDATE, d.ZDATA
                FROM ZICCLOUDSYNCINGOBJECT o
                LEFT JOIN ZICNOTEDATA d ON d.ZNOTE = o.Z_PK
                WHERE o.ZTITLE IS NOT NULL AND o.ZTITLE <> ''
                ORDER BY o.ZCREATIONDATE DESC LIMIT {limit}"""):
            body = note_body(blob) if blob else None
            emit(kind="note", ts=apple_us(cd), mine=True, title=t,
                 text=(body or t), meta={"has_body": bool(body)})
            n += 1

    elif label == "safari":
        for url, title, vt in rows(p, f"""
                SELECT i.url, coalesce(v.title,''), v.visit_time
                FROM history_visits v JOIN history_items i ON i.id = v.history_item
                ORDER BY v.visit_time DESC LIMIT {limit}"""):
            emit(kind="safari_ios", ts=apple_us(vt), mine=False,
                 title=title or url, text=url, meta={"url": url})
            n += 1

    elif label == "whatsapp":
        for txt, ts_, frm, push in rows(p, f"""
                SELECT ZTEXT, ZMESSAGEDATE, ZISFROMME, ZPUSHNAME
                FROM ZWAMESSAGE WHERE ZTEXT IS NOT NULL AND ZTEXT <> ''
                ORDER BY ZMESSAGEDATE DESC LIMIT {limit}"""):
            emit(kind="whatsapp", ts=apple_us(ts_), mine=bool(frm),
                 title=push or "WhatsApp", text=txt,
                 meta={"push_name": push or ""})
            n += 1

    elif label == "voicememo":
        for title, date, dur in rows(p, f"""
                SELECT ZENCRYPTEDTITLE, ZDATE, ZDURATION
                FROM ZCLOUDRECORDING ORDER BY ZDATE DESC LIMIT {limit}"""):
            if not title:
                continue
            emit(kind="voicememo", ts=apple_us(date), mine=True, title=title,
                 text=f"voice memo: {title} ({int(dur or 0)}s)", meta={})
            n += 1

    elif label == "photos":
        # metadata only — captions and place names. Pixels stay out: the image tier is a
        # 21-day cache by design and a 47 GB backup would blow the storage budget.
        for cap, dt, place in rows(p, f"""
                SELECT a.ZTITLE, a.ZDATECREATED, NULL
                FROM ZASSET a WHERE a.ZTITLE IS NOT NULL AND a.ZTITLE <> ''
                ORDER BY a.ZDATECREATED DESC LIMIT {limit}"""):
            emit(kind="photo", ts=apple_us(dt), mine=True, title=cap,
                 text=f"photo: {cap}", meta={})
            n += 1

    elif label == "health":
        for typ, val, sd in rows(p, f"""
                SELECT data_type, quantity, start_date FROM samples
                JOIN quantity_samples USING (data_id)
                ORDER BY start_date DESC LIMIT {limit}"""):
            emit(kind="health", ts=apple_us(sd), mine=True, sensitive=True,
                 title=f"health sample {typ}", text=f"health type={typ} value={val}",
                 meta={"data_type": str(typ)})
            n += 1

    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["verify", "list", "extract", "discover", "schema"])
    ap.add_argument("--udid", required=True)
    ap.add_argument("--path", required=True, help="parent Backup/ directory")
    ap.add_argument("--sources", default=DEFAULT_SOURCES)
    ap.add_argument("--limit", type=int, default=20000)
    ap.add_argument("--grep", default="")
    a = ap.parse_args()

    password = sys.stdin.readline().rstrip("\n")
    if not password:
        out(ok=False, error="no password on stdin"); return

    try:
        b = open_backup(a.udid, password, a.path)
    except Exception as e:
        msg = str(e)
        hint = ("wrong backup password"
                if "pad" in msg.lower() or "decrypt" in msg.lower() else msg[:140])
        out(ok=False, error=hint); return

    if a.mode == "verify":
        dev = ""
        try:
            m = plistlib.load(open(os.path.join(a.path, a.udid, "Manifest.plist"), "rb"))
            lk = m.get("Lockdown", {})
            dev = f"{lk.get('ProductType','?')} iOS {lk.get('ProductVersion','?')}"
        except Exception:
            pass
        out(ok=True, device=dev); return

    files = manifest(b)

    if a.mode == "discover":
        needles = [n.strip().lower() for n in (a.grep or "").split(",") if n.strip()]
        found = []
        for f in files:
            rel, dom = f.get("relativePath") or "", f.get("domain") or ""
            if not rel or not rel.lower().endswith((".sqlite", ".sqlitedb", ".db", ".storedata")):
                continue
            if needles and not any(n in rel.lower() or n in dom.lower() for n in needles):
                continue
            found.append({"domain": dom, "path": rel})
        out(ok=True, total=len(files), databases=len(found),
            items=found if needles else found[:400])
        return

    if a.mode == "schema":
        # Dump table names and row counts for a source, so "0 rows" can be told apart
        # from "wrong table names" without guessing.
        tmp = tempfile.mkdtemp(prefix="exo-schema-")
        try:
            for label in [s.strip() for s in a.sources.split(",") if s.strip()]:
                if label not in SOURCES:
                    continue
                for idx, (dom, rel) in enumerate(resolve_all(files, label)[:6]):
                    p = fetch(b, rel, tmp, f"{label}{idx}")
                    if not p:
                        continue
                    tabs = rows(p, "SELECT name FROM sqlite_master WHERE type='table'")
                    info = {}
                    for (t,) in tabs:
                        try:
                            info[t] = rows(p, f"SELECT count(*) FROM '{t}'")[0][0]
                        except Exception:
                            info[t] = -1
                    out(label=label, file=rel, bytes=os.path.getsize(p),
                        tables={k: v for k, v in sorted(info.items(), key=lambda x: -x[1])[:14]})
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        return

    if a.mode == "list":
        avail = {}
        for label in SOURCES:
            dom, rel = resolve(files, label)
            avail[label] = rel or False
        out(ok=True, sources=avail); return

    tmp = tempfile.mkdtemp(prefix="exo-iphone-")
    total = 0
    try:
        def emit(**kw):
            out(**kw)
        for label in [s.strip() for s in a.sources.split(",") if s.strip()]:
            if label not in SOURCES:
                log(warn=f"unknown source {label}"); continue
            got = extract(b, files, label, tmp, a.limit, emit)
            log(source=label, records=got)
            total += got
        log(done=True, records=total)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
