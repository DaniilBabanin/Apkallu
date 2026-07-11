# NOTES — append-only build log

The loop appends a learnings line at the END of this file each iteration; it is never rewritten or
reordered (the gate fails an iteration that deletes from it). Cross-iteration memory lives here.

2026-07-11 — ollama migration + model benchmarks (interactive session, commits 0dc6828..e0ca416)
- Local serving switched lms→ollama 0.31.2 (systemd override: User=db, OLLAMA_MODELS=~/.cache/ollama-user,
  q8 KV, flash-attn). Reason: ornith-1.0-35b 48 vs 28 tok/s — ollama spills only MoE expert weights to RAM.
- LM Studio kept as download UI; local/ollama-import.sh imports GGUFs with symlinked blobs (0 duplicate GB).
- New benchmarks evals/agentic/examples/: taskflow (greenfield, 0/22 start) + minidb (7 planted bugs, 8/20
  start); solutions/ quarantined via CLAUDE.md rule. kvstore remains the easy tier.
- Results: ornith-35b coder primary (taskflow 22/22 312s; minidb 4/7 honest stall). qwen3-coder-30b
  fallback + bugfix-first pick (minidb 7/7). gemma-4-26b-a4b 86 tok/s, taskflow record 168s, but 0 edits +
  false "finished" on minidb → capped to structured/heavy fallback (replaced gemma-4-12b). ornith-9b only
  function-sized units (kvstore 5/5 130s, taskflow 10/22 stuck). devstral dropped (15x tokens, hit iter cap).
  gemma-31b-qat 6.3 tok/s dense-spill → overnight lane only; its timeout crash fixed via --llm-timeout.
- Spot checks all green: triage 10/10, general digest 4/4, structured JSON 5/5, codegen validated
  (qwen3-coder-next ~90 tok one-shots vs ornith 1-4k reasoning burn).
- Rules learned: active params set speed, total params set ceiling, neither sets tool discipline — only the
  ladder shows it. Token worth > tok/s: prefer the bigger model while it stays reasonably fast.
