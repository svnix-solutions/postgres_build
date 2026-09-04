#!/bin/sh
# Nightly logical backup of the whole cluster to the NAS.
#
# Run as a one-off compose service (profile "backup") via Komodo's
# RunStackService, scheduled by the "Postgres Backup" procedure.
#
# Correctness notes:
#   - pipefail is on, so a pg_dumpall failure mid-stream fails the job.
#     Without it gzip would exit 0 and happily produce a valid archive of a
#     truncated dump -- a backup that looks fine until you need it.
#   - The dump is written to a .partial file and only renamed once gzip -t
#     confirms it, so a half-written file is never mistaken for a good one.
#   - The sentinel check aborts if the NAS is not mounted, rather than
#     quietly filling the node's local disk.

set -eu
set -o pipefail

DEST="${BACKUP_DEST:-/backup}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
SENTINEL="$DEST/.pgbackup-target"

if [ ! -f "$SENTINEL" ]; then
  echo "FATAL: $SENTINEL is missing." >&2
  echo "The NAS is almost certainly not mounted at $DEST. Refusing to write" >&2
  echo "backups to what is probably the node's local disk." >&2
  exit 1
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$DEST/pgdumpall-${TS}.sql.gz"
TMP="${OUT}.partial"

echo "==> pg_dumpall from ${PGHOST} as ${PGUSER}"
pg_dumpall --clean --if-exists | gzip -c > "$TMP"

echo "==> verifying archive"
gzip -t "$TMP"

mv "$TMP" "$OUT"
echo "==> wrote $OUT ($(du -h "$OUT" | cut -f1))"

echo "==> pruning dumps older than ${RETENTION_DAYS} days"
find "$DEST" -maxdepth 1 -type f -name 'pgdumpall-*.sql.gz' -mtime "+${RETENTION_DAYS}" -print -delete || true
# Clean up leftovers from a run that died before the rename.
find "$DEST" -maxdepth 1 -type f -name '*.partial' -mtime +1 -print -delete || true

echo "==> backups on the target:"
ls -lh "$DEST"/pgdumpall-*.sql.gz 2>/dev/null | tail -20 || echo "(none)"
echo "==> free space:"
df -h "$DEST" | tail -1
