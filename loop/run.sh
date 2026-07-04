#!/usr/bin/env bash
# Goal loop v1 — picks the top backlog task, lets Claude work it via /goal, gates, commits, reports.
#
# v1 (2026-06-06): inner claude call migrated from single-shot `claude -p "<prompt>"` (Ralph-loop
# pattern, now superseded) to `claude -p "/goal <condition>"` — Claude Code >= 2.1.139 self-loops
# turns until an INDEPENDENT fast-model evaluator judges the end-state condition met (reading the
# conversation only — it runs nothing). This fixes the half-done-iteration failure mode (watcher
# v0: claude exited 1 mid-task, loop committed the fragment). The outer loop stays: it picks
# tasks, re-runs the gate INDEPENDENTLY (the evaluator can be told things that aren't true),
# commits/reverts, and keeps LoopGuard/stall/escalation as backstops. Requires hooks enabled
# (no disableAllHooks) or /goal errors out.
#
# Hardening (loop-hardening iteration, 2026-06-06):
#   - per-iteration timeout   cap each claude run so one stuck turn can't eat the window
#                             (ITER_TIMEOUT seconds — defaults in Env below).
#   - LoopGuard               hash task+worktree-diff each run; trip after N identical
#                             no-progress iterations (LOOPGUARD_MAX_IDENTICAL, default 2).
#                             Catches the A-B-A-B / same-failing-change repeat.
#   - stall detection         trip after N runs with no commit AND no persisted NOTES.md
#                             change (STALL_MAX, default 2). Catches the do-nothing freeze.
#   A tripped guard never blocks the human OR the rest of the run (substrate: only the action
#   is held): it appends a numbered entry to director/DECISIONS.md (with a default + apply-by
#   date), which PAUSES that task — next_task skips any task quoted in an OPEN decision, and
#   answering the decision (local/decide.sh apply) unpauses it — then the loop moves on to the
#   next runnable task. A cascade unit stops instead: the dispatcher owns moving on.
#
# Usage:
#   MAX_RUNS=3 ./loop/run.sh
#   MAX_MINUTES=120 NTFY_TOPIC=my-topic ./loop/run.sh
#
# Env:
#   MAX_RUNS                 max iterations (default 1 — be deliberate until hardened)
#   MAX_MINUTES              wall-clock budget (default 240)
#   ITER_TIMEOUT             per-iteration claude timeout, seconds (default 3600 — goal runs
#                            are multi-turn, the old single-shot 1800 was routinely too short)
#   GOAL_MAX_TURNS           in-goal turn bound passed to the /goal condition (default 25)
#   LOOPGUARD_MAX_IDENTICAL  pause the task after this many identical task+diff runs (default 2)
#   STALL_MAX                pause the task after this many no-progress runs (default 2)
#   GATE_TAIL_LINES          lines of the last failing gate log inlined into the next attempt's
#                            prompt (default 25)
#   NTFY_TOPIC               if set, push a one-line status to ntfy.sh/<topic> per iteration
#   ALLOW_ALL                1 = explicit bypass (--dangerously-skip-permissions; network
#                            allowlist becomes advisory — supervised use only). DEFAULT is 0
#                            since D-005: sandboxed acceptEdits, enforced by .claude/settings.json
#                            (run local/sandbox-setup.sh check if bash dies at seccomp setup).
#   LOCAL                    1 = zero-quota mode: claude (and the /goal evaluator) served by the
#                            local workhorse via a local server's native Anthropic endpoint — same
#                            harness, same gate (spike verified 2026-06-06, see NOTES). Slower:
#                            ITER_TIMEOUT default becomes 7200. Aborts early if the model isn't
#                            served. Iteration commits are tagged with the local model id.
#   LOCAL_BASE               Anthropic-compatible base URL (default http://localhost:1234)
#   LOCAL_MODEL              served model id (default example/general-model; must be loaded with
#                            ctx >= 32k — Claude Code's system prompt alone is ~23k tokens)
#   LOCAL_CTX                minimum served context under LOCAL=1 (default 65536) — the run
#                            aborts early if llm.sh ensure can't serve the model at this ctx
#   PROJECT_DIR              external-project mode: path to a CLIENT project checkout. When set,
#                            the iteration works the PROJECT (not the agency repo): the inner
#                            claude edits there, the project's OWN gate (PROJECT_GATE) decides
#                            green, the commit lands on an isolated branch (PROJECT_BRANCH) with a
#                            sanitized message (no agency refs, no Claude attribution), and the
#                            agency repo gets only the client-commit ledger + a NOTES bookkeeping
#                            line (VISION: project repos stay agency-agnostic). The mechanical
#                            commit/gate/ledger flow lives in loop/enforce.sh project-commit.
#   PROJECT_BRANCH           isolated work branch in the project checkout (default agency/work).
#   PROJECT_GATE             the project's own gate command, run in PROJECT_DIR (default ./gate.sh).
#   PROJECT_SCOPE            external-project mode: optional attention scope (CM-5). When set, the
#                            worker's /goal prompt tells it to edit ONLY these files/areas and treat
#                            the rest of the (possibly huge) checkout as read-only — narrowing
#                            ATTENTION, not the filesystem (the project gate stays repo-wide). Unset =
#                            a generic "work only on the files this task names" instruction.
#   SPEND_COST_FILE          set by loop/scheduler.sh budget mode (2026-06-15+ monthly-credit
#                            pacing): append each iteration's real total_cost_usd (one float per
#                            line) here so the scheduler can sum the burst's spend. Forces
#                            --output-format json for that iteration's inner claude (the final
#                            result text is still printed). SKIPPED under LOCAL=1 — local
#                            total_cost_usd is fictional CLI price math (NOTES 2026-06-06).
#
# History note (2026-06-12, director): the VISION kill switches (the gate milestone deadline, 14-day
# no-client-commit rule) and their per-iteration `enforce.sh kill-check` call were REMOVED —
# pen-support shipped; no deadline self-pressure on a side project. LoopGuard/stall/escalation
# stay: they are operational guards (stop quota burn), not motivational ones.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

# PG glue (best-effort: PG_AVAIL=0 when PG is down — all pg_* calls then no-op)
# shellcheck source=lib/pg.sh
source "$REPO_DIR/lib/pg.sh"

MAX_RUNS="${MAX_RUNS:-1}"
MAX_MINUTES="${MAX_MINUTES:-240}"
GOAL_MAX_TURNS="${GOAL_MAX_TURNS:-25}"

# LOCAL=1 — run the inner claude against the local workhorse (zero quota burn).
# CLAUDE_ENV is prepended to the claude invocation; empty in cloud mode.
CLAUDE_ENV=()
LOCAL_TAG=""
if [ "${LOCAL:-0}" = "1" ]; then
  LOCAL_BASE="${LOCAL_BASE:-http://localhost:1234}"
  LOCAL_MODEL="${LOCAL_MODEL:-example/general-model}"
  CLAUDE_ENV=(env "ANTHROPIC_BASE_URL=$LOCAL_BASE" "ANTHROPIC_AUTH_TOKEN=lmstudio"
              "ANTHROPIC_MODEL=$LOCAL_MODEL" "ANTHROPIC_DEFAULT_HAIKU_MODEL=$LOCAL_MODEL")
  LOCAL_TAG=", local=$LOCAL_MODEL"
  ITER_TIMEOUT="${ITER_TIMEOUT:-7200}"
  # Fail fast if the workhorse won't serve at full ctx. llm.sh ensure also catches the
  # JIT-fallback trap: a silent 4096-ctx instance under the same id passes a served-list
  # check but kills nested claude (n_keep >= n_ctx; system prompt alone needs ~23k+).
  LOCAL_CTX="${LOCAL_CTX:-65536}"
  if ! "$(cd "$(dirname "$0")/.." && pwd)/local/llm.sh" ensure "$LOCAL_MODEL" "$LOCAL_CTX"; then
    echo "[loop] LOCAL=1 but '$LOCAL_MODEL' won't serve at ctx>=$LOCAL_CTX — aborting." >&2
    exit 1
  fi
else
  ITER_TIMEOUT="${ITER_TIMEOUT:-3600}"
  # Always-inject the cloud login (D-018): the sandboxed inner claude can't read ~/.claude, so pass
  # the existing login token through the env. Prefer an explicit CLAUDE_CODE_OAUTH_TOKEN (e.g. a
  # cascade worker's profile_env); else source it from the ~/.claude login via the cascade.sh seam
  # (resolves UNSANDBOXED only — empty under a sealed/headless context, falling back to ambient
  # login = exactly today's behavior, never worse). DRY: one resolver, shared with the workers.
  _tok="${CLAUDE_CODE_OAUTH_TOKEN:-}"
  if [ -z "$_tok" ]; then
    _tok="$("$REPO_DIR/loop/cascade.sh" oauth-token 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [ -n "$_tok" ]; then CLAUDE_ENV=(env "CLAUDE_CODE_OAUTH_TOKEN=$_tok"); fi
  unset _tok
fi
# Spend capture (scheduler budget mode): when SPEND_COST_FILE is set, capture the inner claude's
# real total_cost_usd this iteration. Never under LOCAL=1 (its cost is fictional CLI math).
CAPTURE_COST=0
if [ -n "${SPEND_COST_FILE:-}" ] && [ "${LOCAL:-0}" != "1" ]; then CAPTURE_COST=1; fi
LOOPGUARD_MAX_IDENTICAL="${LOOPGUARD_MAX_IDENTICAL:-2}"
STALL_MAX="${STALL_MAX:-2}"
DEADLINE=$(( $(date +%s) + MAX_MINUTES * 60 ))

# Permission posture (D-005 flip, 2026-06-06): DEFAULT = OS-sandboxed operation —
# acceptEdits + .claude/settings.json (sandbox strict fail-closed; permissions.allow Bash =
# auto-allow sandboxed bash; permissions.deny shields cred paths from the Read/Write tools).
# The sandbox, not the model, enforces FS and network (non-allowlisted domains -> CONNECT 403).
# ALLOW_ALL=1 is now an EXPLICIT bypass override (--dangerously-skip-permissions): under
# bypass the network allowlist is ADVISORY (prompts auto-approve) — supervised use only.
# Known sandbox limit: host loopback (a local server :1234) unreachable from sandboxed bash.
# All verified live 2026-06-06 — see NOTES.
if [ "${ALLOW_ALL:-0}" = "1" ]; then
  PERM_FLAG=(--dangerously-skip-permissions)
else
  PERM_FLAG=(--permission-mode acceptEdits)
fi

notify() {
  [ -n "${NTFY_TOPIC:-}" ] || return 0
  curl -s -o /dev/null --max-time 10 -d "$1" "https://ntfy.sh/${NTFY_TOPIC}" || true
}

# Run ./gate.sh and tee its output to a persistent log under .cascade/logs/ (gitignored, so it
# survives the gate-fail `git reset --hard`/`git clean` below — the failure reason was previously
# lost to terminal scrollback only). Sets $GATE_LOG; returns the gate's REAL exit code, not tee's.
run_gate_logged() {
  mkdir -p .cascade/logs
  GATE_LOG=".cascade/logs/gate-$(date +%Y%m%d-%H%M%S)-$$.log"
  # The gate (shellcheck + tests) needs NO cloud auth — strip CLAUDE_CODE_OAUTH_TOKEN so it can't
  # leak into a test's output/log and so token-sensitive fixtures see the genuine no-token path.
  # Redact any stray sk-ant-* token from the stream as defense-in-depth (sed -u keeps tee live).
  env -u CLAUDE_CODE_OAUTH_TOKEN ./gate.sh 2>&1 \
    | sed -u -E 's/(sk-ant-[a-z0-9]+-)[A-Za-z0-9_-]{12,}/\1<REDACTED>/g' | tee "$GATE_LOG"
  return "${PIPESTATUS[0]}"
}

# Plan 2 — route the previous gate failure's tail into the next attempt's prompt.
# Gate logs (.cascade/logs/gate-*.log, written by run_gate_logged above) are gitignored, so they
# survive the gate-fail revert (`git reset --hard` + `git clean --exclude=NOTES.md`). On a failure the
# worktree is reverted and the SAME task is re-picked cold next iteration; without this the next
# worker rediscovers the identical failure from scratch (wasted quota). These read from DISK, not a
# loop variable, because cascade runs one worker per process — a variable wouldn't survive.
GATE_TAIL_LINES="${GATE_TAIL_LINES:-25}"

# Capped tail of the MOST-RECENT gate log under $1 (default .cascade/logs), but ONLY when that log
# is a FAILURE — a passing log (last line contains 'RESULT: PASS') means the previous task closed
# and a different task is up, so there is nothing to route. Empty output (rc 0) when no log exists
# or the latest one passed. Uses a glob (not `ls`, which trips SC2012 at the gate's -S style);
# filenames are gate-<UTC-stamp>-<pid>.log, so a lexical sort is chronological.
latest_gate_failure_tail() {
  local dir="${1:-.cascade/logs}" log
  local logs=("$dir"/gate-*.log)
  # No match -> the array holds the un-expanded pattern (a path that doesn't exist).
  [ -e "${logs[0]}" ] || return 0
  log="$(printf '%s\n' "${logs[@]}" | sort | tail -n1)"
  if tail -n 1 "$log" 2>/dev/null | grep -q 'RESULT: PASS'; then
    return 0
  fi
  tail -n "$GATE_TAIL_LINES" "$log"
}

# Prompt-facing block built from latest_gate_failure_tail: the intro + the capped tail, or the
# empty string when there is no prior failure (so the prompt is byte-identical to before).
gate_fail_block() {
  local dir="${1:-.cascade/logs}" body
  body="$(latest_gate_failure_tail "$dir")" || true
  [ -n "$body" ] || return 0
  printf 'A previous attempt failed ./gate.sh in this workspace. Fix the cause shown below\n(tail of the last gate log, ~%s lines) BEFORE re-running the gate:\n\n%s' \
    "$GATE_TAIL_LINES" "$body"
}

# Backlog lines quoted (`> - [ ] …`) inside OPEN (blank **Answer:**) entries of
# director/DECISIONS.md — a tripped guard escalates with the task quoted, so an open escalation
# PAUSES that task; answering it (local/decide.sh apply) unpauses. Open-detection semantics match
# local/decide.sh's awk (cf. loop/scheduler.sh have_task, which consumes the same convention).
paused_tasks() {
  awk '
    function flush() { if (id != "" && ans !~ /[^[:space:]]/) printf "%s", buf; id=""; ans=""; inans=0; buf="" }
    /^## D-[0-9]+ / { flush(); id=$2; next }
    id == ""             { next }
    /^---[[:space:]]*$/  { flush(); next }
    /^\*\*Answer:\*\*/ { inans=1; t=$0; sub(/^\*\*Answer:\*\*/, "", t); ans=ans t; next }
    inans { ans = ans $0; next }
    /^> - \[ \] / { l=$0; sub(/^> /, "", l); buf = buf l "\n" }
    END { flush() }
  ' director/DECISIONS.md 2>/dev/null || true
}

next_task() {
  # CASCADE_TASK lets cascade.sh dispatch a SPECIFIC committed unit (a backlog line) to this
  # worker instead of the top-of-file pick — so a worker runs the unit it was claimed for,
  # not whatever is first. Empty/unset = normal standalone behavior (unchanged).
  if [ -n "${CASCADE_TASK:-}" ]; then
    printf '%s\n' "$CASCADE_TASK"
    return 0
  fi
  # First open task that is NOT paused by an open decision (substrate: only the action is held —
  # a stuck task waits for the director while the loop works the rest of the backlog).
  grep '^- \[ \]' backlog.md 2>/dev/null | grep -vxF -f <(paused_tasks) | head -n1 || true
}

# sha256 of stdin (portable: sha256sum -> shasum -> cksum).
hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    cksum | awk '{print $1}'
  fi
}

hash_file() {
  if [ -f "$1" ]; then hash_stdin <"$1"; else echo absent; fi
}

# Extract total_cost_usd from a `claude --output-format json` result blob; empty if absent or
# unparseable (no jq, timeout-truncated output, etc.). Used by the SPEND_COST_FILE capture path so
# loop/scheduler.sh can pace bursts against the monthly Agent-SDK credit (2026-06-15+ billing).
inner_cost() {
  command -v jq >/dev/null 2>&1 || { printf ''; return 0; }
  printf '%s' "$1" | jq -r '.total_cost_usd // empty' 2>/dev/null || true
}

# Full worktree change set vs HEAD: tracked diff + untracked file contents.
# Always returns 0 so it is safe on the left side of a pipe under `set -e`.
worktree_diff() {
  git diff HEAD 2>/dev/null || true
  local f
  while IFS= read -r -d '' f; do
    printf '\n=== untracked: %s ===\n' "$f"
    cat -- "$f" 2>/dev/null || true
  done < <(git ls-files --others --exclude-standard -z 2>/dev/null)
  return 0
}

# Stable signature for LoopGuard: task text + the change set it produced.
compute_sig() {
  { printf '%s\n=== diff ===\n' "$1"; worktree_diff; } | hash_stdin
}

# Did the iteration's commit actually CLOSE its task? The gate proves quality only; the mechanical
# signal that a task got done is the commit touching its completion record: a standalone task moves
# its line under '## Done' in backlog.md; a cascade unit (partition model) writes its own per-unit
# marker done/<id>.md and does NOT touch the shared backlog (the merge step renders it). Either
# counts. Reads HEAD's file list — exit 0 if a record was touched, 1 if not. Anchored so a lookalike
# (backlogXmd) or a nested path never false-matches.
commit_closed_task() {
  git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null \
    | grep -qE '^(backlog\.md|done/[^/]+\.md)$'
}

# cascade_unit_id <task-line> — print the cascade unit id from a dispatched task line's marker
# (<!-- cascade: id=<id> ... -->), or nothing for a normal standalone backlog task. Pure.
cascade_unit_id() {
  printf '%s' "$1" | grep -oE 'cascade: id=[^ ]+' | sed 's/cascade: id=//' | head -1 || true
}

# done_instruction <task-line> — the "Done means" completion bullet for the /goal prompt. A cascade
# unit records completion by writing its OWN per-unit marker (done/<id>.md) and must NOT edit the
# shared backlog.md — cascade merge renders backlog.md from the markers, so concurrent units never
# collide on it (the partition model; mirrors how current_tasks/*.claim is per-unit). A standalone
# task keeps the in-place move under '## Done'. Pure (only reads the task line). NOTE: this is an
# INSTRUCTION to the worker — real-run compliance (worker actually leaving backlog.md alone) is the
# thing to watch; if a worker disobeys, merge simply escalates the backlog conflict (fail-safe).
done_instruction() {
  local id; id="$(cascade_unit_id "$1")"
  if [ -n "$id" ]; then
    printf 'record completion by writing done/%s.md — a short paragraph (what landed + how the gate proved it). Do NOT edit backlog.md: cascade merge renders it from the per-unit markers, so units never collide on the shared file' "$id"
  else
    printf "the task line is moved under '## Done' in backlog.md with today's date and a summary"
  fi
}

# Pure stall-streak decision (echoes `reset` or `increment`) for one iteration's outcome.
# Args: committed backlog_touched notes_changed project_mode gate_failed  (each 0/1;
# gate_failed defaults to 0 for older callers).
# A committed AGENCY iteration that did NOT touch backlog.md is the half-done signature the
# gate can't see -> `increment`, and it DOMINATES a NOTES.md change (a half-done run still
# appends a learnings/lesson line, which must not mask the missing task close). External-project
# mode has no agency backlog to move, so any committed client iteration counts as progress.
# gate_failed=1 forces `increment`: the harness's OWN gate-failure lesson append flips
# notes_changed every red iteration, which previously reset the streak — an LLM regenerating a
# different failing change each attempt evaded STALL_MAX (and LoopGuard) indefinitely.
stall_decision() {
  local committed="$1" backlog_touched="$2" notes_changed="$3" project_mode="$4" gate_failed="${5:-0}"
  if [ "$gate_failed" -eq 1 ]; then
    echo increment; return 0
  fi
  if [ "$committed" -eq 1 ] && [ "$project_mode" -eq 0 ] && [ "$backlog_touched" -eq 0 ]; then
    echo increment; return 0
  fi
  if [ "$committed" -eq 1 ] || [ "$notes_changed" -eq 1 ]; then
    echo reset; return 0
  fi
  echo increment
}

# Run claude under a per-iteration wall-clock cap (timeout exits 124, or 137 if KILLed).
# CLAUDE_CWD (external-project mode) runs the inner claude in the project checkout; empty = here.
run_claude() {
  ( [ -z "${CLAUDE_CWD:-}" ] || cd "$CLAUDE_CWD"
    local fmt=()
    [ "${CAPTURE_COST:-0}" = "1" ] && fmt=(--output-format json)
    if command -v timeout >/dev/null 2>&1; then
      timeout --signal=TERM --kill-after=30s "$ITER_TIMEOUT" \
        "${CLAUDE_ENV[@]}" claude -p "$1" "${PERM_FLAG[@]}" "${fmt[@]}" --max-turns 80
    else
      "${CLAUDE_ENV[@]}" claude -p "$1" "${PERM_FLAG[@]}" "${fmt[@]}" --max-turns 80
    fi )
}

# Next free D-NNN id in director/DECISIONS.md (base-10 forced; no octal surprises).
next_decision_id() {
  local n
  n="$(grep -hoE '^## D-[0-9]+' director/DECISIONS.md 2>/dev/null \
        | grep -oE '[0-9]+$' | sort -n | tail -1 || true)"
  printf 'D-%03d' "$(( 10#${n:-0} + 1 ))"
}

# Non-blocking escalation: append a decision the director can answer later, then stop.
escalate() {
  local title="$1" body="$2" id today apply
  today="$(date +%F)"
  apply="$(date -d '+3 days' +%F 2>/dev/null || date +%F)"
  mkdir -p director
  # id-mint + append under an flock (cf. local/queue.sh with_lock): concurrent escalations
  # (this loop + parallel cascade dispatchers) must not mint the same D-NNN. The subshell
  # prints the minted id so the caller can log it.
  id="$(
    ( flock -x 9
      new_id="$(next_decision_id)"
      {
        printf '\n## %s — %s\n' "$new_id" "$title"
        printf '**Asked:** %s · **Default applies:** %s → default = pause this task, keep loop alive\n' \
          "$today" "$apply"
        printf '**Trigger:** %s\n' "$body"
        printf '**Question:** How should the director resolve this stuck loop?\n'
        printf '**Options:** (a) investigate & fix the loop/guard · (b) rewrite or split the task · (c) drop the task\n'
        printf '**Recommended default:** (a) — a repeating or stalled loop usually means the task is underspecified, blocked, or the gate is unsatisfiable.\n'
        printf '**Answer:**\n'
      } >> director/DECISIONS.md
      printf '%s' "$new_id"
    ) 9>director/DECISIONS.md.lock
  )"
  pg_node 'decision' "$id" '{}' >/dev/null 2>&1 || true
  echo "[loop] escalated $id — $title"
  notify "agency loop: ESCALATED $id — $title"
}

# --- guard state across iterations ------------------------------------------
PREV_SIG=""
SAME_COUNT=0
STALL_STREAK=0

# Sourcing seam for tests: `RUN_SH_LIB=1 source loop/run.sh` loads the pure helpers above
# (commit_closed_task, stall_decision, …) WITHOUT entering the loop — see tests/run_completion_test.sh.
# RUN_SH_LIB is set only by a sourcing caller, so the `return` is always reached from a sourced
# context (a normal `./loop/run.sh` run never sets it and falls through to the loop).
if [ "${RUN_SH_LIB:-0}" = "1" ]; then
  return 0
fi

run=0
while [ "$run" -lt "$MAX_RUNS" ] && [ "$(date +%s)" -lt "$DEADLINE" ]; do
  run=$((run + 1))

  TASK="$(next_task)"
  if [ -z "$TASK" ]; then
    echo "[loop] no runnable task (backlog empty or all open tasks paused) — stopping."
    notify "agency loop: no runnable task after $((run - 1)) runs"
    break
  fi

  echo "[loop] run $run/$MAX_RUNS — task: $TASK"

  # PG event stream: job-<uuid> (dispatch via PG) or job-<cascade-id> or job-adhoc-<pid>.
  _pg_unit="$(printf '%s' "$TASK" | grep -oE 'cascade: id=[^ ]+' | head -1 \
               | sed 's/.*id=//' || true)"
  if [ -n "${CASCADE_PG_JOB_ID:-}" ]; then
    _pg_stream="job-${CASCADE_PG_JOB_ID}"
  else
    _pg_stream="job-${_pg_unit:-adhoc-$$}"
  fi
  pg_append_event "$_pg_stream" "job.started" "{}"

  NOTES_BEFORE="$(hash_file NOTES.md)"

  # /goal condition: one measurable end state + the check + constraints + a turn bound.
  # The evaluator only reads the conversation, so each condition states how to PROVE it.
  # Two modes: agency (work this repo) and external-project (PROJECT_DIR set — work a client
  # checkout, which to that repo must look like ordinary dev work).
  #
  # Plan 2: in agency mode only, inline the previous gate failure's tail (external-project uses the
  # project's OWN gate via enforce.sh, so there is no agency gate log to route). Empty when there is
  # no prior failure on disk, so the prompt stays byte-identical to before. `$()` strips trailing
  # newlines, so the blank-line separator is re-added here, not baked into gate_fail_block.
  GATE_FAIL_BLOCK=""
  if [ -z "${PROJECT_DIR:-}" ]; then
    GATE_FAIL_BLOCK="$(gate_fail_block || true)"
    if [ -n "$GATE_FAIL_BLOCK" ]; then
      GATE_FAIL_BLOCK="${GATE_FAIL_BLOCK}"$'\n\n'
    fi
  fi
  if [ -n "${PROJECT_DIR:-}" ]; then
    PROJECT_BRANCH="${PROJECT_BRANCH:-agency/work}"
    PROJECT_GATE="${PROJECT_GATE:-./gate.sh}"
    PROJECT_SCOPE="${PROJECT_SCOPE:-}"
    CLAUDE_CWD="$PROJECT_DIR"
    # CM-5: narrow the worker's ATTENTION (not the filesystem). A client checkout can be huge
    # (e.g. a VS Code build) — exploring it all displaces the goal and blows the context window.
    if [ -n "$PROJECT_SCOPE" ]; then
      SCOPE_LINE="Edit ONLY these files/areas: ${PROJECT_SCOPE}. Treat the rest of the checkout as read-only."
    else
      SCOPE_LINE="Work only on the files this task names and their direct dependencies."
    fi
    PROMPT="/goal This client-project task is complete: ${TASK#- \[ \] }

You are working in a CLIENT project checkout at ${PROJECT_DIR}. To this repo you are an ordinary
developer: put NO agency references (no NOTES.md, no D-NNN ids, no 'loop'/'cascade'/'agency'
wording, no Claude/AI attribution) in the code, commits, or docs.

Scope your attention: this may be a large repository. ${SCOPE_LINE} Do NOT read or scan the whole
repo — locate the relevant code with targeted search (grep/glob for the symbols the task names) and
read only those files. Widen the search only when a failing test or error points you elsewhere.

Done means ALL of:
- the change the task describes is implemented in ${PROJECT_DIR}
- the project's own gate passes: run '${PROJECT_GATE}' in ${PROJECT_DIR} and show it green
- you leave the work UNCOMMITTED in the working tree — the harness commits it on an isolated
  branch with a sanitized message and records the client commit in the agency ledger

Constraints: complete ONLY this task, no scope creep. Never git commit, push, or create repos.
If a human decision is needed, do NOT stop: append a numbered D-NNN entry to
${REPO_DIR}/director/DECISIONS.md (the AGENCY repo, never this project), pick the default, continue.

or stop after ${GOAL_MAX_TURNS} turns"
  else
    CLAUDE_CWD=""
    PROMPT="/goal This backlog task is fully complete: ${TASK#- \[ \] }

${GATE_FAIL_BLOCK}Context first (just-in-time — do NOT read NOTES.md in full): read director/STATE.md (binding
decisions + invariants you must not violate) and director/MAP.md (the repo index), then open only
the NOTES.md sections (by the L<n> line pointers in MAP) or the ARCHITECTURE.md parts the MAP points
you to for THIS task.

Done means ALL of, in $(pwd):
- the work the task describes is implemented and working
- ./gate.sh has been run and its output shown, ending in 'RESULT: PASS'
- $(done_instruction "$TASK")
- a learnings section for this task is APPENDED to the END of NOTES.md — never rewrite,
  reorder, or delete existing NOTES.md content; the gate fails the iteration if NOTES.md shrinks

Constraints: complete ONLY this task, no scope creep. Never git commit or push and never
create repos — leave the worktree dirty; the loop harness gates and commits afterwards.
Do not touch anything outside this directory. If a human decision is needed, do NOT stop:
append a numbered D-NNN entry to director/DECISIONS.md (question, options, recommended
default, apply-default-after date), pick the default yourself, note it, and continue.

or stop after ${GOAL_MAX_TURNS} turns"
  fi

  # --- run claude under a per-iteration timeout ---------------------------
  set +e
  if [ "$CAPTURE_COST" = "1" ]; then
    # Budget mode: capture JSON to bank the real cost, then print the result text so the run
    # stays human-readable in the scheduler log.
    CLAUDE_OUT="$(run_claude "$PROMPT")"
    CLAUDE_EXIT=$?
    printf '%s\n' "$CLAUDE_OUT" | jq -r '.result // empty' 2>/dev/null || printf '%s\n' "$CLAUDE_OUT"
    ITER_COST="$(inner_cost "$CLAUDE_OUT")"
    if [ -n "$ITER_COST" ]; then printf '%s\n' "$ITER_COST" >> "$SPEND_COST_FILE"; fi
  else
    run_claude "$PROMPT"
    CLAUDE_EXIT=$?
  fi
  set -e
  if [ "$CLAUDE_EXIT" -eq 124 ] || [ "$CLAUDE_EXIT" -eq 137 ]; then
    echo "[loop] claude exceeded ITER_TIMEOUT=${ITER_TIMEOUT}s — killed."
    notify "agency loop: iteration $run TIMED OUT (${ITER_TIMEOUT}s)"
  fi

  # --- LoopGuard signature: capture BEFORE the gate mutates the worktree --
  # In external-project mode the agency worktree is untouched (claude edits the project), so the
  # signature must hash the PROJECT's change set or LoopGuard would false-trip every iteration.
  if [ -n "${PROJECT_DIR:-}" ]; then
    SIG="$( { printf '%s\n=== diff ===\n' "$TASK"; git -C "$PROJECT_DIR" diff HEAD 2>/dev/null || true; } | hash_stdin )"
  else
    SIG="$(compute_sig "$TASK")"
  fi
  if [ -n "$PREV_SIG" ] && [ "$SIG" = "$PREV_SIG" ]; then
    SAME_COUNT=$((SAME_COUNT + 1))
  else
    SAME_COUNT=1
  fi
  PREV_SIG="$SIG"

  # --- gate -> revert, or commit ------------------------------------------
  committed=0
  backlog_touched=0
  gate_failed=0
  if [ -n "${PROJECT_DIR:-}" ]; then
    # External-project mode: the project's OWN gate + a sanitized commit on an isolated branch are
    # done by enforce.sh (which also records the client commit in the agency ledger). The agency
    # repo gets only NOTES + ledger bookkeeping — the project repo stays agency-agnostic (VISION).
    set +e
    loop/enforce.sh project-commit "$PROJECT_DIR" "$PROJECT_BRANCH" "$PROJECT_GATE" "${TASK#- \[ \] }"
    pc_rc=$?
    set -e
    case "$pc_rc" in
      0) committed=1; echo "[loop] external-project: client commit landed on $PROJECT_BRANCH." ;;
      2) echo "[loop] external-project: no changes to commit this iteration." ;;
      *) echo "[loop] external-project: project gate red / commit failed (rc=$pc_rc) — nothing recorded."
         notify "agency loop: external-project gate failed on '$TASK' (run $run)" ;;
    esac
    {
      echo ""
      echo "## $(date -Iseconds) — external-project iteration: ${TASK#- \[ \] }"
      echo "Project: $PROJECT_DIR · branch $PROJECT_BRANCH · gate '$PROJECT_GATE' · committed=$committed (rc=$pc_rc)."
    } >> NOTES.md
    if [ -n "$(git status --porcelain)" ]; then
      git add -A
      git commit -m "ops: external-project bookkeeping — ${TASK#- \[ \] }" \
        -m "client work on $PROJECT_BRANCH (committed=$committed)${LOCAL_TAG}"
    fi
    if [ -x local/digest.sh ]; then local/digest.sh || true; fi
    notify "agency loop: run $run done (external-project) — $TASK"
  elif [ ! -x ./gate.sh ] || ! git diff --quiet HEAD -- gate.sh; then
    # Fail CLOSED (audit fix 1.1): a missing/renamed/un-chmodded gate.sh previously made the
    # `[ -x ./gate.sh ] && ! run_gate_logged` elif false, falling through to the COMMIT branch —
    # a worker deleting the gate landed ungated work on the base. Treat it exactly like a gate
    # failure: revert (which also restores a tracked gate.sh), log the lesson, never commit.
    # The diff check extends this to TAMPERING: any worker edit to gate.sh (the merge authority)
    # is an automatic FAIL — a modified gate's verdict is worthless.
    # ponytail: tests/ stays worker-editable (softening an existing test still passes) — run
    # tests from HEAD too if that attack ever shows up in a transcript.
    echo "[loop] gate.sh missing, non-executable, or modified vs HEAD — treating as gate FAIL; reverting working tree."
    gate_failed=1
    # reset --hard restores from HEAD, not the index — a worker's `git add`/`git rm` must not
    # survive the revert staged (audit fix 2.3; `git checkout -- .` restored from the INDEX).
    git reset -q --hard HEAD 2>/dev/null || true
    git clean -fd --exclude=NOTES.md 2>/dev/null || true
    {
      echo ""
      echo "## $(date -Iseconds) — gate missing/non-exec/modified on: $TASK"
      echo "gate.sh was absent, lost its executable bit, or was edited; the iteration was reverted UNGATED."
      echo "The revert restores the HEAD gate.sh. Investigate before retrying this task."
    } >> NOTES.md
    pg_append_event "$_pg_stream" "gate.failed" "{}"
    if [ -n "${CASCADE_PG_JOB_ID:-}" ]; then
      pg_fail_job "${CASCADE_PG_JOB_ID}" "${CASCADE_PG_CLAIMER:-}" "gate missing/non-exec"
    fi
    notify "agency loop: gate MISSING/non-exec/modified on '$TASK' (run $run)"
  elif ! run_gate_logged; then
    echo "[loop] gate FAILED (log: $GATE_LOG) — reverting working tree, logging lesson."
    gate_failed=1
    # reset --hard restores from HEAD, not the index — a worker's `git add`/`git rm` must not
    # survive the revert staged (audit fix 2.3; `git checkout -- .` restored from the INDEX).
    git reset -q --hard HEAD 2>/dev/null || true
    git clean -fd --exclude=NOTES.md 2>/dev/null || true
    # Append the lesson AFTER the revert so it survives (the old order let the revert wipe
    # the lesson too). The gate output itself lives in $GATE_LOG (gitignored, untouched).
    {
      echo ""
      echo "## $(date -Iseconds) — gate failure on: $TASK"
      echo "Gate output: $GATE_LOG (gitignored, survives the revert)."
      echo "Iteration reverted. Investigate before retrying this task."
    } >> NOTES.md
    pg_append_event "$_pg_stream" "gate.failed" "{}"
    if [ -n "${CASCADE_PG_JOB_ID:-}" ]; then
      pg_fail_job "${CASCADE_PG_JOB_ID}" "${CASCADE_PG_CLAIMER:-}" "gate failed"
    fi
    notify "agency loop: gate FAILED on '$TASK' (run $run)"
  else
    if [ -n "$(git status --porcelain)" ]; then
      git add -A
      git commit -m "loop: ${TASK#- \[ \] }" -m "iteration $run, claude exit ${CLAUDE_EXIT}${LOCAL_TAG}"
      committed=1
      if commit_closed_task; then backlog_touched=1; fi
      _sha="$(git rev-parse --short HEAD 2>/dev/null || true)"
      pg_append_event "$_pg_stream" "gate.passed" "{}"
      pg_append_event "$_pg_stream" "job.completed" "{\"commit\":\"${_sha}\"}"
      if [ -n "${CASCADE_PG_JOB_ID:-}" ]; then
        pg_complete_job "${CASCADE_PG_JOB_ID}" "${CASCADE_PG_CLAIMER:-}" "${_sha}"
      fi
      # --- lineage: best-effort nodes+edges (PG down = no-op via pg_node/pg_edge) ---
      if [ "${PG_AVAIL}" = "1" ]; then
        _lin_full_sha="$(git rev-parse HEAD 2>/dev/null || true)"
        _lin_job_key="${CASCADE_PG_JOB_ID:-${_pg_unit:-adhoc-$$}}"
        if [ "${LOCAL:-0}" = "1" ]; then
          _lin_model="${LOCAL_MODEL:-unknown-local}"
        else
          _lin_model="${ANTHROPIC_MODEL:-claude-sonnet-4-6}"
        fi
        _lin_prompt_sha="$(printf '%s' "$PROMPT" | hash_stdin)"
        if [ "${ALLOW_ALL:-0}" = "1" ]; then
          _lin_profile="ambient"
        elif [ "${LOCAL:-0}" = "1" ]; then
          _lin_profile="local"
        else
          _lin_profile="online"
        fi
        _lin_machine="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown')"
        _lin_commit_subj="$(git log -1 --format=%s HEAD 2>/dev/null || true)"
        if command -v jq >/dev/null 2>&1; then
          _lin_commit_attrs="$(jq -n --arg s "$_lin_commit_subj" '{subject:$s}' 2>/dev/null || printf '{}')"
          _lin_job_attrs="$(jq -n --arg t "${TASK#- \[ \] }" '{title:$t}' 2>/dev/null || printf '{}')"
        else
          _lin_commit_attrs='{}'
          _lin_job_attrs='{}'
        fi
        _nid_commit="$(  pg_node 'commit'           "$_lin_full_sha"   "$_lin_commit_attrs" || true)"
        _nid_job="$(     pg_node 'job'               "$_lin_job_key"    "$_lin_job_attrs"    || true)"
        _nid_model="$(   pg_node 'model_version'     "$_lin_model"      '{}'                 || true)"
        _nid_prompt="$(  pg_node 'prompt'            "$_lin_prompt_sha" '{}'                 || true)"
        _nid_profile="$( pg_node 'sandbox_profile'   "$_lin_profile"    '{}'                 || true)"
        _nid_machine="$( pg_node 'machine'           "$_lin_machine"    '{}'                 || true)"
        if [ -n "$_nid_commit" ]  && [ -n "$_nid_job" ];     then pg_edge "$_nid_commit" "$_nid_job"     'produced_by'   || true; fi
        if [ -n "$_nid_job" ]     && [ -n "$_nid_model" ];   then pg_edge "$_nid_job"    "$_nid_model"   'ran_on'        || true; fi
        if [ -n "$_nid_job" ]     && [ -n "$_nid_prompt" ];  then pg_edge "$_nid_job"    "$_nid_prompt"  'used_prompt'   || true; fi
        if [ -n "$_nid_job" ]     && [ -n "$_nid_profile" ]; then pg_edge "$_nid_job"    "$_nid_profile" 'under_profile' || true; fi
        if [ -n "$_nid_job" ]     && [ -n "$_nid_machine" ]; then pg_edge "$_nid_job"    "$_nid_machine" 'on_machine'    || true; fi
      fi
      echo "[loop] committed."
    else
      echo "[loop] no changes produced."
    fi
    if [ -x local/digest.sh ]; then local/digest.sh || true; fi
    notify "agency loop: run $run done — $TASK"
  fi

  # --- task-completion check + progress accounting for stall detection ----
  # The gate proves QUALITY (shellcheck/tests), never that the PICKED task actually got done.
  # In agency mode a commit that did NOT move a backlog task (touch backlog.md) is the half-done
  # signature the gate can't see — 2026-06-06 the loop committed unticked watcher work twice with
  # no signal. The /goal evaluator normally enforces the check-off, but it only reads the
  # conversation; this is the independent backstop. Warn + feed the stall streak (never hard-fail:
  # some legit iterations are NOTES-only, e.g. a gate-failure lesson or a research note).
  NOTES_AFTER="$(hash_file NOTES.md)"
  notes_changed=0
  if [ "$NOTES_BEFORE" != "$NOTES_AFTER" ]; then notes_changed=1; fi
  proj_mode=0
  if [ -n "${PROJECT_DIR:-}" ]; then proj_mode=1; fi

  if [ "$committed" -eq 1 ] && [ "$proj_mode" -eq 0 ] && [ "$backlog_touched" -eq 0 ]; then
    echo "[loop] task-completion: committed but backlog.md untouched — task NOT closed; counting as no-progress." >&2
    notify "agency loop: run $run committed but closed NO backlog task — '$TASK'"
  fi

  case "$(stall_decision "$committed" "$backlog_touched" "$notes_changed" "$proj_mode" "$gate_failed")" in
    increment) STALL_STREAK=$((STALL_STREAK + 1)) ;;
    *)         STALL_STREAK=0 ;;
  esac

  # --- guards: escalate + pause the stuck task, keep the loop alive -------
  # The escalation quotes the task line (`> $TASK`), so while the decision is open next_task
  # skips it (paused_tasks above) — the quota stops burning on THIS task without holding the
  # rest of the backlog hostage. Streaks reset because the next iteration works a different
  # task. A cascade unit has no "next task" (this process IS the unit) — it stops; the
  # dispatcher moves on to other units.
  if [ "$SAME_COUNT" -ge "$LOOPGUARD_MAX_IDENTICAL" ]; then
    escalate "LoopGuard tripped after $SAME_COUNT identical iterations" \
"The loop produced the identical task+diff signature (${SIG:0:12}) for $SAME_COUNT consecutive iterations on:
> $TASK

A-B-A-B / stuck-repeat: Claude keeps generating the same change with no forward progress (often a change the gate keeps rejecting). Task paused until the decision is answered."
    if [ -n "${CASCADE_TASK:-}" ]; then
      echo "[loop] LoopGuard tripped after $SAME_COUNT identical iterations — stopping (cascade unit)."
      break
    fi
    echo "[loop] LoopGuard tripped after $SAME_COUNT identical iterations — task paused, moving on."
    PREV_SIG=""; SAME_COUNT=0; STALL_STREAK=0
    continue
  fi

  if [ "$STALL_STREAK" -ge "$STALL_MAX" ]; then
    escalate "Stall detected after $STALL_STREAK runs with no progress" \
"$STALL_STREAK consecutive iterations produced no commit and no persisted NOTES.md change on:
> $TASK

The loop is neither shipping code nor recording why. Likely the task is blocked, underspecified, or claude is erroring/timing out before doing useful work. Task paused until the decision is answered."
    if [ -n "${CASCADE_TASK:-}" ]; then
      echo "[loop] stall detected after $STALL_STREAK runs — stopping (cascade unit)."
      break
    fi
    echo "[loop] stall detected after $STALL_STREAK runs — task paused, moving on."
    PREV_SIG=""; SAME_COUNT=0; STALL_STREAK=0
    continue
  fi
done

echo "[loop] finished ($run runs)."
