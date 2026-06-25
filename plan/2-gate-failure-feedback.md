# Plan 2 — Route the gate-failure tail back to the next attempt

**Source idea:** ComposioHQ/agent-orchestrator — *"CI failures are automatically routed back to the
agent,"* which receives the logs and fixes it. The faithful, lazy version of that.

## The gap
On gate-fail, `loop/run.sh:446-457` reverts the whole worktree and appends a generic NOTES line:

    Gate output: $GATE_LOG (gitignored, survives the revert).
    Iteration reverted. Investigate before retrying this task.

The actual failure (which test, which shellcheck line) lives only in the gitignored `$GATE_LOG`. The
next iteration re-picks the same task cold; its prompt says read NOTES *by range* — it never cats the
log path. So the next worker re-discovers the same failure from scratch. Wasted quota.

## The change
Route the failure to the *next attempt's prompt*, not into NOTES (keep NOTES lean — ARCHITECTURE
principle 5; agent-orchestrator routes-to-agent, it does not persist).

- In the prompt builder (`run.sh` ~line 359, the agency-mode `PROMPT=`), before constructing the
  prompt, look for the most-recent `$GATE_LOG` for this task on disk.
- If found, inline its **capped tail (~25 lines)** as a "last attempt failed the gate with:" block so
  the worker fixes the known failure instead of rediscovering it.
- Already redacted at write time (`run.sh:158` sed strips `sk-ant-*`), so the tail is safe to inline.

## Files
- `loop/run.sh` — prompt builder + a small "latest gate log for this task" lookup.
- `tests/` — a unit-level check that the tail is read from disk and capped (reuse the `RUN_SH_LIB=1`
  sourcing seam at `run.sh:291` to test the helper without entering the loop).

## Done when
`./gate.sh` ends `RESULT: PASS` with a test proving: given a prior gate log on disk, the next prompt
contains its capped tail; given none, the prompt is unchanged (back-compat).

## Notes
- Smallest diff of the three; cheapest win.
- Wrinkle: cascade runs one worker per process, so the tail MUST come from the latest gate log on disk,
  not a loop variable (which doesn't survive across invocations).
- Do NOT keep retrying in-place — Apkallu's two-layer design (inner `/goal` self-loop + independent
  outer gate) means an outer-gate-fail-after-claimed-green is the "worker flaked" case; reverting to a
  clean state is correct. This change only makes the *next* cold attempt better-informed.
