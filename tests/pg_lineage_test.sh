#!/usr/bin/env bash
# Tests for db/migrations/002_lineage.sql against an ephemeral PG18 cluster.
# Skips cleanly when PG18 unavailable (pg_fixture.sh exits 0 with a message).
#
# Covered:
#   1. upsert_node idempotent      — double insert → 1 row, same id both times
#   2. add_edge idempotent         — double add_edge → 1 row
#   3. nodes UPDATE → denied       — agency_loop cannot UPDATE nodes columns
#   4. edges UPDATE (non-inv) → denied — agency_loop cannot UPDATE edges columns
#                                        except invalidated_by
#   5. edges.invalidated_by settable — agency_loop CAN set invalidated_by once
#   6. supersession chain          — older edge invalidated_by set to newer edge id
#   7. views queryable             — commit_provenance, model_outputs, bench_verdicts
#                                    return rows when data present
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=tests/lib/pg_fixture.sh
. tests/lib/pg_fixture.sh

unset CLAUDE_CODE_HOST_HTTP_PROXY_PORT

trap 'pg_fixture_teardown' EXIT

if [ -z "${AGENCY_PG_HOST:-}" ]; then
  echo "# pg_lineage_test: fixture did not export AGENCY_PG_HOST — skip"
  exit 0
fi

FAIL=0
N=0
pass() { N=$(( N + 1 )); echo "ok   $1"; }
fail() { N=$(( N + 1 )); FAIL=1; echo "FAIL $1"; }

# Helper: run SQL as agency_loop; capture stderr too (for permission checks)
agency_sql() { psql -h 127.0.0.1 -p "$AGENCY_PG_PORT" -U agency_loop agency_test -tAq -c "$1" 2>&1; }

# ── 1. upsert_node idempotent ────────────────────────────────────────────────
_ID1="$(pg_admin "SELECT upsert_node('commit','abc123','{\"subject\":\"first\"}')")"
_ID2="$(pg_admin "SELECT upsert_node('commit','abc123','{\"subject\":\"second\"}')")"
_COUNT="$(pg_admin "SELECT count(*) FROM nodes WHERE kind='commit' AND natural_key='abc123'")"

if [ "$_ID1" = "$_ID2" ] && [ "$_COUNT" = "1" ]; then
  pass "upsert_node: idempotent (same id=$_ID1, count=1)"
else
  fail "upsert_node: id1=$_ID1 id2=$_ID2 count=$_COUNT (want same id, count=1)"
fi

# ── 2. add_edge idempotent ───────────────────────────────────────────────────
_MV_ID="$(pg_admin "SELECT upsert_node('model_version','claude-sonnet-4-6','{}')")"
_E1="$(pg_admin "SELECT add_edge($_ID1,$_MV_ID,'ran_on','{}')")"
_E2="$(pg_admin "SELECT add_edge($_ID1,$_MV_ID,'ran_on','{}')")"
_ECOUNT="$(pg_admin "SELECT count(*) FROM edges WHERE from_node=$_ID1 AND to_node=$_MV_ID AND label='ran_on'")"

if [ "$_E1" = "$_E2" ] && [ "$_ECOUNT" = "1" ]; then
  pass "add_edge: idempotent (same id=$_E1, count=1)"
else
  fail "add_edge: e1=$_E1 e2=$_E2 count=$_ECOUNT (want same id, count=1)"
fi

# ── 3. nodes UPDATE → permission denied ──────────────────────────────────────
_ERR="$(agency_sql "UPDATE nodes SET natural_key='tampered' WHERE id=$_ID1" 2>&1 || true)"
if printf '%s' "$_ERR" | grep -qi "permission denied"; then
  pass "perm-denied: UPDATE nodes.natural_key refused"
else
  fail "perm-denied: expected permission denied on nodes UPDATE, got: $_ERR"
fi

# ── 4. edges UPDATE (non-invalidated_by) → denied ────────────────────────────
_ERR2="$(agency_sql "UPDATE edges SET label='tampered' WHERE id=$_E1" 2>&1 || true)"
if printf '%s' "$_ERR2" | grep -qi "permission denied"; then
  pass "perm-denied: UPDATE edges.label refused"
else
  fail "perm-denied: expected permission denied on edges.label UPDATE, got: $_ERR2"
fi

# ── 5. edges.invalidated_by settable by agency_loop ──────────────────────────
# Create a second edge (different label) to act as the superseding edge
_E_NEW="$(pg_admin "SELECT add_edge($_ID1,$_MV_ID,'ran_on_v2','{}')")"
_UPD="$(agency_sql "UPDATE edges SET invalidated_by=$_E_NEW WHERE id=$_E1 RETURNING id" 2>&1 || true)"
if printf '%s' "$_UPD" | grep -q "$_E1"; then
  pass "perm-allowed: agency_loop can set edges.invalidated_by"
else
  fail "perm-allowed: UPDATE edges.invalidated_by failed: $_UPD"
fi

# ── 6. supersession chain settable ───────────────────────────────────────────
_INV="$(pg_admin "SELECT invalidated_by FROM edges WHERE id=$_E1")"
if [ "$_INV" = "$_E_NEW" ]; then
  pass "supersession: edges.invalidated_by=$_E_NEW (points to newer edge)"
else
  fail "supersession: got invalidated_by=$_INV (want $_E_NEW)"
fi

# ── 7. views queryable ───────────────────────────────────────────────────────
# Set up minimal data: commit → produced_by → job; job → ran_on → model_version
_JOB_NODE="$(pg_admin "SELECT upsert_node('job','job-001','{\"title\":\"test job\"}')")"
_COMMIT_NODE="$(pg_admin "SELECT upsert_node('commit','deadbeef','{\"subject\":\"test commit\"}')")"
pg_admin "SELECT add_edge($_COMMIT_NODE,$_JOB_NODE,'produced_by','{}')" >/dev/null
pg_admin "SELECT add_edge($_JOB_NODE,$_MV_ID,'ran_on','{}')" >/dev/null

_CP="$(pg_admin "SELECT count(*) FROM commit_provenance WHERE commit_sha='deadbeef'")"
if [ "$_CP" -ge 1 ]; then
  pass "view commit_provenance: returns row for deadbeef"
else
  fail "view commit_provenance: no rows for deadbeef (count=$_CP)"
fi

_MO="$(pg_admin "SELECT count(*) FROM model_outputs WHERE model_version='claude-sonnet-4-6'")"
if [ "$_MO" -ge 1 ]; then
  pass "view model_outputs: returns rows for claude-sonnet-4-6"
else
  fail "view model_outputs: no rows for claude-sonnet-4-6 (count=$_MO)"
fi

# bench_verdicts: insert eval_result node + produced edge
_ER_NODE="$(pg_admin "SELECT upsert_node('eval_result','er-001','{\"category\":\"coding\",\"score\":\"15/15\"}')")"
pg_admin "SELECT add_edge($_MV_ID,$_ER_NODE,'produced','{}')" >/dev/null
_BV="$(pg_admin "SELECT count(*) FROM bench_verdicts WHERE model_version='claude-sonnet-4-6' AND current=true")"
if [ "$_BV" -ge 1 ]; then
  pass "view bench_verdicts: returns current row for claude-sonnet-4-6"
else
  fail "view bench_verdicts: no current rows (count=$_BV)"
fi

# ── 8. import: idempotent (second run adds 0 rows) ───────────────────────────
_TMP="$(mktemp -d)"

cat > "$_TMP/run-a.ndjson" <<'NDJSON'
{"ts":1000,"model":"testm/m1","category":"_load","ctx":4096,"cold_load_s":1.0,"loaded":true,"load_rc":0,"load_err":""}
{"ts":1000,"model":"testm/m1","category":"coding","task":"t1","rep":1,"passed":true,"wall_s":1,"ttft_s":0.1,"tps":100,"tokens":100,"finish":"stop"}
{"ts":1001,"model":"testm/m1","category":"coding","task":"t1","rep":2,"passed":false,"wall_s":1,"ttft_s":0.1,"tps":100,"tokens":100,"finish":"stop"}
NDJSON

bash local/lineage.sh import "$_TMP/run-a.ndjson" >/dev/null 2>&1
_NI="$(pg_admin "SELECT count(*) FROM nodes WHERE kind='eval_result'")"
_EI="$(pg_admin "SELECT count(*) FROM edges WHERE label='produced'")"

bash local/lineage.sh import "$_TMP/run-a.ndjson" >/dev/null 2>&1
_NI2="$(pg_admin "SELECT count(*) FROM nodes WHERE kind='eval_result'")"
_EI2="$(pg_admin "SELECT count(*) FROM edges WHERE label='produced'")"

if [ "$_NI" = "$_NI2" ] && [ "$_EI" = "$_EI2" ]; then
  pass "import: idempotent (eval_result nodes=$_NI, produced edges=$_EI — unchanged after re-import)"
else
  fail "import: NOT idempotent (nodes $_NI→$_NI2, edges $_EI→$_EI2)"
fi

# ── 9. import: _load-only file adds no eval_result nodes ─────────────────────
_N_BEFORE="$(pg_admin "SELECT count(*) FROM nodes WHERE kind='eval_result'")"
cat > "$_TMP/load-only.ndjson" <<'NDJSON'
{"ts":9999,"model":"loadonly/m","category":"_load","ctx":4096,"cold_load_s":0.5,"loaded":true,"load_rc":0,"load_err":""}
NDJSON

bash local/lineage.sh import "$_TMP/load-only.ndjson" >/dev/null 2>&1
_N_AFTER="$(pg_admin "SELECT count(*) FROM nodes WHERE kind='eval_result'")"

if [ "$_N_BEFORE" = "$_N_AFTER" ]; then
  pass "import: _load rows skipped (eval_result count unchanged: $_N_BEFORE)"
else
  fail "import: _load rows created eval_result nodes (before=$_N_BEFORE after=$_N_AFTER)"
fi

# ── 10. import older then newer: supersession via invalidated_by ──────────────
cat > "$_TMP/run-b.ndjson" <<'NDJSON'
{"ts":2000,"model":"testm/m1","category":"_load","ctx":4096,"cold_load_s":1.0,"loaded":true,"load_rc":0,"load_err":""}
{"ts":2000,"model":"testm/m1","category":"coding","task":"t1","rep":1,"passed":true,"wall_s":1,"ttft_s":0.1,"tps":100,"tokens":100,"finish":"stop"}
{"ts":2001,"model":"testm/m1","category":"coding","task":"t1","rep":2,"passed":true,"wall_s":1,"ttft_s":0.1,"tps":100,"tokens":100,"finish":"stop"}
NDJSON

bash local/lineage.sh import "$_TMP/run-b.ndjson" >/dev/null 2>&1

_OLD_INV="$(pg_admin "SELECT count(*) FROM bench_verdicts WHERE model_version='testm/m1' AND category='coding' AND score='1/2' AND current=false")"
_NEW_CUR="$(pg_admin "SELECT count(*) FROM bench_verdicts WHERE model_version='testm/m1' AND category='coding' AND score='2/2' AND current=true")"

if [ "$_OLD_INV" = "1" ] && [ "$_NEW_CUR" = "1" ]; then
  pass "import: supersession — older verdict (1/2) invalidated, newer (2/2) current"
else
  fail "import: supersession — old_inv=$_OLD_INV (want 1), new_cur=$_NEW_CUR (want 1)"
fi

rm -rf "$_TMP"

# ── 11. lineage commit: provenance + gate verdict ─────────────────────────────
# Set up: new commit → new job → existing model (claude-sonnet-4-6 from test 2)
_TJOB="$(pg_admin "SELECT upsert_node('job','testjob-001','{\"title\":\"cli test\"}')")"
_TCOMMIT="$(pg_admin "SELECT upsert_node('commit','testcommit-001','{}')")"
pg_admin "SELECT add_edge($_TCOMMIT,$_TJOB,'produced_by','{}')" >/dev/null
pg_admin "SELECT add_edge($_TJOB,$_MV_ID,'ran_on','{}')" >/dev/null
# Insert gate.passed event in the job's event stream
pg_admin "INSERT INTO events (stream_name, position, type, data, metadata) VALUES ('job-testjob-001', 1, 'gate.passed', '{}', '{}')" >/dev/null

_OUT="$(bash local/lineage.sh commit testcommit-001 2>&1)"
if printf '%s' "$_OUT" | grep -q "testjob-001" \
    && printf '%s' "$_OUT" | grep -q "gate.passed"; then
  pass "lineage commit: returns job_id and gate verdict from events stream"
else
  fail "lineage commit: got: $(printf '%s' "$_OUT" | tr '\n' '|')"
fi

# ── 12. lineage model: outputs for a model ────────────────────────────────────
_MOUT="$(bash local/lineage.sh model "claude-sonnet-4-6" 2>&1)"
if printf '%s' "$_MOUT" | grep -q "Model: claude-sonnet-4-6" \
    && printf '%s' "$_MOUT" | grep -qE "(job|commit)"; then
  pass "lineage model: returns outputs for claude-sonnet-4-6"
else
  fail "lineage model: got: $(printf '%s' "$_MOUT" | tr '\n' '|')"
fi

# ── 13. lineage bench: current-only by default; --all includes superseded ─────
_B="$(bash local/lineage.sh bench 2>&1)"
_BA="$(bash local/lineage.sh bench --all 2>&1)"
if printf '%s' "$_B" | grep -q "2/2" \
    && ! printf '%s' "$_B" | grep -q "1/2" \
    && printf '%s' "$_BA" | grep -q "1/2" \
    && printf '%s' "$_BA" | grep -q "superseded"; then
  pass "lineage bench: current-only shows 2/2 not 1/2; --all shows superseded 1/2"
else
  fail "lineage bench: bench='$(printf '%s' "$_B" | tr '\n' '|')' all='$(printf '%s' "$_BA" | tr '\n' '|')'"
fi

echo ""
echo "pg_lineage_test: $N tests, $FAIL failed"
exit "$FAIL"
