#!/usr/bin/env bash
# local/retro.sh — agency retro metrics. Deterministic, in-repo, zero deps.
#
# Feeds the VISION stage-2 metric: interventions/week trending DOWN, useful
# output/week trending UP. Numbers only — interpretation lives in /retro.
#
# Metrics (window = RETRO_DAYS, default 7):
#   OUTPUT         commits in window · backlog units done / open
#   INTERVENTIONS  D-NNN escalations raised in window (parsed from **Asked:** dates)
#   QUEUE          total decisions on record
#
# Usage: ./local/retro.sh             print the report
#        ./local/retro.sh --selftest  run the date-parser self-check
# Env:   RETRO_DAYS  window in days (default 7)
#        RETRO_DECISIONS / RETRO_BACKLOG  file overrides (tests)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DECISIONS="${RETRO_DECISIONS:-$REPO_DIR/director/DECISIONS.md}"
BACKLOG="${RETRO_BACKLOG:-$REPO_DIR/backlog.md}"
RETRO_DAYS="${RETRO_DAYS:-7}"

# count_asked_since <decisions-file> <since-epoch> -> count of D-NNN whose
# **Asked:** date is >= since-epoch. Unparseable dates are skipped.
count_asked_since() {
  local f="$1" since="$2" n=0 d e
  [ -f "$f" ] || { printf '0'; return 0; }
  while IFS= read -r d; do
    e="$(date -d "$d" +%s 2>/dev/null || true)"
    [ -n "$e" ] || continue
    if [ "$e" -ge "$since" ]; then n=$((n + 1)); fi
  done < <(grep -oE '\*\*Asked:\*\* [0-9]{4}-[0-9]{2}-[0-9]{2}' "$f" \
             | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
  printf '%s' "$n"
}

selftest() {
  local tmp got since
  tmp="$(mktemp)"
  cat >"$tmp" <<'EOF'
## D-001 — a
**Asked:** 2026-06-15 · **Default applies:** when answered
## D-002 — b
**Asked:** 2026-06-01 · **Default applies:** when answered
## D-003 — c
**Asked:** 2026-06-16 · **Default applies:** when answered
EOF
  since="$(date -d 2026-06-10 +%s)"
  got="$(count_asked_since "$tmp" "$since")"
  rm -f "$tmp"
  if [ "$got" = "2" ]; then
    echo "selftest: PASS (asked-since=$got, want 2)"
  else
    echo "selftest: FAIL (asked-since=$got, want 2)" >&2
    return 1
  fi
}

case "${1:-}" in
  --selftest)
    if selftest; then exit 0; else exit 1; fi
    ;;
esac

since_epoch="$(date -d "-${RETRO_DAYS} days" +%s)"

commits_window="$(git -C "$REPO_DIR" log --since="${RETRO_DAYS} days ago" --oneline 2>/dev/null \
                    | wc -l | tr -d ' ' || true)"
units_done="$(grep -c '^- \[x\]' "$BACKLOG" 2>/dev/null || true)"
units_open="$(grep -c '^- \[ \]' "$BACKLOG" 2>/dev/null || true)"
escalations="$(count_asked_since "$DECISIONS" "$since_epoch")"
decisions_total="$(grep -cE '^## D-[0-9]+' "$DECISIONS" 2>/dev/null || true)"

echo "agency retro — last ${RETRO_DAYS}d (as of $(date '+%F'))"
echo
echo "OUTPUT/week"
printf '  commits in window:  %s\n' "${commits_window:-0}"
printf '  backlog units done: %s\n' "${units_done:-0}"
printf '  backlog units open: %s\n' "${units_open:-0}"
echo
echo "INTERVENTIONS/week  (lower is better — VISION stage-2)"
printf '  escalations raised: %s  (D-NNN asked in window)\n' "${escalations:-0}"
echo
echo "QUEUE"
printf '  decisions on record: %s\n' "${decisions_total:-0}"
