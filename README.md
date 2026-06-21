# Apkallu

A self-hosted autonomous dev agency. Give it an instruction; a loop turns it into committed work —
running implementation inside disposable microVMs and fanning out across many of them in parallel,
while the orchestrator decides and verifies and the VMs develop.

Apkallu is one idea seen from two sides: **how to run agents unattended and sandboxed, with no human
at a terminal.** The loop provides concurrency and coordinates through git refs (not LLM-judged
gates); the microVM is the security boundary — the host is never at risk during execution, and an
agent's output is reviewed before it ships.

Clone it onto any Linux box with hardware virtualization and run an independent agency there.

## What it builds on, and what's actually new

Apkallu is glue, not a new agent or model. The implementation agent inside the VM is OpenHands; the
loop's inner worker is Claude Code; isolation is KVM/libvirt microVMs and bubblewrap; inference is
whatever OpenAI-compatible endpoint you configure. None of those are ours.

What Apkallu adds is the **combination** that runs them *unattended and headless*. No single piece is
novel — the assembly is:

- the **microVM as the security boundary**, so untrusted execution never touches the host;
- **git-ref coordination via committed claim markers** (GUPP) — a worker claims a unit by committing a
  marker, so a second dispatcher reads it and skips; lease-free, no lock server. The merge authority is
  a deterministic gate (`./gate.sh` → `RESULT: PASS`) that commits on green with no human in the loop;
- a **non-blocking decisions queue** — reversible calls take a default and proceed, irreversible ones
  queue with a default of NO, so it never stalls on a human.

Two tools sit closest. The **Ralph loop** (an agent looped to a done-condition) is the nearest in
spirit — minimal glue run to a done-condition; Apkallu adds VM isolation, an external gate instead of a
self-judged commit, git-ref fan-out, and the decisions queue. **ComposioHQ's agent-orchestrator** is
the nearest in mechanics — parallel git-worktree agents merged on a deterministic green-CI gate — so a
pass/fail gate over the model's self-grade is *not* unique to Apkallu. Apkallu's differences from it:
microVM isolation (vs container), committed-ref claiming (vs a watched dashboard), and the gate as the
merge authority paired with a non-blocking decisions queue (vs the gate informing a human who merges) —
the same gate, the opposite stance on the human.

**What it is not:** not a coding agent or a model (it orchestrates existing ones); not a hosted service
(you clone it onto your own Linux box); not a multi-agent chat framework (it deliberately avoids
interactive/TTY coordination, which stalls headless — `policy/substrate.md`); not a general workflow
engine (it is dev-work-specific: backlog → gated commits).

**Status.** The mechanics are built and wired — sandbox isolation, the gate, the loop, git-ref fan-out.
How well it produces unattended work end-to-end depends on the models you point it at and your backlog;
measure that on your own setup rather than taking it on faith.

## What's here
- **loop/** — the iteration loop (`run.sh`), the cascade orchestrator (`cascade.sh`), commit enforcement.
- **evals/agentic/** — the microVM lane: `vm.py` (VM lifecycle), `dispatch.py` (RAM-bounded parallel
  fanout), `run_session.py` (one session), `proxy.py` (auth-injecting proxy that keeps the inference
  key off the VM), `egress_proxy.py` (domain allowlist).
- **local/** — ops: scheduler, watcher, status, the job queue, a local-LLM loader, sandbox setup.
- **lib/ + db/** — optional Postgres control plane (jobs + events).
- **policy/** — routing, delegation, and substrate guidance.
- **tests/** — shell test suites for the above.

## Requirements
Apkallu runs on **any Linux machine** that has:
- **KVM / libvirt** with hardware virtualization — the VM/fanout lane needs it; there is no non-virt
  fallback.
- **An OpenAI-compatible inference endpoint** — a remote provider, or a local server such as
  llama.cpp / vLLM / Ollama.
- `qemu` + `libvirt`, `bubblewrap` + `socat` (the loop's local sandbox), Python 3, and `jq`.

## Install dependencies (Debian / Ubuntu)
Package names are apt; adapt for your distro. Install only the groups you need.

```bash
# Gate + loop tooling (required to run ./gate.sh and the loop)
sudo apt install -y shellcheck jq python3 bubblewrap socat

# VM / fanout lane (KVM) — qemu, libvirt, the cloud-init seed builder, image fetch
sudo apt install -y qemu-system-x86 qemu-utils libvirt-daemon-system \
                    libvirt-clients virt-install xorriso curl
sudo usermod -aG libvirt,kvm "$USER"   # log out/in for the group change to take effect

# Optional: Postgres control plane (jobs + lineage). Tests skip cleanly without it.
sudo apt install -y postgresql-18
```

The host runs only the Python 3 standard library — there are no host pip requirements.
The agent runtime (OpenHands) is installed *inside* the VM image by `build-image.sh`.

## Setup
1. `cp .env.example .env` and set `LLM_BASE_URL`, `LLM_API_KEY`, and `LLM_MODEL`.
2. Configure the local sandbox and check deps: `local/sandbox-setup.sh install`.
3. Build the golden VM image (one-time per machine): `evals/agentic/build-image.sh`.
4. Smoke-test the VM lane: `evals/agentic/smoke.py`.

## Running
- One sandboxed session: `evals/agentic/run_session.py --repo DIR --task-file FILE`
- Parallel fanout: `evals/agentic/dispatch.py --jobs jobs.json`
- The loop: `loop/run.sh` · Status: `status.sh` · TUI: `tui.sh`

## Inference
All inference is provider-agnostic via env vars (see `.env.example`) — nothing is hardcoded to a
vendor. Point Apkallu at any OpenAI-compatible endpoint:

- **`LLM_BASE_URL`** — full upstream URL, `scheme://host[:port]/path` (e.g.
  `https://api.example.com/openai/v1` or `http://localhost:11434/v1`). The host-side proxy remaps the
  request path, so endpoints on `/v1`, `/api/v1`, etc. all work — not just `/openai/v1`.
  (`LLM_UPSTREAM_HOST` is kept as a legacy host-only alternative: implies `https` + `/openai/v1`.)
- **`LLM_API_KEY`** — credential for that endpoint (may also live in `evals/agentic/.secrets.env`).
- **`LLM_MODEL`** — default model slug (override per run with `--model`).

The host-side proxy injects your API key so it never enters the VM.

## License
Apache-2.0.
