#!/usr/bin/env bash
# Fixture tests for local/decide.sh (DECIDE_LIB sourcing seam, no network).
# Covers: open_decisions (open-entry extraction), record_answer (answer
# insertion + error rcs). The bot is gone — director answers over SSH/TUI.
set -u
cd "$(dirname "$0")/.." || exit 1
export DECIDE_LIB=1
# shellcheck source=/dev/null
. ./local/decide.sh

P=0; F=0
expect_eq() { # name got want
  if [ "$2" = "$3" ]; then P=$((P+1)); echo "ok   $1"; else F=$((F+1)); echo "FAIL $1: got [$2] want [$3]"; fi
}

TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT

mkfix() { cat > "$1" << 'EOF'
# Decisions

## D-101 — first open question (Asked: 2026-06-07)
**Question:** Do the thing?
**Options:** (a) yes (b) no
**Answer:**

## D-102 — already answered question
**Question:** Other thing?
**Answer:** (a) — director 2026-06-06.

## D-103 — open with blank answer
**Question:** Third?
**Answer:**

## D-104 — answered on following line
**Question:** Fourth?
**Answer:**
**Default picked by the executing agent (2026-06-07):** (a).

## D-105 — last entry, open, at EOF
**Question:** Fifth?
**Answer:**
EOF
}

# --- open_decisions ---
mkfix "$TD/d.md"
out="$(open_decisions "$TD/d.md")"
expect_eq "pending: three open ids" "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "D-101 D-103 D-105 "
expect_eq "pending: title extracted" "$(printf '%s\n' "$out" | head -1 | cut -f2-)" "first open question (Asked: 2026-06-07)"
expect_eq "pending: answered excluded" "$(printf '%s\n' "$out" | grep -c 'D-102\|D-104' || true)" "0"
expect_eq "pending: empty file ok" "$(open_decisions /dev/null)" ""

# --- record_answer ---
mkfix "$TD/a.md"
record_answer "$TD/a.md" D-101 yes "go ahead" 2026-06-07
expect_eq "apply: rc 0" "$?" "0"
expect_eq "apply: answer line written" "$(grep -m1 '^\*\*Answer:\*\* (yes)' "$TD/a.md")" "**Answer:** (yes) — director via tui 2026-06-07 — go ahead"
expect_eq "apply: D-103 still blank" "$(open_decisions "$TD/a.md" | cut -f1 | tr '\n' ' ')" "D-103 D-105 "
record_answer "$TD/a.md" D-103 no "" 2026-06-08
expect_eq "apply: no-note format" "$(sed -n '/## D-103/,/^## /p' "$TD/a.md" | grep '^\*\*Answer:')" "**Answer:** (no) — director via tui 2026-06-08"
mkfix "$TD/b.md"; cp "$TD/b.md" "$TD/b.orig"
record_answer "$TD/b.md" D-999 yes "" 2026-06-07; expect_eq "apply: missing id rc 2" "$?" "2"
record_answer "$TD/b.md" D-102 yes "" 2026-06-07; expect_eq "apply: answered rc 3" "$?" "3"
expect_eq "apply: untouched on errors" "$(cmp -s "$TD/b.md" "$TD/b.orig" && echo same)" "same"

# --- '---'-separated entries (the canonical block separator; see tests/status_test.sh fixture).
# The separator used to be absorbed as answer text, so an OPEN entry followed by '---' was
# reported as answered: pending omitted it and apply returned rc 3.
mksep() { cat > "$1" << 'EOF'
# Decisions Queue

## D-201 — answered, before a separator
**Question:** First?
**Answer:** (a) — director 2026-06-06. ✅ RESOLVED

---

## D-202 — open, followed by a separator
**Question:** Second?
**Answer:**

---

## D-203 — answered, last entry
**Question:** Third?
**Answer:** (b) — director 2026-06-07.
EOF
}
mksep "$TD/s.md"
expect_eq "pending: --- separator not absorbed as answer" \
  "$(open_decisions "$TD/s.md" | cut -f1 | tr '\n' ' ')" "D-202 "
record_answer "$TD/s.md" D-202 yes "" 2026-07-02
expect_eq "apply: --- separated open entry rc 0" "$?" "0"
expect_eq "apply: --- fixture fully answered" "$(open_decisions "$TD/s.md")" ""

# --- missing decisions file: `pending` is rc 0 / no output (fresh checkout defense).
# Runs the CLI (DECIDE_LIB off) so the [ -f ] guard itself is exercised.
out="$(DECIDE_LIB=0 DECISIONS_FILE="$TD/does-not-exist.md" ./local/decide.sh pending)"
expect_eq "pending: missing file rc 0" "$?" "0"
expect_eq "pending: missing file no output" "$out" ""

echo
echo "decide_test: $P passed, $F failed"
[ "$F" -eq 0 ]
