#!/usr/bin/env bash
# Test for local/digest.sh — the model summary is routed through local/queue.sh submit (D-012),
# so all local work shares one serving chokepoint. Fixture: QUEUE_RUN_CMD stubs the model call
# (no a local server, no network); assert the stub's output lands in REPORT.md and the transient submit
# leaves no queue entry behind. digest reads the real repo's git/backlog read-only and writes the
# report to a temp path (DIGEST_REPORT). The llm.sh + deterministic fallbacks are exercised live
# elsewhere (NOTES 2026-06-06 digest entry).
set -euo pipefail

# hermetic like the gate (gate.sh exports AGENCY_PG_PORT=1): a reachable live PG must not
# flip the PG-down assertions — override only when a check stubs its own psql.
export AGENCY_PG_PORT="${AGENCY_PG_PORT:-1}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT

FAIL=0; N=0
pass() { N=$((N + 1)); echo "ok   $1"; }
fail() { N=$((N + 1)); FAIL=1; echo "FAIL $1"; }

# shellcheck disable=SC2016  # the stub body expands inside queue.sh at run time, not here
DIGEST_REPORT="$TD/REPORT.md" QUEUE_FILE="$TD/q.ndjson" QUEUE_OUT_DIR="$TD/qout" \
  QUEUE_RUN_CMD='echo DIGEST-VIA-QUEUE-OK' \
  "$HERE/local/digest.sh" >/dev/null 2>&1 || true

if grep -q 'DIGEST-VIA-QUEUE-OK' "$TD/REPORT.md" 2>/dev/null; then
  pass "digest routes the summary through queue.sh submit (stub output reaches REPORT.md)"
else
  fail "digest did not use the queue; REPORT head: $(sed -n '1,6p' "$TD/REPORT.md" 2>/dev/null | tr '\n' '|')"
fi

if [ ! -s "$TD/q.ndjson" ] || [ -z "$(jq -r 'select(.id=="digest") | .id' "$TD/q.ndjson" 2>/dev/null)" ]; then
  pass "digest's submit is transient (no leftover queue entry)"
else
  fail "digest left a queue entry: $(cat "$TD/q.ndjson")"
fi

# --- 3. PG down: REPORT.md renders without PG_TODAY_LINE (gate hermetic: AGENCY_PG_PORT=1) ----
# AGENCY_PG_PORT=1 (inherited from gate) → PG_AVAIL=0 → PG_TODAY_LINE="" → no crash, clean output.
DIGEST_REPORT="$TD/REPORT-pgdown.md" QUEUE_FILE="$TD/q2.ndjson" QUEUE_OUT_DIR="$TD/qout2" \
  QUEUE_RUN_CMD='echo PG-DOWN-OK' \
  "$HERE/local/digest.sh" >/dev/null 2>&1 || true
if grep -q 'PG-DOWN-OK' "$TD/REPORT-pgdown.md" 2>/dev/null \
     && ! grep -q 'PG today' "$TD/REPORT-pgdown.md" 2>/dev/null \
     && ! grep -q 'Lineage this week' "$TD/REPORT-pgdown.md" 2>/dev/null; then
  pass "digest PG down: REPORT renders normally, no PG_TODAY_LINE or lineage section"
else
  fail "digest PG down: $(sed -n '1,8p' "$TD/REPORT-pgdown.md" 2>/dev/null | tr '\n' '|')"
fi

# --- 4. PG up (mock psql): PG_TODAY_LINE appears in REPORT ----------------------------------------
mkdir -p "$TD/pgbin"
cat > "$TD/pgbin/psql" <<'MOCK'
#!/usr/bin/env bash
SQL="${3:-$(cat 2>/dev/null || true)}"
case "$SQL" in
  "SELECT 1") echo 1 ;;
  *"job.completed"*) printf 'gate.failed: 1\njob.completed: 3\n' ;;
esac
exit 0
MOCK
chmod +x "$TD/pgbin/psql"

DIGEST_REPORT="$TD/REPORT-pgup.md" QUEUE_FILE="$TD/q3.ndjson" QUEUE_OUT_DIR="$TD/qout3" \
  QUEUE_RUN_CMD='echo PG-UP-OK' \
  PATH="$TD/pgbin:$PATH" AGENCY_PG_PORT=5432 \
  "$HERE/local/digest.sh" >/dev/null 2>&1 || true
if grep -q 'PG today' "$TD/REPORT-pgup.md" 2>/dev/null \
     && grep -q 'job.completed: 3' "$TD/REPORT-pgup.md" 2>/dev/null; then
  pass "digest PG up (mock): PG_TODAY_LINE with events data appears in REPORT"
else
  fail "digest PG up: $(sed -n '1,10p' "$TD/REPORT-pgup.md" 2>/dev/null | tr '\n' '|')"
fi

# --- 5. PG up (mock with lineage queries): "Lineage this week" in REPORT ------
mkdir -p "$TD/pgbin5"
cat > "$TD/pgbin5/psql" <<'MOCK'
#!/usr/bin/env bash
SQL="${3:-$(cat 2>/dev/null || true)}"
case "$SQL" in
  "SELECT 1") echo 1 ;;
  *"count(DISTINCT"*) echo 3 ;;
  *"kind='commit'"*) echo 5 ;;
  *"kind='job'"*) echo 12 ;;
  *"passes_seen"*) printf '' ;;
  *"bench_verdicts"*) echo 0 ;;
  *"job.completed"*) printf 'job.completed: 3\n' ;;
esac
exit 0
MOCK
chmod +x "$TD/pgbin5/psql"

DIGEST_REPORT="$TD/REPORT-lineage.md" QUEUE_FILE="$TD/q5.ndjson" QUEUE_OUT_DIR="$TD/qout5" \
  QUEUE_RUN_CMD='echo LINEAGE-OK' \
  PATH="$TD/pgbin5:$PATH" AGENCY_PG_PORT=5432 \
  "$HERE/local/digest.sh" >/dev/null 2>&1 || true
if grep -q 'Lineage this week' "$TD/REPORT-lineage.md" 2>/dev/null \
     && grep -q 'LINEAGE-OK' "$TD/REPORT-lineage.md" 2>/dev/null; then
  pass "digest lineage section: appears in REPORT when PG up (mock)"
else
  fail "digest lineage section: $(sed -n '1,15p' "$TD/REPORT-lineage.md" 2>/dev/null | tr '\n' '|')"
fi

echo "---"
if [ "$FAIL" -eq 0 ]; then
  echo "digest_test: ALL $N checks passed"
else
  echo "digest_test: FAILURES present ($N checks run)"
fi
exit "$FAIL"
