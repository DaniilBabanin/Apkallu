#!/usr/bin/env bash
# Tests for loop/cascade.sh dispatch end-to-end against an ephemeral PG18 cluster.
# WORKER_CMD is stubbed — no claude, no network.  Skips cleanly when PG18 unavailable.
#
# Verifies that when PG_AVAIL=1 and a queued job exists, cascade dispatch:
#   1. claims the job via claim_next_job() (not file-based claim)
#   2. creates an isolated git worktree + branch
#   3. runs the WORKER_CMD stub with CASCADE_PG_JOB_ID / CASCADE_PG_CLAIMER set
#   4. leaves the job in state=running (worker stub doesn't call complete_job)
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASCADE="$SELF_DIR/loop/cascade.sh"

# shellcheck source=tests/lib/pg_fixture.sh
. "$SELF_DIR/tests/lib/pg_fixture.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; pg_fixture_teardown' EXIT

# Fixture PG is in the sandbox's own netns — direct TCP, no HTTP CONNECT proxy.
# Unset so cascade.sh's lib/pg.sh source also skips the socat bridge.
unset CLAUDE_CODE_HOST_HTTP_PROXY_PORT

FAIL=0
N=0
pass() { N=$(( N + 1 )); echo "ok   $1"; }
fail() { N=$(( N + 1 )); FAIL=1; echo "FAIL $1"; }

# Hermetic auth: no real oauth token for this test
unset CLAUDE_CODE_OAUTH_TOKEN
export AGENCY_HOST_CREDENTIALS=/nonexistent

# Fresh git repo (CASCADE_REPO target) — minimal backlog.md required by cascade
new_repo() {
  local d
  d="$(mktemp -d "$TMP/repo.XXXXXX")"
  git -C "$d" init -q
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  cat > "$d/backlog.md" <<'EOF'
# Backlog
## Parked
## Done
EOF
  git -C "$d" add -A
  git -C "$d" commit -q -m init
  printf '%s' "$d"
}

REPO="$(new_repo)"
WT_DIR="$TMP/worktrees"
mkdir -p "$WT_DIR"

# Worker stub: records the PG env vars it receives, exits 0
STUB="$TMP/worker.sh"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
echo "STUB_JOB_ID=${CASCADE_PG_JOB_ID:-}" > "$TMP_STUB_OUT"
echo "STUB_CLAIMER=${CASCADE_PG_CLAIMER:-}" >> "$TMP_STUB_OUT"
exit 0
STUB_EOF
chmod +x "$STUB"

STUB_OUT="$TMP/stub.out"
export TMP_STUB_OUT="$STUB_OUT"

# ── test: dispatch-pg-claim ─────────────────────────────────────────────────
# Insert a job into the fixture DB, then run cascade dispatch.
# Expected: PG claim path taken, worktree created, job in state=running.

_TASK_ID="pg-test-unit-1"
_TASK_LINE="implement the test feature"
_JOB_UUID="$(pg_admin "INSERT INTO jobs (title, done_condition) VALUES ('$_TASK_ID', '$_TASK_LINE') RETURNING id")"

if [ -z "$_JOB_UUID" ]; then
  echo "FAIL setup: insert job returned empty uuid"
  FAIL=1
fi

OUT="$(
  CASCADE_REPO="$REPO" \
  CASCADE_WT_DIR="$WT_DIR" \
  CASCADE_NO_COMMIT=1 \
  WORKER_CMD="$STUB" \
  AGENCY_PG_HOST="$AGENCY_PG_HOST" \
  AGENCY_PG_PORT="$AGENCY_PG_PORT" \
  AGENCY_PG_DB="$AGENCY_PG_DB" \
  AGENCY_PG_USER="$AGENCY_PG_USER" \
    "$CASCADE" dispatch 2>&1
)"

# 1. dispatch took the PG claim path
if printf '%s' "$OUT" | grep -q "PG claim"; then
  pass "dispatch-pg-claim: output contains 'PG claim'"
else
  fail "dispatch-pg-claim: 'PG claim' not in output; got: $OUT"
fi

# 2. worktree for the unit was created
if [ -d "$WT_DIR/$_TASK_ID" ]; then
  pass "dispatch-pg-claim: worktree created"
else
  fail "dispatch-pg-claim: worktree missing at $WT_DIR/$_TASK_ID"
fi

# 3. worker stub received CASCADE_PG_JOB_ID matching the inserted UUID
if [ -f "$STUB_OUT" ]; then
  _STUB_JID="$(grep "^STUB_JOB_ID=" "$STUB_OUT" | cut -d= -f2-)"
  if [ "$_STUB_JID" = "$_JOB_UUID" ]; then
    pass "dispatch-pg-claim: worker got CASCADE_PG_JOB_ID=$_JOB_UUID"
  else
    fail "dispatch-pg-claim: CASCADE_PG_JOB_ID='$_STUB_JID' (want '$_JOB_UUID')"
  fi
else
  fail "dispatch-pg-claim: worker stub output file missing"
fi

# 4. job is in state=running (worker stub doesn't call complete_job)
_STATE="$(pg_admin "SELECT state FROM jobs WHERE id='$_JOB_UUID'")"
if [ "$_STATE" = "running" ]; then
  pass "dispatch-pg-claim: job state=running after dispatch"
else
  fail "dispatch-pg-claim: job state='$_STATE' (want running)"
fi

echo ""
echo "cascade_pg_test: $N tests, $FAIL failed"
exit "$FAIL"
