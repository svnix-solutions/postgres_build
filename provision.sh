#!/bin/sh
# Idempotent provisioning of app roles, databases and extensions.
#
# DB_PROVISION is a comma-separated list of  name:password[:ext1+ext2]
#   e.g.  formbricks:<hex>:vector,kaneo:<hex>
# For each entry: role <name> (LOGIN, password set/reset), database <name>
# owned by it, and the listed extensions created in that database as
# superuser (so apps that need e.g. pgvector don't need superuser rights).
#
# Never drops anything. Passwords must not contain ':' or ',' -- use hex.

set -eu

if [ -z "${DB_PROVISION:-}" ]; then
  echo "DB_PROVISION is empty; nothing to do."
  exit 0
fi

q() { psql -v ON_ERROR_STOP=1 -X -q "$@"; }

echo "$DB_PROVISION" | tr ',' '\n' | while IFS=: read -r name pw exts; do
  name="$(echo "$name" | tr -d ' ')"
  [ -n "$name" ] || continue
  if [ -z "$pw" ]; then
    echo "FATAL: no password for '$name'" >&2
    exit 1
  fi

  q -d postgres -v name="$name" -v pw="$pw" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'name')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'name') \gexec
ALTER ROLE :"name" WITH LOGIN PASSWORD :'pw';
SELECT format('CREATE DATABASE %I OWNER %I', :'name', :'name')
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'name') \gexec
SQL
  echo "==> role + database: $name"

  for ext in $(echo "${exts:-}" | tr '+' ' '); do
    q -d "$name" -c "CREATE EXTENSION IF NOT EXISTS \"$ext\";"
    echo "    extension: $ext"
  done
done
echo "==> provisioning done"
