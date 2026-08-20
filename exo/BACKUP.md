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

## ⚠️ This is not yet a real backup

**The repository and its password are both on the same disk as the original.** That protects
against accidental deletion, a bad migration, and ransomware (restic snapshots are immutable
once written). It protects against **nothing** that takes the disk: failure, theft, or fire.

The 3-2-1 rule needs a second medium and an offsite copy. Two options:

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
