#!/usr/bin/env bash
# Tests for local/sandbox-setup.sh and the (optional) live .claude/settings.json.
# No network, no deps required: generation is tested against a temp file with
# SANDBOX_SKIP_DEPS=1; the live-settings checks only run if the file exists.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; FAIL=1; }

assert_cfg() { # file name jq_expr
  if jq -e "$3" "$1" >/dev/null 2>&1; then ok "$2"; else bad "$2"; fi
}

# --- 1. fresh write into an empty dir ---------------------------------------
SANDBOX_SETTINGS_FILE="$TMP/fresh/settings.json" SANDBOX_SKIP_DEPS=1 \
  local/sandbox-setup.sh install >/dev/null
F="$TMP/fresh/settings.json"
if jq -e . "$F" >/dev/null 2>&1; then ok "fresh-parses"; else bad "fresh-parses"; fi
assert_cfg "$F" "enabled"          '.sandbox.enabled == true'
assert_cfg "$F" "fail-closed"      '.sandbox.failIfUnavailable == true'
assert_cfg "$F" "strict-no-escape" '.sandbox.allowUnsandboxedCommands == false'
assert_cfg "$F" "deny-ssh"         '.sandbox.filesystem.denyRead | index("~/.ssh")'
assert_cfg "$F" "deny-aws"         '.sandbox.filesystem.denyRead | index("~/.aws")'
assert_cfg "$F" "deny-gh"          '.sandbox.filesystem.denyRead | index("~/.config/gh")'
assert_cfg "$F" "net-localhost"    '.sandbox.network.allowedDomains | index("localhost")'
assert_cfg "$F" "net-anthropic"    '.sandbox.network.allowedDomains | index("api.anthropic.com")'
assert_cfg "$F" "env-scrub"        '.env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB == "1"'
assert_cfg "$F" "perm-allow-bash"  '.permissions.allow | index("Bash")'
assert_cfg "$F" "perm-deny-ssh-read" ".permissions.deny | index(\"Read($HOME/.ssh/**)\")"
assert_cfg "$F" "perm-deny-ssh-write" ".permissions.deny | index(\"Write($HOME/.ssh/**)\")"

# --- 2. merge preserves existing keys, snippet wins on conflict --------------
mkdir -p "$TMP/merge"
cat >"$TMP/merge/settings.json" <<'EOF'
{"permissions": {"allow": ["Bash(ls:*)"]}, "sandbox": {"enabled": false}}
EOF
SANDBOX_SETTINGS_FILE="$TMP/merge/settings.json" SANDBOX_SKIP_DEPS=1 \
  local/sandbox-setup.sh install >/dev/null
M="$TMP/merge/settings.json"
assert_cfg "$M" "merge-keeps-existing" '.permissions.allow | index("Bash(ls:*)")'
assert_cfg "$M" "merge-unions-allow"   '.permissions.allow | index("Bash")'
assert_cfg "$M" "merge-snippet-wins"   '.sandbox.enabled == true'

# --- 3. check subcommand exit codes ------------------------------------------
set +e
SANDBOX_SETTINGS_FILE="$TMP/fresh/settings.json" local/sandbox-setup.sh check >/dev/null 2>&1
rc=$?
set -e
# 0 if deps installed on this box, 3 if not — both consistent; 4 would mean bad config.
if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then ok "check-rc-configured ($rc)"; else bad "check-rc-configured ($rc)"; fi
set +e
SANDBOX_SETTINGS_FILE="$TMP/nope.json" local/sandbox-setup.sh check >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 3 ] || [ "$rc" -eq 4 ]; then ok "check-rc-unconfigured ($rc)"; else bad "check-rc-unconfigured ($rc)"; fi

# --- 4. live project settings, if present, must be coherent ------------------
if [ -f .claude/settings.json ]; then
  L=.claude/settings.json
  if jq -e . "$L" >/dev/null 2>&1; then ok "live-parses"; else bad "live-parses"; fi
  if jq -e '.sandbox.enabled == true' "$L" >/dev/null 2>&1; then
    # enabled sandbox without deps = loop will fail closed at next run — surface it here
    if command -v bwrap >/dev/null 2>&1; then ok "live-dep-bwrap"; else bad "live-dep-bwrap (sandbox on, bwrap missing)"; fi
    if command -v socat >/dev/null 2>&1; then ok "live-dep-socat"; else bad "live-dep-socat (sandbox on, socat missing)"; fi
    assert_cfg "$L" "live-deny-ssh" '.sandbox.filesystem.denyRead | index("~/.ssh")'
    assert_cfg "$L" "live-deny-aws" '.sandbox.filesystem.denyRead | index("~/.aws")'
  else
    ok "live-sandbox-not-enabled (pre-D-005 state)"
  fi
else
  ok "live-settings-absent (pre-install state)"
fi

exit "$FAIL"
