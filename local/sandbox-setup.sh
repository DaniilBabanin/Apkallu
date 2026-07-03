#!/usr/bin/env bash
# sandbox-setup.sh — configure Claude Code's native Linux sandbox for the unattended loop.
# Closes the ARCHITECTURE.md "Planned hardening" gap; pending director approval = D-005.
#
# What it configures (project .claude/settings.json — applies to every claude run in this
# repo, including loop/run.sh's inner `claude -p`):
#   sandbox.enabled=true                 bubblewrap+socat OS isolation for Bash commands
#   sandbox.failIfUnavailable=true       fail CLOSED if deps go missing (no silent unsandboxed)
#   sandbox.allowUnsandboxedCommands=false  strict: no retry-outside-sandbox escape hatch
#   filesystem.denyRead                  ~/.ssh ~/.aws ~/.gnupg ~/.config/gh ~/.claude —
#                                        sandbox does NOT protect these by default; gh auth +
#                                        SSH keys are the named residual risk in ARCHITECTURE
#   network.allowedDomains               localhost/127.0.0.1 (a local server), api.anthropic.com,
#                                        ntfy.sh — domain-level only, ports not supported
#   env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB strip provider creds from Bash subprocess env
#
# Subcommands:
#   check          report deps + settings state. Exit 0 ready · 3 deps missing · 4 not configured.
#   install        (default) verify deps, then write/merge the snippet into the settings file.
#   print          emit the settings snippet to stdout (no writes).
#   -h | --help    usage.
#
# Env:
#   SANDBOX_SETTINGS_FILE  target settings file (default: <repo>/.claude/settings.json)
#   SANDBOX_SKIP_DEPS=1    skip the dependency check (used by tests/)
#
# Deps: bubblewrap (bwrap) + socat — `sudo apt install bubblewrap socat`. Ubuntu 24.04+:
# if `sysctl kernel.apparmor_restrict_unprivileged_userns` is 1, bwrap needs the AppArmor
# fix from the sandboxing docs (we warn, we don't change kernel settings).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS_FILE="${SANDBOX_SETTINGS_FILE:-$REPO_DIR/.claude/settings.json}"

usage() { sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

snippet() {
  # unquoted heredoc so ${HOME} expands to this machine's home — portable across clones (#Apkallu)
  cat <<JSON
{
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false,
    "filesystem": {
      "denyRead": ["~/.ssh", "~/.aws", "~/.gnupg", "~/.config/gh", "~/.claude"]
    },
    "network": {
      "allowedDomains": ["localhost", "127.0.0.1", "api.anthropic.com", "ntfy.sh"]
    }
  },
  "env": {
    "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB": "1"
  },
  "permissions": {
    "allow": ["Bash"],
    "deny": [
      "Read(${HOME}/.ssh/**)", "Write(${HOME}/.ssh/**)",
      "Read(${HOME}/.aws/**)", "Write(${HOME}/.aws/**)",
      "Read(${HOME}/.gnupg/**)", "Write(${HOME}/.gnupg/**)",
      "Read(${HOME}/.config/gh/**)", "Write(${HOME}/.config/gh/**)",
      "Read(${HOME}/.claude/**)", "Write(${HOME}/.claude/**)"
    ]
  }
}
JSON
}
# permissions block rationale (D-005 flip, 2026-06-06):
#   allow Bash    — with the sandbox strict + fail-closed, OS enforcement replaces per-command
#                   prompts: this IS "auto-allow sandboxed bash" for headless acceptEdits runs.
#   deny Read/Write — the Read/Write/Edit TOOLS bypass the bash sandbox (they are not bash);
#                   sandbox denyRead alone leaves ~/.ssh readable via the Read tool.

deps_ok() {
  local missing=()
  command -v bwrap >/dev/null 2>&1 || missing+=(bubblewrap)
  command -v socat >/dev/null 2>&1 || missing+=(socat)
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "[sandbox] missing dependencies: ${missing[*]}"
    echo "[sandbox] install: sudo apt install ${missing[*]}"
    return 1
  fi
  return 0
}

apparmor_warn() {
  # Functional probes beat sysctl reading. Two levels (found the hard way, 2026-06-06):
  # 1. plain userns — Ubuntu's stock bwrap-userns-restrict profile allows this even with
  #    kernel.apparmor_restrict_unprivileged_userns=1, BUT capability-restricts the ns, so
  # 2. NESTED userns (what Claude Code's seccomp setup actually needs) still fails with
  #    "apply-seccomp: ... nested userns is capability-restricted". The docs' fix is a scoped
  #    unconfined AppArmor profile for /usr/bin/bwrap (shipped at local/apparmor-bwrap.profile).
  if ! bwrap --ro-bind / / --dev /dev --proc /proc true 2>/dev/null; then
    echo "[sandbox] ⚠ bwrap cannot create a user namespace — sandbox WILL fail closed."
  elif ! bwrap --ro-bind / / --dev /dev --proc /proc --unshare-all \
         bwrap --ro-bind / / true 2>/dev/null; then
    echo "[sandbox] ⚠ NESTED userns blocked (AppArmor) — sandboxed commands will die at"
    echo "[sandbox]   seccomp setup. Fix (scoped to bwrap, from the sandboxing docs):"
  else
    return 0
  fi
  echo "[sandbox]   sudo install -m644 local/apparmor-bwrap.profile /etc/apparmor.d/bwrap \\"
  echo "[sandbox]     && sudo systemctl reload apparmor"
}

settings_ok() {
  [ -f "$SETTINGS_FILE" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '.sandbox.enabled == true and .sandbox.failIfUnavailable == true' \
    "$SETTINGS_FILE" >/dev/null 2>&1
}

do_check() {
  local rc=0
  if deps_ok; then echo "[sandbox] deps: OK (bwrap + socat)"; else rc=3; fi
  apparmor_warn
  if settings_ok; then
    echo "[sandbox] settings: OK ($SETTINGS_FILE)"
  else
    echo "[sandbox] settings: NOT configured ($SETTINGS_FILE)"
    [ "$rc" -eq 0 ] && rc=4
  fi
  return "$rc"
}

do_install() {
  if [ "${SANDBOX_SKIP_DEPS:-0}" != "1" ]; then
    if ! deps_ok; then exit 3; fi
    apparmor_warn
  fi
  command -v jq >/dev/null 2>&1 || { echo "[sandbox] jq required" >&2; exit 2; }
  mkdir -p "$(dirname "$SETTINGS_FILE")"
  if [ -f "$SETTINGS_FILE" ]; then
    # Deep-merge: existing settings kept, our snippet wins on conflicts — EXCEPT the
    # permissions.allow/deny, sandbox denyRead, and network allowedDomains arrays, which
    # are unioned (jq's * replaces arrays wholesale and would silently drop the user's
    # own rules/entries on reinstall).
    local merged
    merged="$(jq -s '
      . as [$old, $new] | ($old * $new)
      | .permissions.allow = (($old.permissions.allow // []) + ($new.permissions.allow // []) | unique)
      | .permissions.deny  = (($old.permissions.deny  // []) + ($new.permissions.deny  // []) | unique)
      | .sandbox.filesystem.denyRead =
          (($old.sandbox.filesystem.denyRead // []) + ($new.sandbox.filesystem.denyRead // []) | unique)
      | .sandbox.network.allowedDomains =
          (($old.sandbox.network.allowedDomains // []) + ($new.sandbox.network.allowedDomains // []) | unique)
      ' "$SETTINGS_FILE" <(snippet))"
    printf '%s\n' "$merged" >"$SETTINGS_FILE"
    echo "[sandbox] merged sandbox config into existing $SETTINGS_FILE"
  else
    snippet >"$SETTINGS_FILE"
    echo "[sandbox] wrote $SETTINGS_FILE"
  fi
  echo "[sandbox] Loop default is sandboxed acceptEdits (D-005 applied 2026-06-06);"
  echo "[sandbox] ALLOW_ALL=1 on run.sh is the explicit supervised bypass."
}

case "${1:-install}" in
  -h|--help|help) usage; exit 0 ;;
  print)          snippet; exit 0 ;;
  check)
    set +e; do_check; rc=$?; set -e
    exit "$rc"
    ;;
  install|"")     do_install ;;
  *) echo "unknown subcommand: $1" >&2; usage; exit 64 ;;
esac
