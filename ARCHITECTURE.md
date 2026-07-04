# ARCHITECTURE — this instance's design + principles

## Design
A director queues work; an unattended loop turns it into committed, gated changes.

- **The loop** (`loop/run.sh`) picks the top `backlog.md` task, works it via Claude Code's `/goal`,
  runs `./gate.sh`, and commits only on green. The **scheduler** (`loop/scheduler.sh`) bursts
  iterations whenever budget/quota allow. The **cascade** (`loop/cascade.sh`) decomposes a big
  instruction into independent units, dispatches them across isolated git worktrees, and merges the
  gate-green ones back into main (the up-cascade).
- **Execution is sandboxed.** The loop's inner Claude runs on the host under a bubblewrap sandbox
  (`local/sandbox-setup.sh`; fail-closed network allowlist); cascade units get isolated git
  worktrees. A stronger, disposable-VM lane exists (`evals/agentic/`: qemu/libvirt + OpenHands;
  the inference key stays off the VM via host-side `proxy.py`, egress allowlisted by
  `egress_proxy.py`) but runs standalone eval sessions — it is not yet wired into the loop.
- **State is git plus an optional Postgres control plane** (`lib/` + `db/`): jobs and lineage.
  Cross-iteration memory is `NOTES.md` (append-only). Operator-facing state lives under `director/`.

## Principles (the gate, watcher, scheduler, and digest enforce these)
1. **No green, no merge.** A unit is done only when `./gate.sh` ends in `RESULT: PASS`.
2. **Coordinate through git, not an LLM's judgment** (GUPP) — refs and the gate decide, not a model's
   self-grade.
3. **The sandbox is the security boundary.** Untrusted output is gated before it touches anything
   real; payment credentials never reach a worker (workers do carry their own inference token);
   irreversible actions are policy-forbidden to workers — they queue a decision instead.
4. **Idle quota is waste.** The scheduler bursts work whenever budget/quota allow.
5. **Memory is append-only.** `NOTES.md` only grows; the gate fails an iteration that shrinks it
   beyond a small in-place-fix tolerance (`GATE_NOTES_MAX_DELETIONS`, default 20 lines).
