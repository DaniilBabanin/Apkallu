#!/usr/bin/env bash
# GPU worker pool — a local server (OpenAI-compatible) role router. v2 (2026-06-07).
# Usage: ./local/llm.sh <role> "prompt"   (or pipe prompt on stdin)
#        ./local/llm.sh warmup            (load the always-warm lane)
#        ./local/llm.sh ensure <model> <ctx> [ttl]  (load + ctx-pin + probe one model —
#                                          used by loop/run.sh LOCAL=1 and local/queue.sh)
# Roles: triage | general | coder | structured | heavy | embed
#
# Role map from the 2026-06-07 golden suite (policy/routing.md, evals/results/):
#   triage     nemotron-3-nano-4b @8k   — instant classify/route; TRUSTED INPUT ONLY (2/15 security)
#   general    gemma-4-e4b @32k         — digests/summaries/commit msgs; suite 15/15 ×4 cats,
#                                         93 tok/s, long-input verified (18.6k tokens, 11.9s)
#   coder      coder-model @16k     — agentic coding primary (MoE A3B: RAM spill stays fast)
#   structured coder-alt-model @16k       — JSON/schema + tool batches
#   heavy      heavy-model @16k     — deliberate reasoning jobs (unbenched in suite v1)
#   embed      embed-model     — memory search over NOTES/reports
# general-model is demoted from workhorse (7/15 summarize) but stays the proven nested-claude
# LOCAL=1 model @65536 — that path needs ~23k+ ctx for the Claude Code system prompt.
#
# Lanes (routing.md §4): warm lane (embed+nemotron+e4b, ~10GB VRAM, never evicted) vs ONE
# big-MoE slot (the coder/structured/heavy/general/codegen big models — loading one evicts the
# others, never the warm lane). MoE spilling to RAM is fine; only load time hurts → fewest swaps
# wins.
#
# ensure_loaded guards the two live-caught serving traps (policy/delegation.md 2026-06-07):
# KV-OOM load failure silently JIT-falls-back to a 4096-ctx instance under the same id, and
# TTL expiry/JIT reload drops the pinned ctx. Always verify `lms ps --json` after loading.
set -euo pipefail

BASE="${LMSTUDIO_BASE:-http://localhost:1234/v1}"

WARM_LLMS="nvidia/nemotron-3-nano-4b google/gemma-4-e4b"
BIG_SLOT="example/coder-model example/coder-alt-model example/heavy-model example/general-model example/codegen-model"

ps_ctx() { # ps_ctx <model> -> loaded contextLength or empty
  lms ps --json 2>/dev/null | jq -r --arg m "$1" \
    '.[] | select((.identifier // .modelKey // "") | contains($m | split("/")[-1])) | .contextLength // empty' \
    | head -1
}

probe_ok() { # probe_ok <model> — 1-token request; `lms ps` can list a DEAD instance
  curl -s --max-time 180 "$BASE/chat/completions" -H "Content-Type: application/json" \
    -d "$(jq -n --arg m "$1" '{model:$m, max_tokens:1, messages:[{role:"user",content:"hi"}]}')" \
    | jq -e '.choices[0]' >/dev/null 2>&1
}

serving_at() { # serving_at <model> <ctx> — listed at >=ctx AND answers a real request
  local have
  have="$(ps_ctx "$1")"
  [ -n "$have" ] && [ "$have" -ge "$2" ] && probe_ok "$1"
}

ensure_loaded() { # ensure_loaded <model> <ctx> [ttl]
  local model="$1" want="$2" ttl="${3:-7200}" peer
  serving_at "$model" "$want" && return 0
  lms unload "$model" >/dev/null 2>&1 || true   # clear lying/short-ctx instance if any
  # big-slot model: evict big-slot peers first, warm lane only as last resort
  if [[ " $BIG_SLOT " == *" $model "* ]]; then
    for peer in $BIG_SLOT; do
      [ "$peer" = "$model" ] && continue
      [ -n "$(ps_ctx "$peer")" ] && lms unload "$peer" >/dev/null 2>&1 || true
    done
  fi
  lms load "$model" --context-length "$want" --ttl "$ttl" -y >/dev/null 2>&1 || true
  serving_at "$model" "$want" && return 0
  # last resort for big jobs that don't fit beside the warm lane (routing.md §5.4
  # "high-priority forces"): evict warm LLMs (keep the 0.6GB embedder), retry once.
  # Caller re-warms cheaply via `llm.sh warmup` (~8s).
  if [[ " $BIG_SLOT " == *" $model "* ]]; then
    lms unload "$model" >/dev/null 2>&1 || true
    for peer in $WARM_LLMS; do
      lms unload "$peer" >/dev/null 2>&1 || true
    done
    lms load "$model" --context-length "$want" --ttl "$ttl" -y >/dev/null 2>&1 || true
    serving_at "$model" "$want" && return 0
  fi
  echo "LLM_ERROR: $model not serving at ctx>=$want (ps: $(ps_ctx "$model" || echo none); probe failed)" >&2
  return 1
}

if [ "${1:-}" = "warmup" ]; then
  ensure_loaded "example/embed-model" 1 99999 || true
  ensure_loaded "nvidia/nemotron-3-nano-4b" 8192 99999
  ensure_loaded "google/gemma-4-e4b" 32768 99999
  echo "warm lane up:"; lms ps
  exit 0
fi

# ensure <model> <ctx> [ttl] — CLI seam for run.sh LOCAL=1 / cascade local profile:
# guarantees the model serves at >=ctx (a JIT 4096 fallback instance passes a mere
# "is it listed" check — this doesn't).
if [ "${1:-}" = "ensure" ]; then
  ensure_loaded "${2:?model}" "${3:?ctx}" "${4:-7200}"
  exit $?
fi

ROLE="${1:?role required: triage|general|coder|structured|heavy|embed|warmup}"
shift || true
PROMPT="${*:-$(cat)}"

case "$ROLE" in
  triage)     MODEL="nvidia/nemotron-3-nano-4b" CTX=8192  MAXTOK=2000  ;;  # classify/route/yes-no — trusted input only
  general)    MODEL="google/gemma-4-e4b"        CTX=32768 MAXTOK=6000  ;;  # summaries, digests
  coder)      MODEL="example/coder-model"      CTX=16384 MAXTOK=8000  ;;  # agentic coding primary
  structured) MODEL="example/coder-alt-model"     CTX=16384 MAXTOK=8000  ;;  # JSON/schema output
  heavy)      MODEL="example/heavy-model"      CTX=16384 MAXTOK=12000 ;;  # deliberate reasoning jobs
  embed)      MODEL="example/embed-model" ;;
  *) echo "unknown role: $ROLE" >&2; exit 1 ;;
esac

if [ "$ROLE" = "embed" ]; then
  ensure_loaded "$MODEL" 1 99999 || true
  curl -s "$BASE/embeddings" -H "Content-Type: application/json" \
    -d "$(jq -n --arg m "$MODEL" --arg p "$PROMPT" '{model:$m, input:$p}')" \
    | jq -r '.data[0].embedding'
else
  ensure_loaded "$MODEL" "$CTX"
  # max_tokens guards against reasoning models spending the whole budget thinking;
  # the jq fallback surfaces what happened instead of printing nothing.
  curl -s --max-time 300 "$BASE/chat/completions" -H "Content-Type: application/json" \
    -d "$(jq -n --arg m "$MODEL" --arg p "$PROMPT" --argjson mt "${MAXTOK:-6000}" \
        '{model:$m, max_tokens:$mt, temperature:0.2,
          messages:[
            {role:"system", content:"Be concise. Output only the final answer, no preamble."},
            {role:"user", content:$p}]}')" \
    | jq -r 'if (.choices[0].message.content // "") != "" then .choices[0].message.content
             elif .choices[0].message.reasoning_content then
               "LLM_WARN: empty content, reasoning only (finish=" + (.choices[0].finish_reason // "?") + ")"
             else "LLM_ERROR: " + tojson end'
fi
