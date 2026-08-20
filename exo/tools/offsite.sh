#!/bin/bash
# Offsite backup: one sealed, client-side-encrypted file per snapshot, into iCloud Drive.
#
# Deliberately NOT a restic repo in a synced folder. restic warns against syncing a
# repository with a file-sync tool, because sync clients partially-write and reorder, and a
# repo mutated from two directions corrupts. Instead this follows the pattern PASS-4 Area K
# arrived at for exactly this problem: **sealed immutable segments**. Every snapshot is
# written once, under a unique dated name, and never modified again — which reduces the
# sync tool's job to "copy new files, never change old ones", the one case every sync tool
# handles perfectly.
#
# Encryption is client-side with `age`, so iCloud stores ciphertext and Apple holds nothing
# readable. Only the PUBLIC key is needed to write a backup, so routine runs never touch the
# secret — the private key stays in the login Keychain (Area K.4: "encryption needs no
# Secure Enclave, only decryption does").
set -euo pipefail

DB="${EXO_DB:-$HOME/.exocortex/phase1.db}"
PUB_FILE="${EXO_OFFSITE_PUB:-$HOME/.exocortex/offsite.pub}"
DEST="${EXO_OFFSITE_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Exocortex-Backup}"
KEEP="${EXO_OFFSITE_KEEP:-14}"

[ -f "$PUB_FILE" ] || { echo "no public key at $PUB_FILE — run exo offsite-init"; exit 1; }
PUB="$(cat "$PUB_FILE")"
mkdir -p "$DEST"

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
STAMP="$(date -u +%Y-%m-%dT%H%M%SZ)"
OUT="$DEST/exocortex-$STAMP.db.gz.age"

# Never copy the live database: a SQLite file with an active WAL is not a consistent
# on-disk artifact. VACUUM INTO produces a transactionally consistent, compacted snapshot.
sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
sqlite3 "$DB" "VACUUM INTO '$STAGE/exocortex.db'"

gzip -6 -c "$STAGE/exocortex.db" | age -r "$PUB" -o "$OUT"

# A plaintext companion so a future reader knows what the .age file is without needing this
# repo to explain it. Contains no content — only shape.
cat > "$DEST/README.txt" <<TXT
Exocortex offsite backups.

Each exocortex-<UTC timestamp>.db.gz.age is one complete, self-contained snapshot:
a SQLite database, gzipped, then encrypted with age (https://age-encryption.org)
to a single recipient. Files are written once and never modified.

To restore:
    age -d -i <your-private-key-file> exocortex-<stamp>.db.gz.age | gunzip > exocortex.db
    sqlite3 exocortex.db "PRAGMA integrity_check;"

The private key lives in the macOS login Keychain under service "exocortex.offsite".
Export it with:
    security find-generic-password -s exocortex.offsite -a age_identity -w

IF YOU LOSE THAT KEY THESE FILES ARE UNREADABLE. Keep a copy somewhere that is not
this Mac.

Latest snapshot written: $STAMP
TXT

# Prune oldest, keeping the most recent N. Immutable files make this the only mutation.
# `find`, not a glob: the iCloud path contains spaces, and a quoted-variable + glob
# concatenation silently matches nothing under zsh — which made the restore path look
# broken when the file was there all along.
find "$DEST" -maxdepth 1 -name 'exocortex-*.db.gz.age' -print0 \
  | xargs -0 ls -t 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  rm -f "$old"; echo "pruned $(basename "$old")"
done

SIZE=$(du -h "$OUT" | cut -f1)
COUNT=$(find "$DEST" -maxdepth 1 -name 'exocortex-*.db.gz.age' | wc -l | tr -d ' ')
echo "wrote $(basename "$OUT")  ($SIZE)  ·  $COUNT snapshots offsite"
