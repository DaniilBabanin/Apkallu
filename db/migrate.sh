#!/usr/bin/env bash
# db/migrate.sh — apply numbered SQL migrations from db/migrations/ in order, once each.
# (implementation-plan.md ground rules: psql + a schema_migrations table, no framework.)
#
# Each migration runs in ONE transaction together with its schema_migrations insert
# (psql --single-transaction wraps the -f and -c in a single BEGIN/COMMIT), so a failed
# migration leaves no trace. Migration files must therefore NOT contain BEGIN/COMMIT.
#
# Usage: ./db/migrate.sh            (idempotent — re-run any time)
# Env:   AGENCY_DB  database name (default: agency)
#        plus standard PG* vars (PGHOST etc.) — default is the local unix socket as the
#        calling OS user (peer auth); see db/README.md for the role setup.
set -euo pipefail
cd "$(dirname "$0")" || exit 1

DB="${AGENCY_DB:-agency}"
PSQL=(psql --no-psqlrc --quiet --set=ON_ERROR_STOP=1 -d "$DB")

"${PSQL[@]}" -c "CREATE TABLE IF NOT EXISTS schema_migrations (
  version    text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);"

applied=0
skipped=0
for f in migrations/[0-9]*.sql; do
  [ -e "$f" ] || { echo "migrate: no migration files in db/migrations/" >&2; exit 1; }
  v="$(basename "$f" .sql)"
  if [ "$("${PSQL[@]}" -tAc "SELECT 1 FROM schema_migrations WHERE version = '$v'")" = "1" ]; then
    skipped=$((skipped + 1))
    continue
  fi
  echo "migrate: applying $v"
  "${PSQL[@]}" --single-transaction -f "$f" \
    -c "INSERT INTO schema_migrations (version) VALUES ('$v');"
  applied=$((applied + 1))
done
echo "migrate: $applied applied, $skipped already up to date (db=$DB)"
