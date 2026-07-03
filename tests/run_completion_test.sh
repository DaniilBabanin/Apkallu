#!/usr/bin/env bash
# Tests for loop/run.sh's task-completion check — the backstop that catches a committed iteration
# which did NOT close its backlog task (the gate proves quality, not completion). Fixture-driven:
# run.sh is sourced via its RUN_SH_LIB=1 seam (loads the pure helpers WITHOUT entering the loop),
# every git-mutating case runs in a throwaway repo, so NO claude, NO network, and the live repo's
# state never affects the assertions.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
N=0
pass() { N=$((N + 1)); echo "ok   $1"; }
fail() { N=$((N + 1)); FAIL=1; echo "FAIL $1"; }

# Load the pure helpers (commit_closed_task, stall_decision) without running the loop.
# shellcheck source=/dev/null
RUN_SH_LIB=1 source "$SELF_DIR/loop/run.sh"

# Fresh temp git repo with a backlog.md + a NOTES.md, one base commit so HEAD/diff-tree work.
new_repo() {
  local d
  d="$(mktemp -d "$TMP/repo.XXXXXX")"
  git -C "$d" init -q
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  printf '# Backlog\n\n- [ ] a task\n\n## Done\n' > "$d/backlog.md"
  printf '# Notes\n' > "$d/NOTES.md"
  printf 'x\n' > "$d/other.txt"
  git -C "$d" add -A
  git -C "$d" commit -qm base
  printf '%s' "$d"
}

# --- commit_closed_task: HEAD touched backlog.md? ---------------------------
R="$(new_repo)"; cd "$R"
# 1. commit that does NOT touch backlog.md -> not closed (rc 1)
printf 'changed\n' >> other.txt
git commit -qam "loop: edit other"
if commit_closed_task; then fail "no-backlog-commit -> not-closed"; else pass "no-backlog-commit -> not-closed"; fi

# 2. commit that DOES touch backlog.md -> closed (rc 0)
printf -- '- moved\n' >> backlog.md
git commit -qam "loop: move task to Done"
if commit_closed_task; then pass "backlog-commit -> closed"; else fail "backlog-commit -> closed"; fi

# 3. commit touching BOTH backlog.md and NOTES.md still counts as closed (the normal happy path)
R="$(new_repo)"; cd "$R"
printf -- '- moved\n' >> backlog.md
printf 'learnings\n' >> NOTES.md
git commit -qam "loop: task + notes"
if commit_closed_task; then pass "backlog+notes-commit -> closed"; else fail "backlog+notes-commit -> closed"; fi

# 4. a substring filename (backlogXmd) must NOT match (grep -F, anchored) ----
R="$(new_repo)"; cd "$R"
printf 'y\n' > "backlogXmd"   # would match an unanchored / unescaped 'backlog.md' pattern
git add -A
git commit -qm "loop: add lookalike file"
if commit_closed_task; then fail "lookalike-filename -> not-closed"; else pass "lookalike-filename -> not-closed"; fi

# 5. a cascade unit's per-unit marker (done/<id>.md) ALSO counts as closing (partition model) ----
R="$(new_repo)"; cd "$R"
mkdir -p ./done
printf 'landed\n' > done/cTest-u1.md
git add -A
git commit -qm "loop: write done-marker"
if commit_closed_task; then pass "done-marker-commit -> closed (cascade partition)"; else fail "done-marker-commit -> closed (cascade partition)"; fi

# 6. a nested path under done/ must NOT match (markers are single-level done/<id>.md) ----
R="$(new_repo)"; cd "$R"
mkdir -p ./done/sub
printf 'z\n' > done/sub/y.md
git add -A
git commit -qm "loop: nested done file"
if commit_closed_task; then fail "nested-done -> not-closed"; else pass "nested-done -> not-closed"; fi

# --- stall_decision: committed backlog_touched notes_changed project_mode [gate_failed] ---
chk() { # name expected committed backlog_touched notes_changed project_mode [gate_failed]
  local name="$1" want="$2" got
  got="$(stall_decision "$3" "$4" "$5" "$6" "${7:-0}")"
  if [ "$got" = "$want" ]; then pass "$name"; else fail "$name (got '$got' want '$want')"; fi
}

# agency mode (project_mode=0)
chk "closed-task -> reset"                 reset     1 1 0 0
chk "closed-task+notes -> reset"           reset     1 1 1 0
chk "committed-but-unclosed -> increment"  increment 1 0 0 0
# the key one: a half-done run still appends NOTES; that must NOT mask the missing close
chk "unclosed-but-notes -> increment"      increment 1 0 1 0
chk "notes-only-no-commit -> reset"        reset     0 0 1 0
chk "nothing-happened -> increment"        increment 0 0 0 0

# external-project mode (project_mode=1): no agency backlog to move, any commit = progress
chk "external-commit -> reset"             reset     1 0 0 1
chk "external-notes-only -> reset"         reset     0 0 1 1
chk "external-nothing -> increment"        increment 0 0 0 1

# gate_failed=1 forces increment: the harness's own gate-failure lesson append flips
# notes_changed every red iteration — that must NOT reset the streak (audit fix 1.4), or
# an LLM regenerating a different failing change each attempt evades STALL_MAX forever.
chk "gate-fail+notes -> increment"         increment 0 0 1 0 1
chk "gate-fail-no-notes -> increment"      increment 0 0 0 0 1
chk "gate-fail dominates all-progress"     increment 1 1 1 0 1
chk "gate-fail external-mode -> increment" increment 0 0 1 1 1
chk "gate_failed omitted -> old behavior"  reset     0 0 1 0    # back-compat default

# a red-gate STREAK: N consecutive gate-fails (each appending a NOTES lesson) must return
# increment EVERY time, so STALL_STREAK reaches STALL_MAX and the loop stops.
streak_ok=1
for _ in 1 2 3; do
  [ "$(stall_decision 0 0 1 0 1)" = "increment" ] || streak_ok=0
done
if [ "$streak_ok" -eq 1 ]; then pass "3 consecutive red gates -> 3x increment (streak trips STALL_MAX)"; else fail "3 consecutive red gates -> 3x increment"; fi

# --- cascade_unit_id + done_instruction: the /goal completion contract (partition vs standalone) --
# The ONLY mechanical check on the run.sh contract change — a real claude worker can't run in the
# gate, so the prompt branch is verified here (a stub worker would obey either instruction blindly).
CASCADE_LINE='- [ ] **build it** — do the thing. <!-- cascade: id=cZ-u7 blocked-by=none -->'
PLAIN_LINE='- [ ] just a normal backlog task'

id="$(cascade_unit_id "$CASCADE_LINE")"
if [ "$id" = "cZ-u7" ]; then pass "cascade_unit_id extracts the unit id from a dispatched marker"; else fail "cascade_unit_id got '$id' (want cZ-u7)"; fi
id="$(cascade_unit_id "$PLAIN_LINE")"
if [ -z "$id" ]; then pass "cascade_unit_id is empty for a standalone task"; else fail "cascade_unit_id got '$id' (want empty)"; fi

di="$(done_instruction "$CASCADE_LINE")"
if printf '%s' "$di" | grep -q 'done/cZ-u7\.md' && printf '%s' "$di" | grep -qi 'do NOT edit backlog'; then
  pass "done_instruction (cascade): names done/<id>.md and forbids editing backlog.md"
else
  fail "done_instruction (cascade) wrong: $di"
fi
di="$(done_instruction "$PLAIN_LINE")"
if printf '%s' "$di" | grep -q '## Done' && ! printf '%s' "$di" | grep -q 'done/'; then
  pass "done_instruction (standalone): keeps the in-place move under '## Done'"
else
  fail "done_instruction (standalone) wrong: $di"
fi

# --- inner_cost: parse total_cost_usd from a `claude --output-format json` blob (budget mode) ---
# Feeds loop/scheduler.sh's burst spend accounting; must be empty (a no-op record) when absent.
if command -v jq >/dev/null 2>&1; then
  ic() { local got; got="$(inner_cost "$1")"; if [ "$got" = "$2" ]; then pass "$3"; else fail "$3 (got '$got' want '$2')"; fi; }
  ic '{"type":"result","is_error":false,"total_cost_usd":0.0123,"result":"done"}' 0.0123 "inner_cost: extracts total_cost_usd"
  ic '{"type":"result","is_error":false,"result":"no cost field here"}'           ""     "inner_cost: missing field -> empty"
  ic 'this is not json at all'                                                     ""     "inner_cost: unparseable -> empty (no abort)"
else
  echo "skip inner_cost checks (no jq)"
fi

echo "---"
if [ "$FAIL" -ne 0 ]; then
  echo "run_completion_test: FAIL ($N checks)"; exit 1
fi
echo "run_completion_test: OK ($N checks)"
