# Delegation Policy — who does the work

Apkallu has three places work can run: the **orchestrator** (a frontier model that plans, decides,
and verifies), **sandboxed VM sessions** (a long-horizon agent that implements on a throwaway copy of
the repo), and **local models** (served from a local OpenAI-compatible server — unmetered, but weaker
and limited by your hardware). This file is the rule for picking among them.

## Core principle

**The orchestrator decides and verifies. The sandbox implements. Local models do the cheap, high-volume,
low-stakes work.**

- The orchestrator owns the judgment calls: what to build, how to decompose it, which lane to route to,
  and — the part that never delegates — whether a result is actually correct and merge-worthy.
- Real implementation work (writing code against a real task) is handed to a **sandboxed VM session**:
  launch it, let it develop on an isolated checkout, then review the patch it returns. The orchestrator
  orchestrates and verifies; the VM develops.
- Local models are free, so when a task is genuinely low-stakes, prefer local.

### What the orchestrator keeps for itself

Anything a sandbox VM **cannot** do stays with the orchestrator:

- Reproduction, diagnosis, and verification that need a **real browser or device** — a VM can't drive
  one.
- The final review / merge decision. This is a trust boundary: a worker's output is untrusted until the
  orchestrator (or a gate) has checked it.
- Planning, decomposition, and architecture — these need the strongest reasoning available.

A fix isn't done because it applied or type-checked. It's done when it works **and** broke nothing else,
verified with a real test — and the orchestrator confirmed it's fixing the real mechanism, not a guess.

## Decompose, then delegate (the small-input rule)

Weaker workers (local models especially) degrade fast on large inputs: they reason endlessly, run out of
output budget, or fabricate a plausible-looking result instead of doing the work. The defence is
**decompose before delegating** — the orchestrator breaks a task into small, self-contained chunks
(function-sized, not file-sized), the worker executes each chunk, the orchestrator aggregates and
verifies. Keep the input to a weak worker small. This is the MinionS pattern: decompose → execute →
verify.

The discriminator for whether a worker can be trusted unattended is **not code quality** — most models
can write a correct snippet. It's **honesty under the harness protocol**: does it actually run the thing,
report the real output, and respect file-safety rules (e.g. append-only files), or does it claim success
it never achieved? A fabricated "done" is the worst outcome, because it burns an iteration silently. The
cure is harness-side: make success conditions demand **gate-checkable artifacts** (a file that exists, a
test that ran, a mode that's set), so a fabricated completion fails the gate regardless of which model
produced it.

## Routing table

| Work | Goes to | Why |
|---|---|---|
| Planning, decomposition, architecture | orchestrator | needs frontier reasoning |
| Code on real tasks | sandboxed VM session | isolated checkout; orchestrator reviews the returned patch |
| Reproduction / verification needing a real browser or device | orchestrator | a VM can't drive one |
| Final review / merge judgment | orchestrator | trust boundary |
| Log / diff / trace summarization | local (general) | high volume, low stakes |
| Task triage, routing, yes/no checks | local (triage) | fast and free |
| First-pass code review before the orchestrator | local (coder) | filters noise before spending frontier tokens |
| Test / boilerplate drafts (orchestrator verifies) | local (coder) | decompose → local execute → verify |
| Embeddings / memory search | local (embed) | never costs metered tokens |
| Watching / polling / monitoring | local (triage) | runs continuously for free; wakes the orchestrator only when needed |

Pick a lane by two axes: **does the task need tools, and does it need reasoning?** Tool-using,
reasoning-heavy work goes up the ladder (sandbox or orchestrator); trivial, high-volume, read-only work
goes local. When a local model is suitable, the routing config names which model fills each role
(`<your-model>` per role) — Apkallu works with whatever models and providers you configure.

## Spend policy

- **No unattended paid spend.** Any paid resource is a queued decision with no auto-default — the operator
  approves it explicitly. Default to free tiers.
- **Metered model quota** (your inference provider) is bounded: every loop run carries mandatory stop
  conditions (a max-runs and/or max-minutes cap). Overflow past the included quota is opt-in, not silent.
- **Local models are unmetered.** When in doubt and the task is low-stakes, go local.

## Local serving notes

If you run local models, the served context length is load-bearing and easy to get wrong:

- A load can silently fail (out of memory for the KV cache) and a later request can spin up a
  **much smaller default context** under the same model id — which then breaks any nested agent that
  needs the larger window. **Always verify the actual served context length after loading**, don't trust
  that the requested size took.
- Idle expiry plus lazy reload can quietly drop a pinned context length. Pin it, and re-check.

Net: prefer a serving setup where the right context loads cleanly with no special flags, and treat any
model that needs serving hacks to fit as a worse choice for unattended work, all else equal. Dense models
that don't fit in VRAM read every parameter per token and run slow — batch-only. Mixture-of-experts
models read only their active experts, so they stay usable even when their full weights spill to RAM; the
cost there is load time, not steady-state speed.
