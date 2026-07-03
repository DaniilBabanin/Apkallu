#!/usr/bin/env bash
# cascade.sh — the down-cascade (org/cascade.md) on the proven loop. v1, D-006 (a): no bash
# mailbox; coordination lives in git refs (GUPP), never in an LLM's judgment.
#
# It turns ONE director instruction into committed, gated work via two mechanics:
#
#   decompose "<instruction>"   Tech Director step. Calls a `claude -p` contract that splits the
#                               instruction into >=2 task units (each a /goal done-condition +
#                               blocked-by) and writes them to backlog.md, then COMMITS them
#                               (commit-before-dispatch: a worker checking out cannot see
#                               uncommitted state). The decompose call is the ONLY LLM step and
#                               is overridable (DECOMPOSE_CMD) so the mechanics are testable
#                               without burning quota. Real decomposition only: <2 units fails.
#
#   dispatch [--profile P]      Ops/Security/Worker step. Picks the next READY unit (unchecked,
#                               unclaimed, blocked-by satisfied — all read from git-tracked
#                               state), CLAIMS it by committing a marker under current_tasks/
#                               (so concurrent dispatchers never double-pick), creates an
#                               ISOLATED git worktree + branch (cascade/<id>), and runs ONE
#                               worker (loop/run.sh /goal, overridable via WORKER_CMD) there.
#                               Respects the <=5 concurrency ceiling (cascade.md §Concurrency).
#                               --profile <local|online|mixed> injects the in-sandbox worker
#                               env so the nested claude spawns correctly (D-007; see
#                               profile_env). Omitted = ambient env (back-compat).
#
#   reset <id>                  Release a failed/stuck unit for a clean retry: remove its worktree
#                               + branch + claim (the diagnostic log under .cascade/logs/ is kept),
#                               leaving the backlog unit unchecked so `dispatch` re-picks it.
#
#   merge                       The UP-cascade: land every DONE, gate-green cascade/<id> branch into
#                               the base branch (HEAD), in blocked-by order; prune each merged unit's
#                               worktree + branch + claim. A merge conflict means the disjoint-paths
#                               invariant broke — it is NOT auto-resolved: abort, escalate (D-NNN),
#                               leave the branch intact. Runs local/digest.sh after a non-empty batch
#                               (the "+digest" half). Merge authority = git facts + ./gate.sh, no LLM.
#
#   reconcile                   Bulk maintenance (replaces ad-hoc `reset` for batch cleanup):
#                               call reap_expired() to requeue PG leases that expired, prune
#                               orphan worktrees (no claim + PG confirms not running), prune
#                               orphan cascade/* branches (no worktree), and report job↔git
#                               drift. All best-effort: PG down skips PG steps safely.
#
#   next-ready                  Pure: print the next ready unit id (rc 0) or nothing (rc 1).
#                               No writes — used by dispatch and by tests/ (fixture backlogs).
#
#   profile-env <P> [id]        Pure: print the worker env a profile injects (KEY=VALUE per line).
#                               Inspection + the seam tests/ exercise. rc 0 ok · 1 unknown profile
#                               · 2 online/mixed but no token resolvable.
#
#   oauth-token                 Pure: print the resolved cloud token (env / oauth-token file /
#                               ~/.claude login — see resolve_oauth_token). The UNSANDBOXED launcher
#                               uses it to always inject the existing login into sandboxed work:
#                               `export CLAUDE_CODE_OAUTH_TOKEN="$(loop/cascade.sh oauth-token)"`.
#
# "Done" is never an LLM saying so: a unit is done only when its branch passes ./gate.sh and is
# checked off in backlog.md. run.sh owns that per-unit verdict; this script orchestrates BOTH the
# DOWN-cascade (decompose -> dispatch) and the UP-cascade (merge -> digest): git facts decide.
#
# Why git-worktree (not the `claude --worktree` flag): the worker is loop/run.sh, which runs the
# gate and commits in its OWN cwd. So worker-level isolation means the WHOLE worker (claude edit
# + gate + commit) must run inside the worktree — exactly what `git worktree add` + cd gives.
# It is the same mechanism `claude --worktree` uses under the hood; driving it here keeps run.sh's
# gate/commit landing on the unit's isolated branch.
#
# Env:
#   CASCADE_REPO            operate on this repo instead of the script's own (tests / worktrees).
#   DECOMPOSE_CMD           override the decompose command (tests). Default: a `claude -p` call.
#   CASCADE_DECOMPOSE_MAX_TURNS  max turns for the default decompose `claude -p` (default 6; D-019).
#   WORKER_CMD              override the worker command (tests). Default: ./loop/run.sh.
#   CASCADE_GATE_CMD       override the per-branch merge gate (tests). Default: ./gate.sh, run
#                          inside the unit's worktree (the `merge` subcommand's green check).
#   CASCADE_DIGEST_CMD     override the post-merge digest command (tests). Default: local/digest.sh.
#   CASCADE_BATCH           batch id prefix for generated unit ids (default c<timestamp>).
#   CASCADE_MAX_CONCURRENT  concurrency ceiling = claims in flight (default 5).
#   CASCADE_WT_DIR          worktree base dir (default <repo>/.cascade/worktrees, gitignored).
#   CASCADE_NO_COMMIT       1 = write files but skip git commits (dry run / inspection).
#   MAX_RUNS                passed to the worker (default 1 — sequential bursts, cascade.md).
#   --- sandbox worker profiles (D-007), used by --profile / profile-env ---
#   CASCADE_LOCAL_BASE      local model base URL for the local/mixed profiles (default
#                           http://localhost:1234 — a local server; ollama is :11434).
#   CASCADE_LOCAL_MODEL     local served model id (default example/general-model).
#   CASCADE_LOCAL_CTX       ctx the local worker model is pinned at when routed through the queue
#                           (default 65536 — the nested-claude requirement; matches run.sh LOCAL=1).
#   CASCADE_VIA_QUEUE       1 (default) = a --profile local worker is run THROUGH local/queue.sh
#                           (enqueue + drain, model-aware: routing.md §5) so concurrent local
#                           workers don't each fire an independent `lms load` and thrash the
#                           big-MoE slot; 0 = run the worker inline (the pre-queue behavior).
#   CASCADE_QUEUE           path to queue.sh (default local/queue.sh) — overridable for tests.
#   CASCADE_CONFIG_BASE     parent dir for the worker's CLAUDE_CONFIG_DIR (default $TMPDIR —
#                           MUST be writable in-sandbox; /tmp is read-only there).
#   AGENCY_OAUTH_TOKEN_FILE online/mixed token file, read OUTSIDE the repo (default
#                           ~/.config/agency/oauth-token). CLAUDE_CODE_OAUTH_TOKEN env overrides.
#
# Exit: 0 ok · 1 nothing ready / usage · 2 decompose failed (escalated) · 3 at concurrency cap.

set -euo pipefail

# _CASCADE_SCRIPT_DIR is always the real repo (cascade.sh's parent), regardless of CASCADE_REPO.
# CASCADE_REPO only redirects git-state reads (backlog, claims, worktrees) — not script locations.
_CASCADE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${CASCADE_REPO:-$_CASCADE_SCRIPT_DIR}"
cd "$REPO_DIR"

# PG glue (best-effort: PG_AVAIL=0 when PG is down — all pg_* calls then no-op)
# shellcheck source=lib/pg.sh
source "$_CASCADE_SCRIPT_DIR/lib/pg.sh"

BACKLOG="backlog.md"
CLAIM_DIR="current_tasks"
DONE_DIR="done"   # per-unit done-markers (done/<id>.md); the merge renders BACKLOG from these
CASCADE_MAX_CONCURRENT="${CASCADE_MAX_CONCURRENT:-5}"
CASCADE_WT_DIR="${CASCADE_WT_DIR:-$REPO_DIR/.cascade/worktrees}"
CASCADE_LOG_DIR="${CASCADE_LOG_DIR:-$REPO_DIR/.cascade/logs}"   # worker run logs (gitignored; in the MAIN repo, so a worktree revert/prune can't take them)

# Sandbox worker profile knobs (D-007: workers spawn IN-sandbox). See profile_env().
CASCADE_LOCAL_BASE="${CASCADE_LOCAL_BASE:-http://localhost:1234}"   # a local server / ollama base URL
CASCADE_LOCAL_MODEL="${CASCADE_LOCAL_MODEL:-example/general-model}"    # local served model id
CASCADE_LOCAL_CTX="${CASCADE_LOCAL_CTX:-65536}"                     # nested-claude ctx (run.sh LOCAL=1)
WORKER_CONFIG_BASE="${CASCADE_CONFIG_BASE:-${TMPDIR:-/tmp}}"        # CLAUDE_CONFIG_DIR parent (writable in-sandbox)

# usage(): print the header comment block (everything up to `set -euo`), comment markers stripped.
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

# --- git-tracked state readers (GUPP: read coordination from git, not an LLM) ----------------
# Unit marker in backlog.md: <!-- cascade: id=<id> blocked-by=<id|none> -->

unit_ids() {
  grep -oE '<!-- cascade: id=[^ ]+' "$BACKLOG" 2>/dev/null | sed 's/.*id=//' || true
}

unit_line() {
  grep -E "<!-- cascade: id=$1 " "$BACKLOG" 2>/dev/null | head -1 || true
}

unit_blocked_by() {
  unit_line "$1" | sed -nE 's/.*blocked-by=([^ ]+) -->.*/\1/p'
}

unit_checked() {
  grep -qE "^- \[x\] .*<!-- cascade: id=$1 " "$BACKLOG" 2>/dev/null
}

unit_claimed() {
  [ -f "$CLAIM_DIR/$1.claim" ]
}

# rc 0 if this unit's work is already merged into HEAD's history. The worker's loop commit IS the
# backlog line (`git commit -m "loop: <line>"`), so it carries the `cascade: id=<id> ` marker and
# only reaches master on merge; the claim commit ("cascade claim: <id>") lacks that marker, so an
# in-flight unit is NOT matched. --grep matches commit MESSAGES, not the tree, so the marker that
# lives in backlog.md never false-positives. Trailing space disambiguates u1 from u10 (cf. unit_line).
unit_merged() {
  [ -n "$(git log -1 --format=%H -F --grep="cascade: id=$1 " 2>/dev/null || true)" ]
}

# rc 0 if branch cascade/<id> carries the worker's loop commit for this unit AHEAD of the base
# (HEAD). The merge readiness signal — NOT unit_checked: the worker moves the backlog line to Done
# (checks the box) on its BRANCH, so unit_checked(main) is still false until the merge lands. The
# loop commit's MESSAGE mechanically embeds the marker (run.sh: `git commit -m "loop: <line>"`,
# and the line carries `cascade: id=<id> `), so this is the same robust trick as unit_merged but
# scoped to what the branch adds. A branch with only the claim commit (work not done / rolled back)
# has nothing ahead and is NOT matched. Trailing space disambiguates u1 from u10 (cf. unit_merged).
branch_unit_done() {
  [ -n "$(git log "HEAD..cascade/$1" -1 --format=%H -F --grep="cascade: id=$1 " 2>/dev/null || true)" ]
}

active_claims() {
  local n=0 pg_n=0
  if [ -d "$CLAIM_DIR" ]; then
    n="$(find "$CLAIM_DIR" -maxdepth 1 -name '*.claim' 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [ "${PG_AVAIL:-0}" = "1" ]; then
    pg_n="$(pg_query "SELECT count(*)::text FROM jobs WHERE state='running'" \
              | tr -d '[:space:]' || echo 0)"
  fi
  printf '%s' "$(( n + pg_n ))"
}

# First unit that is unchecked, unclaimed, and not blocked by an unfinished unit. rc 0 + id, else 1.
next_ready() {
  local id bb
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if unit_checked "$id"; then continue; fi
    if unit_claimed "$id"; then continue; fi
    if unit_merged "$id"; then
      echo "[cascade] next-ready: $id work is merged but its backlog line is unchecked — skipping (re-tick the line)." >&2
      continue
    fi
    bb="$(unit_blocked_by "$id")"
    if [ -n "$bb" ] && [ "$bb" != "none" ]; then
      if ! unit_checked "$bb"; then continue; fi
    fi
    printf '%s\n' "$id"
    return 0
  done < <(unit_ids)
  return 1
}

# --- non-blocking escalation (ARCHITECTURE principle 1) --------------------------------------
next_decision_id() {
  local n
  n="$(grep -hoE '^## D-[0-9]+' director/DECISIONS.md 2>/dev/null \
        | grep -oE '[0-9]+$' | sort -n | tail -1 || true)"
  printf 'D-%03d' "$(( 10#${n:-0} + 1 ))"
}

# escalate <title> <body> [question] [options] [recommended] [default-note]
# Append a non-blocking director decision (ARCHITECTURE principle 1). The optional 3rd–6th args let
# a caller supply its own question/options/recommended/default-note; omitted, they default to the
# decompose-failure wording (the original, sole caller) so its output is byte-for-byte unchanged.
escalate() {
  local title="$1" body="$2"
  local question="${3:-The decompose contract did not yield >=2 valid units — what should change?}"
  local options="${4:-(a) re-run decompose (transient miss) · (b) sharpen the instruction · (c) fix the decompose prompt/model}"
  local recommended="${5:-(a) — usually a transient/format miss; persistent failure means (c).}"
  local defnote="${6:-default = skip this instruction, keep cascade alive}"
  local id today apply
  today="$(date +%F)"
  apply="$(date -d '+3 days' +%F 2>/dev/null || date +%F)"
  mkdir -p director
  # id-mint + append under an flock (cf. local/queue.sh with_lock): concurrent escalations
  # (parallel dispatchers / the loop) must not mint the same D-NNN. The subshell prints the
  # minted id so the caller can log it.
  id="$(
    ( flock -x 9
      new_id="$(next_decision_id)"
      {
        printf '\n## %s — %s\n' "$new_id" "$title"
        printf '**Asked:** %s · **Default applies:** %s → %s\n' "$today" "$apply" "$defnote"
        printf '**Trigger:** %s\n' "$body"
        printf '**Question:** %s\n' "$question"
        printf '**Options:** %s\n' "$options"
        printf '**Recommended default:** %s\n' "$recommended"
        printf '**Answer:**\n'
      } >> director/DECISIONS.md
      printf '%s' "$new_id"
    ) 9>director/DECISIONS.md.lock
  )"
  echo "[cascade] escalated $id — $title" >&2
}

# --- sandbox worker profiles (D-007: workers spawn IN the sandbox) ---------------------------
# The 2026-06-07 sandbox-spawn spike (NOTES) proved a nested worker-`claude` runs INSIDE the
# sandbox with three ingredients, here assembled per profile and injected into the worker env:
#   * NO_PROXY= / no_proxy=  — the sandbox sets HTTP(S)_PROXY to a host-side proxy but NO_PROXY
#     covers loopback, so loopback would bypass the proxy into the dead netns. Cleared, loopback
#     egress goes through the host proxy (127.0.0.1 + api.anthropic.com are allowlisted). The
#     worker's OWN bash inherits this too, so in-sandbox llm.sh / curl to a local server also work.
#   * CLAUDE_CONFIG_DIR under $TMPDIR — a child claude needs no ~/.claude (denyRead in-sandbox);
#     a fresh writable config dir + env auth is enough. /tmp is RO in-sandbox; $TMPDIR is writable.
#   * env auth, per profile — local: a local server base URL + dummy token (zero secrets); online:
#     CLAUDE_CODE_OAUTH_TOKEN (cloud); mixed: online main + local evaluator/subagent model.
#
# Resolve the cloud OAuth token for online/mixed WITHOUT ever storing it in the repo. Sources, in
# order (first non-empty wins):
#   1. CLAUDE_CODE_OAUTH_TOKEN in the env — the UNSANDBOXED harness injects it (see the `oauth-token`
#      subcommand). Inside a sandboxed dispatcher this is the ONLY source that can work; sources 2/3
#      read sealed paths.
#   2. first non-comment line of $AGENCY_OAUTH_TOKEN_FILE (default ~/.config/agency/oauth-token — an
#      optional long-lived `claude setup-token`).
#   3. the director's EXISTING ~/.claude login — the access token in $AGENCY_HOST_CREDENTIALS
#      (default ~/.claude/.credentials.json). "Just use my login" (D-018): no separate setup-token,
#      the worker rides the director's own login. Resolves UNSANDBOXED only (the sandbox denyReads
#      ~/.claude → empty here, fall through). Needs jq. This is the short-lived ACCESS token (no
#      in-worker refresh) — fine for short units; for long runs prefer the refresh-capable config-dir
#      copy (D-018). Prints "" if none.
HOST_CREDENTIALS_FILE="${AGENCY_HOST_CREDENTIALS:-$HOME/.claude/.credentials.json}"
resolve_oauth_token() {
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN"
    return 0
  fi
  local f="${AGENCY_OAUTH_TOKEN_FILE:-$HOME/.config/agency/oauth-token}"
  if [ -f "$f" ]; then
    # First field only: strip at the first whitespace so a trailing inline comment
    # ("token  # prod") is dropped instead of glued onto the token.
    local t; t="$(awk '/^[^#[:space:]]/ { print $1; exit }' "$f" 2>/dev/null || true)"
    if [ -n "$t" ]; then printf '%s' "$t"; return 0; fi
  fi
  if [ -r "$HOST_CREDENTIALS_FILE" ] && command -v jq >/dev/null 2>&1; then
    jq -r '.claudeAiOauth.accessToken // .accessToken // empty' "$HOST_CREDENTIALS_FILE" 2>/dev/null | tr -d '[:space:]' || true
  fi
}

# profile_env <local|online|mixed> [unit-id] — print the env (KEY=VALUE per line) to inject into
# a worker so it spawns claude correctly in-sandbox. Pure assembly (no git, no network); inputs
# are only env vars, so it is fixture-testable. rc 0 = printed; rc 1 = unknown profile;
# rc 2 = online/mixed but no token (so dispatch can refuse BEFORE claiming, leaving no orphan).
profile_env() {
  local profile="$1" id="${2:-worker}" tok=""
  case "$profile" in
    local) ;;
    online|mixed)
      tok="$(resolve_oauth_token)"
      if [ -z "$tok" ]; then
        echo "[cascade] '$profile' profile needs a cloud token — set CLAUDE_CODE_OAUTH_TOKEN or create ${AGENCY_OAUTH_TOKEN_FILE:-$HOME/.config/agency/oauth-token} (director: 'claude setup-token')." >&2
        return 2
      fi ;;
    *)
      echo "[cascade] unknown profile: '$profile' (want local|online|mixed)" >&2
      return 1 ;;
  esac

  # Universal sandbox-spawn recipe (all profiles).
  printf 'NO_PROXY=\nno_proxy=\nCLAUDE_CONFIG_DIR=%s\n' "$WORKER_CONFIG_BASE/agency-worker-$id"

  case "$profile" in
    local)
      # Delegate model env + serving-check + commit-tag to run.sh's proven LOCAL=1 path.
      printf 'LOCAL=1\nLOCAL_BASE=%s\nLOCAL_MODEL=%s\n' "$CASCADE_LOCAL_BASE" "$CASCADE_LOCAL_MODEL" ;;
    online)
      printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$tok" ;;
    mixed)
      # Cloud main (OAuth) + local evaluator/subagent tier via the default-haiku model id.
      # NOTE: a single ANTHROPIC_BASE_URL can't split cloud-main / local-haiku on its own — this
      # is the unverified piece (see D-008); the env is assembled as designed.
      printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nANTHROPIC_DEFAULT_HAIKU_MODEL=%s\n' "$tok" "$CASCADE_LOCAL_MODEL" ;;
  esac
}

# --- decompose (Tech Director) ---------------------------------------------------------------
decompose_prompt() {
  cat <<EOF
You are the Technical Director of an autonomous software agency. Decompose ONE director
instruction into a set of independently executable task units for the backlog.

Director instruction:
<<<
$1
>>>

Rules:
- Produce AT LEAST 2 units. A single passthrough unit is a failure — real decomposition only.
- Each unit must be completable by one worker in one session and verifiable by ./gate.sh
  (shellcheck + tests/), the same bar as the existing backlog.
- Each unit's "done" is a /goal-style end-state condition: concrete, checkable, and stating
  how the gate proves it (e.g. "tests/foo_test.sh exercises X and is part of the green gate").
- Express real dependencies with blocked_by = the 1-based index of the unit that must finish
  first (0 = no dependency). No cycles, no self-references.
- Stay within existing repo conventions; invent no scope beyond the instruction.
- Sharpen as you split (Think folded into Plan): each unit's "done" names the OUTCOME the
  director gets, not just the files touched. Prefer the SMALLEST slice that still demos that
  outcome — do not gold-plate or plan more than the instruction needs. Fewer, tighter units win.
- If any part of the instruction is irreversible (deploys to running services, deletions
  outside a worktree, anything touching credentials or money), do NOT plan it as an executable
  unit — plan the largest reversible slice and leave the irreversible part for a director decision.

Output ONLY a JSON array — no prose, no markdown fences. Schema:
[ { "title": "<=60 chars", "done": "the done-condition", "blocked_by": 0 }, ... ]

Do NOT use any tools and do NOT read or edit any files — you are PLANNING the work, not doing it.
The instruction may be phrased imperatively ("create X", "tag Y"); still only PLAN it into units.
Reply with the JSON array as your entire first message.
EOF
}

run_decompose() { # $1 = instruction; stdout = raw model output
  if [ -n "${DECOMPOSE_CMD:-}" ]; then
    bash -c "$DECOMPOSE_CMD" 2>/dev/null || true
  else
    local prompt
    prompt="$(decompose_prompt "$1")"
    # max-turns headroom: a single turn that ends in a tool_use (the model trying to ACT on an
    # imperative instruction) hits the cap and returns "Error: Reached max turns (1)" instead of the
    # JSON (D-019). A few turns let it recover to a final text answer. The prompt forbids tools, so
    # this is a safety net, not an invitation to go agentic.
    claude -p "$prompt" --max-turns "${CASCADE_DECOMPOSE_MAX_TURNS:-6}" 2>/dev/null || true
  fi
}

# stdin = raw model output; stdout = compact JSON array of >=2 valid units; rc 0 ok / 1 invalid.
extract_units() {
  local raw cleaned arr
  raw="$(cat)"
  cleaned="$(printf '%s\n' "$raw" | sed -e 's/```[a-zA-Z]*//g' -e 's/```//g')"
  arr="$(printf '%s' "$cleaned" | tr '\n' ' ' | grep -oE '\[.*\]' | head -1 || true)"
  [ -n "$arr" ] || return 1
  printf '%s' "$arr" | jq -ce '
    select(type=="array" and length>=2 and
           all(.[]; (.title|type=="string" and length>0) and
                    (.done |type=="string" and length>0)))' 2>/dev/null || return 1
}

# Insert a block file's contents before the first ## Parked (else ## Done, else append).
insert_block() {
  local blockfile="$1" tmp anchor
  tmp="$(mktemp)"
  anchor='^## Parked'
  if ! grep -qE "$anchor" "$BACKLOG"; then anchor='^## Done'; fi
  if grep -qE "$anchor" "$BACKLOG"; then
    awk -v af="$blockfile" -v anchor="$anchor" '
      $0 ~ anchor && !ins { while ((getline l < af) > 0) print l; close(af); ins=1 }
      { print }
    ' "$BACKLOG" > "$tmp"
  else
    cp "$BACKLOG" "$tmp"
    printf '\n' >> "$tmp"
    cat "$blockfile" >> "$tmp"
  fi
  mv "$tmp" "$BACKLOG"
}

cmd_decompose() {
  local instruction="$1"
  if [ -z "$instruction" ]; then
    echo "[cascade] decompose needs an instruction argument" >&2
    return 1
  fi
  local batch raw units
  batch="${CASCADE_BATCH:-c$(date +%Y%m%d-%H%M%S)}"
  raw="$(run_decompose "$instruction")"
  if ! units="$(printf '%s' "$raw" | extract_units)"; then
    escalate "cascade decompose produced no usable units" \
"The decompose contract for instruction <<${instruction}>> returned output that was not a JSON array of >=2 valid units (each needs a non-empty title + done). Raw head: $(printf '%s' "$raw" | head -c 200)"
    echo "[cascade] decompose FAILED — escalated. Output was not >=2 valid units." >&2
    return 2
  fi

  local n i=1 title done_cond bb_idx bb_ref id blockfile
  n="$(printf '%s' "$units" | jq 'length')"
  blockfile="$(mktemp)"
  printf '### cascade batch %s — %s\n' "$batch" "${instruction:0:80}" > "$blockfile"
  while [ "$i" -le "$n" ]; do
    title="$(printf '%s' "$units" | jq -r ".[$((i-1))].title")"
    done_cond="$(printf '%s' "$units" | jq -r ".[$((i-1))].done")"
    bb_idx="$(printf '%s' "$units" | jq -r ".[$((i-1))].blocked_by // 0
              | if type==\"string\" then (if .==\"none\" then 0 else (tonumber? // 0) end) else . end")"
    id="$batch-u$i"
    bb_ref="none"
    if [ "${bb_idx%.*}" -gt 0 ] 2>/dev/null && [ "${bb_idx%.*}" -le "$n" ] && [ "${bb_idx%.*}" -ne "$i" ]; then
      bb_ref="$batch-u${bb_idx%.*}"
    fi
    printf -- '- [ ] **%s** — %s <!-- cascade: id=%s blocked-by=%s -->\n' \
      "$title" "$done_cond" "$id" "$bb_ref" >> "$blockfile"
    i=$((i + 1))
  done

  insert_block "$blockfile"
  rm -f "$blockfile"
  echo "[cascade] decompose: wrote $n units to $BACKLOG (batch $batch)."

  if [ "${CASCADE_NO_COMMIT:-0}" != "1" ]; then
    git add "$BACKLOG"
    git commit -q -m "cascade decompose: $batch ($n units)" -m "${instruction:0:200}"
    echo "[cascade] committed (commit-before-dispatch): $(git rev-parse --short HEAD)"
  fi

  # PG: insert job rows (best-effort — PG down is not an error here).
  if [ "${PG_AVAIL:-0}" = "1" ]; then
    declare -A _pg_batch_uuids
    local j=1
    while [ "$j" -le "$n" ]; do
      local _bb_idx _bb_ref _bb_uuid _cascade_id _backlog_line _uuid
      _cascade_id="$batch-u$j"
      _backlog_line="$(grep -E "<!-- cascade: id=${_cascade_id} " "$BACKLOG" 2>/dev/null | head -1 || true)"
      _bb_idx="$(printf '%s' "$units" | jq -r ".[$((j-1))].blocked_by // 0 \
                  | if type==\"string\" then (if .==\"none\" then 0 else (tonumber? // 0) end) else . end")"
      _bb_uuid=""
      if [ "${_bb_idx%.*}" -gt 0 ] 2>/dev/null \
           && [ "${_bb_idx%.*}" -le "$n" ] && [ "${_bb_idx%.*}" -ne "$j" ]; then
        _bb_ref="$batch-u${_bb_idx%.*}"
        _bb_uuid="${_pg_batch_uuids[$_bb_ref]:-}"
      fi
      _uuid="$(pg_insert_job "$_cascade_id" "${_backlog_line}" "${_bb_uuid}" 2>/dev/null \
                 | tr -d '[:space:]' || true)"
      if [ -n "$_uuid" ]; then
        _pg_batch_uuids["$_cascade_id"]="$_uuid"
        echo "[cascade] PG job inserted: $_cascade_id → $_uuid"
      fi
      j=$(( j + 1 ))
    done
    unset _pg_batch_uuids
  fi
}

# Build the single shell command line that runs ONE worker in its worktree, for the queue's cmd
# path (`bash -c "$payload"` runs from the main repo, so cd into the worktree first). Mirrors the
# inline `( cd "$wt" && env CASCADE_TASK=… MAX_RUNS=… <worker_env…> bash -c "$worker" )`. Every
# field goes through printf %q so it round-trips safely through the second bash parse.
build_worker_payload() { # build_worker_payload <wt> <task-line> <worker> [env KEY=VAL ...]
  local wt="$1" line="$2" worker="$3"; shift 3
  local p kv
  p="cd $(printf '%q' "$wt") && env CASCADE_TASK=$(printf '%q' "$line") MAX_RUNS=$(printf '%q' "${MAX_RUNS:-1}")"
  for kv in "$@"; do p="$p $(printf '%q' "$kv")"; done
  printf '%s bash -c %s' "$p" "$(printf '%q' "$worker")"
}

# --- dispatch (Ops schedule + Security bound + Worker) ---------------------------------------
cmd_dispatch() {
  local profile=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile)   profile="${2:-}"; shift 2 ;;
      --profile=*) profile="${1#--profile=}"; shift ;;
      *) echo "[cascade] dispatch: unknown arg '$1' (only --profile <local|online|mixed>)" >&2; return 1 ;;
    esac
  done

  local claims
  claims="$(active_claims)"
  if [ "$claims" -ge "$CASCADE_MAX_CONCURRENT" ]; then
    echo "[cascade] dispatch: at concurrency cap ($claims/$CASCADE_MAX_CONCURRENT)." >&2
    return 3
  fi

  local id="" line="" pg_id=""

  # PG path: claim_next_job() atomically picks + claims; no claim file needed.
  if [ "${PG_AVAIL:-0}" = "1" ]; then
    local pg_row
    pg_row="$(pg_claim_next_job "dispatch-$$" || true)"
    if [ -n "$pg_row" ] && [ "$pg_row" != "null" ] && command -v jq >/dev/null 2>&1; then
      pg_id="$(printf '%s' "$pg_row" | jq -r '.id // empty' 2>/dev/null || true)"
      id="$(printf '%s' "$pg_row" | jq -r '.title // empty' 2>/dev/null || true)"
      line="$(printf '%s' "$pg_row" | jq -r '.done_condition // empty' 2>/dev/null || true)"
      if [ -n "$pg_id" ] && [ -n "$id" ]; then
        echo "[cascade] dispatch: PG claim → $id (job $pg_id)"
      else
        pg_id=""; id=""; line=""
      fi
    fi
  fi

  # Fallback: file-based claim (also the path when PG has no matching queued job).
  if [ -z "$id" ]; then
    if ! id="$(next_ready)"; then
      echo "[cascade] dispatch: nothing ready (no unchecked, unclaimed, unblocked unit)."
      return 1
    fi
    line="$(unit_line "$id")"
  fi

  # --profile (D-007): assemble the in-sandbox worker env. Validate BEFORE any worktree
  # creation so a missing token / bad profile leaves no orphan. Empty = ambient (back-compat).
  local -a worker_env=()
  if [ -n "$profile" ]; then
    local profenv prc=0
    profenv="$(profile_env "$profile" "$id")" || prc=$?
    if [ "$prc" -ne 0 ]; then
      echo "[cascade] dispatch: profile '$profile' unusable (rc=$prc) — not dispatching $id." >&2
      # PG rollback: fail the job so it's re-queued.
      if [ -n "$pg_id" ]; then pg_fail_job "$pg_id" "dispatch-$$" "profile unusable rc=$prc"; fi
      return 2
    fi
    while IFS= read -r kv; do
      if [ -n "$kv" ]; then worker_env+=("$kv"); fi
    done <<<"$profenv"
    echo "[cascade] dispatch: profile=$profile (worker env: $(printf '%s ' "${worker_env[@]%%=*}"))"
  fi

  local branch wt
  branch="cascade/$id"
  wt="$CASCADE_WT_DIR/$id"

  if [ -n "$pg_id" ]; then
    # PG path: no claim file, no commit — PG job state IS the claim.
    worker_env+=("CASCADE_PG_JOB_ID=$pg_id")
    worker_env+=("CASCADE_PG_CLAIMER=dispatch-$$")
    echo "[cascade] claimed $id -> $branch (via PG, no claim file)"
  else
    # File-based claim (GUPP): commit the marker so concurrent dispatchers skip this unit.
    mkdir -p "$CLAIM_DIR"
    {
      printf 'unit: %s\n' "$id"
      printf 'branch: %s\n' "$branch"
      printf 'worktree: %s\n' "$wt"
      printf 'claimed: %s\n' "$(date -Iseconds)"
      printf 'pid: %s\n' "$$"
    } > "$CLAIM_DIR/$id.claim"
    if [ "${CASCADE_NO_COMMIT:-0}" != "1" ]; then
      git add "$CLAIM_DIR/$id.claim"
      git commit -q -m "cascade claim: $id"
    fi
    echo "[cascade] claimed $id -> $branch"
  fi

  # Isolated worktree + branch (worker-level isolation; see header).
  git worktree prune 2>/dev/null || true
  git worktree add -q -b "$branch" "$wt" HEAD
  echo "[cascade] worktree: $wt (branch $branch)"

  # Run ONE worker there. CASCADE_TASK forces run.sh to this specific unit (run.sh honors it).
  local worker rc=0
  worker="${WORKER_CMD:-./loop/run.sh}"
  local queue="${CASCADE_QUEUE:-local/queue.sh}"
  if [ "$profile" = "local" ] && [ "${CASCADE_VIA_QUEUE:-1}" != "0" ] && [ -x "$queue" ]; then
    # Anti-thrash wiring (D-012): route the LOCAL worker through the model-aware queue instead of
    # spawning the model directly. Concurrent local workers then drain by big-MoE affinity
    # (routing.md §5) — one `lms load` amortized over the batch — rather than each evicting the
    # others' model. The worker self-ensures its own model (run.sh LOCAL=1), so the task is pinned
    # to the local model + nested-claude ctx and a single drain runs whatever is ready (enqueue +
    # drain at the burst boundary). `cd <wt>` is baked into the payload so worktree isolation holds.
    local payload
    payload="$(build_worker_payload "$wt" "$line" "$worker" "${worker_env[@]}")"
    echo "[cascade] enqueue worker for $id -> queue ($CASCADE_LOCAL_MODEL, ctx $CASCADE_LOCAL_CTX)"
    "$queue" enqueue coder --cmd "$payload" --models "$CASCADE_LOCAL_MODEL" --ctx "$CASCADE_LOCAL_CTX" >/dev/null
    set +e
    "$queue" drain
    rc=$?
    set -e
    echo "[cascade] queue drain for $id exited rc=$rc (result on branch $branch)."
  else
    mkdir -p "$CASCADE_LOG_DIR"
    local wlog="$CASCADE_LOG_DIR/$id.log"
    echo "[cascade] dispatching worker for $id ... (log: $wlog)"
    set +e
    ( cd "$wt" && env CASCADE_TASK="$line" MAX_RUNS="${MAX_RUNS:-1}" "${worker_env[@]}" bash -c "$worker" ) 2>&1 \
      | sed -u -E 's/(sk-ant-[a-z0-9]+-)[A-Za-z0-9_-]{12,}/\1<REDACTED>/g' | tee "$wlog"
    rc=${PIPESTATUS[0]}
    set -e
    echo "[cascade] worker for $id exited rc=$rc (result on branch $branch). Full log: $wlog"
  fi
  return 0
}

# prune_unit <id> — silent git teardown of a unit's worktree + branch (idempotent; missing pieces
# skipped). The shared teardown used by both `reset` (clean retry) and `merge` (post-land cleanup);
# it touches ONLY git refs/worktrees — the claim file + backlog line are the caller's concern.
prune_unit() {
  local branch="cascade/$1" wt="$CASCADE_WT_DIR/$1"
  if [ -d "$wt" ]; then
    git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
  fi
  git worktree prune 2>/dev/null || true
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git branch -D "$branch" >/dev/null 2>&1 || true
  fi
}

# reset <id> — release a unit so dispatch can re-pick it: remove its worktree + branch + claim
# (claims are a filesystem check, so removal unclaims it). The backlog unit stays unchecked and its
# log under .cascade/logs/ is KEPT (the diagnosis you re-run to read). Idempotent: missing pieces
# are skipped. Use after a worker fails the gate and you want a clean retry of the same unit.
cmd_reset() {
  local id="${1:-}"
  if [ -z "$id" ]; then
    echo "[cascade] reset needs a unit id (e.g. c20260608-113130-u1)" >&2
    return 1
  fi
  local branch="cascade/$id" wt="$CASCADE_WT_DIR/$id" claim="$CLAIM_DIR/$id.claim"
  if [ -d "$wt" ]; then echo "[cascade] reset: removing worktree $wt"; fi
  if git show-ref --verify --quiet "refs/heads/$branch"; then echo "[cascade] reset: deleting branch $branch"; fi
  prune_unit "$id"
  if git ls-files --error-unmatch "$claim" >/dev/null 2>&1; then
    git rm -qf "$claim" >/dev/null 2>&1 || rm -f "$claim"
    if [ "${CASCADE_NO_COMMIT:-0}" != "1" ]; then
      git commit -q -m "cascade reset: release $id" -- "$claim" 2>/dev/null || true
    fi
    echo "[cascade] reset: released claim $claim"
  elif [ -f "$claim" ]; then
    rm -f "$claim"
    echo "[cascade] reset: removed untracked claim $claim"
  fi
  echo "[cascade] reset: $id released — dispatch will re-pick it (log kept under $CASCADE_LOG_DIR)."
}

# reconcile — bulk maintenance: reap expired PG leases, prune orphan worktrees + branches,
# report job↔git drift. All best-effort: safe to run while dispatch is active.
# PG down: skips reap + orphan-worktree pruning (can't tell if PG-claimed); still prunes
# orphan branches (git-only).
cmd_reconcile() {
  echo "[cascade] reconcile: starting..."

  # 1. Reap expired PG leases (running jobs whose visible_at elapsed → queued or dead-letter).
  if [ "${PG_AVAIL:-0}" = "1" ]; then
    local reaped
    reaped="$(pg_query 'SELECT reap_expired()' | tr -d '[:space:]' || echo 0)"
    echo "[cascade] reconcile: reap_expired → ${reaped:-0} lease(s) requeued"
  else
    echo "[cascade] reconcile: PG unavail — skipping reap_expired"
  fi

  # 2. Prune orphan worktrees. With PG available: prune if no claim file AND PG shows no
  #    running job with that title. Without PG: skip (can't distinguish PG-claimed jobs).
  local rn_titles=""
  if [ "${PG_AVAIL:-0}" = "1" ]; then
    rn_titles="$(pg_query "SELECT title FROM jobs WHERE state='running'" || true)"
  fi

  git worktree prune 2>/dev/null || true
  if [ -d "$CASCADE_WT_DIR" ] && [ "${PG_AVAIL:-0}" = "1" ]; then
    local wt_path wt_id claim_path is_pg_running
    for wt_path in "$CASCADE_WT_DIR"/*/; do
      [ -d "$wt_path" ] || continue
      wt_id="$(basename "$wt_path")"
      claim_path="$CLAIM_DIR/$wt_id.claim"
      [ -f "$claim_path" ] && continue  # still claimed via file path — skip
      is_pg_running=0
      if printf '%s\n' "$rn_titles" | grep -qxF "$wt_id" 2>/dev/null; then
        is_pg_running=1
      fi
      if [ "$is_pg_running" -eq 0 ]; then
        echo "[cascade] reconcile: orphan worktree $wt_path — removing"
        git worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path"
      fi
    done
  elif [ -d "$CASCADE_WT_DIR" ]; then
    echo "[cascade] reconcile: PG unavail — skipping orphan worktree pruning"
  fi
  git worktree prune 2>/dev/null || true

  # 3. Prune orphan cascade/* branches: branch exists but no corresponding worktree directory.
  local branch_id br_wt_path
  while IFS= read -r branch_id; do
    [ -n "$branch_id" ] || continue
    br_wt_path="$CASCADE_WT_DIR/$branch_id"
    if [ ! -d "$br_wt_path" ]; then
      echo "[cascade] reconcile: orphan branch cascade/$branch_id (no worktree) — deleting"
      git branch -D "cascade/$branch_id" 2>/dev/null || true
    fi
  done < <(git for-each-ref --format='%(refname:short)' 'refs/heads/cascade/' 2>/dev/null \
           | sed 's|^cascade/||' || true)

  # 4. Report job↔git drift: PG running jobs with no worktree (worker vanished).
  if [ "${PG_AVAIL:-0}" = "1" ] && [ -n "$rn_titles" ]; then
    local title
    while IFS= read -r title; do
      [ -n "$title" ] || continue
      if [ ! -d "$CASCADE_WT_DIR/$title" ]; then
        echo "[cascade] reconcile: drift — PG job '$title' is running but has no worktree"
      fi
    done <<<"$rn_titles"
  fi

  echo "[cascade] reconcile: done."
}

# render_backlog — single-writer regeneration of BACKLOG from per-unit done-markers on the base.
# The partition model (D-006 lineage): a worker no longer ticks the shared BACKLOG; it writes its own
# done/<id>.md on its branch, so branches are purely additive (disjoint) and fan-in never conflicts on
# BACKLOG. merge is the SOLE writer of the rendered view => no sink race within a run; deterministic +
# idempotent (flipping an already-[x] line is a no-op). The marker file holds the worker's move-to-Done
# prose (a per-unit completion record / lineage spine). Tick every unit that has a landed marker.
render_backlog() {
  local m id
  if [ ! -d "$DONE_DIR" ]; then return 0; fi
  for m in "$DONE_DIR"/*.md; do
    [ -e "$m" ] || continue
    id="$(basename "$m" .md)"
    sed -i "/id=$id /s/^- \[ \]/- [x]/" "$BACKLOG"
  done
}

# --- merge (the UP-cascade: land gate-green, done branches into the base) ---------------------
# GUPP up-cascade: a cascade/<id> branch whose worker finished the unit (its loop commit is present,
# ahead of the base — branch_unit_done) AND whose isolated branch passes ./gate.sh is, by Apkallu's
# own rule, DONE — so land it. git facts + the gate are the merge authority; no LLM, no human.
#   * order: a unit waits until its blocked-by dependency has landed in the base; multi-pass, so a
#     merge can unblock the next (a dep's loop commit reaching HEAD satisfies unit_merged(dep)).
#   * green-branch ⇒ green-merge under the disjoint-paths invariant (AGENCY.md): a branch that truly
#     needed an unmerged dep's code would fail its OWN isolated gate, and a shared path surfaces as a
#     merge conflict — so a clean gate + a clean merge together are the honest "safe to land" proof.
#   * conflicts: a conflict means the disjoint-paths invariant broke. It is NOT auto-resolved (that
#     is a human call) — abort, escalate (D-NNN), leave the branch + worktree intact, skip only it.
#   * cleanup: a merged unit's worktree + branch are pruned (prune_unit) and its claim released.
#   * after a non-empty batch, run local/digest.sh (the "+digest" half of the up-cascade).
# NOTE: a PG-claimed unit's job row is NOT transitioned here (the file-claim path is released; the
# PG job-state lifecycle on merge is future work) — a known gap, not a silent one.
cmd_merge() {
  local base gate_cmd merged=0 conflicted=0 skipped=0
  base="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
  gate_cmd="${CASCADE_GATE_CMD:-./gate.sh}"
  local -a merged_ids=()
  local -A handled=()

  local progress=1 id branch wt bb
  while [ "$progress" = 1 ]; do
    progress=0
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      branch="cascade/$id"
      if ! git show-ref --verify --quiet "refs/heads/$branch"; then continue; fi  # gone (merged)
      if [ -n "${handled[$id]:-}" ]; then continue; fi          # conflicted / gate-failed this run
      if ! branch_unit_done "$id"; then continue; fi            # worker not finished on the branch
      bb="$(unit_blocked_by "$id")"
      if [ -n "$bb" ] && [ "$bb" != "none" ]; then
        if ! unit_checked "$bb" && ! unit_merged "$bb"; then
          continue                                              # blocked-by has not landed yet — wait
        fi
      fi
      wt="$CASCADE_WT_DIR/$id"
      if [ ! -d "$wt" ]; then
        echo "[cascade] merge: $id has no worktree to gate — skipping." >&2
        handled[$id]=1; skipped=$((skipped + 1)); continue
      fi
      if ! ( cd "$wt" && bash -c "$gate_cmd" ) >/dev/null 2>&1; then
        echo "[cascade] merge: $id branch is not gate-green — skipping (no green, no merge)." >&2
        handled[$id]=1; skipped=$((skipped + 1)); continue
      fi
      # Lazy: a fast-forward when the base has not moved, else a no-edit merge commit. NEVER resolve
      # a conflict — abort + escalate (disjoint paths means a conflict is a broken invariant).
      if git merge --ff-only "$branch" >/dev/null 2>&1 \
           || git merge --no-edit "$branch" >/dev/null 2>&1; then
        echo "[cascade] merge: landed $id into $base."
        prune_unit "$id"
        merged_ids+=("$id"); merged=$((merged + 1)); progress=1
      else
        git merge --abort >/dev/null 2>&1 || true
        escalate "cascade merge conflict on $id" \
"Merging cascade/$id into $base hit a conflict — the disjoint-paths invariant (AGENCY.md: units own disjoint paths so branches merge clean) was violated. Auto-resolution is unsafe; the branch + worktree are left intact." \
"cascade/$id conflicts with $base on merge — how should it land?" \
"(a) inspect the conflicting paths and merge by hand · (b) reset the unit and re-dispatch from current $base · (c) drop the unit" \
"(a) — the worktree + branch are preserved for inspection; a conflict means two units shared a path." \
"default = skip this merge, leave the branch for manual handling, keep the cascade alive"
        echo "[cascade] merge: $id CONFLICTS — aborted, escalated (branch left intact)." >&2
        handled[$id]=1; conflicted=$((conflicted + 1))
      fi
    done < <(git for-each-ref --format='%(refname:short)' 'refs/heads/cascade/' 2>/dev/null \
             | sed 's|^cascade/||' || true)
  done

  # Release the claims of every landed unit (one commit; mirrors reset's claim release).
  if [ "${#merged_ids[@]}" -gt 0 ]; then
    local rid removed=0
    for rid in "${merged_ids[@]}"; do
      if git ls-files --error-unmatch "$CLAIM_DIR/$rid.claim" >/dev/null 2>&1; then
        git rm -qf "$CLAIM_DIR/$rid.claim" >/dev/null 2>&1 || rm -f "$CLAIM_DIR/$rid.claim"
        removed=$((removed + 1))
      elif [ -f "$CLAIM_DIR/$rid.claim" ]; then
        rm -f "$CLAIM_DIR/$rid.claim"
      fi
    done
    if [ "$removed" -gt 0 ]; then
      git commit -q -m "cascade merge: release $removed claim(s)" -- "$CLAIM_DIR" 2>/dev/null || true
    fi
  fi

  # Single-writer render of the human BACKLOG from the per-unit done-markers now on the base.
  # merge owns this write (no other writer touches BACKLOG during fan-in), so it cannot conflict;
  # it is idempotent, so a re-run is a safe no-op. NOTE: concurrent `merge` invocations are not
  # expected (fan-in is a single step) — if that changes, guard merge with a single-instance lock.
  if [ "$merged" -gt 0 ]; then
    render_backlog
    git add "$BACKLOG" 2>/dev/null || true
    if ! git diff --cached --quiet -- "$BACKLOG" 2>/dev/null; then
      git commit -q -m "cascade merge: render backlog from done-markers ($merged landed)" -- "$BACKLOG" 2>/dev/null || true
    fi
  fi

  # The "+digest" half of the up-cascade — only after we actually landed something.
  if [ "$merged" -gt 0 ]; then
    local digest_cmd="${CASCADE_DIGEST_CMD:-}"
    if [ -n "$digest_cmd" ]; then
      bash -c "$digest_cmd" || true
    elif [ -x local/digest.sh ]; then
      local/digest.sh || true
    fi
  fi

  echo "[cascade] merge: $merged landed, $conflicted conflict(s) escalated, $skipped skipped."
  return 0
}

# --- dispatch ---------------------------------------------------------------------------------
case "${1:-}" in
  decompose)   shift; cmd_decompose "${1:-}" ;;
  dispatch)    shift; cmd_dispatch "$@" ;;
  reset)       shift; cmd_reset "${1:-}" ;;
  merge)       cmd_merge ;;
  reconcile)   cmd_reconcile ;;
  next-ready)  next_ready ;;
  profile-env) shift; profile_env "${1:-}" "${2:-cli}" ;;
  oauth-token) resolve_oauth_token; echo ;;
  -h|--help|"") usage ;;
  *) echo "[cascade] unknown subcommand: $1" >&2; usage; exit 1 ;;
esac
