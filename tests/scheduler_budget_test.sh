#!/usr/bin/env bash
# Tests for loop/scheduler.sh v1 monthly-budget pacing: the billing-mode switch, the spend
# ledger (record + per-day/per-month sums), and the pure pacing decision. Fixture-driven via the
# SCHED_NOW_EPOCH clock seam + an isolated STATE_DIR — NO claude, NO network, no real clock.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHED="$SELF_DIR/loop/scheduler.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"

FAIL=0
N=0
pass() { N=$((N + 1)); echo "ok   $1"; }
fail() { N=$((N + 1)); FAIL=1; echo "FAIL $1"; }

# Fixed epochs (local time): around the 2026-06-15 billing cutover.
E_PRE="$(date -d '2026-06-07 12:00:00' +%s)"     # window mode (before cutover)
E_CUT="$(date -d '2026-06-15 00:00:00' +%s)"     # exactly the cutover -> budget mode
E_A="$(date -d '2026-06-20 10:00:00' +%s)"       # budget era, day A
E_B="$(date -d '2026-06-21 10:00:00' +%s)"       # day B, same month
E_NEXT="$(date -d '2026-07-02 10:00:00' +%s)"    # next month

# Run a scheduler subcommand at a pinned "now", isolated state dir, capturing rc + stdout.
OUT=""; RC=0
sched() { local epoch="$1"; shift
  set +e
  OUT="$(STATE_DIR="$STATE" SCHED_NOW_EPOCH="$epoch" "$SCHED" "$@" 2>/dev/null)"
  RC=$?
  set -e
}

num_eq() { awk -v a="$1" -v b="$2" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<1e-9)}'; }
expect_eq()  { if [ "$1" = "$2" ];        then pass "$3"; else fail "$3 (got '$1' want '$2')"; fi; }
expect_num() { if num_eq "$1" "$2";       then pass "$3"; else fail "$3 (got '$1' want '$2')"; fi; }
# expect_action want_rc want_action name  -- asserts the last `budget` call's rc + ACTION= field.
expect_action() {
  if [ "$RC" = "$1" ] && printf '%s' "$OUT" | grep -q "ACTION=$2"; then
    pass "$3"
  else
    fail "$3 (rc=$RC want $1, out='$OUT')"
  fi
}

# --- 1. billing mode switch -------------------------------------------------
sched "$E_PRE" mode; expect_eq "$OUT" window "mode pre-cutover -> window"
sched "$E_CUT" mode; expect_eq "$OUT" budget "mode at cutover -> budget"
sched "$E_A"   mode; expect_eq "$OUT" budget "mode post-cutover -> budget"

# --- 2. spend ledger: record + per-day / per-month sums ---------------------
sched "$E_A" spend add 1.50 probe
sched "$E_A" spend add 2.00 burst
sched "$E_A" spend today; expect_num "$OUT" 3.5 "today sum = 3.50 (two same-day rows)"
sched "$E_A" spend month; expect_num "$OUT" 3.5 "month sum = 3.50"

sched "$E_B" spend add 1.00 burst            # later day, same month
sched "$E_B" spend today; expect_num "$OUT" 1.0 "today resets on a new day (1.00)"
sched "$E_B" spend month; expect_num "$OUT" 4.5 "month accumulates across days (4.50)"

sched "$E_NEXT" spend add 5.00 burst         # next month
sched "$E_NEXT" spend month; expect_num "$OUT" 5.0 "month resets on a new month (5.00)"
# June total (3.50 day A + 1.00 day B = 4.50) is unaffected by the July 5.00 spend.
sched "$E_A"    spend month; expect_num "$OUT" 4.5 "prior month unchanged by later-month spend"

# --- 3. record_spend ignores empty / zero / non-numeric ---------------------
Z="$TMP/zstate"
zsched() { set +e; OUT="$(STATE_DIR="$Z" SCHED_NOW_EPOCH="$E_A" "$SCHED" "$@" 2>/dev/null)"; RC=$?; set -e; }
zsched spend add 0 probe
zsched spend add "" probe
zsched spend add abc probe
zsched spend month; expect_num "$OUT" 0 "zero/empty/non-numeric amounts are not recorded"

# --- 4. pacing decision (pure): BURST / SLEEP_DAY / SLEEP_MONTH --------------
# budget $10 over 10 days -> daily allowance $1.00.
B="$TMP/bstate"
bsched() { local epoch="$1"; shift
  set +e
  OUT="$(STATE_DIR="$B" SCHED_NOW_EPOCH="$epoch" MONTHLY_BUDGET_USD=10 BUDGET_DAY_DIVISOR=10 "$SCHED" "$@" 2>/dev/null)"
  RC=$?
  set -e
}

bsched "$E_A" budget
expect_action 0 BURST "empty ledger -> BURST (rc 0)"

bsched "$E_A" spend add 1.00 burst   # today hits the $1.00 daily pace
bsched "$E_A" budget
expect_action 30 SLEEP_DAY "today >= daily allowance -> SLEEP_DAY (rc 30)"

bsched "$E_B" budget                 # new day -> today resets, month so far only $1.00
expect_action 0 BURST "new day under monthly cap -> BURST again"

# Drive the MONTH total to the $10 cap via earlier-in-month days; today (E_B) itself stays $0.
M="$TMP/mstate"
for d in 02 03 04 05 06 07 08 09; do
  e="$(date -d "2026-06-$d 09:00:00" +%s)"
  STATE_DIR="$M" SCHED_NOW_EPOCH="$e" MONTHLY_BUDGET_USD=10 BUDGET_DAY_DIVISOR=10 "$SCHED" spend add 1.50 burst >/dev/null
done
set +e
OUT="$(STATE_DIR="$M" SCHED_NOW_EPOCH="$E_B" MONTHLY_BUDGET_USD=10 BUDGET_DAY_DIVISOR=10 "$SCHED" budget 2>/dev/null)"; RC=$?
set -e
expect_action 31 SLEEP_MONTH "month spend >= monthly budget -> SLEEP_MONTH (rc 31), today still zero"

echo "---"
if [ "$FAIL" -ne 0 ]; then
  echo "scheduler_budget_test: FAIL ($N checks)"; exit 1
fi
echo "scheduler_budget_test: OK ($N checks)"
