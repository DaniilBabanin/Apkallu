#!/usr/bin/env bash
# Tests for gate.sh's NOTES.md append-only guard (audit fix 1.2) and the .cascade/ sweep
# exclusion (audit fix 1.3). The guard must fail CLOSED: an index removal (git rm --cached),
# a worktree wipe/absence, and a binary rewrite all end the gate in FAIL — and the deletion
# tolerance scales with file size, so a full wipe of a SMALL file fails even under the flat
# GATE_NOTES_MAX_DELETIONS. Fixture-driven: the REAL gate.sh is copied into a throwaway git
# repo per case (no tests/ dir there, so no recursion), the live repo is never mutated.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
N=0
pass() { N=$((N + 1)); echo "ok   $1"; }
fail() { N=$((N + 1)); FAIL=1; echo "FAIL $1"; }

# Fresh sandbox repo: an N-line NOTES.md tracked at HEAD + the LIVE gate.sh copied in
# (untracked — the guard reads HEAD:NOTES.md, not the index entry for gate.sh).
new_sandbox() { # [notes-lines]
  local d n="${1:-10}" i
  d="$(mktemp -d "$TMP/gate.XXXXXX")"
  git -C "$d" init -q
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  for ((i = 1; i <= n; i++)); do printf 'note line %d\n' "$i"; done > "$d/NOTES.md"
  git -C "$d" add -A
  git -C "$d" commit -qm base
  cp "$SELF_DIR/gate.sh" "$d/gate.sh"
  chmod +x "$d/gate.sh"
  printf '%s' "$d"
}

# Run the sandbox's gate; sets GATE_RC + GATE_LAST (last output line, the verdict).
run_gate() { # dir
  local out
  set +e
  out="$(cd "$1" && ./gate.sh 2>&1)"
  GATE_RC=$?
  set -e
  GATE_LAST="$(printf '%s\n' "$out" | tail -n 1)"
  GATE_OUT="$out"
}

expect_fail() { # dir name reason-grep
  run_gate "$1"
  if [ "$GATE_RC" -ne 0 ] && [ "$GATE_LAST" = "[gate] RESULT: FAIL" ]; then
    pass "$2 -> gate FAIL"
  else
    fail "$2 -> gate FAIL (rc=$GATE_RC, last='$GATE_LAST')"
  fi
  if printf '%s' "$GATE_OUT" | grep -q "$3"; then
    pass "$2 -> reason names the guard"
  else
    fail "$2 -> reason names the guard (want grep '$3')"
  fi
}

expect_pass() { # dir name
  run_gate "$1"
  if [ "$GATE_RC" -eq 0 ] && [ "$GATE_LAST" = "[gate] RESULT: PASS" ]; then
    pass "$2 -> gate PASS"
  else
    fail "$2 -> gate PASS (rc=$GATE_RC, last='$GATE_LAST')"
  fi
}

# --- 1. clean tree -> PASS (guard reports 0 deletions) ------------------------
D="$(new_sandbox)"
expect_pass "$D" "clean tree"

# --- 2. legit append -> PASS (the normal iteration shape) ---------------------
D="$(new_sandbox)"
printf 'appended lesson A\nappended lesson B\n' >> "$D/NOTES.md"
expect_pass "$D" "legit append"

# --- 3. small in-place fix within tolerance -> PASS ---------------------------
# 10-line file: tolerance = min(flat 20, 10/2) = 5; deleting 2 lines is a legit fix.
D="$(new_sandbox 10)"
sed -i '1,2d' "$D/NOTES.md"
expect_pass "$D" "2-line fix in a 10-line file (under tolerance)"

# --- 4. untracked-wipe: git rm --cached + rewrite -> FAIL ----------------------
# The old guard keyed on the INDEX (git ls-files) — removing the index entry made the
# guard vanish entirely and the gate pass on a total wipe.
D="$(new_sandbox)"
git -C "$D" rm -q --cached NOTES.md
printf 'wiped\n' > "$D/NOTES.md"
expect_fail "$D" "git rm --cached + wipe" "removed from the index"

# --- 5. worktree file deleted outright -> FAIL --------------------------------
D="$(new_sandbox)"
rm "$D/NOTES.md"
expect_fail "$D" "NOTES.md deleted" "missing from the worktree"

# --- 6. binary rewrite -> FAIL (numstat '-' used to hit the OK branch) ---------
D="$(new_sandbox)"
printf 'BIN\000BIN\000BIN\n' > "$D/NOTES.md"
expect_fail "$D" "binary rewrite" "non-numeric deletion count"

# --- 7. full wipe of a SMALL file -> FAIL --------------------------------------
# 10 deletions is under the flat max (20) — the size-scaled tolerance (10/2 = 5) catches it.
D="$(new_sandbox 10)"
printf 'rewritten from scratch\n' > "$D/NOTES.md"
expect_fail "$D" "full wipe of a 10-line file" "lines deleted"

# --- 8. .cascade/ exclusion (audit fix 1.3) ------------------------------------
# A live worker's worktree under .cascade/ must not fail the MAIN repo's gate: a
# deliberately shellcheck-broken .sh there is skipped by the gate's find sweep.
D="$(new_sandbox)"
mkdir -p "$D/.cascade/worktrees/x"
cat > "$D/.cascade/worktrees/x/bad.sh" <<'EOF'
#!/bin/sh
if [ $undefined = foo ]; then echo $undefined; fi
ls *.txt | grep thing
EOF
expect_pass "$D" "broken .sh under .cascade/ is not swept"

# .gitignore: worktree checkouts under .cascade/ are invisible to the live repo's git.
if git -C "$SELF_DIR" check-ignore -q .cascade/worktrees/x/y.sh; then
  pass ".cascade/worktrees/x/y.sh is gitignored"
else
  fail ".cascade/worktrees/x/y.sh is gitignored"
fi

echo "---"
if [ "$FAIL" -ne 0 ]; then
  echo "gate_notes_guard_test: FAIL ($N checks)"; exit 1
fi
echo "gate_notes_guard_test: OK ($N checks)"
