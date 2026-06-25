# Plan 1 — Up-cascade auto-merge (gate-green branch → main)

**Source idea:** ComposioHQ/agent-orchestrator `approved-and-green → auto-merge`. The pattern Apkallu's
own "gate is the merge authority" philosophy already implies.

## The gap
`cascade.sh:50` openly defers merge-back: *"the up-cascade — merge + digest — is … not this one."*
Confirmed by grep: nothing in `loop/enforce.sh` (subcommands: `record`, `project-commit`, `counts`,
`sanitize`) or anywhere else merges `cascade/*` branches into main. So `dispatch` fans out workers,
each passes `./gate.sh` on its isolated `cascade/<id>` branch — and the green branches just sit there.
The down-cascade is built; the up-cascade is not.

## The change
A worker's branch that is gate-green and whose backlog unit is checked off is, by Apkallu's own rule,
*done* — so merge it. No LLM, no human: git facts decide.

- New `cascade.sh merge` (or extend `reconcile`): for each `cascade/<id>` whose unit is checked
  (`unit_checked`) and whose branch passes the gate, fast-forward / merge into main, then prune the
  worktree + branch (reuse `reset`'s teardown).
- Order by `blocked-by` so dependents merge after their deps (the dep graph already exists in the unit
  markers; `next_ready` logic is the reference).
- Disjoint-paths invariant (AGENCY recipe) means merges should be conflict-free; if a merge conflicts,
  do NOT auto-resolve — `escalate` it (irreversible-ish, human call) and skip only that branch.
- Run `local/digest.sh` after the batch (the "+ digest" half of up-cascade).

## Files
- `loop/cascade.sh` — new subcommand, reuse `unit_checked` / claim teardown / `escalate`.
- `tests/cascade_test.sh` (or a new `tests/cascade_merge_test.sh`) — fixture branches: one green-merges,
  one conflicting-escalates, one blocked-waits.

## Done when
`./gate.sh` ends `RESULT: PASS` with a test proving: a checked + gate-green `cascade/<id>` branch lands
on main and its worktree/branch are pruned; a conflicting branch escalates (D-NNN) instead of merging.

## Notes
- Philosophy fit: perfect — extends GUPP (refs decide), no dashboard, no LLM arbitration.
- Highest value of the three: it fills a real hole, not a polish.
- Keep it lazy: a `git merge --ff-only` where possible; fall back to a no-edit merge commit. Don't build
  conflict resolution — escalate instead.
