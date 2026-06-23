#!/usr/bin/env bash
# evals/agentic/setup.sh — one-shot preflight for a fresh checkout. Provisions the gitignored
# drop-ins the runtime needs and validates the rest, reporting every gap at once. Idempotent.
#
# Gaps it closes (all are gitignored, so a fresh clone lacks them):
#   build/        runtime logs/locks — created here and by vm.py at import (build-image.sh not required)
#   ssh/ key      VM access key — auto-generated ONLY when safe (see below)
#   .secrets.env  inference credential — checked, never auto-generated
#   LLM_BASE_URL  upstream — checked
#   base.qcow2    golden VM image — checked
#
# SSH-key safety: a generated key only works if base.qcow2's baked authorized_keys trusts its .pub.
#   - no image yet      → generate (build-image.sh bakes the matching .pub in the same run)
#   - image + no key    → REFUSE to generate (a fresh key the image rejects just reproduces the
#                         opaque "SSH never came up" failure); tell the operator to restore/rebuild
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SSH_KEY="$HERE/ssh/agent_id_ed25519"
POOL=agentic
BASE_VOL=base.qcow2

miss=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; miss=1; }
image_present() { virsh vol-list "$POOL" 2>/dev/null | grep -q "$BASE_VOL"; }

echo "[setup] runtime dirs"
mkdir -p "$HERE/build"; ok "build/"

echo "[setup] VM ssh key"
if [ -r "$SSH_KEY" ]; then
  ok "ssh key present"
elif image_present; then
  bad "image $POOL/$BASE_VOL exists but its ssh key is absent ($SSH_KEY)"
  echo "      → restore the key that pairs with that image, or rebuild: $HERE/build-image.sh"
else
  mkdir -p "$HERE/ssh"; chmod 700 "$HERE/ssh"
  ssh-keygen -t ed25519 -N "" -C agent@agentic -f "$SSH_KEY" >/dev/null
  ok "generated ssh key (build-image.sh will bake its .pub into the image)"
fi

echo "[setup] inference config"
# shellcheck source=/dev/null  # .env is a gitignored runtime drop-in, absent from fresh clones /
# git-worktree checkouts; without this, `shellcheck -x` emits SC1091 and fails the worktree gate.
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi
if [ -n "${LLM_BASE_URL:-}${LLM_UPSTREAM_HOST:-}" ]; then ok "LLM_BASE_URL set"
else warn "LLM_BASE_URL / LLM_UPSTREAM_HOST unset (set in $ROOT/.env) — proxy has no upstream"; fi
if [ -n "${LLM_API_KEY:-}" ] || grep -qs LLM_API_KEY "$HERE/.secrets.env"; then
  ok "LLM_API_KEY present"
else
  warn "no LLM_API_KEY in env or $HERE/.secrets.env — proxy refuses to start (credential, can't auto-gen)"
fi

echo "[setup] VM image"
if image_present; then ok "$POOL/$BASE_VOL present"
else warn "no $POOL/$BASE_VOL — build it: $HERE/build-image.sh"; fi

echo
if [ "$miss" = 0 ]; then echo "[setup] OK"; else echo "[setup] BLOCKED — resolve ✗ above"; exit 1; fi
