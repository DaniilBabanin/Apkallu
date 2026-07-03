#!/usr/bin/env bash
# Tests for local/watcher.sh — the 15-min health monitor. Two audit regressions:
#   (3.2) do_backup writes its daily dedup state even when maybe_ping never ran
#         (STATE_DIR must exist on the healthy path, else pg_dump reruns every tick);
#   (3.4) an ongoing stall pings ONCE — the dedup signature is normalized (kind +
#         threshold), so the growing minute counter can't defeat REALERT suppression.
# Hermetic: temp STATE_DIR/backup dir, stubbed pg_dump/curl/date on PATH, disk/VRAM
# thresholds forced above 100% so real host pressure can't add concerns.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WATCHER="$REPO_DIR/local/watcher.sh"

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

want_eq() {  # desc, got, expected
  local desc="$1" got="$2" expected="$3"
  if [ "$got" = "$expected" ]; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc (got '$got', expected '$expected')" >&2
    fail=$((fail + 1))
  fi
}

TMP="$(mktemp -d)"
DECOY_PID=""
trap '[ -n "$DECOY_PID" ] && kill "$DECOY_PID" 2>/dev/null; rm -rf "$TMP"' EXIT

# --- stubs on PATH: pg_dump + curl log their calls; date honors FAKE_NOW_OFFSET ---
mkdir -p "$TMP/bin" "$TMP/backups"
: > "$TMP/pg_dump.calls"
: > "$TMP/curl.calls"
cat > "$TMP/bin/pg_dump" <<EOF
#!/usr/bin/env bash
echo "pg_dump \$*" >> "$TMP/pg_dump.calls"
echo FAKEDUMP
EOF
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "$TMP/curl.calls"
EOF
cat > "$TMP/bin/date" <<'EOF'
#!/usr/bin/env bash
# +%s advances by $FAKE_NOW_OFFSET so a "later tick" needs no real sleep
if [ "${1:-}" = "+%s" ]; then echo $(( $(/bin/date +%s) + ${FAKE_NOW_OFFSET:-0} )); else exec /bin/date "$@"; fi
EOF
chmod +x "$TMP/bin/pg_dump" "$TMP/bin/curl" "$TMP/bin/date"

watch_env() {  # common hermetic env, then VAR=... overrides + command
  env PATH="$TMP/bin:$PATH" \
      WATCHER_NO_MODEL=1 WATCHER_DISK_PCT=101 WATCHER_DISK_CRIT=102 WATCHER_VRAM_PCT=101 \
      DECISIONS_FILE="$TMP/no-decisions.md" WATCHER_NOW=2099-01-09 \
      AGENCY_BACKUP_DIR="$TMP/backups" AGENCY_BACKUP_DB=testdb \
      "$@"
}

# --- (3.2) backup dedup: state dir created on the healthy path, one dump per day ---
echo "== backup dedup (3.2)"
STATE_A="$TMP/state-a/agency-watcher"   # deliberately nonexistent nested dir

OUT1="$(watch_env STATE_DIR="$STATE_A" NTFY_TOPIC= WATCHER_STALL_SECS=999999999 "$WATCHER" run 2>&1)"
want "tick 1 writes a dump"                    "$OUT1" "backup:"
want "tick 1 reports the dump written"         "$OUT1" "written"
want_eq "tick 1: pg_dump ran once"             "$(wc -l < "$TMP/pg_dump.calls")" "1"
want_eq "dedup state file written"             "$(cat "$STATE_A/last_backup_date" 2>/dev/null || echo MISSING)" "2099-01-09"

OUT2="$(watch_env STATE_DIR="$STATE_A" NTFY_TOPIC= WATCHER_STALL_SECS=999999999 "$WATCHER" run 2>&1)"
want "tick 2 skips (already ran today)"        "$OUT2" "already ran today"
want_eq "tick 2: pg_dump still ran only once"  "$(wc -l < "$TMP/pg_dump.calls")" "1"

# --- (3.4) stall alert dedup: two ticks of the same stall -> one ntfy push --------
echo "== stall alert dedup (3.4)"
STATE_B="$TMP/state-b/agency-watcher"

# decoy loop/run.sh process so check_stall sees the loop as alive
mkdir -p "$TMP/loop"
printf '#!/usr/bin/env bash\nsleep 300\n' > "$TMP/loop/run.sh"
chmod +x "$TMP/loop/run.sh"
bash "$TMP/loop/run.sh" & DECOY_PID=$!

OUT3="$(watch_env STATE_DIR="$STATE_B" NTFY_TOPIC=watcher-test WATCHER_STALL_SECS=1 \
        FAKE_NOW_OFFSET=0 "$WATCHER" run 2>&1)"
want "tick 1 sees the stall"                   "$OUT3" "possible stall"
want "tick 1 pushes the alert"                 "$OUT3" "pushed alert"
want_eq "tick 1: one curl push"                "$(wc -l < "$TMP/curl.calls")" "1"

# 2 minutes later the stall minute-counter has grown — the ping must be suppressed
OUT4="$(watch_env STATE_DIR="$STATE_B" NTFY_TOPIC=watcher-test WATCHER_STALL_SECS=1 \
        FAKE_NOW_OFFSET=120 "$WATCHER" run 2>&1)"
want "tick 2 still sees the stall"             "$OUT4" "possible stall"
want "tick 2 suppresses the re-ping"           "$OUT4" "suppressed"
want_eq "tick 2: still exactly one curl push"  "$(wc -l < "$TMP/curl.calls")" "1"

echo ""
echo "watcher_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
