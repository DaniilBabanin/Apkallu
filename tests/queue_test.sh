#!/usr/bin/env bash
# Fixture tests for local/queue.sh — the §5 model-aware queue policy. Pure: no lms,
# no network, no models. Loaded-server state is injected via QUEUE_PS_JSON; execution
# is stubbed via QUEUE_RUN_CMD (cascade.sh seam pattern).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Q="$HERE/../local/queue.sh"
TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT
export QUEUE_FILE="$TD/queue.ndjson"
export QUEUE_OUT_DIR="$TD/out"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (want: $2, got: $3)"; fi
}

reset_q() { rm -f "$QUEUE_FILE"; }

NONE='{"models":[]}'
QC30='{"models":[{"name":"qwen/qwen3-coder-30b:latest","context_length":16384}]}'
WARM_QC30='{"models":[{"name":"google/gemma-4-e4b:latest","context_length":32768},
           {"name":"nvidia/nemotron-3-nano-4b:latest","context_length":8192},
           {"name":"qwen/qwen3-coder-30b:latest","context_length":16384}]}'

# --- 1. warm lane drains first, independent of big slot (§5.5) ---------------
reset_q
"$Q" enqueue coder  --prompt "big job"   --id c1 >/dev/null
"$Q" enqueue triage --prompt "tiny job"  --id t1 >/dev/null
pick="$(QUEUE_PS_JSON="$NONE" "$Q" next)"
check "warm lane first" "t1	nvidia/nemotron-3-nano-4b" "$pick"

# --- 2. affinity drain: task acceptable on loaded model wins (§5.3) ----------
reset_q
"$Q" enqueue heavy --prompt "think hard" --id h1 >/dev/null   # first choice ornith
"$Q" enqueue coder --prompt "fix bug"    --id c1 >/dev/null   # qwen3-coder-30b acceptable (2nd)
pick="$(QUEUE_PS_JSON="$QC30" "$Q" next)"
check "affinity beats FIFO" "c1	qwen/qwen3-coder-30b" "$pick"

# --- 3. drain loaded model fully before any swap (§5.4 first clause) ---------
reset_q
"$Q" enqueue structured --prompt "json a" --id s1 >/dev/null  # qwen3-coder-30b first choice
"$Q" enqueue codegen    --prompt "gen b"  --id g1 >/dev/null  # coder-next first choice
pick="$(QUEUE_PS_JSON="$QC30" "$Q" next)"
check "no swap while loaded has work" "s1	qwen/qwen3-coder-30b" "$pick"

# --- 4. swap when loaded has NO acceptable work; amortize by count (§5.4) ----
reset_q
"$Q" enqueue structured --prompt "json"  --id s1 >/dev/null   # 1 task for glm
"$Q" enqueue codegen    --prompt "gen1"  --id g1 >/dev/null   # 2 tasks for coder-next
"$Q" enqueue codegen    --prompt "gen2"  --id g2 >/dev/null
pick="$(QUEUE_PS_JSON='{"models":[{"name":"qwen/qwen3.6-35b-a3b:latest","context_length":16384}]}' "$Q" next)"
check "swap amortized to max-count model" "g1	qwen/qwen3-coder-next" "$pick"

# --- 5. high prio forces first choice despite loaded affinity (§5.4) ---------
reset_q
"$Q" enqueue coder --prompt "routine"   --id c1 >/dev/null            # qwen3-coder-30b acceptable
"$Q" enqueue heavy --prompt "urgent"    --id h1 --prio 9 >/dev/null   # forces ornith
pick="$(QUEUE_PS_JSON="$QC30" "$Q" next)"
check "force-prio overrides affinity" "h1	ornith-1.0-35b" "$pick"

# --- 7. warm models in ps don't count as the big slot ------------------------
reset_q
"$Q" enqueue coder --prompt "x" --id c1 >/dev/null
pick="$(QUEUE_PS_JSON="$WARM_QC30" "$Q" next)"
check "warm lane invisible to big-slot state" "c1	qwen/qwen3-coder-30b" "$pick"

# --- 8. run: executes, marks done, writes output (stubbed) -------------------
reset_q
"$Q" enqueue triage --prompt "classify me" --id t1 >/dev/null
# shellcheck disable=SC2016  # stub expands at run time, not here
out="$(QUEUE_PS_JSON="$NONE" QUEUE_RUN_CMD='echo "model=$QUEUE_MODEL ctx=$QUEUE_CTX prompt=$QUEUE_PROMPT"' "$Q" run)"
case "$out" in done\ t1*) ok "run marks done" ;; *) fail "run marks done ($out)" ;; esac
check "run output captured" "model=nvidia/nemotron-3-nano-4b ctx=8192 prompt=classify me" \
  "$(cat "$QUEUE_OUT_DIR/t1.txt")"
check "state is done" "done" "$(jq -r 'select(.id=="t1") | .state' "$QUEUE_FILE")"

# --- 9. run failure marks failed, drain continues past it --------------------
reset_q
"$Q" enqueue triage  --prompt "boom" --id t1 >/dev/null
"$Q" enqueue general --prompt "fine" --id g1 >/dev/null
# shellcheck disable=SC2016  # stub expands at run time, not here
QUEUE_PS_JSON="$NONE" QUEUE_RUN_CMD='test "$QUEUE_PROMPT" != boom' "$Q" drain >/dev/null 2>&1
check "failed task marked" "failed" "$(jq -r 'select(.id=="t1") | .state' "$QUEUE_FILE")"
check "drain continued past failure" "done" "$(jq -r 'select(.id=="g1") | .state' "$QUEUE_FILE")"

# --- 10. prio orders within a lane, seq breaks ties --------------------------
reset_q
"$Q" enqueue general --prompt "low"  --id g1 --prio 3 >/dev/null
"$Q" enqueue general --prompt "high" --id g2 --prio 7 >/dev/null
pick="$(QUEUE_PS_JSON="$NONE" "$Q" next)"
check "prio orders warm lane" "g2	google/gemma-4-e4b" "$pick"

# --- 11. empty queue: next rc=1 ----------------------------------------------
reset_q
if QUEUE_PS_JSON="$NONE" "$Q" next >/dev/null 2>&1; then
  fail "empty queue returns nonzero"
else
  ok "empty queue returns nonzero"
fi

# --- 12. --ctx overrides the class-default ctx (nested-claude pin: 65536) -----
reset_q
"$Q" enqueue coder --cmd "run me" --models example/general-model --ctx 65536 --id cx1 >/dev/null
check "--ctx overrides class default" "65536" "$(jq -r 'select(.id=="cx1") | .ctx' "$QUEUE_FILE")"
check "default ctx still applies without --ctx" "32768" \
  "$("$Q" enqueue coder --prompt p --id cx2 >/dev/null; jq -r 'select(.id=="cx2") | .ctx' "$QUEUE_FILE")"

# --- 13. submit: enqueue + run NOW + print output + leave no entry (transient) ---------------
reset_q
# shellcheck disable=SC2016  # stub expands at run time, not here
out="$(QUEUE_PS_JSON="$NONE" QUEUE_RUN_CMD='echo "SUBMIT model=$QUEUE_MODEL ctx=$QUEUE_CTX"' \
        "$Q" submit general --prompt "digest me" --id d1)"
check "submit returns the task output on stdout" "SUBMIT model=google/gemma-4-e4b ctx=32768" "$out"
check "submit is transient (entry removed)" "" "$(jq -r 'select(.id=="d1") | .id' "$QUEUE_FILE" 2>/dev/null)"

# --- 14. atomic claim: two concurrent drains on ONE task run its payload exactly once --------
reset_q
"$Q" enqueue general --prompt "solo" --id r1 >/dev/null
export RACE_LOG="$TD/race.log"
: > "$RACE_LOG"
# shellcheck disable=SC2016  # stub expands at run time, not here
QUEUE_PS_JSON="$NONE" QUEUE_RUN_CMD='sleep 0.3; echo ran >> "$RACE_LOG"' "$Q" drain >/dev/null 2>&1 &
race_p1=$!
# shellcheck disable=SC2016  # stub expands at run time, not here
QUEUE_PS_JSON="$NONE" QUEUE_RUN_CMD='sleep 0.3; echo ran >> "$RACE_LOG"' "$Q" drain >/dev/null 2>&1 &
race_p2=$!
wait "$race_p1" "$race_p2" || true
check "concurrent drains: payload ran exactly once" "1" "$(wc -l < "$RACE_LOG" | tr -d ' ')"
check "raced task ends done" "done" "$(jq -r 'select(.id=="r1") | .state' "$QUEUE_FILE")"

# --- 15. recovery: a "running" task with a DEAD owner pid is requeued and re-picked ----------
reset_q
"$Q" enqueue general --prompt "orphan" --id o1 >/dev/null
( : ) & dead_pid=$!
wait "$dead_pid" || true
mut="$TD/mut.ndjson"
jq -c --argjson pid "$dead_pid" '.state="running" | .pid=$pid | .claimed_at=(now|floor)' \
  "$QUEUE_FILE" > "$mut" && mv "$mut" "$QUEUE_FILE"
pick="$(QUEUE_PS_JSON="$NONE" "$Q" next)"
check "dead-owner running task re-picked by next" "o1	google/gemma-4-e4b" "$pick"
check "dead-owner task requeued" "queued" "$(jq -r 'select(.id=="o1") | .state' "$QUEUE_FILE")"

# --- 16. recovery: live owner inside the lease stays running; an expired lease is requeued ---
reset_q
"$Q" enqueue general --prompt "leased" --id l1 >/dev/null
jq -c --argjson pid "$$" '.state="running" | .pid=$pid | .claimed_at=(now|floor)' \
  "$QUEUE_FILE" > "$mut" && mv "$mut" "$QUEUE_FILE"
if QUEUE_PS_JSON="$NONE" "$Q" next >/dev/null 2>&1; then
  fail "live in-lease running task must not be re-picked"
else
  ok "live in-lease running task not re-picked"
fi
jq -c '.claimed_at = 100' "$QUEUE_FILE" > "$mut" && mv "$mut" "$QUEUE_FILE"
pick="$(QUEUE_PS_JSON="$NONE" QUEUE_LEASE=60 "$Q" next)"
check "expired-lease running task re-picked" "l1	google/gemma-4-e4b" "$pick"

echo "---"
echo "queue_test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
