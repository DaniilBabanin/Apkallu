#!/usr/bin/env bash
# Tests for loop/cascade.sh `merge` — the UP-cascade (land gate-green, done branches into the base).
# Fixture-driven: CASCADE_GATE_CMD / CASCADE_DIGEST_CMD are stubbed, so NO real gate, NO model, NO
# network. Every case runs in its own throwaway repo (CASCADE_REPO), so this repo is never touched.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASCADE="$SELF_DIR/loop/cascade.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
N=0
pass() { N=$((N + 1)); echo "ok   $1"; }
fail() { N=$((N + 1)); FAIL=1; echo "FAIL $1"; }

# Fresh temp git repo with a minimal backlog.md (Parked + Done anchors).
new_repo() {
  local d
  d="$(mktemp -d "$TMP/repo.XXXXXX")"
  git -C "$d" init -q
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  cat > "$d/backlog.md" <<'EOF'
# Backlog

## Bootstrap
- [ ] **existing task** — a pre-existing standalone task.

## Parked
- nothing parked.

## Done
- nothing done.
EOF
  printf '.cascade/\n' > "$d/.gitignore"
  git -C "$d" add -A
  git -C "$d" commit -q -m init
  printf '%s' "$d"
}

# sim_unit <repo> <id> <worktree-edit-cmd> — simulate a completed dispatch of unit <id> under the
# PARTITION model (the worker contract run.sh now emits for cascade units):
#   * commit a tracked claim file on the base (as dispatch does, before the worktree exists),
#   * create the isolated worktree + branch cascade/<id> from HEAD,
#   * run <edit-cmd> inside the worktree (the worker's file change),
#   * write the unit's OWN done-marker done/<id>.md and NOT touch the shared backlog.md (so branches
#     are purely additive/disjoint and fan-in never collides on the backlog),
#   * commit the worker's loop commit, whose MESSAGE carries the `cascade: id=<id> ` marker
#     (run.sh's `git commit -m "loop: <line>"`) — the mechanical merge-readiness signal.
sim_unit() {
  local d="$1" id="$2" editcmd="$3" line wt="$1/.cascade/worktrees/$2"
  line="$(grep -E "<!-- cascade: id=$id " "$d/backlog.md" | head -1)"
  mkdir -p "$d/current_tasks"
  printf 'unit: %s\n' "$id" > "$d/current_tasks/$id.claim"
  git -C "$d" add "current_tasks/$id.claim"
  git -C "$d" commit -q -m "cascade claim: $id"
  git -C "$d" worktree add -q -b "cascade/$id" "$wt" HEAD
  ( cd "$wt" && bash -c "$editcmd" )
  mkdir -p "$wt/done"
  printf '%s\nDone: landed.\n' "${line#- \[ \] }" > "$wt/done/$id.md"
  git -C "$wt" add -A
  git -C "$wt" commit -q -m "loop: ${line#- \[ \] }"
}

# --- 1. green-merges + conflict-escalates + blocked-waits, all in one batch -------------------
D="$(new_repo)"
# A shared file two units will both touch (the conflict seed) — committed before any branch is cut.
printf 'base\n' > "$D/conflict.txt"
git -C "$D" add conflict.txt && git -C "$D" commit -q -m "seed conflict.txt"
cat >> "$D/backlog.md" <<'EOF'
- [ ] **green unit** — lands clean on a disjoint path. <!-- cascade: id=cUp-g blocked-by=none -->
- [ ] **conflict unit** — touches the shared path. <!-- cascade: id=cUp-c blocked-by=none -->
- [ ] **dep undone** — never finished. <!-- cascade: id=cUp-a blocked-by=none -->
- [ ] **blocked unit** — waits on the undone dep. <!-- cascade: id=cUp-b blocked-by=cUp-a -->
EOF
git -C "$D" add -A && git -C "$D" commit -q -m "add cUp units"

# Three completed branches; cUp-a is never dispatched (the unmet dependency).
sim_unit "$D" cUp-g 'printf hi > feature_g.txt'
sim_unit "$D" cUp-c 'printf branch-version > conflict.txt'
sim_unit "$D" cUp-b 'printf hi > feature_b.txt'
# Base moves AFTER the branches were cut (edits the shared path) → forces a real (no-edit) merge
# commit for the disjoint green unit AND a conflict for cUp-c.
printf 'main-version\n' > "$D/conflict.txt"
git -C "$D" add conflict.txt && git -C "$D" commit -q -m "base edits conflict.txt"

DECISIONS_BEFORE="$(grep -c '^## D-' "$D/director/DECISIONS.md" 2>/dev/null || true)"
CASCADE_REPO="$D" CASCADE_GATE_CMD='true' \
  CASCADE_DIGEST_CMD="printf ran > $TMP/digest_ran.txt" \
  "$CASCADE" merge >/dev/null 2>&1 || true

# green: landed on base, worktree + branch + claim pruned.
g_landed="$([ -f "$D/feature_g.txt" ] && echo yes || echo no)"
g_branch_gone="$(git -C "$D" show-ref --verify --quiet refs/heads/cascade/cUp-g && echo no || echo yes)"
g_wt_gone="$([ ! -d "$D/.cascade/worktrees/cUp-g" ] && echo yes || echo no)"
g_claim_gone="$([ ! -f "$D/current_tasks/cUp-g.claim" ] && echo yes || echo no)"
g_checked="$(grep -c '^- \[x\] .*id=cUp-g ' "$D/backlog.md" || true)"
# conflict: NOT merged, branch + worktree intact, a fresh D-NNN escalated, no half-merge left.
c_branch_kept="$(git -C "$D" show-ref --verify --quiet refs/heads/cascade/cUp-c && echo yes || echo no)"
c_wt_kept="$([ -d "$D/.cascade/worktrees/cUp-c" ] && echo yes || echo no)"
c_not_landed="$(git -C "$D" show HEAD:conflict.txt 2>/dev/null | grep -c 'main-version' || true)"
no_half_merge="$([ ! -f "$D/.git/MERGE_HEAD" ] && echo yes || echo no)"
DECISIONS_AFTER="$(grep -c '^## D-' "$D/director/DECISIONS.md" 2>/dev/null || true)"
escalated_one="$([ "$DECISIONS_AFTER" -eq "$((DECISIONS_BEFORE + 1))" ] && echo yes || echo no)"
escalation_names_c="$(grep -c 'cUp-c' "$D/director/DECISIONS.md" 2>/dev/null || true)"
# blocked: NOT merged (dep cUp-a never landed), branch + claim intact.
b_branch_kept="$(git -C "$D" show-ref --verify --quiet refs/heads/cascade/cUp-b && echo yes || echo no)"
b_claim_kept="$([ -f "$D/current_tasks/cUp-b.claim" ] && echo yes || echo no)"
# digest: ran (batch was non-empty).
digest_ran="$([ -f "$TMP/digest_ran.txt" ] && echo yes || echo no)"

if [ "$g_landed" = yes ] && [ "$g_branch_gone" = yes ] && [ "$g_wt_gone" = yes ] \
     && [ "$g_claim_gone" = yes ] && [ "$g_checked" = 1 ]; then
  pass "merge: a done, gate-green branch lands on the base and its worktree+branch+claim are pruned"
else
  fail "merge green (landed=$g_landed branch_gone=$g_branch_gone wt_gone=$g_wt_gone claim_gone=$g_claim_gone checked=$g_checked)"
fi

if [ "$c_branch_kept" = yes ] && [ "$c_wt_kept" = yes ] && [ "$c_not_landed" = 1 ] \
     && [ "$no_half_merge" = yes ] && [ "$escalated_one" = yes ] && [ "$escalation_names_c" -ge 1 ]; then
  pass "merge: a conflicting branch is aborted + escalated (D-NNN), left intact, base unchanged"
else
  fail "merge conflict (branch_kept=$c_branch_kept wt_kept=$c_wt_kept base_intact=$c_not_landed no_half_merge=$no_half_merge escalated_one=$escalated_one names_c=$escalation_names_c)"
fi

if [ "$b_branch_kept" = yes ] && [ "$b_claim_kept" = yes ]; then
  pass "merge: a unit blocked by an unlanded dep waits (not merged, branch+claim kept)"
else
  fail "merge blocked-waits (branch_kept=$b_branch_kept claim_kept=$b_claim_kept)"
fi

if [ "$digest_ran" = yes ]; then
  pass "merge: runs the post-batch digest after landing at least one unit"
else
  fail "merge digest did not run on a non-empty batch"
fi

# --- 1b. FAN-IN: two independent done units BOTH land conflict-free; merge renders the backlog ----
# This is the exact case the partition model fixes: pre-partition, both units ticked the shared
# backlog and the 2nd merge conflicted on it. Now each writes done/<id>.md (disjoint) and merge is
# the single writer of the rendered backlog.
D="$(new_repo)"
cat >> "$D/backlog.md" <<'EOF'
- [ ] **widget one** — disjoint path. <!-- cascade: id=cFan-u1 blocked-by=none -->
- [ ] **widget two** — disjoint path. <!-- cascade: id=cFan-u2 blocked-by=none -->
EOF
git -C "$D" add -A && git -C "$D" commit -q -m "add fan-in units"
sim_unit "$D" cFan-u1 'printf hi > feat_one.txt'
sim_unit "$D" cFan-u2 'printf hi > feat_two.txt'
DEC_BEFORE="$(grep -c '^## D-' "$D/director/DECISIONS.md" 2>/dev/null || true)"; DEC_BEFORE="${DEC_BEFORE:-0}"
CASCADE_REPO="$D" CASCADE_GATE_CMD='true' CASCADE_DIGEST_CMD='true' "$CASCADE" merge >/dev/null 2>&1 || true
if [ -f "$D/feat_one.txt" ] && [ -f "$D/feat_two.txt" ]; then both_landed=yes; else both_landed=no; fi
both_rendered="$(grep -c '^- \[x\] .*id=cFan-u' "$D/backlog.md" || true)"
branches_left="$(git -C "$D" for-each-ref --format='%(refname:short)' refs/heads/cascade/ | grep -c cFan || true)"
no_half="$([ ! -f "$D/.git/MERGE_HEAD" ] && echo yes || echo no)"
DEC_AFTER="$(grep -c '^## D-' "$D/director/DECISIONS.md" 2>/dev/null || true)"; DEC_AFTER="${DEC_AFTER:-0}"
no_escalation="$([ "$DEC_AFTER" = "$DEC_BEFORE" ] && echo yes || echo no)"
if [ "$both_landed" = yes ] && [ "$both_rendered" = 2 ] && [ "$branches_left" = 0 ] \
     && [ "$no_half" = yes ] && [ "$no_escalation" = yes ]; then
  pass "merge fan-in: 2 independent done units both land conflict-free; backlog rendered [x] for both"
else
  fail "merge fan-in (landed=$both_landed rendered=$both_rendered branches=$branches_left no_half=$no_half no_esc=$no_escalation)"
fi

# 1c. render is single-writer + idempotent: a second merge is a safe no-op, backlog byte-identical
BL1="$(md5sum < "$D/backlog.md")"
CASCADE_REPO="$D" CASCADE_GATE_CMD='true' CASCADE_DIGEST_CMD='true' "$CASCADE" merge >/dev/null 2>&1 || true
BL2="$(md5sum < "$D/backlog.md")"
if [ "$BL1" = "$BL2" ]; then
  pass "merge render is idempotent: re-running merge leaves backlog.md byte-identical"
else
  fail "merge render not idempotent (backlog.md changed on re-merge)"
fi

# --- 2. no green, no merge: a done branch whose gate fails is NOT merged ----------------------
D="$(new_repo)"
cat >> "$D/backlog.md" <<'EOF'
- [ ] **red unit** — done but gate fails. <!-- cascade: id=cRd-u1 blocked-by=none -->
EOF
git -C "$D" add -A && git -C "$D" commit -q -m "add red unit"
sim_unit "$D" cRd-u1 'printf hi > feature_red.txt'

CASCADE_REPO="$D" CASCADE_GATE_CMD='false' \
  CASCADE_DIGEST_CMD="printf ran > $TMP/digest_ran2.txt" \
  "$CASCADE" merge >/dev/null 2>&1 || true

red_not_landed="$([ ! -f "$D/feature_red.txt" ] && echo yes || echo no)"
red_branch_kept="$(git -C "$D" show-ref --verify --quiet refs/heads/cascade/cRd-u1 && echo yes || echo no)"
red_no_decision="$([ ! -f "$D/director/DECISIONS.md" ] && echo yes || echo no)"
red_no_digest="$([ ! -f "$TMP/digest_ran2.txt" ] && echo yes || echo no)"
if [ "$red_not_landed" = yes ] && [ "$red_branch_kept" = yes ] \
     && [ "$red_no_decision" = yes ] && [ "$red_no_digest" = yes ]; then
  pass "merge: a not-gate-green branch is skipped (not merged, not escalated, no digest run)"
else
  fail "merge gate-fail (not_landed=$red_not_landed branch_kept=$red_branch_kept no_decision=$red_no_decision no_digest=$red_no_digest)"
fi

# --- 3. unfinished branch (claim only, no loop commit) is not a merge candidate ---------------
D="$(new_repo)"
cat >> "$D/backlog.md" <<'EOF'
- [ ] **unfinished** — dispatched, worker never finished. <!-- cascade: id=cUf-u1 blocked-by=none -->
EOF
git -C "$D" add -A && git -C "$D" commit -q -m "add unfinished unit"
# Mimic a dispatch that claimed + branched but produced no loop commit (gate failed, rolled back).
mkdir -p "$D/current_tasks"
printf 'unit: cUf-u1\n' > "$D/current_tasks/cUf-u1.claim"
git -C "$D" add -A && git -C "$D" commit -q -m "cascade claim: cUf-u1"
git -C "$D" worktree add -q -b cascade/cUf-u1 "$D/.cascade/worktrees/cUf-u1" HEAD

CASCADE_REPO="$D" CASCADE_GATE_CMD='true' "$CASCADE" merge >/dev/null 2>&1 || true
uf_branch_kept="$(git -C "$D" show-ref --verify --quiet refs/heads/cascade/cUf-u1 && echo yes || echo no)"
uf_no_decision="$([ ! -f "$D/director/DECISIONS.md" ] && echo yes || echo no)"
if [ "$uf_branch_kept" = yes ] && [ "$uf_no_decision" = yes ]; then
  pass "merge: a branch with only a claim commit (no finished work) is not merged or escalated"
else
  fail "merge unfinished (branch_kept=$uf_branch_kept no_decision=$uf_no_decision)"
fi

# --- 4. nothing to merge -> rc 0, no digest --------------------------------------------------
D="$(new_repo)"
set +e
CASCADE_REPO="$D" CASCADE_DIGEST_CMD="printf ran > $TMP/digest_ran3.txt" \
  "$CASCADE" merge >/dev/null 2>&1
rc=$?
set -e
empty_no_digest="$([ ! -f "$TMP/digest_ran3.txt" ] && echo yes || echo no)"
if [ "$rc" -eq 0 ] && [ "$empty_no_digest" = yes ]; then
  pass "merge: an empty batch exits rc 0 and does not run the digest"
else
  fail "merge empty (rc=$rc no_digest=$empty_no_digest)"
fi

echo "---"
if [ "$FAIL" -eq 0 ]; then
  echo "cascade_merge_test: ALL $N checks passed"
else
  echo "cascade_merge_test: FAILURES present ($N checks run)"
fi
exit "$FAIL"
