#!/usr/bin/env bash
# state-sync.sh — pinned-anchor sync for director/STATE.md. No LLM, no network:
# pure awk over director/DECISIONS.md (CM-1, the never-compacted decision anchor).
#
# Modes:
#   local/state-sync.sh [DECISIONS_FILE]
#       Print the "binding decisions in force" block to stdout: a header line
#       followed by one "D-NNN — <title>" line per entry carrying a standalone
#       "**Binding:** yes" line, in document order. DECISIONS_FILE defaults to
#       director/DECISIONS.md relative to the repo root.
#
#   local/state-sync.sh apply [STATE_FILE] [DECISIONS_FILE]
#       Rewrite ONLY the auto-synced binding block in STATE_FILE — the lines
#       BETWEEN the BEGIN/END binding-block markers — with fresh output. The
#       hand-seeded invariants section (everything outside the markers) is left
#       byte-for-byte untouched. Refuses (rc 3) if either marker is missing, so it
#       can never silently clobber a malformed anchor. In-place, perms preserved.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BEGIN_MARK='<!-- BEGIN binding-block (auto-synced by local/state-sync.sh apply — do not hand-edit) -->'
END_MARK='<!-- END binding-block -->'

# Temp files (apply mode); cleaned on exit. A RETURN trap can't see a function's
# locals after it returns (set -u → unbound), so track them as globals + one EXIT trap.
TMP_BLK=""
TMP_OUT=""
cleanup() {
  [ -n "$TMP_BLK" ] && rm -f "$TMP_BLK"
  [ -n "$TMP_OUT" ] && rm -f "$TMP_OUT"
  return 0
}
trap cleanup EXIT

# Print the binding block (header + one "D-NNN — <title>" line per tagged entry).
print_block() {
  local decisions="$1"
  echo "binding decisions in force"
  awk '
    /^## D-[0-9]+ —/ {
        if (title != "" && binding) { print title }
        title = substr($0, 4)
        binding = 0
    }
    /^\*\*Binding:\*\* yes$/ { binding = 1 }
    END { if (title != "" && binding) { print title } }
  ' "$decisions"
}

# Replace the content between the BEGIN/END markers in STATE_FILE with a fresh block.
apply_block() {
  local state="$1" decisions="$2"
  if [ ! -f "$state" ]; then
    echo "state-sync: STATE file not found: $state" >&2
    return 3
  fi
  if ! grep -qF "$BEGIN_MARK" "$state" || ! grep -qF "$END_MARK" "$state"; then
    echo "state-sync: $state is missing the BEGIN/END binding-block markers — refusing to edit." >&2
    return 3
  fi
  TMP_BLK="$(mktemp)"
  TMP_OUT="$(mktemp)"
  print_block "$decisions" > "$TMP_BLK"
  awk -v blkfile="$TMP_BLK" -v b="$BEGIN_MARK" -v e="$END_MARK" '
    function emit(   line) { while ((getline line < blkfile) > 0) print line; close(blkfile) }
    index($0, b) { print; emit(); skip = 1; next }
    index($0, e) { print; skip = 0; next }
    skip { next }
    { print }
  ' "$state" > "$TMP_OUT"
  cat "$TMP_OUT" > "$state"   # truncate-in-place: preserve the file's perms/inode
}

main() {
  if [ "${1:-}" = "apply" ]; then
    apply_block "${2:-$REPO_DIR/director/STATE.md}" "${3:-$REPO_DIR/director/DECISIONS.md}"
  else
    print_block "${1:-$REPO_DIR/director/DECISIONS.md}"
  fi
}

main "$@"
