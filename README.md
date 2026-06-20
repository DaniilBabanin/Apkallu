# Apkallu

A self-hosted autonomous dev agency. Give it an instruction; a loop turns it into committed work —
running implementation inside disposable microVMs and fanning out across many of them in parallel,
while the orchestrator decides and verifies and the VMs develop.

Apkallu is one idea seen from two sides: **how to run agents unattended and sandboxed, with no human
at a terminal.** The loop provides concurrency and coordinates through git refs (not LLM-judged
gates); the microVM is the security boundary — the host is never at risk during execution, and an
agent's output is reviewed before it ships.

Clone it onto any Linux box with hardware virtualization and run an independent agency there.

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

## Setup
1. `cp .env.example .env` and fill in your inference endpoint, key, and model.
2. Configure the local sandbox and check deps: `local/sandbox-setup.sh install`.
3. Build the golden VM image (one-time per machine): `evals/agentic/build-image.sh`.
4. Smoke-test the VM lane: `evals/agentic/smoke.py`.

## Running
- One sandboxed session: `evals/agentic/run_session.py --repo DIR --task-file FILE`
- Parallel fanout: `evals/agentic/dispatch.py --jobs jobs.json`
- The loop: `loop/run.sh` · Status: `status.sh` · TUI: `tui.sh`

## Inference
All inference is provider-agnostic via env vars (see `.env.example`) — nothing is hardcoded to a
vendor. The host-side proxy injects your API key so it never enters the VM.

## License
Apache-2.0.
