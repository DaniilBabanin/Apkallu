#!/usr/bin/env bash
# gate.sh — the merge gate. "No green, no merge." (ARCHITECTURE.md, principle 1)
#
# Lints every .sh file in the repo with shellcheck, then runs any executable
# scripts under tests/. Exits non-zero if any check fails so loop/run.sh rolls
# the iteration back. This is the gate for everything the loop builds after it.
#
# Usage: ./gate.sh
#
# Env:
#   GATE_SHELLCHECK_SEVERITY  min severity that fails the gate:
#                             error | warning | info | style
#                             (default: style — see note below)
#   GATE_SHELLCHECK_OPTS      extra args passed verbatim to shellcheck (default: -x)
#   GATE_NOTES_MAX_DELETIONS  max lines an iteration may DELETE from NOTES.md vs HEAD
#                             (default 20; effective tolerance is capped at half the
#                             file's HEAD line count, so a full wipe of a SMALL file
#                             still fails). NOTES.md is the loop's only cross-iteration
#                             memory and is append-only by convention; a local-model run
#                             (2026-06-06) rewrote it wholesale, wiping 204 lines. Catches
#                             whole-file rewrites while allowing small in-place fixes.
#
# Severity note: v0 defaulted to "warning" while loop/run.sh carried info-level
# findings; those were cleaned and the default was raised to "style" (strictest,
# the intended end state) per D-003 (2026-06-06). Override anytime:
#   GATE_SHELLCHECK_SEVERITY=warning ./gate.sh
#
# Exit codes: 0 all checks passed · 1 a check failed · 2 a required tool missing.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

SEVERITY="${GATE_SHELLCHECK_SEVERITY:-style}"  # default raised warning->style per D-003 (2026-06-06)
read -ra SC_EXTRA <<<"${GATE_SHELLCHECK_OPTS:--x}" || true

fail=0

# --- shellcheck on all .sh files --------------------------------------------
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "[gate] FATAL: shellcheck not on PATH — it is this system's merge gate." >&2
  echo "[gate] install: 'sudo apt install shellcheck' or 'brew install shellcheck'." >&2
  exit 2
fi

mapfile -d '' sh_files < <(find . -type f -name '*.sh' -not -path './.git/*' -not -path './.cascade/*' -print0)

if [ "${#sh_files[@]}" -eq 0 ]; then
  echo "[gate] shellcheck: no .sh files found."
else
  echo "[gate] shellcheck (severity=$SEVERITY) on ${#sh_files[@]} file(s)..."
  if shellcheck -S "$SEVERITY" "${SC_EXTRA[@]}" "${sh_files[@]}"; then
    echo "[gate] shellcheck: OK"
  else
    echo "[gate] shellcheck: FAIL" >&2
    fail=1
  fi
fi

# --- NOTES.md append-only guard ----------------------------------------------
# Memory must not shrink. Fails CLOSED (audit fix 1.2, 2026-07-02): anchored to HEAD
# (not the index, so `git rm --cached` can't skip it), absent/untracked worktree file
# fails, a binary rewrite (numstat '-') fails, and the deletion tolerance is capped at
# half the file's HEAD line count so a full wipe of a small file fails too.
NOTES_MAX_DEL="${GATE_NOTES_MAX_DELETIONS:-20}"
if git rev-parse HEAD >/dev/null 2>&1 && git cat-file -e HEAD:NOTES.md 2>/dev/null; then
  if [ ! -f NOTES.md ]; then
    echo "[gate] NOTES.md guard: FAIL — tracked in HEAD but missing from the worktree." >&2
    fail=1
  elif ! git ls-files --error-unmatch NOTES.md >/dev/null 2>&1; then
    echo "[gate] NOTES.md guard: FAIL — tracked in HEAD but removed from the index (git rm --cached?)." >&2
    fail=1
  else
    notes_del="$(git diff HEAD --numstat -- NOTES.md | awk '{print $2}')"
    notes_head_lines="$(git show HEAD:NOTES.md | wc -l | tr -d '[:space:]')"
    notes_tol="$NOTES_MAX_DEL"
    if [ $(( notes_head_lines / 2 )) -lt "$notes_tol" ]; then notes_tol=$(( notes_head_lines / 2 )); fi
    if ! [[ "${notes_del:-0}" =~ ^[0-9]+$ ]]; then
      echo "[gate] NOTES.md guard: FAIL — non-numeric deletion count '${notes_del}' (binary rewrite?)." >&2
      fail=1
    elif [ "${notes_del:-0}" -gt "$notes_tol" ]; then
      echo "[gate] NOTES.md guard: FAIL — $notes_del lines deleted (max $notes_tol for a ${notes_head_lines}-line file)." >&2
      echo "[gate] NOTES.md is append-only loop memory; a rewrite destroys it." >&2
      fail=1
    else
      echo "[gate] NOTES.md guard: OK (${notes_del:-0} deletions)."
    fi
  fi
fi

# --- tests/ (run any executable script that exists) -------------------------
if [ -d tests ]; then
  mapfile -d '' test_files < <(find tests -type f -perm -u+x -print0)
  if [ "${#test_files[@]}" -eq 0 ]; then
    echo "[gate] tests/ exists but has no executable scripts — skipping."
  else
    echo "[gate] running ${#test_files[@]} test script(s)..."
    # Hermetic: tests must never touch the live control-plane DB. lib/pg.sh
    # honors AGENCY_PG_PORT; 1 = closed port → PG_AVAIL=0 → file-fallback paths.
    # A test that needs real PG must point AGENCY_PG_DB at an ephemeral DB itself.
    export AGENCY_PG_PORT="${AGENCY_PG_PORT:-1}"
    for t in "${test_files[@]}"; do
      echo "[gate]   -> $t"
      if ! "$t"; then
        echo "[gate] test FAIL: $t" >&2
        fail=1
      fi
    done
  fi
else
  echo "[gate] no tests/ directory — skipping tests."
fi

# --- verdict ----------------------------------------------------------------
if [ "$fail" -ne 0 ]; then
  echo "[gate] RESULT: FAIL" >&2
  exit 1
fi
echo "[gate] RESULT: PASS"
