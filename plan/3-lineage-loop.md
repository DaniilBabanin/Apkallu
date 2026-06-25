# Plan 3 — Close the lineage loop (the "self-improving" angle)

**Source idea:** Composio's "self-improving system" framing. The one genuinely novel adaptation —
a feature, not a gap-fill. Verify appetite before building.

## The gap
`loop/run.sh:501-511` already records a full lineage graph per green commit:
commit → job → model → prompt → profile → machine (schema in `db/migrations/002_lineage.sql`).
The data is **written and never read**: `local/retro.sh` only counts commits / backlog units /
decisions — it ignores the lineage graph entirely. The signal needed to learn *which model / profile /
prompt yields green* is captured and unused.

## The change (start lazy, rung 4 — use what's installed)
Don't build an ML loop. Add one query.

- Extend `local/retro.sh` (or a sibling) with a **green-rate by model/profile** readout from the
  lineage tables: per `model_version` / `sandbox_profile`, count jobs that reached a `commit` node vs.
  jobs that didn't. PG-down → skip cleanly (mirror the existing `PG_AVAIL=0` no-op pattern).
- Surface it in `director/REPORT.md` via `local/digest.sh` so the director sees "model X greens 80%,
  model Y 30%" and can route accordingly.
- Only later, if it earns it: feed that back into `policy/routing.md` / cascade `--profile` auto-pick.
  NOT now — YAGNI until the readout proves useful.

## Files
- `local/retro.sh` (+ a lineage query) or a new `local/lineage.sh` reader — note `local/lineage.sh`
  already exists; check what it does first and extend rather than duplicate.
- `tests/pg_lineage_test.sh` already exists — extend it with a green-rate fixture.

## Done when
`./gate.sh` ends `RESULT: PASS` with a test proving: given fixture lineage rows, the readout reports
correct green-rate per model/profile; PG-unavailable prints a clean skip, no error.

## Notes
- Highest novelty, lowest urgency. The other two close holes; this opens a capability.
- Verify the director actually wants routing-by-history before going past the readout — otherwise it's
  speculative scope (VISION decision filter: asked-for first).
- `local/lineage.sh` and `tests/pg_lineage_test.sh` exist — confirm scope overlap before writing.
