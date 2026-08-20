#!/bin/bash
# exocortex backup.
#
# Never backs up the live database file. A SQLite DB with an active WAL is not a
# consistent artifact on disk: a copy taken mid-checkpoint captures a db+wal pair that
# needs recovery on restore, and Time Machine additionally copies the WHOLE file every
# time any page changes (PASS-4 Area K.3). Instead `VACUUM INTO` writes a transactionally
# consistent, already-compacted snapshot, and that is what gets backed up.
set -euo pipefail

DB="${EXO_DB:-$HOME/.exocortex/phase1.db}"
REPO="${RESTIC_REPOSITORY:-$HOME/.exocortex/backup}"
PASS="${RESTIC_PASSWORD_FILE:-$HOME/.exocortex/.restic-pass}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

export RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PASS"

echo "snapshotting $DB …"
sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
sqlite3 "$DB" "VACUUM INTO '$STAGE/exocortex.db';"

# A human-readable manifest travels with every snapshot, so a restore in 2046 does not
# depend on this repo still existing to explain what the file is (Area K.6).
cat > "$STAGE/README.txt" <<TXT
exocortex snapshot — $(date -u +%Y-%m-%dT%H:%M:%SZ)

exocortex.db is a SQLite 3 database (a US Library of Congress recommended storage format).
Open it with any sqlite3 client; no application is required.

  events            one row per captured moment. ts is microseconds since the Unix epoch,
                    UTC; ts_tz is the local UTC offset in minutes at capture time.
  events_fts        FTS5 full-text index over events. Derived; rebuildable.
  vectors           binary + int8 embeddings. Derived; rebuildable from events.text.
  retention_policy  per-class TTL with the date it took effect.
  purge_receipt     append-only record of every scheduled deletion.

trust is one of self / verified / third_party / untrusted, assigned at capture by source,
never by a model. Rows with trust=third_party contain other people's data.

events: $(sqlite3 "$DB" 'SELECT count(*) FROM events;')
span:   $(sqlite3 "$DB" "SELECT date(min(ts)/1000000,'unixepoch')||' to '||date(max(ts)/1000000,'unixepoch') FROM events WHERE ts>0;")
TXT

restic backup --tag exocortex --quiet "$STAGE" \
  && echo "backed up ok"
restic forget --quiet --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune 2>/dev/null || true
restic snapshots --compact 2>/dev/null | tail -5
