#!/usr/bin/env bash
# Tests for local/map-gen.sh — the deterministic director/MAP.md generator (CM-2).
# No LLM, no network. Runs map-gen against a temp fixture ROOT (its own NOTES.md,
# director/DECISIONS.md, and .sh files) and asserts the three sections render
# correctly: Files (header + fallback), NOTES index, Decisions OPEN|CLOSED|BINDING.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MAP_GEN="$REPO_DIR/local/map-gen.sh"

pass=0
fail=0

want() {  # desc, haystack, needle
  local desc="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc" >&2
    echo "    expected to find: $needle" >&2
    fail=$((fail + 1))
  fi
}

want_not() {  # desc, haystack, needle
  local desc="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    echo "  FAIL: $desc" >&2
    echo "    expected NOT to find: $needle" >&2
    fail=$((fail + 1))
  else
    echo "  PASS: $desc"
    pass=$((pass + 1))
  fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT/director"

# A script WITH an em-dash header, and one WITHOUT (exercises the fallback).
cat > "$ROOT/aaa.sh" <<'EOF'
#!/usr/bin/env bash
# aaa.sh — does the alpha thing.
echo alpha
EOF
cat > "$ROOT/zzz.sh" <<'EOF'
#!/usr/bin/env bash
# plain comment, no em-dash here
echo zeta
EOF

# Throwaway copies that must NOT be indexed: a cascade worktree clone of aaa.sh
# (would duplicate every script per active unit) and a build artifact.
mkdir -p "$ROOT/.cascade/worktrees/w1" "$ROOT/evals/agentic/build"
cp "$ROOT/aaa.sh" "$ROOT/.cascade/worktrees/w1/aaa.sh"
cat > "$ROOT/evals/agentic/build/artifact.sh" <<'EOF'
#!/usr/bin/env bash
# artifact.sh — generated build artifact, not source.
EOF

cat > "$ROOT/NOTES.md" <<'EOF'
# Notes
intro line
## 2026-01-01 — first section
body
## 2026-01-02 — second section
body
EOF

cat > "$ROOT/director/DECISIONS.md" <<'EOF'
# Decisions

## D-100 — Open one
**Question:** open?
**Answer:**

---

## D-101 — Closed one
**Answer:** done

---

## D-102 — Binding one
**Answer:** done
**Binding:** yes
EOF

OUT="$("$MAP_GEN" "$ROOT")"

# Section headers present.
want "has Files section"     "$OUT" "## Files (shell scripts)"
want "has NOTES index"       "$OUT" "## NOTES.md index"
want "has Decisions index"   "$OUT" "## Decisions index"

# (1) Files: em-dash header used, and fallback to first comment for the headerless one.
# shellcheck disable=SC2016  # backticks are literal markdown in the expected output, not command subst
want "Files: aaa.sh uses its em-dash header" "$OUT" '`aaa.sh` — aaa.sh — does the alpha thing.'
# shellcheck disable=SC2016  # backticks are literal markdown in the expected output, not command subst
want "Files: zzz.sh falls back to first comment" "$OUT" '`zzz.sh` — plain comment, no em-dash here'

# (1b) Files: cascade worktrees and build artifacts are excluded, source copy kept.
want_not "Files: no .cascade worktree entries"      "$OUT" '.cascade/'
want_not "Files: no evals/agentic/build entries"    "$OUT" 'evals/agentic/build/'
# shellcheck disable=SC2016  # backticks are literal markdown in the expected output, not command subst
aaa_count="$(printf '%s\n' "$OUT" | grep -cF -- '`aaa.sh`' || true)"
if [ "$aaa_count" = "1" ]; then
  echo "  PASS: Files: exactly one aaa.sh entry (worktree copy not duplicated)"
  pass=$((pass + 1))
else
  echo "  FAIL: Files: expected exactly one aaa.sh entry, got $aaa_count" >&2
  fail=$((fail + 1))
fi

# (2) NOTES index: line-pointer + title per section.
want "NOTES: first section pointer"  "$OUT" "first section"
want "NOTES: pointer carries a line number" "$OUT" "- L"

# (3) Decisions: status classification.
want "Decisions: open -> OPEN"       "$OUT" "- D-100  OPEN  Open one"
want "Decisions: answered -> CLOSED" "$OUT" "- D-101  CLOSED  Closed one"
want "Decisions: tagged -> BINDING"  "$OUT" "- D-102  BINDING  Binding one"

# Purity: no network/LLM calls in the generator itself.
if grep -qE '\bcurl\b|\bwget\b|\bllm\b' "$MAP_GEN"; then
  echo "  FAIL: map-gen.sh contains network/LLM calls" >&2
  fail=$((fail + 1))
else
  echo "  PASS: map-gen.sh has no network/LLM calls"
  pass=$((pass + 1))
fi

echo ""
echo "map_gen_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
