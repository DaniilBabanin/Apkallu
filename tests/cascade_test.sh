#!/usr/bin/env bash
# Tests for loop/cascade.sh — the down-cascade mechanics. Fixture-driven: DECOMPOSE_CMD and
# WORKER_CMD are stubbed, so NO claude and NO network are touched. Every git-mutating case runs
# in its own throwaway repo (CASCADE_REPO override), so this repo's history is never touched.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASCADE="$SELF_DIR/loop/cascade.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hermetic auth: a REAL worker runs WITH the ~/.claude login resolvable (CLAUDE_CODE_OAUTH_TOKEN in
# its env via D-018 always-inject, and/or the host ~/.claude credentials reachable). That would flip
# the "no-token -> rc 2" assertions below (resolve_oauth_token would find a real token). Clear ALL
# three sources up front so these fixtures test the intended path regardless of ambient auth; tests
# that WANT a token set it explicitly (env or AGENCY_OAUTH_TOKEN_FILE).
unset CLAUDE_CODE_OAUTH_TOKEN
export AGENCY_HOST_CREDENTIALS=/nonexistent

FAIL=0
N=0
pass() { N=$((N + 1)); echo "ok   $1"; }
fail() { N=$((N + 1)); FAIL=1; echo "FAIL $1"; }

# Fresh temp git repo with a minimal backlog.md (Parked + Done anchors) and run.sh stand-in dir.
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

# --- 1. decompose: instruction -> >=2 committed units with done-condition + blocked-by --------
D="$(new_repo)"
printf '%s' '[
 {"title":"preflight.sh","done":"local/preflight.sh checks deps; gate green.","blocked_by":0},
 {"title":"preflight test","done":"tests/preflight_test.sh part of green gate.","blocked_by":1}
]' > "$TMP/units2.json"

if CASCADE_REPO="$D" CASCADE_BATCH=cT DECOMPOSE_CMD="cat $TMP/units2.json" \
     "$CASCADE" decompose "make a preflight check" >/dev/null 2>&1; then
  u1="$(grep -c '<!-- cascade: id=cT-u1 blocked-by=none -->' "$D/backlog.md" || true)"
  u2="$(grep -c '<!-- cascade: id=cT-u2 blocked-by=cT-u1 -->' "$D/backlog.md" || true)"
  inserted_before_parked="$(awk '/cascade: id=cT-u2/{u=NR} /^## Parked/{p=NR} END{print (u && p && u<p)?"yes":"no"}' "$D/backlog.md")"
  committed="$(git -C "$D" log -1 --pretty=%s | grep -c '^cascade decompose: cT' || true)"
  touched_backlog="$(git -C "$D" show --name-only --pretty=format: HEAD | grep -c '^backlog.md$' || true)"
  if [ "$u1" = 1 ] && [ "$u2" = 1 ] && [ "$inserted_before_parked" = yes ] \
       && [ "$committed" = 1 ] && [ "$touched_backlog" = 1 ]; then
    pass "decompose writes 2 units, resolves blocked-by, inserts before Parked, commits backlog"
  else
    fail "decompose (u1=$u1 u2=$u2 before_parked=$inserted_before_parked committed=$committed touched=$touched_backlog)"
  fi
else
  fail "decompose exited non-zero on valid 2-unit fixture"
fi

# --- 2. decompose enforces real decomposition: 1 unit -> rc 2 + escalation, no backlog change -
D="$(new_repo)"
before="$(md5sum < "$D/backlog.md")"
printf '%s' '[{"title":"only one","done":"single passthrough.","blocked_by":0}]' > "$TMP/units1.json"
set +e
CASCADE_REPO="$D" CASCADE_BATCH=cX DECOMPOSE_CMD="cat $TMP/units1.json" \
  "$CASCADE" decompose "do one thing" >/dev/null 2>&1
rc=$?
set -e
after="$(md5sum < "$D/backlog.md")"
escalated="$(grep -c '^## D-' "$D/director/DECISIONS.md" 2>/dev/null || true)"
if [ "$rc" -eq 2 ] && [ "$before" = "$after" ] && [ "$escalated" -ge 1 ]; then
  pass "decompose rejects <2 units (rc 2, escalated D-NNN, backlog untouched)"
else
  fail "decompose <2 units (rc=$rc backlog_changed=$([ "$before" = "$after" ] && echo no || echo yes) escalated=$escalated)"
fi

# --- 3. decompose handles fenced / prose-wrapped JSON ----------------------------------------
D="$(new_repo)"
cat > "$TMP/fenced.txt" <<'EOF'
Here is the decomposition:
```json
[
 {"title":"alpha","done":"alpha done; gate green.","blocked_by":0},
 {"title":"beta","done":"beta done; gate green.","blocked_by":1}
]
```
EOF
if CASCADE_REPO="$D" CASCADE_BATCH=cF DECOMPOSE_CMD="cat $TMP/fenced.txt" \
     "$CASCADE" decompose "fenced output" >/dev/null 2>&1 \
     && grep -q '<!-- cascade: id=cF-u2 blocked-by=cF-u1 -->' "$D/backlog.md"; then
  pass "decompose extracts JSON from markdown-fenced / prose-wrapped output"
else
  fail "decompose could not parse fenced output"
fi

# --- 4. next-ready: respects checked / claimed / blocked-by ----------------------------------
D="$(new_repo)"
cat >> "$D/backlog.md" <<'EOF'
- [x] **done unit** — finished. <!-- cascade: id=cR-u0 blocked-by=none -->
- [ ] **claimed unit** — busy. <!-- cascade: id=cR-u1 blocked-by=none -->
- [ ] **blocked unit** — waits on u3. <!-- cascade: id=cR-u2 blocked-by=cR-u3 -->
- [ ] **the dep, unfinished** — must run first. <!-- cascade: id=cR-u3 blocked-by=none -->
EOF
mkdir -p "$D/current_tasks"
printf 'unit: cR-u1\n' > "$D/current_tasks/cR-u1.claim"
ready="$(CASCADE_REPO="$D" "$CASCADE" next-ready || true)"
# u0 checked (skip), u1 claimed (skip), u2 blocked by unfinished u3 (skip) -> u3 is first ready.
if [ "$ready" = "cR-u3" ]; then
  pass "next-ready skips checked+claimed+blocked, returns first runnable dep (cR-u3)"
else
  fail "next-ready returned '$ready' (want cR-u3)"
fi

# now finish u3 -> u2 becomes ready (blocked-by satisfied)
sed -i 's/^- \[ \] \*\*the dep, unfinished\*\*/- [x] **the dep, unfinished**/' "$D/backlog.md"
ready2="$(CASCADE_REPO="$D" "$CASCADE" next-ready || true)"
if [ "$ready2" = "cR-u2" ]; then
  pass "next-ready unblocks a unit once its blocked-by dependency is checked off"
else
  fail "next-ready after dep done returned '$ready2' (want cR-u2)"
fi

# all done/claimed -> nothing ready, rc 1
D="$(new_repo)"
cat >> "$D/backlog.md" <<'EOF'
- [x] **all done** — finished. <!-- cascade: id=cE-u1 blocked-by=none -->
EOF
set +e
CASCADE_REPO="$D" "$CASCADE" next-ready >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  pass "next-ready exits rc 1 when nothing is ready"
else
  fail "next-ready rc on empty was $rc (want 1)"
fi

# --- 4b. next-ready: skips a unit whose work is already merged (loop commit in history) but whose
# backlog line was never ticked — the duplicate-dispatch guard (see NOTES: u4 re-dispatch). ------
D="$(new_repo)"
cat >> "$D/backlog.md" <<'EOF'
- [ ] **merged but unticked** — work landed, checkbox forgotten. <!-- cascade: id=cM-u1 blocked-by=none -->
EOF
git -C "$D" add -A
# the worker's loop commit IS the backlog line (run.sh: git commit -m "loop: <line>"); it reaches
# master on merge, carrying the marker in its MESSAGE (not just in backlog.md's content).
git -C "$D" commit -q -m 'loop: **merged but unticked** — work landed, checkbox forgotten. <!-- cascade: id=cM-u1 blocked-by=none -->'
set +e
ready="$(CASCADE_REPO="$D" "$CASCADE" next-ready 2>/dev/null)"
rc=$?
set -e
if [ -z "$ready" ] && [ "$rc" -eq 1 ]; then
  pass "next-ready skips a merged-but-unchecked unit (no duplicate dispatch)"
else
  fail "next-ready returned '$ready' rc=$rc for merged-but-unchecked unit (want empty, rc 1)"
fi

# control: a unit with ONLY a claim commit (work not yet merged) is still returned — a claim
# message must NOT count as merged, and the marker sitting in backlog.md must NOT match --grep.
D="$(new_repo)"
cat >> "$D/backlog.md" <<'EOF'
- [ ] **fresh unit** — never dispatched. <!-- cascade: id=cN-u1 blocked-by=none -->
EOF
git -C "$D" add -A
git -C "$D" commit -q -m 'cascade claim: cN-u1'
ready="$(CASCADE_REPO="$D" "$CASCADE" next-ready || true)"
if [ "$ready" = "cN-u1" ]; then
  pass "next-ready still returns a unit with only a claim commit (claim != merged work)"
else
  fail "next-ready returned '$ready' (want cN-u1) — claim commit/backlog marker must not count as merged"
fi

# --- 5. dispatch: claim (committed) + isolated worktree/branch + worker runs in worktree ------
D="$(new_repo)"
cat >> "$D/backlog.md" <<'EOF'
- [ ] **build it** — implement the thing; gate green. <!-- cascade: id=cD-u1 blocked-by=none -->
EOF
git -C "$D" add -A && git -C "$D" commit -q -m "add unit"
# Stub worker: prove it ran INSIDE the worktree and received the unit line via CASCADE_TASK.
# $CASCADE_TASK must stay literal here — it expands later inside cascade.sh's `bash -c`.
# shellcheck disable=SC2016
WORKER='printf "%s" "$CASCADE_TASK" > worker_ran.txt'
if CASCADE_REPO="$D" WORKER_CMD="$WORKER" "$CASCADE" dispatch >/dev/null 2>&1; then
  claim_committed="$(git -C "$D" log -1 --pretty=%s | grep -c '^cascade claim: cD-u1' || true)"
  claim_file="$([ -f "$D/current_tasks/cD-u1.claim" ] && echo yes || echo no)"
  branch="$(git -C "$D" branch --list 'cascade/cD-u1' --format='%(refname:short)')"
  wt_ran="$([ -f "$D/.cascade/worktrees/cD-u1/worker_ran.txt" ] && echo yes || echo no)"
  task_passed="$(grep -c 'id=cD-u1' "$D/.cascade/worktrees/cD-u1/worker_ran.txt" 2>/dev/null || true)"
  if [ "$claim_committed" = 1 ] && [ "$claim_file" = yes ] && [ "$branch" = "cascade/cD-u1" ] \
       && [ "$wt_ran" = yes ] && [ "$task_passed" = 1 ]; then
    pass "dispatch claims (committed), makes isolated worktree+branch, runs worker there with CASCADE_TASK"
  else
    fail "dispatch (claim_commit=$claim_committed claim=$claim_file branch=$branch wt_ran=$wt_ran task=$task_passed)"
  fi
else
  fail "dispatch exited non-zero on a ready unit"
fi

# after dispatch, the unit is claimed -> next-ready finds nothing (no double-pick)
set +e
CASCADE_REPO="$D" "$CASCADE" next-ready >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  pass "dispatch's committed claim removes the unit from next-ready (no double-pick)"
else
  fail "claimed unit still appears in next-ready (rc=$rc)"
fi

# --- 5b. reset: releases a dispatched unit (worktree+branch+claim) so it can be re-picked -----
CASCADE_REPO="$D" CASCADE_NO_COMMIT=1 "$CASCADE" reset cD-u1 >/dev/null 2>&1 || true
r_wt="$([ ! -d "$D/.cascade/worktrees/cD-u1" ] && echo yes || echo no)"
r_br="$(git -C "$D" show-ref --verify --quiet refs/heads/cascade/cD-u1 && echo no || echo yes)"
r_claim="$([ ! -f "$D/current_tasks/cD-u1.claim" ] && echo yes || echo no)"
r_ready="$(CASCADE_REPO="$D" "$CASCADE" next-ready 2>/dev/null || true)"
if [ "$r_wt" = yes ] && [ "$r_br" = yes ] && [ "$r_claim" = yes ] && [ "$r_ready" = cD-u1 ]; then
  pass "reset removes worktree+branch+claim and the unit becomes re-pickable"
else
  fail "reset (wt_gone=$r_wt branch_gone=$r_br claim_gone=$r_claim next-ready=$r_ready)"
fi

# --- 6. dispatch refuses past the concurrency ceiling ----------------------------------------
D="$(new_repo)"
cat >> "$D/backlog.md" <<'EOF'
- [ ] **capped unit** — should not run; cap reached. <!-- cascade: id=cC-u9 blocked-by=none -->
EOF
git -C "$D" add -A && git -C "$D" commit -q -m "add capped unit"
mkdir -p "$D/current_tasks"
for k in 1 2 3; do printf 'unit: busy-%s\n' "$k" > "$D/current_tasks/busy-$k.claim"; done
set +e
CASCADE_REPO="$D" CASCADE_MAX_CONCURRENT=3 WORKER_CMD='echo should-not-run' \
  "$CASCADE" dispatch >/dev/null 2>&1
rc=$?
set -e
not_claimed="$([ -f "$D/current_tasks/cC-u9.claim" ] && echo claimed || echo no)"
if [ "$rc" -eq 3 ] && [ "$not_claimed" = no ]; then
  pass "dispatch refuses at the <=N concurrency cap (rc 3, unit not claimed)"
else
  fail "dispatch cap (rc=$rc claimed=$not_claimed)"
fi

# --- 7. dispatch with nothing ready -> rc 1 --------------------------------------------------
D="$(new_repo)"
set +e
CASCADE_REPO="$D" "$CASCADE" dispatch >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  pass "dispatch exits rc 1 when no unit is ready"
else
  fail "dispatch with nothing ready rc=$rc (want 1)"
fi

# --- 8. sandbox worker profiles: env-assembly fn (D-007) -------------------------------------
# profile-env is the pure seam. All cases set CASCADE_CONFIG_BASE so the recipe path is stable,
# and drive the token via AGENCY_OAUTH_TOKEN_FILE / CLAUDE_CODE_OAUTH_TOKEN — no claude, no net.
D="$(new_repo)"
CB="$TMP/cfgbase"

# 8a. local profile = sandbox recipe + LOCAL=1 knobs, and ZERO secrets.
penv="$(CASCADE_REPO="$D" CASCADE_CONFIG_BASE="$CB" CASCADE_LOCAL_MODEL=example/general-model \
          "$CASCADE" profile-env local u1)"
if grep -qx 'NO_PROXY=' <<<"$penv" && grep -qx 'no_proxy=' <<<"$penv" \
     && grep -qx "CLAUDE_CONFIG_DIR=$CB/agency-worker-u1" <<<"$penv" \
     && grep -qx 'LOCAL=1' <<<"$penv" && grep -qx 'LOCAL_MODEL=example/general-model' <<<"$penv" \
     && ! grep -q 'OAUTH\|TOKEN' <<<"$penv"; then
  pass "profile-env local: clears NO_PROXY, sets \$TMPDIR config dir + LOCAL=1, no secrets"
else
  fail "profile-env local env wrong: $(printf '%s' "$penv" | tr '\n' '|')"
fi

# 8b. online profile = recipe + OAuth token from a file OUTSIDE the repo; no LOCAL=1.
printf '# comment\nsk-ant-oat-FAKE\n' > "$TMP/oat.txt"
penv="$(CASCADE_REPO="$D" CASCADE_CONFIG_BASE="$CB" AGENCY_OAUTH_TOKEN_FILE="$TMP/oat.txt" \
          "$CASCADE" profile-env online u2)"
if grep -qx 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-FAKE' <<<"$penv" \
     && grep -qx 'NO_PROXY=' <<<"$penv" && ! grep -q 'LOCAL=1' <<<"$penv"; then
  pass "profile-env online: injects OAuth token from out-of-repo file, skips comment line"
else
  fail "profile-env online env wrong: $(printf '%s' "$penv" | tr '\n' '|')"
fi

# 8c. online with NO token resolvable -> rc 2, nothing printed (dispatch can refuse pre-claim).
set +e
penv="$(env -u CLAUDE_CODE_OAUTH_TOKEN CASCADE_REPO="$D" AGENCY_OAUTH_TOKEN_FILE=/nonexistent \
          "$CASCADE" profile-env online u3 2>/dev/null)"
rc=$?
set -e
if [ "$rc" -eq 2 ] && [ -z "$penv" ]; then
  pass "profile-env online without a token: rc 2, no env emitted"
else
  fail "profile-env online no-token rc=$rc out='$penv' (want rc 2, empty)"
fi

# 8d. mixed = cloud OAuth main + local evaluator model (ANTHROPIC_DEFAULT_HAIKU_MODEL).
penv="$(CASCADE_REPO="$D" CASCADE_CONFIG_BASE="$CB" CLAUDE_CODE_OAUTH_TOKEN=sk-ant-env-MIX \
          CASCADE_LOCAL_MODEL=example/general-model "$CASCADE" profile-env mixed u4)"
if grep -qx 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-env-MIX' <<<"$penv" \
     && grep -qx 'ANTHROPIC_DEFAULT_HAIKU_MODEL=example/general-model' <<<"$penv" \
     && grep -qx 'NO_PROXY=' <<<"$penv"; then
  pass "profile-env mixed: cloud OAuth main + local default-haiku model + recipe"
else
  fail "profile-env mixed env wrong: $(printf '%s' "$penv" | tr '\n' '|')"
fi

# 8e. unknown profile -> rc 1.
set +e
CASCADE_REPO="$D" "$CASCADE" profile-env bogus >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  pass "profile-env rejects an unknown profile (rc 1)"
else
  fail "profile-env unknown rc=$rc (want 1)"
fi

# --- 9. dispatch --profile injects the env into the worker (NO_PROXY cleared for its bash) ----
D="$(new_repo)"
cat >> "$D/backlog.md" <<'EOF'
- [ ] **profiled unit** — runs under a profile. <!-- cascade: id=cP-u1 blocked-by=none -->
EOF
git -C "$D" add -A && git -C "$D" commit -q -m "add profiled unit"
# Worker dumps its whole env so we can prove the recipe + task both arrived.
WORKER='env > worker_env.txt'
if CASCADE_REPO="$D" CASCADE_CONFIG_BASE="$TMP/wcfg" WORKER_CMD="$WORKER" \
     "$CASCADE" dispatch --profile local >/dev/null 2>&1; then
  wenv="$D/.cascade/worktrees/cP-u1/worker_env.txt"
  if [ -f "$wenv" ] && grep -qx 'NO_PROXY=' "$wenv" && grep -qx 'LOCAL=1' "$wenv" \
       && grep -q '^CLAUDE_CONFIG_DIR=' "$wenv" && grep -q 'id=cP-u1' "$wenv"; then
    pass "dispatch --profile local: worker bash gets cleared NO_PROXY + LOCAL=1 + CASCADE_TASK"
  else
    fail "dispatch --profile local env not injected (env file: $([ -f "$wenv" ] && echo present || echo missing))"
  fi
else
  fail "dispatch --profile local exited non-zero on a ready unit"
fi

# --- 10. dispatch --profile online with no token: refuse BEFORE claiming (no orphan) ----------
D="$(new_repo)"
cat >> "$D/backlog.md" <<'EOF'
- [ ] **needs token** — online only. <!-- cascade: id=cO-u1 blocked-by=none -->
EOF
git -C "$D" add -A && git -C "$D" commit -q -m "add online unit"
set +e
env -u CLAUDE_CODE_OAUTH_TOKEN CASCADE_REPO="$D" AGENCY_OAUTH_TOKEN_FILE=/nonexistent \
  WORKER_CMD='echo should-not-run' "$CASCADE" dispatch --profile online >/dev/null 2>&1
rc=$?
set -e
claimed="$([ -f "$D/current_tasks/cO-u1.claim" ] && echo yes || echo no)"
branched="$(git -C "$D" branch --list 'cascade/cO-u1' --format='%(refname:short)')"
if [ "$rc" -eq 2 ] && [ "$claimed" = no ] && [ -z "$branched" ]; then
  pass "dispatch --profile online w/o token: rc 2, no claim, no branch (validates pre-claim)"
else
  fail "dispatch online no-token (rc=$rc claimed=$claimed branched='$branched')"
fi

# --- 11. dispatch --profile local routes the worker THROUGH local/queue.sh (D-012 anti-thrash) -
# CASCADE_QUEUE points at the REAL queue.sh; QUEUE_RUN_CMD stubs its execution (no model, no
# network) and captures the enqueued payload, so we can assert the worker was enqueued pinned to
# the local model + nested-claude ctx, with the worktree cd + CASCADE_TASK baked in.
D="$(new_repo)"
cat >> "$D/backlog.md" <<'EOF'
- [ ] **queued worker** — runs via the queue. <!-- cascade: id=cQ-u1 blocked-by=none -->
EOF
git -C "$D" add -A && git -C "$D" commit -q -m "add queued unit"
PFILE="$TMP/qpayload.txt"
# shellcheck disable=SC2016  # $QUEUE_PROMPT expands inside queue.sh at run time, not here
if CASCADE_REPO="$D" CASCADE_QUEUE="$SELF_DIR/local/queue.sh" \
     QUEUE_FILE="$TMP/q.ndjson" QUEUE_OUT_DIR="$TMP/qout" \
     QUEUE_RUN_CMD='printf "%s" "$QUEUE_PROMPT" > '"$PFILE" \
     WORKER_CMD='true' "$CASCADE" dispatch --profile local >/dev/null 2>&1; then
  enq_model="$(jq -r 'select(.kind=="cmd") | .models[0]' "$TMP/q.ndjson" 2>/dev/null | head -1)"
  enq_ctx="$(jq -r 'select(.kind=="cmd") | .ctx' "$TMP/q.ndjson" 2>/dev/null | head -1)"
  pl_cd="$(grep -c 'worktrees/cQ-u1' "$PFILE" 2>/dev/null || true)"
  pl_task="$(grep -c 'id=cQ-u1' "$PFILE" 2>/dev/null || true)"
  pl_local="$(grep -c 'LOCAL=1' "$PFILE" 2>/dev/null || true)"
  if [ "$enq_model" = "example/general-model" ] && [ "$enq_ctx" = 65536 ] \
       && [ "$pl_cd" -ge 1 ] && [ "$pl_task" -ge 1 ] && [ "$pl_local" -ge 1 ]; then
    pass "dispatch --profile local enqueues a model+ctx-pinned worker and drains it via the queue"
  else
    fail "dispatch via queue (model=$enq_model ctx=$enq_ctx cd=$pl_cd task=$pl_task local=$pl_local)"
  fi
else
  fail "dispatch --profile local (queue route) exited non-zero"
fi

# --- 12. queue route is opt-out: CASCADE_VIA_QUEUE=0 runs the worker inline (back-compat) ------
D="$(new_repo)"
cat >> "$D/backlog.md" <<'EOF'
- [ ] **inline worker** — runs inline. <!-- cascade: id=cI-u1 blocked-by=none -->
EOF
git -C "$D" add -A && git -C "$D" commit -q -m "add inline unit"
if CASCADE_REPO="$D" CASCADE_QUEUE="$SELF_DIR/local/queue.sh" CASCADE_VIA_QUEUE=0 \
     QUEUE_FILE="$TMP/q2.ndjson" WORKER_CMD='printf ran > worker_ran.txt' \
     "$CASCADE" dispatch --profile local >/dev/null 2>&1; then
  ran_inline="$([ -f "$D/.cascade/worktrees/cI-u1/worker_ran.txt" ] && echo yes || echo no)"
  no_enqueue="$([ -s "$TMP/q2.ndjson" ] && echo enqueued || echo none)"
  if [ "$ran_inline" = yes ] && [ "$no_enqueue" = none ]; then
    pass "CASCADE_VIA_QUEUE=0 runs the worker inline (no enqueue) — back-compat preserved"
  else
    fail "opt-out inline (ran=$ran_inline enqueue=$no_enqueue)"
  fi
else
  fail "dispatch --profile local CASCADE_VIA_QUEUE=0 exited non-zero"
fi

# --- 13. reconcile PG down: prunes orphan branch (no worktree), keeps live branch -----------
# PG unavail (gate's AGENCY_PG_PORT=1) → skip reap + skip orphan worktree pruning.
# Orphan branch (cascade/* with no worktree dir) IS pruned (pure git, no PG needed).
D="$(new_repo)"
# Orphan branch: cascade branch with NO worktree directory
git -C "$D" branch cascade/cRec-orphan HEAD
# Live branch: cascade branch WITH a worktree directory AND a claim file
git -C "$D" branch cascade/cRec-live HEAD
mkdir -p "$D/.cascade/worktrees/cRec-live" "$D/current_tasks"
printf 'unit: cRec-live\n' > "$D/current_tasks/cRec-live.claim"

CASCADE_REPO="$D" "$CASCADE" reconcile >/dev/null 2>&1 || true

orphan_br="$(git -C "$D" branch --list 'cascade/cRec-orphan' --format='%(refname:short)')"
live_br="$(git -C "$D" branch --list 'cascade/cRec-live' --format='%(refname:short)')"
if [ -z "$orphan_br" ] && [ -n "$live_br" ]; then
  pass "reconcile PG down: orphan branch pruned, live branch (has worktree) kept"
else
  fail "reconcile PG down (orphan_gone=$([ -z "$orphan_br" ] && echo yes || echo no) live_kept=$([ -n "$live_br" ] && echo yes || echo no))"
fi

# --- 14. reconcile PG up (mock): orphan worktree pruned when PG confirms no running job --------
mkdir -p "$TMP/pgbin"
cat > "$TMP/pgbin/psql" <<'MOCK'
#!/usr/bin/env bash
SQL="${3:-$(cat 2>/dev/null || true)}"
case "$SQL" in
  "SELECT 1") echo 1 ;;
  *"reap_expired"*) echo 0 ;;
  *"FROM jobs WHERE state"*) ;;  # empty = no running jobs in PG
esac
exit 0
MOCK
chmod +x "$TMP/pgbin/psql"

D="$(new_repo)"
# Orphan worktree: directory exists, no claim file, PG mock has no running job for it
git -C "$D" branch cascade/cOWT-orphan HEAD
mkdir -p "$D/.cascade/worktrees/cOWT-orphan"
# Live (file-claimed): claim file present → must not be pruned
git -C "$D" branch cascade/cOWT-live HEAD
mkdir -p "$D/.cascade/worktrees/cOWT-live" "$D/current_tasks"
printf 'unit: cOWT-live\n' > "$D/current_tasks/cOWT-live.claim"

PATH="$TMP/pgbin:$PATH" AGENCY_PG_PORT=5432 CASCADE_REPO="$D" \
  "$CASCADE" reconcile >/dev/null 2>&1 || true

orphan_wt_gone="$([ ! -d "$D/.cascade/worktrees/cOWT-orphan" ] && echo yes || echo no)"
live_wt_kept="$([ -d "$D/.cascade/worktrees/cOWT-live" ] && echo yes || echo no)"
if [ "$orphan_wt_gone" = yes ] && [ "$live_wt_kept" = yes ]; then
  pass "reconcile PG up (mock): orphan worktree pruned (PG confirms not running), live kept"
else
  fail "reconcile PG up (orphan_wt_gone=$orphan_wt_gone live_wt_kept=$live_wt_kept)"
fi

echo "---"
if [ "$FAIL" -eq 0 ]; then
  echo "cascade_test: ALL $N checks passed"
else
  echo "cascade_test: FAILURES present ($N checks run)"
fi
exit "$FAIL"
