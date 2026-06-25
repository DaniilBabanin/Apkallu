# Plan 4 — Self-healing VM setup + preflight (DONE — commit 1761e94)

**Source idea:** transferring the novita + ssh config into a fresh checkout and trying the smoke
test. It failed twice on gitignored drop-ins the runtime assumed `build-image.sh` had already
provisioned. The lazy fix: the runtime owns its prereqs or fails loud — it never assumes them.

## The gap
The runtime path (`vm.py` / `smoke.py` / `run_session.py`) assumed `build-image.sh` had run in this
checkout. On a fresh clone (image + creds dropped in, builder skipped):
- `evals/agentic/build/` absent → `smoke.py:31` / `vm.py:189,249` / `run_session.py:38` open a log
  inside it → `FileNotFoundError`, instant crash.
- `evals/agentic/ssh/agent_id_ed25519` absent → `vm.py` uses it with no existence check → the VM
  boots, leases DHCP, then SSH auth fails for the full 20×3s loop → opaque `SSH never came up at
  <ip>` after ~3 min, with no hint the key is the cause.

Both are gitignored, so a fresh checkout always lacks them.

## The change
Self-heal what the runtime can; fail fast with a pointer on what it can't.

- `vm.py`: `os.makedirs(HERE/"build", exist_ok=True)` at import — every consumer `import vm`, so one
  line covers all `build/` writers. Preflight in `up()`: if the ssh key isn't readable, `raise
  SystemExit("… run evals/agentic/setup.sh")` before `virt-install` — instant clear error, no
  3-min boot-then-timeout.
- `build-image.sh`: auto-`ssh-keygen` when the key is absent (was `die "run ssh-keygen first"`).
  Safe there: the matching `.pub` is baked into the image the same run, so the pair is always
  consistent.
- `setup.sh` (new): one-shot, idempotent preflight. Provisions `build/` + key, validates inference
  config (`LLM_BASE_URL`, `LLM_API_KEY` / `.secrets.env`) and the VM image, reports every gap at
  once. **Auto-gens the key only when no image exists yet** (build-image bakes the match);
  **hard-stops when an image is present but its key is missing** — a fresh key that image rejects
  would silently recreate the gap. Credentials are checked, never auto-generated.
- `.gitignore`: ssh/ key, build/ runtime, generated smoke.md.

## Not done (deliberate)
- AGENCY.md is **not** wired to call setup.sh — the runtime error is JIT (fires only on a real gap);
  a doc mention would be eager (every session runs the no-op preflight → wasted roundtrip).
- `setup.sh` does not re-bake a mismatched image; that's `build-image.sh`'s job.

## Files
- `evals/agentic/vm.py` — makedirs at import + key preflight in `up()`
- `evals/agentic/build-image.sh` — auto-gen key when absent
- `evals/agentic/setup.sh` — new idempotent preflight
- `.gitignore` — local drop-ins (ssh/, build/, smoke.md)

## Verified
Idempotent (3× setup.sh, byte-identical, no mutation); safety gate (image + no key → hard-stop, no
gen); `vm.up()` preflight clear error; smoke `ALL PASS` + a real `run_session.py` task (created
`READY.txt`) end-to-end — no manual setup step.
