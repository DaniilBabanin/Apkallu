# ARCHITECTURE — this instance's design + principles

## Design
A director queues work; an unattended loop turns it into committed, gated changes.

- **The loop** (`loop/run.sh`) picks the top `backlog.md` task, works it via Claude Code's `/goal`,
  runs `./gate.sh`, and commits only on green. The **scheduler** (`loop/scheduler.sh`) bursts
  iterations whenever budget/quota allow. The **cascade** (`loop/cascade.sh`) decomposes a big
  instruction into independent units, dispatches them across isolated git worktrees, and merges the
  gate-green ones back into main (the up-cascade).
- **Execution is sandboxed.** Code that runs untrusted commands goes to a disposable microVM
  (`evals/agentic/`): the host is never at risk, the inference key stays off the VM (host-side
  `proxy.py`), and egress is allowlisted (`egress_proxy.py`). The loop's own inner Claude runs under
  a bubblewrap sandbox (`local/sandbox-setup.sh`). Pure text-gen skips the VM — it is only boot tax.
- **State is git plus an optional Postgres control plane** (`lib/` + `db/`): jobs and lineage.
  Cross-iteration memory is `NOTES.md` (append-only). Operator-facing state lives under `director/`.

## Principles (the gate, watcher, scheduler, and digest enforce these)
1. **No green, no merge.** A unit is done only when `./gate.sh` ends in `RESULT: PASS`.
2. **Coordinate through git, not an LLM's judgment** (GUPP) — refs and the gate decide, not a model's
   self-grade.
3. **The VM is the security boundary.** Untrusted output is gated before it touches anything real;
   secrets and irreversible actions never reach a worker.
4. **Idle quota is waste.** The scheduler bursts work whenever budget/quota allow.
5. **Memory is append-only.** `NOTES.md` only grows; the gate fails an iteration that shrinks it.
