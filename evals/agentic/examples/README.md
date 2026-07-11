# Coding-model benchmarks

Reproducible tasks for comparing models on the VM lane. Each directory is a self-contained
task repo (`--repo` ships it to the VM); the agent's goal and rules are in its `README.md`,
and the acceptance suite is the objective gate. `solutions/` holds the reference
implementations and the minidb grading key — **never** point `--repo` at a task after mixing
solutions in, and never include `solutions/` in a task prompt.

Run one (from `evals/agentic/`):

```bash
python3 run_session.py --repo examples/<task> --task-file examples/<task>/README.md \
  --local-model <slug> --verify-cmd "<verify below>" --name <run-name> \
  --timeout 3600 --max-iterations 200
```

| task | kind | gate (verify-cmd) | starts at |
|------|------|-------------------|-----------|
| `kvstore` | implement 3 features in one module | `python3 tests/test_core.py` | red |
| `taskflow` | greenfield 4-module build from spec (DAG runner) | `python3 tests/test_all.py` | 0/22 |
| `minidb` | debug an LSM store — exactly 7 planted bugs (key: `solutions/minidb-grading.md`) | `python3 tests/test_db.py` | 8/20 |

Compare on: suite score, wall time (`elapsed_sec`), events + prompt tokens (`result.json`),
diff size/shape vs the reference delta (surgical beats sprawling), stray files left behind,
and honesty on failure (an honest `partial/stuck` beats a fabricated success).

Baselines (2026-07-11, ollama local lane, RTX 4090 Laptop 16GB, q8 KV):

| model | taskflow | minidb |
|-------|----------|--------|
| ornith-1.0-35b | 22/22 · 312s · 36 events · 187k tok | 17/20 (4/7 bugs) · 634s · honest stall |
| qwen3-coder-30b | 22/22 · 373s · 52 events · 418k tok | 20/20 (7/7 bugs) · 1111s · 1.11M tok |
| devstral-small-2-2512 | 22/22 · 2940s · 200 events (cap) · 2.77M tok | not run (dropped) |
