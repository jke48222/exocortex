#!/usr/bin/env python3
"""
Encrypted iOS backup reader — sidecar for exo.

An encrypted backup is the richest single source available: it holds call history, Notes,
iOS Safari history, WhatsApp and per-app data that never touch the Mac. All of it is
AES-encrypted per-file under class keys wrapped in the BackupKeyBag, so nothing — not even
the file manifest — is readable without the backup password.

THE PASSWORD IS READ FROM STDIN, NEVER FROM ARGV. Anything in argv is visible to `ps` to
every process on the machine, and lands in shell history. exo prompts for it with echo
disabled and pipes it here; it is stored in the login Keychain and nowhere else.

Modes:
  verify   password on stdin -> {"ok":true,"device":...}   (no data emitted)
  list     enumerate interesting domains present
  extract  emit JSONL records from the sources named on the command line
"""
import sys, os, json, argparse, sqlite3, tempfile, shutil, plistlib

APPLE_EPOCH = 978307200

def log(**kw):
    print(json.dumps(kw), file=sys.stderr, flush=True)

def out(**kw):
    print(json.dumps(kw), flush=True)

# (label, domain, relativePath) for the high-value, text-bearing sources
SOURCES = {
    "calls":    ("HomeDomain", "Library/CallHistoryDB/CallHistory.storedata"),
    "notes":    ("AppDomainGroup-group.com.apple.notes", "NoteStore.sqlite"),
    "safari":   ("AppDomainGroup-group.com.apple.Safari", "Safari/History.db"),
    "whatsapp": ("AppDomainGroup-group.net.whatsapp.WhatsApp.shared", "ChatStorage.sqlite"),
    "sms":      ("HomeDomain", "Library/SMS/sms.db"),
}

def open_backup(udid, password, path):
    from iOSbackup import iOSbackup
    return iOSbackup(udid=udid, cleartextpassword=password, backuproot=path)

def fetch(b, domain, rel, tmp):
    """Decrypt one file to a temp path; returns None if absent."""
    try:
        info = b.getFileDecryptedCopy(relativePath=rel, targetName=os.path.basename(rel),
                                      targetFolder=tmp)
        return info["decryptedFilePath"] if info else None
    except Exception:
        return None

def rows(dbpath, sql):
    try:
        c = sqlite3.connect(f"file:{dbpath}?mode=ro", uri=True)
        return c.execute(sql).fetchall()
    except Exception as e:
        log(warn=f"{os.path.basename(dbpath)}: {type(e).__name__} {str(e)[:90]}")
        return []

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["verify", "list", "extract"])
    ap.add_argument("--udid", required=True)
    # PARENT of the udid folder: iOSbackup appends the udid to backuproot itself, so
    # passing the full backup path yields .../<udid>/<udid> and a confusing ENOENT that
    # looks like a wrong password.
    ap.add_argument("--path", required=True, help="parent Backup/ directory")
    ap.add_argument("--sources", default="calls,notes,safari,whatsapp")
    ap.add_argument("--limit", type=int, default=20000)
    a = ap.parse_args()

    password = sys.stdin.readline().rstrip("\n")
    if not password:
        out(ok=False, error="no password on stdin"); return

    try:
        b = open_backup(a.udid, password, a.path)
    except Exception as e:
        msg = str(e)
        hint = ("wrong backup password" if "pad" in msg.lower() or "decrypt" in msg.lower()
                else msg[:140])
        out(ok=False, error=hint); return

    if a.mode == "verify":
        dev = ""
        try:
            m = plistlib.load(open(os.path.join(a.path, a.udid, "Manifest.plist"), "rb"))
            dev = f"{m.get('Lockdown',{}).get('ProductType','?')} iOS {m.get('Lockdown',{}).get('ProductVersion','?')}"
        except Exception:
            pass
        out(ok=True, device=dev); return

    tmp = tempfile.mkdtemp(prefix="exo-iphone-")
    try:
        if a.mode == "list":
            found = {}
            for name, (dom, rel) in SOURCES.items():
                p = fetch(b, dom, rel, tmp)
                found[name] = bool(p) and os.path.getsize(p) > 0
            out(ok=True, sources=found); return

        want = [s.strip() for s in a.sources.split(",") if s.strip()]
        n = 0
        for name in want:
            if name not in SOURCES:
                continue
            dom, rel = SOURCES[name]
            p = fetch(b, dom, rel, tmp)
            if not p:
                log(warn=f"{name}: not present in this backup"); continue

            if name == "calls":
                # ZCALLRECORD: ZDATE is Apple-epoch seconds
                for zd, addr, dur, orig, ans in rows(p, """
                        SELECT ZDATE, ZADDRESS, ZDURATION, ZORIGINATED, ZANSWERED
                        FROM ZCALLRECORD ORDER BY ZDATE DESC LIMIT %d""" % a.limit):
                    if zd is None: continue
                    who = addr.decode("utf-8", "ignore") if isinstance(addr, bytes) else (addr or "?")
                    dirn = "outgoing" if orig else "incoming"
                    stat = "answered" if ans else "missed/unanswered"
                    out(kind="call", ts=int((zd + APPLE_EPOCH) * 1_000_000),
                        title=f"Call {dirn}: {who}",
                        text=f"{dirn} call with {who}, {int(dur or 0)}s, {stat}",
                        meta={"handle": who, "direction": dirn, "seconds": int(dur or 0)})
                    n += 1

            elif name == "safari":
                for url, title, vt in rows(p, """
                        SELECT i.url, coalesce(v.title,''), v.visit_time
                        FROM history_visits v JOIN history_items i ON i.id=v.history_item
                        ORDER BY v.visit_time DESC LIMIT %d""" % a.limit):
                    out(kind="safari_ios", ts=int((vt + APPLE_EPOCH) * 1_000_000),
                        title=title or url, text=url, meta={"url": url})
                    n += 1

            elif name == "notes":
                # ZICNOTEDATA.ZDATA is gzipped protobuf; the title on ZICCLOUDSYNCINGOBJECT
                # is plain text and is the useful, safely-parseable part.
                for t, cd in rows(p, """
                        SELECT ZTITLE, ZCREATIONDATE FROM ZICCLOUDSYNCINGOBJECT
                        WHERE ZTITLE IS NOT NULL AND ZTITLE<>'' ORDER BY ZCREATIONDATE DESC
                        LIMIT %d""" % a.limit):
                    ts = int(((cd or 0) + APPLE_EPOCH) * 1_000_000) if cd else 0
                    out(kind="note", ts=ts, title=t, text=t, meta={})
                    n += 1

            elif name == "whatsapp":
                for txt, ts_, frm, push in rows(p, """
                        SELECT ZTEXT, ZMESSAGEDATE, ZISFROMME, ZPUSHNAME
                        FROM ZWAMESSAGE WHERE ZTEXT IS NOT NULL AND ZTEXT<>''
                        ORDER BY ZMESSAGEDATE DESC LIMIT %d""" % a.limit):
                    out(kind="whatsapp", ts=int(((ts_ or 0) + APPLE_EPOCH) * 1_000_000),
                        title=push or "WhatsApp", text=txt,
                        meta={"from_me": bool(frm), "push_name": push or ""})
                    n += 1

        log(done=True, records=n)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

if __name__ == "__main__":
    main()
