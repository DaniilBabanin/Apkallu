#!/usr/bin/env bash
# Tests for pg_node / pg_edge (lib/pg.sh lineage writers).
#
# 1. Hermetic: AGENCY_PG_PORT=1 → pg_node/pg_edge are no-ops (PG_AVAIL=0)
# 2. pg_fixture: simulate commit lineage → verify expected nodes+edges in DB
#    and that commit_provenance view resolves the commit
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

FAIL=0; N=0
pass() { N=$(( N + 1 )); echo "ok   $1"; }
fail() { N=$(( N + 1 )); FAIL=1; echo "FAIL $1"; }

# ── 1. Hermetic: PG down → no-op ─────────────────────────────────────────────
# Subshells isolate env changes; disable SC2030/SC2031 (intentional local export).
# shellcheck disable=SC2030,SC2031
if (
  export AGENCY_PG_PORT=1
  unset CLAUDE_CODE_HOST_HTTP_PROXY_PORT 2>/dev/null || true
  # shellcheck source=lib/pg.sh
  . lib/pg.sh
  result="$(pg_node 'commit' 'abc123' '{}')"
  [ "${PG_AVAIL}" = "0" ] && [ -z "$result" ]
); then
  pass "hermetic: pg_node no-op when PG_AVAIL=0"
else
  fail "hermetic: pg_node should be no-op when PG_AVAIL=0"
fi

# shellcheck disable=SC2030,SC2031
if (
  export AGENCY_PG_PORT=1
  unset CLAUDE_CODE_HOST_HTTP_PROXY_PORT 2>/dev/null || true
  . lib/pg.sh
  result="$(pg_edge '1' '2' 'ran_on')"
  [ "${PG_AVAIL}" = "0" ] && [ -z "$result" ]
); then
  pass "hermetic: pg_edge no-op when PG_AVAIL=0"
else
  fail "hermetic: pg_edge should be no-op when PG_AVAIL=0"
fi

# ── 2. pg_fixture: simulate commit lineage ────────────────────────────────────
# shellcheck source=tests/lib/pg_fixture.sh
. tests/lib/pg_fixture.sh

unset CLAUDE_CODE_HOST_HTTP_PROXY_PORT 2>/dev/null || true

trap 'pg_fixture_teardown' EXIT

if [ -z "${AGENCY_PG_HOST:-}" ]; then
  echo "# pg_writers_test: fixture unavailable — fixture tests skipped"
  echo ""
  echo "pg_writers_test: $N tests, $FAIL failed"
  exit "$FAIL"
fi

# Source lib/pg.sh with fixture env vars so PG_AVAIL=1
# shellcheck source=lib/pg.sh
. lib/pg.sh

if [ "${PG_AVAIL}" != "1" ]; then
  echo "# pg_writers_test: lib/pg.sh PG_AVAIL=0 despite fixture — fixture tests skipped"
  echo ""
  echo "pg_writers_test: $N tests, $FAIL failed"
  exit "$FAIL"
fi

# Simulate what run.sh does after a successful gate+commit
_sha="deadbeef1234567890abcdef1234567890abcdef"
_job_key="test-job-writers-001"
_model_key="claude-sonnet-4-6"
_prompt_sha="aabb$(printf '%.0s0' {1..60})"
_profile="online"
_machine="testbox"

_nid_commit="$(  pg_node 'commit'          "$_sha"        '{"subject":"test commit"}' || true)"
_nid_job="$(     pg_node 'job'             "$_job_key"    '{"title":"test lineage task"}' || true)"
_nid_model="$(   pg_node 'model_version'   "$_model_key"  '{}' || true)"
_nid_prompt="$(  pg_node 'prompt'          "$_prompt_sha" '{}' || true)"
_nid_profile="$( pg_node 'sandbox_profile' "$_profile"    '{}' || true)"
_nid_machine="$( pg_node 'machine'         "$_machine"    '{}' || true)"

if [ -n "$_nid_commit" ];  then pass "pg_node: commit returned id=$_nid_commit";         else fail "pg_node: commit returned empty id"; fi
if [ -n "$_nid_job" ];     then pass "pg_node: job returned id=$_nid_job";               else fail "pg_node: job returned empty id"; fi
if [ -n "$_nid_model" ];   then pass "pg_node: model_version returned id=$_nid_model";   else fail "pg_node: model_version returned empty id"; fi
if [ -n "$_nid_prompt" ];  then pass "pg_node: prompt returned id=$_nid_prompt";         else fail "pg_node: prompt returned empty id"; fi
if [ -n "$_nid_profile" ]; then pass "pg_node: sandbox_profile returned id=$_nid_profile"; else fail "pg_node: sandbox_profile returned empty id"; fi
if [ -n "$_nid_machine" ]; then pass "pg_node: machine returned id=$_nid_machine";       else fail "pg_node: machine returned empty id"; fi

# Add edges (same guard pattern as run.sh)
if [ -n "$_nid_commit" ]  && [ -n "$_nid_job" ];     then pg_edge "$_nid_commit" "$_nid_job"     'produced_by'   || true; fi
if [ -n "$_nid_job" ]     && [ -n "$_nid_model" ];   then pg_edge "$_nid_job"    "$_nid_model"   'ran_on'        || true; fi
if [ -n "$_nid_job" ]     && [ -n "$_nid_prompt" ];  then pg_edge "$_nid_job"    "$_nid_prompt"  'used_prompt'   || true; fi
if [ -n "$_nid_job" ]     && [ -n "$_nid_profile" ]; then pg_edge "$_nid_job"    "$_nid_profile" 'under_profile' || true; fi
if [ -n "$_nid_job" ]     && [ -n "$_nid_machine" ]; then pg_edge "$_nid_job"    "$_nid_machine" 'on_machine'    || true; fi

# Verify all 6 node kinds exist
_node_count="$(pg_admin "SELECT count(*) FROM nodes WHERE kind IN ('commit','job','model_version','prompt','sandbox_profile','machine')")"
if [ "${_node_count:-0}" -ge 6 ]; then
  pass "pg_fixture: all 6 node kinds present (count=$_node_count)"
else
  fail "pg_fixture: expected >=6 nodes, got ${_node_count:-0}"
fi

# Verify all 5 edge labels exist
_edge_count="$(pg_admin "SELECT count(*) FROM edges WHERE label IN ('produced_by','ran_on','used_prompt','under_profile','on_machine')")"
if [ "${_edge_count:-0}" -ge 5 ]; then
  pass "pg_fixture: all 5 edge labels present (count=$_edge_count)"
else
  fail "pg_fixture: expected >=5 edges, got ${_edge_count:-0}"
fi

# Verify commit_provenance resolves the simulated commit
_cp="$(pg_admin "SELECT count(*) FROM commit_provenance WHERE commit_sha='$_sha'")"
if [ "${_cp:-0}" -ge 1 ]; then
  pass "pg_fixture: commit_provenance resolves simulated commit (count=$_cp)"
else
  fail "pg_fixture: commit_provenance shows no row for sha=$_sha"
fi

# Verify pg_node is idempotent (double-insert same natural_key)
_nid2="$(pg_node 'commit' "$_sha" '{"subject":"duplicate"}' || true)"
_dedup="$(pg_admin "SELECT count(*) FROM nodes WHERE kind='commit' AND natural_key='$_sha'")"
if [ "$_nid2" = "$_nid_commit" ] && [ "$_dedup" = "1" ]; then
  pass "pg_node: idempotent (second call same id, count=1)"
else
  fail "pg_node: idempotency failed (id1=$_nid_commit id2=$_nid2 count=$_dedup)"
fi

echo ""
echo "pg_writers_test: $N tests, $FAIL failed"
exit "$FAIL"
