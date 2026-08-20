#!/bin/bash
# Restore the newest offsite snapshot to a target path (default /tmp/exocortex-restored.db).
#
# Exists because the first restore attempt failed twice over, and a backup nobody has
# restored is not a backup:
#   * a glob over the space-containing iCloud path matched nothing under zsh
#   * `security find-generic-password -w` returns HEX, not text, when the stored value
#     contains newlines — age received hex and reported "unknown identity type"
set -euo pipefail

DEST="${EXO_OFFSITE_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Exocortex-Backup}"
TARGET="${1:-/tmp/exocortex-restored.db}"

SNAP="$(find "$DEST" -maxdepth 1 -name 'exocortex-*.db.gz.age' -print0 \
        | xargs -0 ls -t 2>/dev/null | head -1)"
[ -n "$SNAP" ] || { echo "no snapshot found in $DEST"; exit 1; }

KEY="$(mktemp)"; trap 'rm -f "$KEY"' EXIT
chmod 600 "$KEY"
RAW="$(security find-generic-password -s exocortex.offsite -a age_identity -w)"
# security emits hex when the secret is not printable ASCII (ours has newlines)
if printf '%s' "$RAW" | grep -qE '^[0-9a-fA-F]+$'; then
  printf '%s' "$RAW" | xxd -r -p > "$KEY"
else
  printf '%s\n' "$RAW" > "$KEY"
fi

echo "restoring $(basename "$SNAP")"
age -d -i "$KEY" "$SNAP" | gunzip > "$TARGET"
echo "  -> $TARGET  ($(du -h "$TARGET" | cut -f1))"
echo "  integrity: $(sqlite3 "$TARGET" 'PRAGMA integrity_check;' | head -1)"
echo "  events:    $(sqlite3 "$TARGET" 'SELECT count(*) FROM events;')"
