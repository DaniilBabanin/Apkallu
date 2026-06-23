# Routing — how work reaches an execution lane

Apkallu turns instructions into committed work. This guide is the routing layer: given a task,
which **execution lane** runs it, with **which model**, and how concurrent work is queued.

The orchestrator **routes and verifies**; workers and VMs **execute**. The orchestrator never trusts
a worker's word that something ran — it checks the artifact, runs the test, reads the gate. Safety
lives in the harness, the sandbox, and the gate, never in the worker model.

You configure the models and the provider via env; nothing here is tied to a specific vendor. The
references below — "a small local model", "a strong open coder", "the frontier model" — are roles you
fill with whatever you run.

---

## The decision axis: does the task execute code?

This is the cleanest split, and it determines the lane before model choice does.

- **Executes code** (agentic work: drives tools, runs tests, runs commands, touches untrusted or
  experimental code) → **always the VM lane.** The model is just a parameter to the sandbox. The VM
  is what makes execution safe: real tests run inside it (so a model that *claims* it ran something is
  caught), and code runs in an isolated guest, not on the host.
- **Pure generation** (embeddings, classify/route, summarize, docs, commit messages, JSON/structured
  output, explain) → **direct**, to the cheapest warm model that clears the bar. Do **not** route this
  through the VM: no code executes, so the VM adds only boot latency and no safety. Output-side risk is
  handled by keeping secrets out of context and by the gate.

---

## The three lanes (the *where*)

- **Local lane** — open models you run on your own hardware via a local OpenAI-compatible server
  (e.g. llama.cpp, vLLM, or Ollama). Free, private, fast for small models.
  Treat local models as having **zero injection-safety** and as prone to **fabricating execution when
  unsupervised** (claiming a test passed without running it). So a local model is safe only when used
  (a) on **trusted input** for cheap, general, high-volume generation, or (b) **as the model inside the
  VM sandbox**, where the harness runs the real tests and the gate covers the output.

- **Remote lane** — a strong open coder served by your remote inference provider, configured through
  `.env` (provider base URL + API key). Use it when local quality is insufficient or when you need
  many concurrent sessions that a single local box can't serialize. Like local models, treat it as
  injection-unsafe; it earns trust only behind the sandbox and the gate.

- **VM lane** — an isolated guest (e.g. a microVM with the agent SDK and a container runtime inside)
  where a model can execute code without touching the host. This is a **sandbox (the *where*)**,
  orthogonal to the **model (the *who*)**: the VM can host a local coder OR a remote open model. Use it
  whenever a model must run untrusted or experimental code. The VM is the security boundary — secrets
  stay off the VM.

- **Frontier lane** — your strongest model (typically a paid frontier API). It is the quality ceiling
  for planning and orchestration, and it is the **gater** that reviews any lane's output before anything
  irreversible happens. Not sandboxed by default, so it is not where you run untrusted code; it is where
  you reason about it.

---

## Sensible defaults — start cheap, escalate by difficulty and stakes

| Task profile | Default lane · model | Why |
|---|---|---|
| Embeddings / RAG | local · a small embedding model (pinned, co-resident) | free, always warm |
| Trivial: classify / route / yes-no | local · a small warm model | instant, free — **trusted input only** |
| General non-code: summaries, docs, commit msgs | local · a small-to-mid warm model | cheap, free, no code executes |
| Structured / JSON / schema output | local · a model good at structured output | enforce the schema in the harness |
| Coding, fully-specified, testable, **sandbox needed** | VM · a **local coder** first (free) → escalate to VM · a remote open model if it fails | sandbox catches fabrication; try free before paid |
| Hard / long-horizon real-world coding | VM · a strong open coder you configure (remote) | best available, sandboxed; escalate the ones that matter |
| Hard / novel / ambiguous / high-stakes; planning; orchestration | **frontier** | quality ceiling and reasoning |
| Review / gate of any lane's output; secrets / irreversible actions | **frontier** (or a human) | worker output is untrusted; safety is the harness + gate, never the worker |

**Escalation ladder:**
`local (trusted/cheap) → VM + local coder (free sandbox) → VM + remote open model (paid sandbox) → frontier`

Rules that never bend:
- Never run untrusted code outside the VM.
- Never put secrets in a local or open-model worker's context. Workers get no payment credentials and
  no cloud tokens — those live only in the orchestrator's dispatch environment.
- Irreversible actions (deploy / delete / credentials / money) always pass the gate.

---

## Roles — pick by two axes: needs tools? needs reasoning?

Fill each role with whatever model you've configured.

- **Embeddings / RAG** — a small embedding model. Pin it; it co-resides with everything and never
  triggers a swap.
- **Trivial generation, routing, classify, yes/no** — the smallest capable local model. Instant.
  Trusted input only.
- **General non-code** (summaries, docs, comments, commit messages, explanations) — a small-to-mid
  general model.
- **Agentic coding** (the model drives tools inside the VM) — a capable open coder. This is the only
  role that needs the sandbox.
- **Pure code generation, fully specified, no tools** — your best-quality coder; quality matters more
  than latency here.
- **Structured / JSON / schema output** — a model that follows schemas well; enforce the grammar or
  JSON schema in the harness rather than trusting the model.
- **Reasoning-heavy** — a model with strong reasoning; give it a generous token budget so it doesn't
  get cut off mid-thought.

---

## Cost is load time, not steady-state

For local serving, the recurring cost is usually **swapping a big model into memory**, not per-token
inference. So:

- Keep a **small model warm at all times** for cheap, high-volume work. Never let one trivial task
  evict a working coder.
- Load a **bigger model on demand**, and hold **one big model at a time** for simplicity.
- Give the active big model a generous keep-alive so a batch doesn't unload mid-run.
- Heuristic: **warm-and-good-enough beats cold-and-better.** Prefer the acceptable model that's already
  loaded over a marginally better one that costs a full reload.

---

## Queueing — be model-aware, not FIFO

A naive FIFO scheduler thrashes by reloading models for whichever task is next. Instead:

1. **Tag each task** with a capability class and an **ordered list of acceptable models** (best first),
   not a single hard pin — so the scheduler can pick "an acceptable model that's already loaded."
2. **Track the currently-loaded big model** as scheduler state.
3. **Drain by affinity:** prefer queued tasks whose acceptable set includes the loaded model.
4. **Switch the big-model slot** only when no acceptable work remains for it, or a high-priority task
   forces it — and only when enough queued work justifies amortizing the reload. Never reload a big
   model for a single task if a resident model is good enough.
5. **Keep the warm lane independent:** route trivial and general work to the always-warm small model on
   a separate queue; never evict the coder for it.
6. **Pin embeddings** so RAG never causes a swap.

Net effect: most tasks hit a warm model, and the expensive slot changes only when a batch earns it.

---

## Security posture, by lane

A recap of what the lanes and rules above already establish, in one place: every worker model is
assumed prompt-injectable, so safety lives in the harness, the sandbox, and the gate, never in the
model. The VM is the boundary (untrusted or experimental code runs only inside it, secrets stay off
it). No worker gets cloud tokens or payment credentials. Worker output is untrusted until the gater
(frontier model or human) reviews it, and irreversible actions always stop at the gate.

---

## Notes on concurrency

A single local box runs one big model at a time, so sandboxed local-coder work is effectively
**serialized**. When you need many parallel sandboxed sessions, prefer the remote lane (cloud,
K-concurrent). The "executes code → VM always" rule pays a per-task VM-boot cost; at low volume that's
fine. A warm or pooled VM can amortize it later if throughput demands it — not worth building until it
does.
