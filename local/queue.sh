#!/usr/bin/env bash
# Model-aware local task queue — routing.md §5, implemented 2026-06-07.
#
# FIFO thrashes the big-MoE slot (each swap = a 12–48GB load). This queue drains by
# MODEL AFFINITY instead:
#   §5.1  tasks carry a capability CLASS → ordered acceptable-model list (best first),
#         never a single hard pin
#   §5.2  the currently-loaded big-MoE model is read from `lms ps` (server state)
#   §5.3  prefer queued work whose acceptable set includes the loaded model
#   §5.4  switch the big slot only when it has NO acceptable work left, or a
#         high-priority task (prio >= QUEUE_FORCE_PRIO) forces its first choice;
#         on a switch, pick the first-choice model with the MOST queued tasks
#         (amortize the load over a batch)
#   §5.5  warm lane (nemotron/e4b) is an independent queue — always drains first,
#         never causes (or waits for) a big-slot swap
#   §5.6  dense-heavy lane REMOVED 2026-06-07 — director dropped example-model ("too
#         slow"); no dense model remains in the loadout
#   §5.7  embedding stays pinned (llm.sh warmup); it is not a queue target
#
# Queue file: local/queue.ndjson (one JSON object per task). Mutations hold an flock
# so enqueue/run can race safely. Execution delegates model serving to
# `local/llm.sh ensure` (ctx-pin + functional probe + lane-aware eviction).
#
# Usage:
#   ./local/queue.sh enqueue <class> [--prompt "…" | --cmd "…"] [--prio N] [--models "a,b"] [--ctx N]
#   ./local/queue.sh submit <class> [enqueue-opts]  # enqueue + run NOW, print output (transient)
#   ./local/queue.sh next                 # print id+model chosen by policy (no side effects)
#   ./local/queue.sh run [id]             # run one task (default: policy pick)
#   ./local/queue.sh drain [max]          # run until empty (or max tasks)
#   ./local/queue.sh status | classes
#
# Classes (from the 2026-06-07 golden suite, policy/routing.md role map):
#   triage     → nemotron-4b                                  (warm; TRUSTED INPUT ONLY)
#   general    → gemma-4-e4b                                  (warm)
#   coder      → coder-model > coder-alt-model > general-model
#   codegen    → codegen-model > coder-model           (pure code gen, no tools)
#   structured → coder-alt-model > general-model
#   heavy      → heavy-model > general-model
#
# Env:
#   QUEUE_FILE        queue path (default local/queue.ndjson)
#   QUEUE_PS_JSON     test seam: JSON for loaded-model state instead of `lms ps --json`
#   QUEUE_RUN_CMD     test seam: command run instead of the real chat call; gets
#                     QUEUE_MODEL/QUEUE_CTX/QUEUE_PROMPT env (cascade.sh DECOMPOSE_CMD pattern)
#   QUEUE_FORCE_PRIO  priority that forces a slot switch (default 9)
#   LMSTUDIO_BASE     chat endpoint base (default http://localhost:1234/v1)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE_FILE="${QUEUE_FILE:-$HERE/queue.ndjson}"
LOCK_FILE="$QUEUE_FILE.lock"
OUT_DIR="${QUEUE_OUT_DIR:-$HERE/queue-out}"
BASE="${LMSTUDIO_BASE:-http://localhost:1234/v1}"
FORCE_PRIO="${QUEUE_FORCE_PRIO:-9}"

# Keep in sync with local/llm.sh (WARM_LLMS/BIG_SLOT) and policy/routing.md.
WARM_SET="nvidia/nemotron-3-nano-4b google/gemma-4-e4b"

class_models() { # class_models <class> -> comma list, best first
  case "$1" in
    triage)      echo "nvidia/nemotron-3-nano-4b" ;;
    general)     echo "google/gemma-4-e4b" ;;
    coder)       echo "example/coder-model,example/coder-alt-model,example/general-model" ;;
    codegen)     echo "example/codegen-model,example/coder-model" ;;
    structured)  echo "example/coder-alt-model,example/general-model" ;;
    heavy)       echo "example/heavy-model,example/general-model" ;;
    *) return 1 ;;
  esac
}

class_ctx() { # class_ctx <class>
  case "$1" in
    triage) echo 8192 ;;
    general) echo 32768 ;;
    *) echo 16384 ;;
  esac
}

ps_json() { # loaded-model state; QUEUE_PS_JSON overrides for tests
  if [ -n "${QUEUE_PS_JSON:-}" ]; then printf '%s' "$QUEUE_PS_JSON"
  else lms ps --json 2>/dev/null || echo '[]'
  fi
}

loaded_big() { # print the loaded big-slot model id ("" if none)
  local m ids
  ids="$(ps_json | jq -r '.[] | (.identifier // .modelKey // "")')"
  while read -r m; do
    [ -z "$m" ] && continue
    case " $WARM_SET example/embed-model " in
      *" $m "*) continue ;;
    esac
    echo "$m"; return 0
  done <<< "$ids"
  return 0
}

is_warm_first() { # is_warm_first <models-csv> — task belongs to the warm lane?
  case " $WARM_SET " in *" ${1%%,*} "*) return 0 ;; *) return 1 ;; esac
}

queued() { # queued [filter-jq] — emit queued tasks as NDJSON
  [ -f "$QUEUE_FILE" ] || return 0
  jq -c 'select(.state == "queued")' "$QUEUE_FILE"
}

with_lock() { ( flock -x 9; "$@" ) 9>"$LOCK_FILE"; }

_set_state() { # _set_state <id> <state> [result]
  local tmp
  tmp="$(mktemp)"
  jq -c --arg id "$1" --arg st "$2" --arg res "${3:-}" \
    'if .id == $id then .state = $st | (if $res != "" then .result = $res else . end) else . end' \
    "$QUEUE_FILE" > "$tmp" && mv "$tmp" "$QUEUE_FILE"
}

_remove() { # _remove <id> — drop a task line (submit is transient: the caller already has the output)
  [ -f "$QUEUE_FILE" ] || return 0
  local tmp
  tmp="$(mktemp)"
  jq -c --arg id "$1" 'select(.id != $id)' "$QUEUE_FILE" > "$tmp" && mv "$tmp" "$QUEUE_FILE"
}

cmd_enqueue() {
  local class="$1"; shift
  local prompt="" cmd="" prio=5 models="" id="" ctx=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt) prompt="$2"; shift 2 ;;
      --cmd)    cmd="$2"; shift 2 ;;
      --prio)   prio="$2"; shift 2 ;;
      --models) models="$2"; shift 2 ;;
      --ctx)    ctx="$2"; shift 2 ;;
      --id)     id="$2"; shift 2 ;;
      *) echo "unknown flag: $1" >&2; return 1 ;;
    esac
  done
  [ -n "$models" ] || models="$(class_models "$class")" || { echo "unknown class: $class" >&2; return 1; }
  [ -n "$prompt$cmd" ] || { echo "need --prompt or --cmd" >&2; return 1; }
  [ -n "$ctx" ] || ctx="$(class_ctx "$class")"   # --ctx overrides the class default (e.g. nested-claude 65536)
  [ -n "$id" ] || id="q$(date +%s%N | cut -c1-16)"
  local kind="prompt" payload="$prompt"
  [ -n "$cmd" ] && { kind="cmd"; payload="$cmd"; }
  local line
  line="$(jq -nc --arg id "$id" --arg class "$class" --argjson prio "$prio" \
    --arg models "$models" --arg kind "$kind" --arg payload "$payload" \
    --argjson ctx "$ctx" --argjson seq "$(($(date +%s%N) / 1000))" \
    '{id:$id, state:"queued", prio:$prio, class:$class, models:($models|split(",")),
      kind:$kind, payload:$payload, ctx:$ctx, seq:$seq}')"
  with_lock _append "$line"
  echo "$id"
}

_append() { printf '%s\n' "$1" >> "$QUEUE_FILE"; }

# pick — the §5 policy. Prints "<id>\t<model>" or returns 1 when nothing is runnable.
cmd_next() {
  local all loaded
  all="$(queued)"
  [ -n "$all" ] || return 1
  loaded="$(loaded_big)"

  # §5.5 warm lane drains first, independent of the big slot
  local pick
  pick="$(printf '%s\n' "$all" | jq -sc '
    [.[] | select(.models[0] as $m | ($m == "nvidia/nemotron-3-nano-4b" or $m == "google/gemma-4-e4b"))]
    | sort_by(-.prio, .seq) | .[0] // empty')"
  if [ -n "$pick" ]; then
    printf '%s\t%s\n' "$(jq -r .id <<<"$pick")" "$(jq -r '.models[0]' <<<"$pick")"
    return 0
  fi

  local big
  big="$(printf '%s\n' "$all" | jq -sc '
    [.[] | select((.models[0] | test("nemotron|gemma") | not))]')"
  [ "$(jq 'length' <<<"$big")" -gt 0 ] || return 1

  # §5.4 high-priority forces its FIRST choice (even at swap cost)
  pick="$(jq -c --argjson fp "$FORCE_PRIO" \
    '[.[] | select(.prio >= $fp)] | sort_by(-.prio, .seq) | .[0] // empty' <<<"$big")"
  if [ -n "$pick" ]; then
    printf '%s\t%s\n' "$(jq -r .id <<<"$pick")" "$(jq -r '.models[0]' <<<"$pick")"
    return 0
  fi

  # §5.3 affinity: drain tasks acceptable on the loaded big model
  if [ -n "$loaded" ]; then
    pick="$(jq -c --arg m "$loaded" \
      '[.[] | select(.models | index($m))] | sort_by(-.prio, .seq) | .[0] // empty' <<<"$big")"
    if [ -n "$pick" ]; then
      printf '%s\t%s\n' "$(jq -r .id <<<"$pick")" "$loaded"
      return 0
    fi
  fi

  # §5.4 slot switch: loaded model has no acceptable work → swap to the first-choice
  # model with the most queued tasks (amortize), oldest task of that model first
  local model
  model="$(jq -r 'group_by(.models[0]) | map({m: .[0].models[0], n: length, oldest: (map(.seq) | min)})
    | sort_by(-.n, .oldest) | .[0].m' <<<"$big")"
  pick="$(jq -c --arg m "$model" '[.[] | select(.models[0] == $m)] | sort_by(-.prio, .seq) | .[0]' <<<"$big")"
  printf '%s\t%s\n' "$(jq -r .id <<<"$pick")" "$model"
}

cmd_run() {
  local id="${1:-}" model task
  if [ -n "$id" ]; then
    task="$(jq -c --arg id "$id" 'select(.id == $id and .state == "queued")' "$QUEUE_FILE" | head -1)"
    [ -n "$task" ] || { echo "no queued task: $id" >&2; return 1; }
    model="$(loaded_big)"
    jq -e --arg m "$model" '.models | index($m)' <<<"$task" >/dev/null 2>&1 || model="$(jq -r '.models[0]' <<<"$task")"
  else
    local line
    line="$(cmd_next)" || { echo "queue empty / nothing runnable" >&2; return 1; }
    id="${line%%$'\t'*}"; model="${line##*$'\t'}"
    task="$(jq -c --arg id "$id" 'select(.id == $id)' "$QUEUE_FILE" | head -1)"
  fi
  local ctx kind payload
  ctx="$(jq -r .ctx <<<"$task")"
  kind="$(jq -r .kind <<<"$task")"
  payload="$(jq -r .payload <<<"$task")"
  with_lock _set_state "$id" running
  mkdir -p "$OUT_DIR"
  local out="$OUT_DIR/$id.txt" rc=0
  if [ -n "${QUEUE_RUN_CMD:-}" ]; then
    QUEUE_MODEL="$model" QUEUE_CTX="$ctx" QUEUE_PROMPT="$payload" \
      bash -c "$QUEUE_RUN_CMD" > "$out" 2>&1 || rc=$?
  elif [ "$kind" = "cmd" ]; then
    "$HERE/llm.sh" ensure "$model" "$ctx" || rc=$?
    [ $rc -eq 0 ] && { QUEUE_MODEL="$model" QUEUE_CTX="$ctx" bash -c "$payload" > "$out" 2>&1 || rc=$?; }
  else
    "$HERE/llm.sh" ensure "$model" "$ctx" || rc=$?
    if [ $rc -eq 0 ]; then
      curl -s --max-time 600 "$BASE/chat/completions" -H "Content-Type: application/json" \
        -d "$(jq -n --arg m "$model" --arg p "$payload" \
            '{model:$m, max_tokens:8000, temperature:0.2,
              messages:[{role:"system", content:"Be concise. Output only the final answer, no preamble."},
                        {role:"user", content:$p}]}')" \
        | jq -r '.choices[0].message.content // ("LLM_ERROR: " + tojson)' > "$out" || rc=$?
      grep -q '^LLM_ERROR' "$out" && rc=1
    fi
  fi
  if [ $rc -eq 0 ]; then with_lock _set_state "$id" "done" "$out"; echo "done $id ($model) -> $out"
  else with_lock _set_state "$id" failed "$out"; echo "FAILED $id ($model) rc=$rc -> $out" >&2; return 1
  fi
}

cmd_drain() {
  local max="${1:-100}" n=0
  while [ "$n" -lt "$max" ]; do
    cmd_next >/dev/null 2>&1 || break
    cmd_run || true
    n=$((n + 1))
  done
  echo "drained $n task(s)"
}

# submit <class> [enqueue-opts] — the synchronous "enqueue + drain-one" primitive: enqueue a task,
# run it NOW via the same policy/serving path as drain, print its output to stdout, then drop the
# entry (transient — the caller already holds the result; a fixed --id reuses one out file). Used
# by callers that need the answer inline (e.g. local/digest.sh). Honors QUEUE_RUN_CMD (tests).
cmd_submit() {
  local id rc=0
  id="$(cmd_enqueue "$@")" || return 1
  cmd_run "$id" >&2 || rc=$?
  cat "$OUT_DIR/$id.txt" 2>/dev/null || true
  with_lock _remove "$id" || true
  return "$rc"
}

cmd_status() {
  [ -f "$QUEUE_FILE" ] || { echo "queue empty (no file)"; return 0; }
  echo "loaded big-slot: $(loaded_big || echo none)"
  jq -r '[.state, .id, .class, .prio, .models[0]] | @tsv' "$QUEUE_FILE" \
    | sort | column -t
}

case "${1:-}" in
  enqueue) shift; cmd_enqueue "$@" ;;
  submit)  shift; cmd_submit "$@" ;;
  next)    cmd_next ;;
  run)     shift || true; cmd_run "${1:-}" ;;
  drain)   shift || true; cmd_drain "${1:-100}" ;;
  status)  cmd_status ;;
  classes) for c in triage general coder codegen structured heavy; do
             printf '%-12s %s (ctx %s)\n' "$c" "$(class_models "$c")" "$(class_ctx "$c")"
           done ;;
  *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
