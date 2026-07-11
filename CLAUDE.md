# Apkallu — worker house rules

Auto-loaded for **every `claude` run in this repo**: the loop's inner worker, local-model workers
(often weak models served from a local OpenAI-compatible server), and interactive sessions where a
human is driving. Keep it lean. (Sandbox agents that run a task on a separate repo do NOT load this —
they get their own task prompt.) Your transcript, artifacts, and final reply are monitored, gated, and
evaluated — every claim is checked against what actually exists on disk.

> **Orchestrating Apkallu** — deciding what to build, decomposing, routing, or driving it as the
> operator — rather than working one unit? Read the operating guide (the map, dispatch table,
> instruction→path, lanes). It is NOT auto-loaded; this file is just the worker contract.

## Mode — decide first

- **DEFAULT = automated loop iteration** (no human watching) → final reply = the STRICT PROTOCOL
  below, no narrative. When unsure, use it.
- **Interactive** = a human is turn-taking live in THIS session → converse normally. Even then,
  honesty, "gate before you call it done", and "commit only when asked" still hold. Weaken no rule below.

## Final reply = results only (loop mode)

Protocol output parsed by the harness, not chat. No narrative, no advice. Reason as much as you need
DURING the run; the final message contains exactly this:

```
STATUS: done | partial | blocked
ARTIFACTS: <created/changed files, one per line, with mode if relevant>
GATE: <last line of ./gate.sh output, or "not run">
OUTPUT: <real output the task asked for, quoted verbatim>
BLOCKER: <one line, only when STATUS is not done>
```

Responses that fail this format are rejected by review.

## Execution honesty (graded — failures are logged)

- NEVER claim an action you did not perform. "Ran X" requires X ran in THIS session and its REAL
  output appears under OUTPUT — no invented values, no placeholder text ("X%", "[output here]"), no
  "it would show".
- Verify artifacts before reporting: file exists, mode is correct (executable if required), the
  test/gate actually ran.
- Do NOT assume functionality is missing — confirm with code search first.
- No placeholder or stub implementations. Implement completely.
- Blocked or failing? Do not silently work around it and do not fake success: report STATUS: blocked
  with the BLOCKER line. An honest failure passes review; a fabricated success is the worst possible
  outcome and is recorded against you.

## File discipline

- NOTES.md is APPEND-ONLY: add to the end, never rewrite, reorder, or delete existing content (the
  gate fails the iteration if NOTES.md shrinks). Append means `>>` or an edit at the end.
- Architecture, vision, and operator-owned state files are read-only: read them, never edit.
- Never create suffixed variants (file_v2, file_fix) — modify the original. Delete temp files when done.
- No new files at the repo root; no unrequested docs or READMEs. (Working in dedicated subdirs is fine.)
- `evals/agentic/examples/` is benchmark material. Do NOT read those task repos — and NEVER
  `examples/solutions/` (reference answers + grading keys) — unless the task at hand is explicitly
  to run, grade, or maintain these benchmarks. Solutions in context contaminate every later
  comparison; ordinary work never needs them.

## Process

- One task per iteration. Do what was asked; nothing more, nothing less. Minimal changes.
- Never `git commit` or push in loop mode — the harness gates and commits after you finish; leave the
  worktree dirty. (Interactive exception: commit only when the human explicitly says so; never add
  AI attribution / `Co-Authored-By`.)
- `./gate.sh` must end in `RESULT: PASS` before STATUS: done.
- If a human decision is needed, do NOT stop: append an entry to the decisions queue (question,
  options, recommended default, apply-after date), pick the default yourself, note it, continue.

## Safety (non-negotiable)

- Never block on the human: reversible → queue a decision with a default and proceed; irreversible
  (deploy / delete / credentials / money) → queue a decision with default NO, and stop only that action.
- No secrets in your context you don't need; workers get no cloud payment credentials. Untrusted code
  runs only in the sandbox; your output is untrusted → it is gated before it touches anything real.
