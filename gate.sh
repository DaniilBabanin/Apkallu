#!/usr/bin/env bash
# gate.sh — the merge gate. "No green, no merge." (ARCHITECTURE.md, principle 4)
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
#                             (default: warning — see note below)
#   GATE_SHELLCHECK_OPTS      extra args passed verbatim to shellcheck (default: -x)
#   GATE_NOTES_MAX_DELETIONS  max lines an iteration may DELETE from NOTES.md vs HEAD
#                             (default 20). NOTES.md is the loop's only cross-iteration
#                             memory and is append-only by convention; a local-model run
#                             (2026-06-06) rewrote it wholesale, wiping 204 lines. Catches
#                             whole-file rewrites while allowing small in-place fixes.
#
# Severity note (v0): default is "warning" so the gate is green on the existing
# tree. loop/run.sh currently carries info-level findings (SC2015 A&&B||C,
# SC2086 unquoted $PERM_FLAG). Once those are cleaned, bump the default to
# "style" (strictest) — the intended end state. Override anytime:
#   GATE_SHELLCHECK_SEVERITY=style ./gate.sh
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

mapfile -d '' sh_files < <(find . -type f -name '*.sh' -not -path './.git/*' -print0)

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
# Memory must not shrink: fail if the working tree deletes more than
# GATE_NOTES_MAX_DELETIONS lines from NOTES.md relative to HEAD.
NOTES_MAX_DEL="${GATE_NOTES_MAX_DELETIONS:-20}"
if git rev-parse HEAD >/dev/null 2>&1 && git ls-files --error-unmatch NOTES.md >/dev/null 2>&1; then
  notes_del="$(git diff HEAD --numstat -- NOTES.md | awk '{print $2}')"
  if [[ "${notes_del:-0}" =~ ^[0-9]+$ ]] && [ "${notes_del:-0}" -gt "$NOTES_MAX_DEL" ]; then
    echo "[gate] NOTES.md guard: FAIL — $notes_del lines deleted (max $NOTES_MAX_DEL)." >&2
    echo "[gate] NOTES.md is append-only loop memory; a rewrite destroys it." >&2
    fail=1
  else
    echo "[gate] NOTES.md guard: OK (${notes_del:-0} deletions)."
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
