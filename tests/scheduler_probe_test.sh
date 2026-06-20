#!/usr/bin/env bash
# Tests for loop/scheduler.sh `probe` — fixture-driven via PROBE_CMD, no claude, no network.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
check() { # name expected_rc expected_line fixture_cmd
  local name="$1" want_rc="$2" want_out="$3" cmd="$4" out rc
  set +e
  out="$(PROBE_CMD="$cmd" loop/scheduler.sh probe)"
  rc=$?
  set -e
  if [ "$rc" -ne "$want_rc" ] || [ "$out" != "$want_out" ]; then
    echo "FAIL $name: rc=$rc (want $want_rc) out='$out' (want '$want_out')"
    FAIL=1
  else
    echo "ok   $name"
  fi
}

# 1. healthy window: valid result JSON, is_error false -> OK
cat >"$TMP/ok.json" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"duration_ms":2000,"result":"pong","total_cost_usd":0.0123}
EOF
check "ok-json"        0  "STATE=OK RESET="                "cat $TMP/ok.json"

# 2. capped, plain-text CLI message with reset epoch -> CAPPED + epoch extracted
echo 'Claude AI usage limit reached|2069252800' >"$TMP/capped.txt"
check "capped-epoch"   20 "STATE=CAPPED RESET=2069252800"  "cat $TMP/capped.txt"

# 3. capped, embedded in an error JSON -> CAPPED (regex must win over JSON parse)
cat >"$TMP/capped.json" <<'EOF'
{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Claude AI usage limit reached|2069252800"}
EOF
check "capped-json"    20 "STATE=CAPPED RESET=2069252800"  "cat $TMP/capped.json"

# 4. capped, no parsable epoch -> CAPPED with empty RESET (caller falls back to CAP_RETRY_SECS)
echo '5-hour limit reached - resets 3am' >"$TMP/capped-noepoch.txt"
check "capped-noepoch" 20 "STATE=CAPPED RESET="            "cat $TMP/capped-noepoch.txt"

# 5. garbage output -> ERROR (fail safe: never burst on noise)
check "garbage"        21 "STATE=ERROR RESET="             "echo halp such error"

# 6. probe command itself dies -> ERROR
check "probe-dies"     21 "STATE=ERROR RESET="             "exit 7"

# 7. error JSON without a limit message (e.g. auth failure) -> ERROR, not OK
cat >"$TMP/err.json" <<'EOF'
{"type":"result","subtype":"error_during_execution","is_error":true,"result":"OAuth token expired"}
EOF
check "error-json"     21 "STATE=ERROR RESET="             "cat $TMP/err.json"

exit "$FAIL"
