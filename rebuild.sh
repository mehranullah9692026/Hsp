#!/usr/bin/env bash
# Drops and recreates a database, then applies everything in the correct order:
#   1) migrations/001 ... 005   2) seeds/001_reference.sql   3) seeds/002_sample_data.sql (optional)
# Usage:  ./rebuild.sh <dbname> [--no-sample]
# Connection comes from standard libpq variables (PGHOST, PGPORT, PGUSER, PGPASSWORD).
# DESTRUCTIVE: for development/testing only.
set -euo pipefail

DB="${1:-}"
[[ -n "$DB" ]] || { echo "ERROR: database name missing. Usage: ./rebuild.sh <dbname> [--no-sample]" >&2; exit 2; }
[[ "$DB" =~ ^[A-Za-z0-9_]+$ ]] || { echo "ERROR: database name may contain only letters, digits and underscore." >&2; exit 2; }
if [[ "$DB" == *prod* ]]; then
  echo "ERROR: refusing to drop a database whose name contains 'prod'. Use incremental migrations in production." >&2; exit 2
fi
command -v psql >/dev/null || { echo "ERROR: psql is not installed or not on PATH." >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
PSQL=(psql -v ON_ERROR_STOP=1 -q)
trap 'echo "FAILED while running: ${CURRENT:-setup}. Nothing after this step was applied." >&2' ERR

CURRENT="connection check"
"${PSQL[@]}" -d postgres -Atc "select 1" >/dev/null
CURRENT="extension check"
MISSING="$("${PSQL[@]}" -d postgres -Atc "select string_agg(e,', ') from unnest(array['pgcrypto','citext','pg_trgm','btree_gist']) e where e not in (select name from pg_available_extensions)")"
[[ -z "$MISSING" ]] || { echo "ERROR: missing PostgreSQL contrib extensions: $MISSING (install postgresql-contrib)" >&2; exit 2; }

CURRENT="create database"
"${PSQL[@]}" -d postgres -c "DROP DATABASE IF EXISTS \"$DB\"" -c "CREATE DATABASE \"$DB\""

# Migrations are applied in filename order (001, 002, ...). Do not rename or reorder them.
for f in "$HERE"/migrations/*.sql; do
  CURRENT="migration $(basename "$f")"; echo "[migrate] $(basename "$f")"
  "${PSQL[@]}" -d "$DB" -f "$f"
done

CURRENT="seed 001_reference.sql"; echo "[seed]    001_reference.sql (required)"
"${PSQL[@]}" -d "$DB" -f "$HERE/seeds/001_reference.sql"

if [[ "${2:-}" != "--no-sample" ]]; then
  CURRENT="seed 002_sample_data.sql"; echo "[seed]    002_sample_data.sql (TEST DATA ONLY)"
  "${PSQL[@]}" -d "$DB" -f "$HERE/seeds/002_sample_data.sql"
fi
trap - ERR
echo "OK: database '$DB' is ready."
