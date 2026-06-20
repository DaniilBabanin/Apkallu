# Execution Substrate — where work runs, and what is trusted

This file defines Apkallu's execution-substrate model: where work actually runs, what provides
concurrency, and where the trust boundaries sit. The recurring principle is one sentence:
**the orchestrator enforces policy; the agent provides intelligence.** The agent is hired for
reasoning, not for authority — every consequential action it proposes is mediated by the substrate.

## The model

- **Concurrency comes from the proven orchestration loop.** The loop dispatches parallel work the way
  it already dispatches sequential work — by fanning out into isolated checkouts and aggregating the
  results. Concurrency is a property of how the orchestrator schedules work, not a feature of any one
  agent runtime. There is a bounded ceiling on how many units run at once.

- **Work runs inside the microVM sandbox.** Real implementation happens in a throwaway VM on an
  isolated copy of the repo, never on the host. The VM is the security boundary: whatever an agent does
  inside it — run code, install packages, touch the filesystem — cannot reach the host. The host is
  never at risk during execution. When the VM is discarded, so is anything it did.

- **Agent output is untrusted until it is reviewed.** A patch coming back from a sandbox is a
  *proposal*, not a merge. It is gated by review (by the orchestrator, or by an automated gate, or
  both) before it ships anywhere real. "It applied" and "it type-checked" are not "it's done" — done
  means it works, it broke nothing else, and that was verified. Code quality is cheap; trust is earned
  at the gate.

- **Irreversible actions stay behind a gate.** Anything that cannot be undone — deploying, deleting,
  spending money, anything credentialed — does not happen autonomously. It becomes a queued decision
  with a default of NO; only the action itself is held, the rest of the run continues. Reversible
  choices get a sensible default and proceed; the operator is never a blocker for ordinary work.

## Why the loop, and not an interactive multi-agent runtime

A general design principle, not a one-off finding: **interactive-only concurrency features are
unsuitable for unattended, headless runs.** Many multi-agent or "team" runtimes are built for a human
sitting at a terminal — they coordinate through a TTY, drive sub-agents as terminal panes, or require
an interactive session to dispatch work. Under Apkallu's run model (a non-interactive process, no human
at a keyboard, output piped) those mechanisms have nothing to attach to and stall immediately.

So Apkallu does not depend on any such runtime for its concurrency. The orchestration loop already
provides parallelism through isolated checkouts and keeps all coordination in version control, where it
is durable and inspectable rather than living in an ephemeral interactive session. If a future
substrate is ever adopted, the bar it must clear is **headless dispatch with no TTY** — verified
before it is trusted, the same as any other agent output.

## The trust boundaries, in one view

| Boundary | What it protects | How it is enforced |
|---|---|---|
| Host ↔ sandbox | The host machine and its credentials | All untrusted execution runs in the microVM; the VM is disposable |
| Agent output ↔ what ships | The real repo / production | Review or an automated gate before anything merges or deploys |
| Reversible ↔ irreversible | Anything that can't be undone | Irreversible actions queue a decision (default NO); the run continues |

The orchestrator owns all three. The agent's job is to be smart inside them.
