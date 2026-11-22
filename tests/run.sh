#!/usr/bin/env bash
# Rebuilds a scratch database and runs all checks. Exit code 0 = everything passed.
# Usage: tests/run.sh [dbname]     (default dbname: hms_schema_test)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DB="${1:-hms_schema_test}"

if ! "$HERE/../rebuild.sh" "$DB"; then
  echo "TESTS NOT RUN: database rebuild failed (see message above)." >&2; exit 1
fi

OUT="$(psql -d "$DB" -f "$HERE/schema_tests.sql" 2>&1)"; RC=$?
echo "$OUT"
if [[ $RC -ne 0 ]]; then echo "TESTS FAILED: psql exited with code $RC" >&2; exit 1; fi
if echo "$OUT" | grep -qE '^ FAIL |ERROR:'; then echo "TESTS FAILED" >&2; exit 1; fi
if ! echo "$OUT" | grep -qE '^\s+[0-9]+ \|\s+0 \|'; then echo "TESTS FAILED: could not confirm 0 failures" >&2; exit 1; fi
echo "ALL TESTS PASSED"
