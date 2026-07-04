#!/usr/bin/env bash
# Tests for the guard-pause mechanic (substrate: only the action is held — a tripped guard
# escalates a D-NNN quoting the task, which PAUSES that task; the loop works the rest of the
# backlog; answering the decision unpauses). Covers loop/run.sh paused_tasks/next_task via the
# RUN_SH_LIB=1 sourcing seam — no claude, no network, fixture dirs only. loop/scheduler.sh's
# have_task duplicates the same awk convention, so this is its logic test too.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
N=0
pass() { N=$((N + 1)); echo "ok   $1"; }
fail() { N=$((N + 1)); FAIL=1; echo "FAIL $1"; }

# shellcheck source=/dev/null
RUN_SH_LIB=1 source "$SELF_DIR/loop/run.sh"

# Fixture: backlog with two open tasks; DECISIONS.md written per-case.
D="$TMP/repo"
mkdir -p "$D/director"
printf '# Backlog\n\n- [ ] task alpha\n- [ ] task beta\n\n## Done\n' > "$D/backlog.md"
cd "$D"

# 1. no decisions file -> top task picked, nothing paused
if [ -z "$(paused_tasks)" ] && [ "$(next_task)" = "- [ ] task alpha" ]; then
  pass "no decisions -> top task picked"
else
  fail "no decisions (paused='$(paused_tasks)' next='$(next_task)')"
fi

# 2. OPEN decision quoting task alpha -> alpha paused, beta picked
cat > director/DECISIONS.md <<'EOF'
# Decisions Queue

## D-001 — LoopGuard tripped after 2 identical iterations
**Asked:** 2026-07-04 · **Default applies:** 2026-07-07 → default = pause this task, keep loop alive
**Trigger:** The loop produced the identical task+diff signature for 2 consecutive iterations on:
> - [ ] task alpha

Stuck-repeat.
**Question:** How should the director resolve this stuck loop?
**Options:** (a) investigate · (b) split · (c) drop
**Recommended default:** (a)
**Answer:**
EOF
if [ "$(paused_tasks)" = "- [ ] task alpha" ] && [ "$(next_task)" = "- [ ] task beta" ]; then
  pass "open decision pauses quoted task; next open task picked"
else
  fail "open-decision pause (paused='$(paused_tasks)' next='$(next_task)')"
fi

# 3. answering the decision unpauses (same detection as local/decide.sh apply)
sed -i 's/^\*\*Answer:\*\*$/**Answer:** (a) — director via tui 2026-07-04/' director/DECISIONS.md
if [ -z "$(paused_tasks)" ] && [ "$(next_task)" = "- [ ] task alpha" ]; then
  pass "answered decision unpauses the task"
else
  fail "answered-decision unpause (paused='$(paused_tasks)' next='$(next_task)')"
fi

# 4. all open tasks paused -> next_task empty (loop/scheduler stop condition)
cat > director/DECISIONS.md <<'EOF'
## D-001 — stall
**Trigger:** no progress on:
> - [ ] task alpha
**Answer:**

## D-002 — stall
**Trigger:** no progress on:
> - [ ] task beta
**Answer:**
EOF
if [ -z "$(next_task)" ]; then
  pass "all tasks paused -> next_task empty"
else
  fail "all-paused (next='$(next_task)')"
fi

# 5. CASCADE_TASK bypasses the pause filter (dispatched unit runs regardless)
if [ "$(CASCADE_TASK='- [ ] task alpha' next_task)" = "- [ ] task alpha" ]; then
  pass "CASCADE_TASK bypasses pause filter"
else
  fail "CASCADE_TASK bypass"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "pause_task_test: all $N passed"
else
  echo "pause_task_test: FAILURES ($N run)"
  exit 1
fi
