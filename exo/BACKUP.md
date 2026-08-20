# Backup

```bash
bash tools/backup.sh          # snapshot + prune, safe to run any time
```

## What it does, and why it doesn't just copy the file

It never backs up the live database. A SQLite DB with an active WAL **is not a consistent
artifact on disk** — a copy taken mid-checkpoint captures a `db`+`wal` pair needing recovery
on restore. So `backup.sh` runs `PRAGMA wal_checkpoint(TRUNCATE)` then **`VACUUM INTO`**, which
writes a transactionally consistent, already-compacted snapshot, and backs that up instead.

(This is also why the live DB should be excluded from Time Machine: Time Machine has never
done sub-file delta transfer, so an 80 MB `.db` that changed by 4 KB is copied as 80 MB,
daily — PASS-4 Area K.3.)

Every snapshot carries a plaintext `README.txt` describing the schema, the timestamp
convention, and what `trust` means — so a restore doesn't depend on this repo still existing
to explain the file.

Retention: 7 daily, 5 weekly, 12 monthly.

## Verified 2026-08-20

Restored to a scratch directory: **79 MiB, `integrity_check` = ok, 91,384 events (matching
live), and FTS5 search worked immediately after restore** (30 hits for a test term). A backup
that has not been restored is not a backup.

## Offsite — done

```bash
bash tools/offsite.sh            # encrypted snapshot -> iCloud Drive
bash tools/offsite-restore.sh    # restore the newest one
```

**Verified 2026-08-20: restored 175 MB, `integrity_check` ok, all 100,318 events.**

Deliberately **not** a restic repo in a synced folder — restic warns against syncing a
repository, because sync clients partially write and reorder, and a repo mutated from two
directions corrupts. Instead each snapshot is a **sealed immutable file**
(`exocortex-<UTC>.db.gz.age`), written once and never modified, which reduces the sync
client's job to "copy new files, never touch old ones" — the one case every sync tool
handles perfectly. That is the same pattern PASS-4 Area K arrived at for multi-device sync.

| property | verified |
|---|---|
| iCloud stores ciphertext only | `age-encryption.org/v1` header; `orrery` not findable in the file |
| Wrong key rejected | ✅ |
| Private key on disk | **0 files** — Keychain only |
| Encryption needs no secret | only the public key is used to write a backup |

Two bugs the restore test caught, both of which would have made the backup worthless:

- a glob over the space-containing iCloud path **silently matched nothing under zsh**;
  `find` is used instead
- **`security find-generic-password -w` returns HEX**, not text, when the stored value
  contains newlines — `age` received hex and reported "unknown identity type". The restore
  script detects and decodes it

## ⚠️ The remaining gap is the key, not the data

The data is now offsite. **The decryption key is not.** It lives in this Mac's login
Keychain, so a disk failure or theft loses the key and every iCloud snapshot becomes
unreadable ciphertext.

**Export it to a password manager:**

```bash
exo offsite-key          # copies to the clipboard — never prints it
# paste into your password manager, then:
exo offsite-key-clear
```

It is **never printed**, so it cannot end up in scrollback, a shell history file, or a
terminal recording. The clipboard entry is marked `org.nspasteboard.ConcealedType`, and
exo's own clipboard capture redacts age keys — verified, not assumed.

**Do not keep it in Apple Notes.** Notes is an ingested source *and* it syncs to iCloud,
which is where the encrypted snapshots live. Storing it there means (a) the next Notes
ingest pulls your key into the database that gets shipped offsite, and (b) anyone who
compromises the Apple ID holds both the ciphertext and its key — which is exactly the
property client-side encryption existed to provide. A password manager on a different
account restores it.

PASS-4 Area K.4's 50-year scheme is Shamir 3-of-5 on metal; a password-manager copy closes
the real risk today.

For a second offsite provider (different failure domain from iCloud):

**Backblaze B2** — cheapest with genuinely free restore (PASS-4 Area K.3: $6.95/TB/mo, and
**$0 egress**, versus S3 Glacier Deep Archive's 92× restore multiplier):

```bash
# create a bucket + application key at backblaze.com, then:
export B2_ACCOUNT_ID=...  B2_ACCOUNT_KEY=...
export RESTIC_REPOSITORY="b2:your-bucket:exocortex"
export RESTIC_PASSWORD_FILE=~/.exocortex/.restic-pass
restic init
bash tools/backup.sh
```

**Or an external disk** — cheapest and needs no account:

```bash
RESTIC_REPOSITORY=/Volumes/YourDisk/exocortex-backup restic init
RESTIC_REPOSITORY=/Volumes/YourDisk/exocortex-backup bash tools/backup.sh
```

**Either way, move the password off this machine.** `~/.exocortex/.restic-pass` is a random
32-byte key stored `chmod 600` — if the disk dies, the key dies with it and the backup is
unrecoverable. Print it, or put it in a password manager. Area K.4's scheme is Shamir 3-of-5
on metal for the 50-year case; a printed copy in a drawer is a reasonable start.

## Automating it

```bash
# run daily at 04:00
cat > ~/Library/LaunchAgents/com.exocortex.backup.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.exocortex.backup</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>REPLACE_WITH_ABSOLUTE_PATH/tools/backup.sh</string>
  </array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>0</integer></dict>
</dict></plist>
PLIST
launchctl load ~/Library/LaunchAgents/com.exocortex.backup.plist
```
