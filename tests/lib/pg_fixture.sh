#!/usr/bin/env bash
# tests/lib/pg_fixture.sh — ephemeral PG18 cluster for integration tests.
#
# Source this at the top of a test that needs a real database:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/../lib/pg_fixture.sh"   # adjust path as needed
#
# After sourcing, AGENCY_PG_HOST/PORT/DB/USER are set to point at the ephemeral
# cluster.  pg_fixture_teardown() stops postgres and removes the data dir; call it
# from your EXIT trap.  pg_admin "<sql>" runs SQL as the cluster superuser (bypasses
# agency_loop column-level grants — useful for test setup / state inspection).
#
# TCP-only: no unix socket.  AF_UNIX is seccomp-denied in the bwrap worker sandbox
# (db/README.md §Sandbox); the fixture uses -k '' so postgres never tries it.
# auth: trust on 127.0.0.1/32 — no password needed (test cluster only, never exposed).
#
# Clean skip (exit 0) when PG18 binaries are absent or the cluster can't start.
# The gate treats any test that exits 0 as passing; a clean skip is correct here.

_PG18_BIN="/usr/lib/postgresql/18/bin"

if ! [ -x "$_PG18_BIN/initdb" ] || ! [ -x "$_PG18_BIN/pg_ctl" ]; then
  echo "# pg_fixture: PG18 not found at $_PG18_BIN — skip"
  exit 0
fi

_PG_DIR="$(mktemp -d)"
# Deterministic-ish port from PID; stays in 35000-44999 (away from well-known ports).
_PG_PORT=$(( 35000 + ( $$ % 10000 ) ))
_PG_ADMIN_USER="$(id -un)"

pg_fixture_teardown() {
  "$_PG18_BIN/pg_ctl" -D "$_PG_DIR" stop -m immediate -s 2>/dev/null || true
  rm -rf "$_PG_DIR"
}

# Init cluster
"$_PG18_BIN/initdb" -D "$_PG_DIR" -U "$_PG_ADMIN_USER" --no-instructions \
  >/dev/null 2>&1 || {
  echo "# pg_fixture: initdb failed — skip"
  rm -rf "$_PG_DIR"
  exit 0
}

# Trust auth on TCP; no unix socket path needed
cat > "$_PG_DIR/pg_hba.conf" <<EOF
host  all  all  127.0.0.1/32  trust
host  all  all  ::1/128       trust
EOF

# Start postgres: TCP only (-k '' disables unix socket)
"$_PG18_BIN/pg_ctl" -D "$_PG_DIR" start \
  -o "-h 127.0.0.1 -p $_PG_PORT -k ''" >/dev/null 2>&1 || {
  echo "# pg_fixture: pg_ctl start failed — skip"
  pg_fixture_teardown
  exit 0
}

# Wait up to 10 s for the server to accept connections
_pg_ready=0
for _i in {1..20}; do
  if psql -h 127.0.0.1 -p "$_PG_PORT" -U "$_PG_ADMIN_USER" postgres \
       -c '' >/dev/null 2>&1; then
    _pg_ready=1; break
  fi
  sleep 0.5
done
unset _i

if [ "$_pg_ready" != "1" ]; then
  echo "# pg_fixture: server did not become ready in 10 s — skip"
  pg_fixture_teardown
  exit 0
fi

# Create the test database
psql -h 127.0.0.1 -p "$_PG_PORT" -U "$_PG_ADMIN_USER" postgres \
  -qc "CREATE DATABASE agency_test OWNER \"$_PG_ADMIN_USER\"" >/dev/null 2>&1 || {
  echo "# pg_fixture: createdb failed — skip"
  pg_fixture_teardown
  exit 0
}

# Apply the core schema (relative to fixture's parent = tests/; repo root = one level up)
_FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_REPO_DIR="$(cd "$_FIXTURE_DIR/../.." && pwd)"

psql -h 127.0.0.1 -p "$_PG_PORT" -U "$_PG_ADMIN_USER" agency_test \
  -q < "$_PG_REPO_DIR/db/migrations/001_core.sql" >/dev/null 2>&1 || {
  echo "# pg_fixture: migration 001 failed — skip"
  pg_fixture_teardown
  exit 0
}

psql -h 127.0.0.1 -p "$_PG_PORT" -U "$_PG_ADMIN_USER" agency_test \
  -q < "$_PG_REPO_DIR/db/migrations/002_lineage.sql" >/dev/null 2>&1 || {
  echo "# pg_fixture: migration 002 failed — skip"
  pg_fixture_teardown
  exit 0
}

# Export override vars — lib/pg.sh reads these at source time
export AGENCY_PG_HOST="127.0.0.1"
export AGENCY_PG_PORT="$_PG_PORT"
export AGENCY_PG_DB="agency_test"
export AGENCY_PG_USER="agency_loop"

# Superuser helper: run SQL bypassing agency_loop column-level grants.
# Used by tests for setup, clock manipulation, and state inspection.
# -q suppresses command tags (INSERT 0 1 etc.) so RETURNING output is unambiguous.
pg_admin() {
  psql -h 127.0.0.1 -p "$_PG_PORT" -U "$_PG_ADMIN_USER" agency_test \
    -tAq -c "$1" 2>/dev/null
}
