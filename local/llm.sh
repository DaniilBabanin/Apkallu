#!/usr/bin/env bash
# GPU worker pool — ollama role router. v3 (2026-07-11; v2 drove LM Studio's lms).
# Usage: ./local/llm.sh <role> "prompt"   (or pipe prompt on stdin)
#        ./local/llm.sh warmup            (load the always-warm lane)
#        ./local/llm.sh ensure <model> <ctx> [ttl]  (load + ctx check + probe one model —
#                                          used by loop/run.sh LOCAL=1 and local/queue.sh)
# Roles: triage | general | coder | structured | heavy | embed
#
# Role map — the operator's current loadout (2026-06-07 golden suite + 2026-07-11 VM evals,
# evals/agentic/results/). These are our picks; swap the slugs for your own models — the roles
# themselves are defined in policy/routing.md.
#   triage     nemotron-3-nano-4b @8k   — instant classify/route; TRUSTED INPUT ONLY (2/15 security)
#   general    gemma-4-e4b @32k         — digests/summaries/commit msgs; suite 15/15 ×4 cats,
#                                         93 tok/s, long-input verified (18.6k tokens, 11.9s)
#   coder      ornith-1.0-35b @32k      — agentic coding primary; reasoning model. VM evals
#                                         2026-07-11: kvstore 5/5 (255s), roman bugfix 13/13 (72s).
#                                         Agentic harnesses need ctx ≥16k (OpenHands' opening
#                                         prompt alone is ~6k; run_session.py preflights this)
#   structured qwen3-coder-30b @16k     — JSON/schema + tool batches (MoE A3B; VM e2e pass 2026-07-03)
#   heavy      ornith-1.0-35b @32k      — deliberate reasoning jobs. Reasoning bench 2026-07-11
#                                         (6 checkable tasks): ornith 6/6 in 193s vs
#                                         qwen3.6-35b-a3b 6/6 in 248s — tie on correctness,
#                                         ornith faster + fewer tokens, and sharing the coder
#                                         slot means heavy work never forces a model swap
#   embed      qwen3-embedding-0.6b     — memory search over NOTES/reports
# gemma-4-26b-a4b (MoE 3.8B-active, 100% GPU, 86 tok/s) fills the big-general fallback slot in
# the queue chains (local/queue.sh) — it aced taskflow (22/22, 168s, the speed record) but made
# ZERO edits on the minidb debugging eval and false-finished, so it is capped at general/
# structured fallback, never coder. ornith-1.0-9b (73 tok/s, 6GB) cleared kvstore 5/5 in 130s
# but stalled at 10/22 on taskflow — fit for function-sized decomposed units only. The
# nested-claude LOCAL=1 model stays env-set (loop/run.sh LOCAL_MODEL) — that path needs ~23k+
# ctx for the Claude Code system prompt.
#
# Serving (2026-07-11): ollama, chosen after benching ornith 48 vs 28 tok/s on LM Studio —
# ollama's MoE placement keeps all-layer attention on GPU and spills only expert weights to RAM.
# LM Studio stays the download/browse UI; local/ollama-import.sh imports its GGUFs into ollama
# with SYMLINKED blobs (no duplicate weights). Two consequences:
#   - ctx is pinned per model at import (Modelfile num_ctx); no JIT-shrink trap. Too small →
#     re-import with a bigger pin.
#   - deleting a model in LM Studio breaks the symlink → loud load failure here; re-download
#     or `ollama rm`.
# Eviction is the ollama scheduler's job (LRU under memory pressure); the old lms big-slot
# eviction dance is gone. Warm lane = long keep_alive on the small models.
set -euo pipefail

BASE="${OLLAMA_BASE:-http://localhost:11434}"

EMBED_MODEL="text-embedding-qwen3-embedding-0.6b"

ps_ctx() { # ps_ctx <model> -> loaded context_length or empty
  curl -s --max-time 5 "$BASE/api/ps" 2>/dev/null | jq -r --arg m "$1" \
    '.models[]? | select(((.name // "") | sub(":latest$"; "")) == $m) | .context_length // empty' \
    | head -1
}

probe_ok() { # probe_ok <model> — 1-token request proves the instance actually answers
  curl -s --max-time 180 "$BASE/v1/chat/completions" -H "Content-Type: application/json" \
    -d "$(jq -n --arg m "$1" '{model:$m, max_tokens:1, messages:[{role:"user",content:"hi"}]}')" \
    | jq -e '.choices[0]' >/dev/null 2>&1
}

serving_at() { # serving_at <model> <ctx> — listed at >=ctx AND answers a real request
  local have
  have="$(ps_ctx "$1")"
  [ -n "$have" ] && [ "$have" -ge "$2" ] && probe_ok "$1"
}

ensure_loaded() { # ensure_loaded <model> <ctx> [ttl-seconds]
  local model="$1" want="$2" ttl="${3:-7200}" have
  serving_at "$model" "$want" && return 0
  # load (blocks until loaded); ollama serves at the Modelfile num_ctx pin, scheduler evicts LRU
  curl -s --max-time 300 "$BASE/api/generate" -H "Content-Type: application/json" \
    -d "$(jq -n --arg m "$model" --arg ka "${ttl}s" '{model:$m, keep_alive:$ka}')" >/dev/null 2>&1 || true
  serving_at "$model" "$want" && return 0
  have="$(ps_ctx "$model")"
  if [ -n "$have" ] && [ "$have" -lt "$want" ]; then
    echo "LLM_ERROR: $model pinned at num_ctx $have < $want — re-import:" \
         "./local/ollama-import.sh <gguf> $model $want" >&2
  else
    echo "LLM_ERROR: $model not serving (probe failed — imported? broken symlink? see ollama list)" >&2
  fi
  return 1
}

if [ "${1:-}" = "warmup" ]; then
  curl -s --max-time 60 "$BASE/api/embed" -H "Content-Type: application/json" \
    -d "$(jq -n --arg m "$EMBED_MODEL" '{model:$m, input:"warm", keep_alive:"24h"}')" >/dev/null || true
  ensure_loaded "nvidia/nemotron-3-nano-4b" 8192 99999
  ensure_loaded "google/gemma-4-e4b" 32768 99999
  echo "warm lane up:"
  curl -s "$BASE/api/ps" | jq -r '.models[]? | "\(.name)  ctx=\(.context_length)"'
  exit 0
fi

# ensure <model> <ctx> [ttl] — CLI seam for run.sh LOCAL=1 / cascade local profile:
# guarantees the model serves at >=ctx and actually answers (not just listed).
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
  coder)      MODEL="ornith-1.0-35b"            CTX=32768 MAXTOK=8000  ;;  # agentic coding primary
  structured) MODEL="qwen/qwen3-coder-30b"      CTX=16384 MAXTOK=8000  ;;  # JSON/schema output
  heavy)      MODEL="ornith-1.0-35b"            CTX=32768 MAXTOK=12000 ;;  # deliberate reasoning jobs
  embed)      MODEL="text-embedding-qwen3-embedding-0.6b" ;;
  *) echo "unknown role: $ROLE" >&2; exit 1 ;;
esac

if [ "$ROLE" = "embed" ]; then
  # /api/embed loads the model on demand; long keep_alive = the warm pin
  curl -s --max-time 120 "$BASE/api/embed" -H "Content-Type: application/json" \
    -d "$(jq -n --arg m "$MODEL" --arg p "$PROMPT" '{model:$m, input:$p, keep_alive:"24h"}')" \
    | jq -r '.embeddings[0]'
else
  ensure_loaded "$MODEL" "$CTX"
  # max_tokens guards against reasoning models spending the whole budget thinking;
  # the jq fallback surfaces what happened instead of printing nothing.
  curl -s --max-time 300 "$BASE/v1/chat/completions" -H "Content-Type: application/json" \
    -d "$(jq -n --arg m "$MODEL" --arg p "$PROMPT" --argjson mt "${MAXTOK:-6000}" \
        '{model:$m, max_tokens:$mt, temperature:0.2,
          messages:[
            {role:"system", content:"Be concise. Output only the final answer, no preamble."},
            {role:"user", content:$p}]}')" \
    | jq -r 'if (.choices[0].message.content // "") != "" then .choices[0].message.content
             elif (.choices[0].message.reasoning_content // .choices[0].message.reasoning) then
               "LLM_WARN: empty content, reasoning only (finish=" + (.choices[0].finish_reason // "?") + ")"
             else "LLM_ERROR: " + tojson end'
fi
