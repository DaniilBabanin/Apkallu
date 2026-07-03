#!/usr/bin/env bash
# map-gen.sh — director/MAP.md generator. Deterministic, no LLM, no network (CM-2).
# A token-cheap repo index a worker reads INSTEAD of the whole repo: the condensed
# "table of contents" — load full files only when this index points you there.
# Three sections:
#   (1) Files       — one-line purpose per shell script, from its first
#                     "# <name> — <desc>" header comment (fallback: first comment).
#   (2) NOTES.md    — one pointer per "## " section as "L<n> — <title>" so a worker
#                     reads NOTES by line range, never the whole ~26k-token file.
#   (3) Decisions   — one line per D-NNN: "D-NNN  OPEN|CLOSED|BINDING  <title>".
#
# Usage: local/map-gen.sh [ROOT]
#   ROOT defaults to the repo root; override (e.g. a temp fixture dir) for tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="${1:-$DEFAULT_ROOT}"
cd "$ROOT"

STAMP="$(date -Iseconds 2>/dev/null || date)"

printf '# Repo Map (index — read this, not the whole repo)\n'
printf '_Generated %s · deterministic (no model) by local/map-gen.sh._\n\n' "$STAMP"
printf 'Condensed table of contents. Load a full file only when this index points you there.\n\n'

# --- (1) Files: one-line purpose per shell script ---------------------------
printf '## Files (shell scripts)\n\n'
while IFS= read -r f; do
  rel="${f#./}"
  # `|| true`: grep returns non-zero on no-match, which pipefail+set -e would treat as fatal.
  desc="$(grep -m1 -E '^# .+ — .+' "$f" 2>/dev/null | sed -E 's/^# //' || true)"
  if [ -z "$desc" ]; then
    desc="$(grep -m1 -E '^# ' "$f" 2>/dev/null | sed -E 's/^# //' || true)"
  fi
  [ -n "$desc" ] || desc='(no description)'
  # shellcheck disable=SC2016  # backticks are literal markdown code-span syntax, not command subst
  printf -- '- `%s` — %s\n' "$rel" "$desc"
done < <(find . -type f -name '*.sh' -not -path './.git/*' \
           -not -path './.cascade/*' -not -path './evals/agentic/build/*' | sort)
printf '\n'

# --- (2) NOTES.md index: one pointer per "## " section ----------------------
printf '## NOTES.md index (append-only loop memory — read by range)\n\n'
if [ -f NOTES.md ]; then
  grep -nE '^## ' NOTES.md | sed -E 's/^([0-9]+):## /- L\1 — /' || true
else
  printf '_(no NOTES.md)_\n'
fi
printf '\n'

# --- (3) Decisions index: D-NNN status + title ------------------------------
printf '## Decisions index (director/DECISIONS.md)\n\n'
if [ -f director/DECISIONS.md ]; then
  awk '
    function flush() {
      if (id == "") return
      status = "CLOSED"
      if (ans !~ /[^[:space:]]/) status = "OPEN"
      else if (binding) status = "BINDING"
      printf "- %s  %s  %s\n", id, status, title
      id = ""
    }
    /^## D-[0-9]+/ {
      flush()
      id = $2
      title = $0; sub(/^## D-[0-9]+ — /, "", title)
      ans = ""; inans = 0; binding = 0
      next
    }
    id == "" { next }
    /^---[[:space:]]*$/ { flush(); next }
    /^\*\*Binding:\*\* yes[[:space:]]*$/ { binding = 1 }
    /^\*\*Answer:\*\*/ { inans = 1; t = $0; sub(/^\*\*Answer:\*\*/, "", t); ans = ans t; next }
    inans { ans = ans " " $0 }
    END { flush() }
  ' director/DECISIONS.md
else
  printf '_(no DECISIONS.md)_\n'
fi
