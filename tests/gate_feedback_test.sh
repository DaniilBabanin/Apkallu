#!/usr/bin/env bash
# Tests for loop/run.sh's gate-failure feedback (Plan 2): the previous gate log's tail is routed
# into the next attempt's prompt instead of being rediscovered cold. run.sh is sourced via its
# RUN_SH_LIB=1 seam (pure helpers, no loop), and every fixture lives in a throwaway dir — no
# claude, no network, the live repo's .cascade/logs never touched.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
N=0
pass() { N=$((N + 1)); echo "ok   $1"; }
fail() { N=$((N + 1)); FAIL=1; echo "FAIL $1"; }

# Load the pure helpers (latest_gate_failure_tail, gate_fail_block) without running the loop.
# shellcheck source=/dev/null
RUN_SH_LIB=1 source "$SELF_DIR/loop/run.sh"

# A realistic FAILED gate log — shape mirrors run_gate_logged's tee output; last line is the verdict.
mkfail() { # dir name
  local d="$1" f="$2"
  cat > "$d/$f" <<'EOF'
[gate] shellcheck (severity=style) on 21 file(s)...
[gate] shellcheck: OK
[gate] running 18 test script(s)...
[gate]   -> tests/queue_test.sh
[gate] test FAIL: tests/queue_test.sh
[gate] RESULT: FAIL
EOF
}

# A PASSED gate log — last line is the green verdict.
mkpass() { # dir name
  local d="$1" f="$2"
  cat > "$d/$f" <<'EOF'
[gate] shellcheck (severity=style) on 21 file(s)...
[gate] shellcheck: OK
[gate] running 18 test script(s)...
[gate] RESULT: PASS
EOF
}

# --- 1. no log dir at all -> empty (back-compat: the prompt is unchanged) ----
D="$TMP/none"   # does not exist
if [ -z "$(gate_fail_block "$D")" ]; then pass "no log dir -> gate_fail_block empty"; else fail "no log dir -> gate_fail_block empty"; fi
if [ -z "$(latest_gate_failure_tail "$D")" ]; then pass "no log dir -> tail empty"; else fail "no log dir -> tail empty"; fi

# --- 2. dir exists but holds no gate-*.log -> empty -------------------------
D="$TMP/empty"; mkdir -p "$D"; : > "$D/unrelated.txt"
if [ -z "$(gate_fail_block "$D")" ]; then pass "empty dir -> empty"; else fail "empty dir -> empty"; fi

# --- 3. a single FAIL log -> routed: intro + the failing tail line ----------
D="$TMP/fail"; mkdir -p "$D"; mkfail "$D" "gate-20260623-100000-1.log"
BLK="$(gate_fail_block "$D")"
if [ -n "$BLK" ]; then pass "FAIL log -> block non-empty"; else fail "FAIL log -> block non-empty"; fi
if printf '%s' "$BLK" | grep -q 'failed ./gate.sh'; then pass "FAIL log -> block carries the intro"; else fail "FAIL log -> block carries the intro"; fi
if printf '%s' "$BLK" | grep -q 'test FAIL: tests/queue_test.sh'; then pass "FAIL log -> the tail reaches the block"; else fail "FAIL log -> the tail reaches the block"; fi

# --- 4. latest log PASSED -> empty (a closed task must not leak into the next) -
D="$TMP/pass"; mkdir -p "$D"; mkpass "$D" "gate-20260623-100000-1.log"
if [ -z "$(gate_fail_block "$D")" ]; then pass "PASS log -> empty"; else fail "PASS log -> empty"; fi

# --- 5. two logs: only the LATEST (lexically-last filename) decides ----------
D="$TMP/two_fail_latest"; mkdir -p "$D"
mkpass "$D" "gate-20260623-100000-1.log"     # older, passed
mkfail "$D" "gate-20260623-110000-2.log"     # newer, failed -> routes
if [ -n "$(gate_fail_block "$D")" ]; then pass "newer FAIL after older PASS -> routes"; else fail "newer FAIL after older PASS -> routes"; fi

D="$TMP/two_pass_latest"; mkdir -p "$D"
mkfail "$D" "gate-20260623-100000-1.log"     # older, failed
mkpass "$D" "gate-20260623-110000-2.log"     # newer, passed -> nothing to route
if [ -z "$(gate_fail_block "$D")" ]; then pass "newer PASS after older FAIL -> empty"; else fail "newer PASS after older FAIL -> empty"; fi

# --- 6. capping: the tail is bounded to GATE_TAIL_LINES and keeps the LAST lines -
D="$TMP/cap"; mkdir -p "$D"
{
  for ((i = 1; i <= 19; i++)); do printf 'line-%02d\n' "$i"; done
  echo "[gate] RESULT: FAIL"
} > "$D/gate-20260623-120000-1.log"
TAILOUT="$(GATE_TAIL_LINES=5 latest_gate_failure_tail "$D")"
LC="$(printf '%s\n' "$TAILOUT" | wc -l | tr -d ' ')"
if [ "$LC" = "5" ]; then pass "cap=5 -> exactly 5 lines"; else fail "cap=5 -> exactly 5 lines (got $LC)"; fi
if printf '%s' "$TAILOUT" | grep -q 'RESULT: FAIL'; then pass "cap keeps the verdict (last line)"; else fail "cap keeps the verdict (last line)"; fi
if printf '%s' "$TAILOUT" | grep -q 'line-19'; then pass "cap keeps the recent tail (line-19)"; else fail "cap keeps the recent tail (line-19)"; fi
if printf '%s' "$TAILOUT" | grep -q 'line-01'; then fail "cap must drop the head (line-01 leaked)"; else pass "cap drops the head (no line-01)"; fi

echo "---"
if [ "$FAIL" -ne 0 ]; then
  echo "gate_feedback_test: FAIL ($N checks)"; exit 1
fi
echo "gate_feedback_test: OK ($N checks)"
