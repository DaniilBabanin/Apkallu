#!/usr/bin/env bash
# scheduler.sh — quota scheduler v1 (ARCHITECTURE.md principle 4: idle quota is waste).
#
# Two billing regimes, switched by BILLING_CUTOVER (default 2026-06-15 — the date headless
# `claude -p` / the Agent SDK stops drawing the interactive ~5h windows and starts drawing a
# SEPARATE monthly credit, $100/mo on Max 5x; re-verified against provider docs 2026-06-06).
# The binding constraint flips with it, so the scheduler does too:
#
#   WINDOW mode (before the cutover — pre-June-15 compat, the v0 behavior, unchanged):
#     PROBE  -> OK: burst · CAPPED: sleep until the reset epoch · ERROR: retry/give up.
#     The constraint is window freshness; the sleep-until-reset logic is correct here only.
#
#   BUDGET mode (on/after the cutover — the v1 addition):
#     PROBE is demoted to a HEALTH CHECK (claude installed/authed/reachable). Capacity is no
#     longer a 5h window but a monthly dollar credit, so each cycle PACES against it:
#       month spend >= MONTHLY_BUDGET_USD  -> sleep toward the month reset
#       today spend >= daily allowance     -> sleep toward the next day (pace, don't binge)
#       otherwise                          -> burst, then bank the burst's real cost
#     Spend accounting sums total_cost_usd from the probe + the burst (run.sh writes each
#     iteration's cost via SPEND_COST_FILE) into the SPEND_LEDGER; LOCAL=1 runs are excluded
#     (their cost is fictional CLI math). A CAPPED probe in budget mode (monthly credit
#     exhausted) is still honored AND its raw output is appended to cap-events.log — the
#     "limit reached|<epoch>" parse is UNVERIFIED for this new billing path (it was guessed for
#     the window path too), so the first real cap event is captured for a human to confirm/fix.
#
# Both modes: a burst that escalated (new D-NNN) does NOT stop the scheduler — the loop pauses
# the stuck task itself (run.sh skips tasks quoted in an open decision), so the next burst works
# the rest of the backlog; the operator is notified, never a blocker. While capped/paced,
# local-tier work (refresh REPORT.md via local/digest.sh) runs once per event. Stops on: no
# runnable task (backlog empty, or every open task paused by an open decision) ·
# MAX_WALL_MINUTES · PROBE_ERR_MAX consecutive probe errors. flock prevents a second scheduler;
# an already-running loop/run.sh is waited out, never raced.
#
# Subcommands (the spend/budget/mode ones are PURE — no claude, no ntfy — and back tests/):
#   (none) | run   supervise forever (or MAX_WALL_MINUTES).
#   probe          one probe, print "STATE=<OK|CAPPED|ERROR> RESET=<epoch|>", exit 0/20/21.
#   mode           print "window" or "budget" for now (honors SCHED_NOW_EPOCH), exit 0.
#   spend add A [S]   record amount A (source S) in the ledger · spend today|month  print the sum.
#   budget         print MODE/ACTION/TODAY/MONTH/DAILY/BUDGET, exit 0 burst · 30 day · 31 month.
#   status         human-readable budget status block.
#   -h | --help    usage.
#
# Env (all optional):
#   BURST_RUNS        iterations per burst (default 3; keep >= 2 so LoopGuard can trip in-burst)
#   MAX_WALL_MINUTES  total scheduler budget, 0 = unbounded (default 0)
#   CAP_RETRY_SECS    re-probe interval when capped without a parsable reset (default 1800)
#   CAP_SLEEP_MAX     hard cap on any single sleep, guards bad epoch parses (default 21600).
#                     Budget-mode day/month sleeps are also chunked to this and re-derived each
#                     loop, so an approximate next-day/next-month epoch is self-correcting.
#   BURST_PAUSE_SECS  pause between consecutive bursts (default 30)
#   ERR_RETRY_SECS    pause after a probe error (default 300)
#   PROBE_ERR_MAX     consecutive probe errors before giving up (default 3)
#   PROBE_CMD         override the probe command (testing / local-claude experiments)
#   NTFY_TOPIC        push state transitions to ntfy.sh/<topic>
#   STATE_DIR         lock + log dir (default ${XDG_STATE_HOME:-~/.local/state}/agency-scheduler)
#   --- budget mode (v1) ---
#   BILLING_CUTOVER    date headless billing moves to the monthly credit (default 2026-06-15)
#   MONTHLY_BUDGET_USD monthly Agent-SDK credit to pace against (default 100 — Max 5x)
#   BUDGET_DAY_DIVISOR spread the month over N days; daily allowance = budget/N (default 30)
#   SPEND_LEDGER       spend file (default $STATE_DIR/spend.tsv): TAB <iso> <YYYY-MM-DD> <usd> <src>
#   SCHED_NOW_EPOCH    override "now" (unix epoch) for deterministic tests (default `date +%s`)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

# PG glue (best-effort: PG_AVAIL=0 when PG is down — all pg_* calls then no-op)
# shellcheck source=lib/pg.sh
source "$REPO_DIR/lib/pg.sh"

BURST_RUNS="${BURST_RUNS:-3}"
MAX_WALL_MINUTES="${MAX_WALL_MINUTES:-0}"
CAP_RETRY_SECS="${CAP_RETRY_SECS:-1800}"
CAP_SLEEP_MAX="${CAP_SLEEP_MAX:-21600}"
BURST_PAUSE_SECS="${BURST_PAUSE_SECS:-30}"
ERR_RETRY_SECS="${ERR_RETRY_SECS:-300}"
PROBE_ERR_MAX="${PROBE_ERR_MAX:-3}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agency-scheduler}"
LOG_FILE="$STATE_DIR/scheduler.log"

# --- budget mode (v1) --------------------------------------------------------
BILLING_CUTOVER="${BILLING_CUTOVER:-2026-06-15}"
MONTHLY_BUDGET_USD="${MONTHLY_BUDGET_USD:-100}"
BUDGET_DAY_DIVISOR="${BUDGET_DAY_DIVISOR:-30}"
SPEND_LEDGER="${SPEND_LEDGER:-$STATE_DIR/spend.tsv}"
CAP_EVENTS_FILE="$STATE_DIR/cap-events.log"

QUOTA_STATE="ERROR"
RESET_EPOCH=""
PROBE_COST=""
PROBE_RAW=""
SCHED_MODE="window"

# Print the header (lines 2..the first `set -` line) so help stays correct as the header grows.
usage() { sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --- clock seam (SCHED_NOW_EPOCH override keeps budget/date logic test-deterministic) --------
now_epoch() { printf '%s' "${SCHED_NOW_EPOCH:-$(date +%s)}"; }
now_iso()   { date -d "@$(now_epoch)" -Iseconds 2>/dev/null || date -Iseconds; }
now_day()   { date -d "@$(now_epoch)" +%F 2>/dev/null || date +%F; }
now_month() { date -d "@$(now_epoch)" +%Y-%m 2>/dev/null || date +%Y-%m; }

# Which billing regime is "now" in? window (pre-cutover compat) or budget (cutover and after).
billing_mode() {
  local cut
  cut="$(date -d "$BILLING_CUTOVER 00:00:00" +%s 2>/dev/null || echo 0)"
  if [ "$(now_epoch)" -ge "$cut" ]; then echo budget; else echo window; fi
}

# --- spend accounting --------------------------------------------------------
# Append one ledger line. Ignores empty/non-numeric/zero amounts so a missing or error probe
# cost is a no-op rather than a 0-row. The ledger is the sole source of truth for pacing.
record_spend() {
  local amt="$1" src="${2:-manual}"
  [ -n "$amt" ] || return 0
  [[ "$amt" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
  awk -v a="$amt" 'BEGIN{exit !(a+0 > 0)}' || return 0
  mkdir -p "$(dirname "$SPEND_LEDGER")"
  printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "$(now_day)" "$amt" "$src" >> "$SPEND_LEDGER"
  # Mirror to PG (best-effort — TSV is the source of truth; PG down = silent skip).
  pg_append_event "spend-$(now_month)" "spend.recorded" \
    "{\"amount\":\"${amt}\",\"source\":\"${src}\",\"day\":\"$(now_day)\"}" || true
}

# Sum the USD column for ledger rows whose date column starts with PREFIX (a day or a month).
spent_since() {
  local prefix="$1"
  if [ -f "$SPEND_LEDGER" ]; then
    awk -F'\t' -v p="$prefix" 'index($2,p)==1 { s+=$3 } END { printf "%.6f", s+0 }' "$SPEND_LEDGER"
  else
    printf '0.000000'
  fi
}
spent_today() { spent_since "$(now_day)"; }
spent_month() { spent_since "$(now_month)"; }
daily_allowance() { awk -v b="$MONTHLY_BUDGET_USD" -v d="$BUDGET_DAY_DIVISOR" 'BEGIN{printf "%.6f", (d+0>0)? b/d : b}'; }

# Pure pacing decision from the ledger + budget knobs. Month gate is checked before the day gate.
budget_action() {
  local today month daily
  month="$(spent_month)"; today="$(spent_today)"; daily="$(daily_allowance)"
  if awk -v m="$month" -v b="$MONTHLY_BUDGET_USD" 'BEGIN{exit !(m+0 >= b+0)}'; then echo SLEEP_MONTH; return 0; fi
  if awk -v t="$today" -v d="$daily" 'BEGIN{exit !(t+0 >= d+0)}'; then echo SLEEP_DAY; return 0; fi
  echo BURST
}

# Seconds from now to the next local midnight / first-of-next-month (approximate by design — the
# caller chunks to CAP_SLEEP_MAX and re-derives each loop, so an off-by-a-bit epoch self-corrects).
secs_until_next_day() {
  local now nxt
  now="$(now_epoch)"
  nxt="$(date -d "$(now_day) +1 day 00:00:00" +%s 2>/dev/null || echo $((now + 3600)))"
  echo $(( nxt > now ? nxt - now : 3600 ))
}
secs_until_next_month() {
  local now first nxt
  now="$(now_epoch)"
  first="$(date -d "$(now_day) +1 month" +%Y-%m-01 2>/dev/null || echo '')"
  if [ -n "$first" ]; then
    nxt="$(date -d "$first 00:00:00" +%s 2>/dev/null || echo $((now + 86400)))"
  else
    nxt=$((now + 86400))
  fi
  echo $(( nxt > now ? nxt - now : 86400 ))
}

# Append the raw probe output of a cap event for later inspection. The limit-output FORMAT is
# unverified (window AND budget paths) — this captures ground truth to fix the parser against.
capture_cap_event() {
  mkdir -p "$STATE_DIR"
  {
    printf '\n=== cap event %s (mode=%s reset_epoch=%s) ===\n' "$(now_iso)" "$SCHED_MODE" "${RESET_EPOCH:-}"
    printf '%s\n' "$PROBE_RAW"
  } >> "$CAP_EVENTS_FILE"
  log "cap event raw output captured to $CAP_EVENTS_FILE — VERIFY the real limit format vs the parser."
}

budget_status() {
  SCHED_MODE="$(billing_mode)"
  printf 'billing mode : %s (cutover %s, now %s)\n' "$SCHED_MODE" "$BILLING_CUTOVER" "$(now_day)"
  printf 'monthly cap  : $%s  (daily pace $%s over %s days)\n' "$MONTHLY_BUDGET_USD" "$(daily_allowance)" "$BUDGET_DAY_DIVISOR"
  printf 'spent today  : $%s\n' "$(spent_today)"
  printf 'spent month  : $%s\n' "$(spent_month)"
  printf 'next action  : %s\n' "$(budget_action)"
}

log() { printf '%s %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG_FILE"; }

notify() {
  [ -n "${NTFY_TOPIC:-}" ] || return 0
  curl -s -o /dev/null --max-time 10 -d "$1" "https://ntfy.sh/${NTFY_TOPIC}" || true
}

# A task quoted (`> - [ ] …`) in an OPEN (blank **Answer:**) D-entry is PAUSED — run.sh's
# next_task skips it, so bursting on a backlog of only-paused tasks would just burn probes.
# Same awk convention as loop/run.sh paused_tasks / local/decide.sh open_decisions.
paused_tasks() {
  awk '
    function flush() { if (id != "" && ans !~ /[^[:space:]]/) printf "%s", buf; id=""; ans=""; inans=0; buf="" }
    /^## D-[0-9]+ / { flush(); id=$2; next }
    id == ""             { next }
    /^---[[:space:]]*$/  { flush(); next }
    /^\*\*Answer:\*\*/ { inans=1; t=$0; sub(/^\*\*Answer:\*\*/, "", t); ans=ans t; next }
    inans { ans = ans $0; next }
    /^> - \[ \] / { l=$0; sub(/^> /, "", l); buf = buf l "\n" }
    END { flush() }
  ' director/DECISIONS.md 2>/dev/null || true
}

# Runnable = an open backlog task that is not paused by an open decision.
have_task() {
  grep '^- \[ \]' backlog.md 2>/dev/null | grep -vxF -f <(paused_tasks) | grep -qm1 .
}

decisions_count() { grep -c '^## D-' director/DECISIONS.md 2>/dev/null || true; }

# --- probe -------------------------------------------------------------------
# Cheapest reliable signal for "is the window capped": one tool-less, single-turn claude call.
# A capped window errors out without burning quota; a fresh one costs a trivial ping.
run_probe_cmd() {
  if [ -n "${PROBE_CMD:-}" ]; then
    bash -c "$PROBE_CMD" 2>&1
  elif command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM 120 claude -p 'Reply with exactly: pong' \
      --max-turns 1 --output-format json 2>&1
  else
    claude -p 'Reply with exactly: pong' --max-turns 1 --output-format json 2>&1
  fi
}

# Sets QUOTA_STATE / RESET_EPOCH / PROBE_COST. Order matters: the capped regex is checked
# FIRST so a half-garbled limit message can never be misread as a healthy window.
probe() {
  QUOTA_STATE="ERROR"; RESET_EPOCH=""; PROBE_COST=""; PROBE_RAW=""
  local out rc
  set +e
  out="$(run_probe_cmd)"
  rc=$?
  set -e
  PROBE_RAW="$out"
  if printf '%s' "$out" | grep -qiE '(usage|rate|5-hour|weekly)?[ -]*limit reached'; then
    QUOTA_STATE="CAPPED"
    # CLI convention seen in the wild: "...limit reached|<unix-epoch-of-reset>".
    RESET_EPOCH="$(printf '%s' "$out" \
      | grep -oiE 'limit reached\|[0-9]{9,12}' | grep -oE '[0-9]+' | head -1 || true)"
    return 0
  fi
  if [ "$rc" -eq 0 ] && command -v jq >/dev/null 2>&1; then
    local is_err
    # NB: not `.is_error // empty` — jq's // treats false as missing and would drop it.
    is_err="$(printf '%s' "$out" | jq -r '.is_error | tostring' 2>/dev/null || true)"
    if [ "$is_err" = "false" ]; then
      QUOTA_STATE="OK"
      PROBE_COST="$(printf '%s' "$out" | jq -r '.total_cost_usd // empty' 2>/dev/null || true)"
      return 0
    fi
  fi
  # rc!=0 without a limit message, unparsable JSON, or no jq -> ERROR (fail safe: no burst).
}

# --- local tier while capped ---------------------------------------------------
# Summarization-only work costs zero quota: refresh the director digest on the GPU.
local_tier_work() {
  if [ -x local/digest.sh ]; then
    log "capped: running local-tier digest refresh"
    local/digest.sh || true
  fi
}

# --- supervise ----------------------------------------------------------------
main_run() {
  mkdir -p "$STATE_DIR"
  exec 9>"$STATE_DIR/lock"
  if ! flock -n 9; then
    echo "[scheduler] another scheduler holds $STATE_DIR/lock — exiting." >&2
    exit 75
  fi

  local deadline=0 err_streak=0 cap_handled="" budget_handled="" now sleep_secs d_before d_after
  local action reason bc burst_cost_file
  if [ "$MAX_WALL_MINUTES" -gt 0 ]; then
    deadline=$(( $(date +%s) + MAX_WALL_MINUTES * 60 ))
  fi
  SCHED_MODE="$(billing_mode)"
  log "scheduler start (burst=$BURST_RUNS wall=${MAX_WALL_MINUTES}min mode=$SCHED_MODE budget=\$$MONTHLY_BUDGET_USD cutover=$BILLING_CUTOVER)"

  while :; do
    now="$(date +%s)"
    if [ "$deadline" -gt 0 ] && [ "$now" -ge "$deadline" ]; then
      log "wall budget exhausted — stopping."
      break
    fi
    if ! have_task; then
      log "no runnable task (backlog empty or all open tasks paused) — stopping."
      notify "agency scheduler: no runnable task, stopping"
      break
    fi
    # Match only real interpreter invocations (`bash …/loop/run.sh`), not any cmdline that
    # merely mentions the path (`vim loop/run.sh`, `tail -f …/loop/run.sh`).
    if pgrep -f '(^|/)bash [^ ]*loop/run\.sh( |$)' >/dev/null 2>&1; then
      log "a loop/run.sh is already running — waiting, not racing it."
      sleep 300
      continue
    fi

    SCHED_MODE="$(billing_mode)"
    probe
    case "$QUOTA_STATE" in
      OK)
        err_streak=0; cap_handled=""
        # Spend accounting: the probe cost is real (cloud) — bank it. Then, in budget mode only,
        # consult the monthly-credit pacing gate before deciding to burst.
        record_spend "$PROBE_COST" probe
        action="BURST"
        if [ "$SCHED_MODE" = "budget" ]; then action="$(budget_action)"; fi
        if [ "$action" = "SLEEP_DAY" ] || [ "$action" = "SLEEP_MONTH" ]; then
          if [ "$action" = "SLEEP_MONTH" ]; then
            sleep_secs="$(secs_until_next_month)"
            reason="monthly budget \$$MONTHLY_BUDGET_USD reached (month spend \$$(spent_month))"
          else
            sleep_secs="$(secs_until_next_day)"
            reason="daily pace \$$(daily_allowance) reached (today \$$(spent_today))"
          fi
          if [ "$sleep_secs" -gt "$CAP_SLEEP_MAX" ]; then sleep_secs="$CAP_SLEEP_MAX"; fi
          # notify + local-tier work once per pacing event, not per chunked re-check
          if [ "$budget_handled" != "$action" ]; then
            budget_handled="$action"
            notify "agency scheduler: budget pacing — $reason; sleeping $(( sleep_secs / 60 ))min"
            local_tier_work
          fi
          log "budget pacing: $action — $reason; sleeping ${sleep_secs}s"
          sleep "$sleep_secs"
          continue
        fi
        budget_handled=""
        log "probe OK${PROBE_COST:+ (cost \$$PROBE_COST)} [$SCHED_MODE] — bursting $BURST_RUNS run(s)"
        d_before="$(decisions_count)"
        # Budget mode: hand run.sh a cost file so it banks each iteration's real total_cost_usd.
        burst_cost_file="$STATE_DIR/burst-cost.$$"
        : > "$burst_cost_file"
        set +e
        if [ "$SCHED_MODE" = "budget" ]; then
          SPEND_COST_FILE="$burst_cost_file" MAX_RUNS="$BURST_RUNS" "$REPO_DIR/loop/run.sh"
        else
          MAX_RUNS="$BURST_RUNS" "$REPO_DIR/loop/run.sh"
        fi
        set -e
        if [ -s "$burst_cost_file" ]; then
          bc="$(awk '{s+=$1} END{printf "%.6f", s+0}' "$burst_cost_file")"
          record_spend "$bc" burst
          log "burst spend \$$bc (month total \$$(spent_month) of \$$MONTHLY_BUDGET_USD)"
        fi
        rm -f "$burst_cost_file"
        d_after="$(decisions_count)"
        if [ "${d_after:-0}" -gt "${d_before:-0}" ]; then
          # The loop already paused the stuck task (open decision => run.sh skips it), so the
          # next burst works the rest of the backlog. Notify the director; never stop for them.
          log "burst escalated a decision (D count $d_before -> $d_after) — task paused, continuing."
          notify "agency scheduler: loop escalated during burst — task paused, awaiting director"
        fi
        sleep "$BURST_PAUSE_SECS"
        ;;
      CAPPED)
        err_streak=0
        now="$(date +%s)"
        if [[ "$RESET_EPOCH" =~ ^[0-9]+$ ]] && [ "$RESET_EPOCH" -gt "$now" ]; then
          sleep_secs=$(( RESET_EPOCH - now + 60 + RANDOM % 120 ))
        elif [ "$SCHED_MODE" = "budget" ]; then
          # No parsable reset on the monthly-credit path -> sleep toward the month boundary.
          sleep_secs="$(secs_until_next_month)"
        else
          sleep_secs="$CAP_RETRY_SECS"
        fi
        if [ "$sleep_secs" -gt "$CAP_SLEEP_MAX" ]; then sleep_secs="$CAP_SLEEP_MAX"; fi
        # one capture + notify + local-tier pass per cap event, not per retry
        if [ "$cap_handled" != "${RESET_EPOCH:-unknown}" ]; then
          cap_handled="${RESET_EPOCH:-unknown}"
          capture_cap_event
          notify "agency scheduler: CAPPED [$SCHED_MODE], sleeping $(( sleep_secs / 60 ))min${RESET_EPOCH:+ (reset $(date -d "@$RESET_EPOCH" '+%H:%M' 2>/dev/null || echo "@$RESET_EPOCH"))}"
          local_tier_work
        fi
        log "capped [$SCHED_MODE] — sleeping ${sleep_secs}s${RESET_EPOCH:+ (reset epoch $RESET_EPOCH)}"
        sleep "$sleep_secs"
        ;;
      *)
        err_streak=$((err_streak + 1))
        log "probe ERROR ($err_streak/$PROBE_ERR_MAX) — retrying in ${ERR_RETRY_SECS}s"
        if [ "$err_streak" -ge "$PROBE_ERR_MAX" ]; then
          log "giving up after $err_streak consecutive probe errors."
          notify "agency scheduler: $err_streak probe errors in a row — stopped (is claude installed/authed?)"
          exit 1
        fi
        sleep "$ERR_RETRY_SECS"
        ;;
    esac
  done
  log "scheduler finished."
}

# --- entrypoint -----------------------------------------------------------------
case "${1:-run}" in
  -h|--help|help) usage; exit 0 ;;
  probe)
    probe
    printf 'STATE=%s RESET=%s\n' "$QUOTA_STATE" "$RESET_EPOCH"
    case "$QUOTA_STATE" in
      OK) exit 0 ;; CAPPED) exit 20 ;; *) exit 21 ;;
    esac
    ;;
  mode) billing_mode; exit 0 ;;
  spend)
    case "${2:-}" in
      add)   record_spend "${3:-}" "${4:-manual}" ;;
      today) spent_today; printf '\n' ;;
      month) spent_month; printf '\n' ;;
      *) echo "usage: scheduler.sh spend {add <amount> [source] | today | month}" >&2; exit 64 ;;
    esac
    ;;
  budget)
    SCHED_MODE="$(billing_mode)"
    action="$(budget_action)"
    printf 'MODE=%s ACTION=%s TODAY=%s MONTH=%s DAILY=%s BUDGET=%s\n' \
      "$SCHED_MODE" "$action" "$(spent_today)" "$(spent_month)" "$(daily_allowance)" "$MONTHLY_BUDGET_USD"
    case "$action" in
      BURST) exit 0 ;; SLEEP_DAY) exit 30 ;; SLEEP_MONTH) exit 31 ;;
    esac
    ;;
  status) budget_status ;;
  run|"") main_run ;;
  *) echo "unknown subcommand: $1" >&2; usage; exit 64 ;;
esac
