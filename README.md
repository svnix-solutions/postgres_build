# postgres_build

Komodo stack running **PostgreSQL 17** with **pgAdmin 4**, plus a scheduled
logical backup job.

---

## Storage layout

The data directory lives on a **local Docker volume**, never on network
storage. PostgreSQL depends on reliable `fsync` and file locking; NFS and SMB
provide neither dependably, and a stale lock can let two postmasters open the
same data directory and destroy it.

The NAS is used for **backups only**, which is what network storage is good at.

```
  pgdata volume  ──►  local disk   (PGDATA)
  PGBACKUP_PATH  ──►  NAS over NFS (dumps)
```

If you want the data itself on a NAS, use **iSCSI**, not NFS — a LUN gives a
real block device with its own filesystem and correct POSIX semantics.

---

## Services

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| `postgres` | `postgres:17-alpine` | 5432 | the database |
| `pgadmin` | `dpage/pgadmin4` | 5050 → 80 | web admin UI |
| `backup` | `postgres:17-alpine` | — | one-off dump job (compose profile `backup`) |

`backup` sits behind a compose profile, so it never starts on a normal deploy.

---

## Setup

```bash
cp .env.example .env    # then edit it
docker network create db 2>/dev/null || true
docker compose up -d
```

`PGBACKUP_PATH` must point at an **already-mounted** backup volume, and that
directory must contain a sentinel file:

```bash
echo "sentinel" > /mnt/pgbackup/.pgbackup-target
```

The backup job refuses to run without it — see below.

Both ports default to `127.0.0.1`. Set `POSTGRES_BIND` / `PGADMIN_BIND` to a
LAN address to reach them from other hosts. Avoid `0.0.0.0` unless you really
mean to offer a database to every interface.

---

## Backups

Run manually:

```bash
docker compose --profile backup run --rm backup
```

Or, in Komodo, schedule a Procedure with a `RunStackService` execution
targeting the `backup` service.

Output is `pgdumpall-<UTC timestamp>.sql.gz`, pruned after
`BACKUP_RETENTION_DAYS`.

### What the script guards against

A backup job that silently does nothing is worse than no backup job. Three
specific failure modes are handled:

| Guard | Failure it prevents |
| --- | --- |
| `set -o pipefail` | `pg_dumpall` dies mid-stream, `gzip` still exits 0, and you get a **valid archive of half a database** |
| write to `.partial`, `gzip -t`, then rename | an interrupted run leaves a file that looks complete |
| sentinel file check | the NAS is not mounted, and "backups" quietly fill the node's local disk |

The compose file also sets `create_host_path: false` on the backup bind mount,
so Docker refuses to invent an empty directory if the mount is missing.

### Restoring

**Destructive** — `--clean --if-exists` drops and recreates objects:

```bash
gunzip -c /mnt/pgbackup/pgdumpall-<ts>.sql.gz \
  | docker exec -i postgres psql -U postgres -d postgres
```

Test a restore into a throwaway database before you need it for real.

---

## Files

| File | Purpose |
| --- | --- |
| `compose.yaml` | the stack definition |
| `backup.sh` | dump, verify, prune |
| `.env.example` | template for `.env` |
