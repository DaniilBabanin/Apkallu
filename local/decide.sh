#!/usr/bin/env bash
# local/decide.sh — local director-decision record. No network, no creds.
#
# The director answers open decisions over SSH / the TUI, not a chat bot: this
# writes a verdict into the blank **Answer:** line of director/DECISIONS.md and
# lists what is still open. tui.sh's [a] key calls `apply`; `pending` shares the
# same open-detection as local/digest.sh and status.sh.
#
# Usage:  ./local/decide.sh pending                       # open D-NNN (id<TAB>title)
#         ./local/decide.sh apply D-NNN yes|no|always|<text> [note]
#
# Env:    DECISIONS_FILE   override the decisions file (tests).
#         DECIDE_LIB=1     source the functions only (tests), skip the CLI.
set -u

AGENCY_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DECISIONS_FILE="${DECISIONS_FILE:-$AGENCY_DIR/director/DECISIONS.md}"

# open_decisions <file> -> "D-NNN\ttitle" per OPEN entry (blank **Answer:**).
# Same open-detection semantics as local/digest.sh's awk.
open_decisions() {
  awk '
    function flush() {
      if (id != "" && ans !~ /[^[:space:]]/) printf "%s\t%s\n", id, title
      id=""; title=""; ans=""; inans=0
    }
    /^## D-[0-9]+ / {
      flush()
      id=$2; title=$0
      sub(/^## D-[0-9]+[[:space:]]+—[[:space:]]+/, "", title)
      next
    }
    /^\*\*Answer:\*\*/ { inans=1; t=$0; sub(/^\*\*Answer:\*\*/, "", t); ans=ans t; next }
    inans { ans = ans $0 }
    END { flush() }
  ' "$1" 2>/dev/null
}

# record_answer <file> <id> <verdict> <note> <date> — fill the blank **Answer:**.
# rc=2 unknown id, rc=3 already answered; file untouched on both. The "director"
# marker is what status.sh treats as resolved.
record_answer() {
  local f="$1" id="$2" verdict="$3" note="$4" date="$5"
  grep -q "^## $id " "$f" || return 2
  open_decisions "$f" | cut -f1 | grep -qxF "$id" || return 3
  local ans="**Answer:** ($verdict) — director via tui $date"
  if [ -n "$note" ]; then ans="$ans — $note"; fi
  local tmp; tmp="$(mktemp)"
  awk -v id="$id" -v ans="$ans" '
    /^## D-[0-9]+ / { cur=$2 }
    cur==id && /^\*\*Answer:\*\*[[:space:]]*$/ && !done { print ans; done=1; next }
    { print }
  ' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$f" && rm -f "$tmp"
}

# Sourcing seam for tests.
if [ "${DECIDE_LIB:-0}" = "1" ]; then
  return 0
fi

case "${1:-}" in
  pending) open_decisions "$DECISIONS_FILE" ;;
  apply)   record_answer "$DECISIONS_FILE" "${2:?id}" "${3:?verdict}" "${4:-}" "$(date +%F)" ;;
  *) echo "usage: decide.sh pending|apply D-NNN <verdict> [note]" >&2; exit 64 ;;
esac
