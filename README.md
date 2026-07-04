# Apkallu

A self-hosted autonomous dev agency. Give it an instruction; a loop turns it into committed work.
Loop workers run sandboxed (bubblewrap, isolated git worktrees), fanned out in parallel, while the
orchestrator decides and verifies; a disposable-VM lane (`evals/agentic/`) runs isolated coding
sessions for external work.

The idea: run agents unattended and sandboxed, with no human at a terminal. The loop handles
concurrency and coordinates through git refs (plus a Postgres job queue when it's up), not
LLM-judged gates. The sandbox is the security boundary, and an agent's output is gated before it
ships.

Clone it onto any Linux box with hardware virtualization.

## What it builds on, and what's new

Apkallu is glue, not a new agent or model. Inside the VM the implementation agent is OpenHands; the
loop's inner worker is Claude Code; isolation is KVM/libvirt VMs plus bubblewrap; inference is any
OpenAI-compatible endpoint. None of those are ours.

The new part is combining them to run unattended and headless:

- sandboxed execution as the security boundary: loop workers under bubblewrap on isolated
  worktrees; the VM lane for isolated coding sessions on external repos;
- git-ref coordination (GUPP): dispatch claims a unit atomically via the Postgres job queue when
  it's up, else by committing a claim marker a second dispatcher reads and skips. Lease-based in
  PG, lock-server-free in git. Merge authority is a deterministic gate (`./gate.sh` →
  `RESULT: PASS`); the harness commits on green with no human in the loop;
- a non-blocking decisions queue: reversible calls take a default and proceed; irreversible ones
  queue a decision and stay undone until the director answers, pausing only that task.

Closest prior art is the Ralph loop and ComposioHQ's agent-orchestrator; Apkallu differs by combining
VM isolation (over containers), committed-ref claiming (over a watched dashboard), and the gate
as merge authority.

It is not a coding agent or model, a hosted service, a multi-agent chat framework, or a general
workflow engine; it is dev-specific, backlog to gated commits, and avoids interactive/TTY coordination,
which stalls headless (see `policy/substrate.md`).

The mechanics are built and wired. How well it produces unattended work depends on the models you point
it at and your backlog, so measure that on your own setup.

## What's here
- `loop/`: iteration loop (`run.sh`), cascade orchestrator (`cascade.sh`), scheduler
  (`scheduler.sh`), commit enforcement.
- `evals/agentic/`: the VM lane. `vm.py` (lifecycle), `dispatch.py` (RAM-bounded parallel fanout),
  `run_session.py` (one session), `proxy.py` (keeps the inference key off the VM), `egress_proxy.py`
  (domain allowlist).
- `local/`: ops. Watcher, job queue, local-LLM loader, sandbox setup, decision/digest/lineage/map
  tooling. (Status lives at the repo root: `status.sh`.)
- `lib/` + `db/`: optional Postgres control plane (jobs + events).
- `policy/`: routing, delegation, substrate guidance.
- `tests/`: shell test suites.

## Requirements
Any Linux machine with:
- KVM / libvirt with hardware virtualization. The VM/fanout lane needs it; no non-virt fallback.
- An OpenAI-compatible endpoint (remote, or local: llama.cpp, vLLM, Ollama).
- `qemu` + `libvirt`, `bubblewrap` + `socat` (the loop's local sandbox), Python 3, and `jq`.

## Install dependencies (Debian / Ubuntu)
Package names are apt; adapt for your distro. Install only the groups you need.

```bash
# Gate + loop (for ./gate.sh and the loop)
sudo apt install -y shellcheck jq python3 bubblewrap socat

# VM / fanout lane (KVM)
sudo apt install -y qemu-system-x86 qemu-utils libvirt-daemon-system \
                    libvirt-clients virt-install xorriso curl
sudo usermod -aG libvirt,kvm "$USER"   # log out/in to apply

# Optional: Postgres control plane; tests skip without it
sudo apt install -y postgresql-18
```

The host needs only the Python 3 standard library (no pip). OpenHands is installed inside the VM image
by `build-image.sh`.

## Setup
1. `cp .env.example .env` and set `LLM_BASE_URL`, `LLM_API_KEY`, `LLM_MODEL`.
2. Configure the sandbox, check deps: `local/sandbox-setup.sh install`.
3. Build the VM image (one-time): `evals/agentic/build-image.sh`.
4. Smoke-test the VM lane: `evals/agentic/smoke.py`.

## Running
- One sandboxed session: `evals/agentic/run_session.py --repo DIR --task-file FILE`
- Parallel fanout: `evals/agentic/dispatch.py --jobs jobs.json`
- The loop: `loop/run.sh` · Status: `status.sh` · TUI: `tui.sh`

## Inference
Provider-agnostic via env vars (see `.env.example`):

- `LLM_BASE_URL`: full upstream URL, `scheme://host[:port]/path` (e.g. `https://api.example.com/openai/v1`
  or `http://localhost:11434/v1`). The host-side proxy remaps the path, so `/v1`, `/api/v1`, etc. all
  work. (`LLM_UPSTREAM_HOST` is a legacy host-only alias.)
- `LLM_API_KEY`: credential (may also live in `evals/agentic/.secrets.env`).
- `LLM_MODEL`: default model slug (override with `--model`).

The host-side proxy injects your API key so it never enters the VM.

## License
Apache-2.0.
