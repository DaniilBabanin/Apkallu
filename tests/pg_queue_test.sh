#!/usr/bin/env bash
# Tests for the PG job queue via lib/pg.sh against an ephemeral PG18 cluster.
# Skips cleanly when PG18 is unavailable (pg_fixture.sh exits 0 with a message).
#
# Covered:
#   1. racing-claimers   — 2 concurrent claimers × 10 jobs: each job claimed exactly once
#   2. lease-expiry      — short-lease claim, wait, reap_expired() → job back to queued
#   3. blocked-by        — blocked job not claimable until its blocker reaches state=done
#   4. dead-letter       — max_attempts=1: one failure → state=failed (no re-queue)
#   5. perm-denied       — agency_loop: UPDATE events.data → permission denied
#   6. gapless-positions — append_event: per-stream positions are 1, 2, 3, … (no gaps)
#   7. injection         — titles/errors/JSON containing $$, quotes, newlines stored verbatim
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=tests/lib/pg_fixture.sh
. tests/lib/pg_fixture.sh

TMP="$(mktemp -d)"

# The fixture PG is inside the sandbox's own netns — reachable directly without the
# HTTP CONNECT proxy.  Unset the proxy env so lib/pg.sh skips its socat bridge.
unset CLAUDE_CODE_HOST_HTTP_PROXY_PORT

# shellcheck source=lib/pg.sh
. lib/pg.sh   # reads AGENCY_PG_* set by fixture; _pg_init() runs direct TCP (no bridge)

# Re-register teardown (lib/pg.sh's trap '_pg_cleanup' would supersede our trap).
# _pg_cleanup is a no-op here (no bridge was started), so we only need our own.
trap 'rm -rf "$TMP"; pg_fixture_teardown' EXIT

if [ "${PG_AVAIL:-0}" != "1" ]; then
  echo "# pg_queue_test: PG_AVAIL=0 after fixture setup — skip"
  exit 0
fi

FAIL=0
N=0
pass() { N=$(( N + 1 )); echo "ok   $1"; }
fail() { N=$(( N + 1 )); FAIL=1; echo "FAIL $1"; }

# ── 1. racing-claimers ──────────────────────────────────────────────────────
# Insert 10 jobs; two concurrent subshells each drain the queue.  Total claimed
# must equal 10 — FOR UPDATE SKIP LOCKED guarantees no double-pick.

for _j in {1..10}; do
  pg_insert_job "race-job-$_j" "done condition $_j" >/dev/null
done
unset _j

_claim_all() {   # $1=claimer-name $2=output-file
  local _claimed=0
  while true; do
    local _row
    _row="$(pg_claim_next_job "$1")" || break
    [ -n "$_row" ] || break
    _claimed=$(( _claimed + 1 ))
  done
  echo "$_claimed" > "$2"
}

_claim_all "claimer-a" "$TMP/ca.out" &
_PID_A=$!
_claim_all "claimer-b" "$TMP/cb.out" &
_PID_B=$!
wait "$_PID_A" "$_PID_B"

_total=$(( $(cat "$TMP/ca.out") + $(cat "$TMP/cb.out") ))
if [ "$_total" -eq 10 ]; then pass "racing-claimers: total=$_total/10"; else fail "racing-claimers: got $_total/10"; fi

# ── 2. lease-expiry → reap → requeue ────────────────────────────────────────
# Insert a job, claim it with a 1-second lease via superuser SQL, wait 2 s,
# call reap_expired(), verify state returns to queued.

_JOB_REAP="$(pg_admin "INSERT INTO jobs (title,done_condition) VALUES ('reap-me','cond') RETURNING id")"
pg_admin "SELECT claim_next_job('killer','{}'::jsonb,interval '1 second')" >/dev/null

sleep 2

pg_admin "SELECT reap_expired()" >/dev/null
_STATE_REAP="$(pg_admin "SELECT state FROM jobs WHERE id='$_JOB_REAP'")"
if [ "$_STATE_REAP" = "queued" ]; then pass "lease-expiry: state=queued after reap"; else fail "lease-expiry: state=$_STATE_REAP (want queued)"; fi

# Cancel reap-me so it doesn't interfere with blocked-by test ordering
pg_admin "UPDATE jobs SET state='cancelled', finished_at=now() WHERE id='$_JOB_REAP'" >/dev/null

# ── 3. blocked-by ordering ──────────────────────────────────────────────────
# Job B is blocked_by A.  Claim before A is done → only A is returned.
# Complete A, then claim → B is returned.

_JOB_A="$(pg_insert_job "blocker-a" "do A")"
_JOB_B="$(pg_insert_job "blocker-b" "do B" "$_JOB_A")"

_ROW_A="$(pg_claim_next_job "ord-claimer")"
_GOT_A="$(printf '%s' "$_ROW_A" | jq -r '.title // empty' 2>/dev/null)"
_ROW_EMPTY="$(pg_claim_next_job "ord-claimer" || true)"

if [ "$_GOT_A" = "blocker-a" ]; then pass "blocked-by: first claim=blocker-a"; else fail "blocked-by: first claim='$_GOT_A' (want blocker-a)"; fi
if [ -z "$_ROW_EMPTY" ]; then pass "blocked-by: second claim empty (B still blocked)"; else fail "blocked-by: second claim non-empty while B blocked"; fi

pg_complete_job "$_JOB_A" "ord-claimer" "abc123"

_ROW_B="$(pg_claim_next_job "ord-claimer")"
_GOT_B="$(printf '%s' "$_ROW_B" | jq -r '.title // empty' 2>/dev/null)"
if [ "$_GOT_B" = "blocker-b" ]; then pass "blocked-by: blocker done → blocked job claimable"; else fail "blocked-by: after complete got '$_GOT_B' (want blocker-b)"; fi

pg_complete_job "$_JOB_B" "ord-claimer" "def456"

# ── 4. dead-letter at max_attempts ──────────────────────────────────────────
# Insert a job with max_attempts=1.  One claim + one fail → state=failed.

_JOB_DL="$(pg_admin "INSERT INTO jobs (title,done_condition,max_attempts) VALUES ('dead-letter','cond',1) RETURNING id")"
pg_admin "SELECT claim_next_job('dl-claimer')" >/dev/null
pg_fail_job "$_JOB_DL" "dl-claimer" "intentional failure"
_STATE_DL="$(pg_admin "SELECT state FROM jobs WHERE id='$_JOB_DL'")"
if [ "$_STATE_DL" = "failed" ]; then pass "dead-letter: state=failed at max_attempts"; else fail "dead-letter: state=$_STATE_DL (want failed)"; fi

# ── 5. events UPDATE → permission denied ────────────────────────────────────
# agency_loop may only UPDATE events.invalidated_by; any other column must be denied.

pg_append_event "perm-test-stream" "perm.test" '{"x":1}'
_ERR="$(psql -h 127.0.0.1 -p "$AGENCY_PG_PORT" -U agency_loop agency_test \
  -c "UPDATE events SET data = '{\"y\":2}' WHERE stream_name = 'perm-test-stream'" 2>&1 || true)"
if printf '%s' "$_ERR" | grep -qi "permission denied"; then
  pass "perm-denied: UPDATE events.data refused"
else
  fail "perm-denied: expected 'permission denied', got: $_ERR"
fi

# ── 6. gapless per-stream positions ─────────────────────────────────────────
# Three appends to the same stream → positions must be exactly 1, 2, 3.

pg_append_event "gap-stream" "ev.a" '{}'
pg_append_event "gap-stream" "ev.b" '{}'
pg_append_event "gap-stream" "ev.c" '{}'
_POSITIONS="$(pg_admin "SELECT position FROM events WHERE stream_name='gap-stream' ORDER BY position")"
_EXPECTED="$(printf '1\n2\n3')"
if [ "$_POSITIONS" = "$_EXPECTED" ]; then
  pass "gapless-positions: 1,2,3 confirmed"
else
  fail "gapless-positions: got '$_POSITIONS' (want 1 2 3)"
fi

# ── 7. injection regression ─────────────────────────────────────────────────
# Values containing $$, single quotes, double quotes, and newlines must be stored
# verbatim.  lib/pg.sh uses psql -v + :'var' quoting; verify no interpolation.

_TRICKY_TITLE="job with \$\$ and 'quotes' and newline
second line"
_TRICKY_ERR="error: \$\$bad\$\$ and 'oh no' and \"dquote\""

_JOB_INJ="$(pg_insert_job "$_TRICKY_TITLE" "plain condition")"
if [ -n "$_JOB_INJ" ]; then pass "injection: insert with tricky title succeeded"; else fail "injection: insert failed"; fi

# Claim it so we can call fail_job with the tricky error string
pg_admin "SELECT claim_next_job('inj-claimer')" >/dev/null
pg_fail_job "$_JOB_INJ" "inj-claimer" "$_TRICKY_ERR"

_STORED_TITLE="$(pg_admin "SELECT title FROM jobs WHERE id='$_JOB_INJ'")"
_STORED_ERR="$(pg_admin "SELECT last_error FROM jobs WHERE id='$_JOB_INJ'")"

if [ "$_STORED_TITLE" = "$_TRICKY_TITLE" ]; then pass "injection: title stored verbatim"; else fail "injection: title mismatch"; fi
if [ "$_STORED_ERR" = "$_TRICKY_ERR" ]; then pass "injection: last_error stored verbatim"; else fail "injection: error mismatch"; fi

# pg_append_event with tricky JSON containing $$ and quotes
_TRICKY_JSON='{"key":"val with $$ and quote"}'
pg_append_event "inj-stream" "inj.event" "$_TRICKY_JSON"
_STORED_JSON="$(pg_admin "SELECT data::text FROM events WHERE stream_name='inj-stream' LIMIT 1")"
if printf '%s' "$_STORED_JSON" | grep -q '"key"'; then
  pass "injection: event JSON stored (key present)"
else
  fail "injection: event JSON missing key: '$_STORED_JSON'"
fi

echo ""
echo "pg_queue_test: $N tests, $FAIL failed"
exit "$FAIL"
