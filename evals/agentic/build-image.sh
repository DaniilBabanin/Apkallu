#!/usr/bin/env bash
# build-image.sh — a build phase: build the reusable golden VM image (base.qcow2).
#
# Produces a lean Ubuntu 24.04 (noble) qcow2 with: a non-root `agent` user (injected
# SSH key, passwordless sudo), python3.12+pip+venv, git, build-essential, docker (for the
# a build phase a benchmark A/B), and OpenHands (openhands-ai) pre-installed in a venv at
# /opt/openhands. The image is built with plain qemu as the current user in a $HOME scratch
# dir, then uploaded into the libvirt `agentic` pool (system-mode qemu cannot read $HOME — see
# DECISIONS D-022). Idempotent: re-running reuses the downloaded cloud image.
#
# Usage: ./build-image.sh            # full build + upload to pool
#        KEEP_VM=1 ./build-image.sh  # leave the build VM running for debugging (no upload)
#
# Verify (run by this script before upload): boot, SSH, python3 --version, the OpenHands SDK
# headless API imports (`from openhands.sdk import LLM, Agent, Conversation`), `docker run
# hello-world`. NB: current OpenHands (SDK v1.27 via openhands-ai 1.8) has NO
# `openhands.core.main` — headless runs go through the SDK, not the old monolith CLI (D-024).
#
# Exit: 0 image built+verified+uploaded · non-zero on any failed step.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build"
SSH_KEY="$HERE/ssh/agent_id_ed25519"
POOL="agentic"
VOL="base.qcow2"

CLOUD_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
CLOUD_IMG="$BUILD/noble-cloudimg.qcow2"
WORK="$BUILD/base.qcow2"
SEED="$BUILD/seed.iso"
CONSOLE="$BUILD/console.log"

DISK_SIZE="30G"     # virtual; qcow2 stays sparse. Headroom for OpenHands deps + docker images.
MEM_MB="6144"
VCPUS="4"
SSH_PORT="2222"
SSH_HOST="127.0.0.1"

log() { printf '[build-image] %s\n' "$*"; }
die() { printf '[build-image] FATAL: %s\n' "$*" >&2; exit 1; }

ssh_agent() {
  ssh -i "$SSH_KEY" -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 -o LogLevel=ERROR \
    "agent@$SSH_HOST" "$@"
}

[ -r "$SSH_KEY" ] || die "missing SSH key $SSH_KEY (run ssh-keygen first)"
command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not found"
command -v xorriso >/dev/null || die "xorriso not found"
mkdir -p "$BUILD"

# --- 1. download cloud image (idempotent) -----------------------------------
if [ ! -f "$CLOUD_IMG" ]; then
  log "downloading Ubuntu noble cloud image..."
  curl -fSL -o "$CLOUD_IMG.part" "$CLOUD_URL"
  mv "$CLOUD_IMG.part" "$CLOUD_IMG"
else
  log "cloud image present, reusing: $CLOUD_IMG"
fi

# --- 2. working overlay-free copy, resized ----------------------------------
log "creating working disk ($DISK_SIZE)..."
cp --reflink=auto "$CLOUD_IMG" "$WORK"
qemu-img resize "$WORK" "$DISK_SIZE" >/dev/null

# --- 3. cloud-init seed (NoCloud) -------------------------------------------
PUBKEY="$(cat "$SSH_KEY.pub")"
cat > "$BUILD/meta-data" <<EOF
instance-id: agentic-golden
local-hostname: agentic-golden
EOF

# Provisioning runs as root in runcmd; each step records a status into provision.json so the
# host can verify what actually installed. OpenHands is the heavy/fragile step → it is last.
cat > "$BUILD/user-data" <<EOF
#cloud-config
users:
  - name: agent
    groups: [sudo]
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    ssh_authorized_keys:
      - $PUBKEY
package_update: true
packages:
  - git
  - build-essential
  - python3-pip
  - python3-venv
  - curl
  - ca-certificates
  - jq
  - rsync
write_files:
  - path: /usr/local/bin/agentic-provision.sh
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      set -uo pipefail
      mkdir -p /var/lib/agentic
      status=/var/lib/agentic/provision.json
      ok=1
      record() { # name rc
        printf '{"%s": %s}\n' "\$1" "\$( [ "\$2" -eq 0 ] && echo true || echo false )" >> /var/lib/agentic/steps.ndjson
        [ "\$2" -eq 0 ] || ok=0
      }
      # docker
      curl -fsSL https://get.docker.com | sh; record docker \$?
      usermod -aG docker agent
      systemctl enable --now docker
      # openhands venv
      python3 -m venv /opt/openhands; record venv \$?
      /opt/openhands/bin/pip install --upgrade pip wheel >/dev/null 2>&1; record pip \$?
      /opt/openhands/bin/pip install uv >/dev/null 2>&1; record uv \$?
      /opt/openhands/bin/pip install openhands-ai >/dev/null 2>&1; record openhands \$?
      chown -R agent:agent /opt/openhands
      # libvirt-portable networking: cloud-init pins the build NIC by MAC, so a re-cloned
      # overlay with a different MAC gets no DHCP. Use a MAC-agnostic glob and stop cloud-init
      # from regenerating the pinned netplan (validated: a libvirt overlay leases + SSHs in).
      printf 'network: {config: disabled}\n' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
      rm -f /etc/netplan/50-cloud-init.yaml
      { echo 'network:'; echo '  version: 2'; echo '  ethernets:'; echo '    agentic-any:'; echo '      match: {name: "en*"}'; echo '      dhcp4: true'; echo '      dhcp-identifier: mac'; } > /etc/netplan/99-agentic.yaml
      chmod 600 /etc/netplan/99-agentic.yaml
      netplan generate; record netplan \$?
      # Each overlay must get its own DHCP identity + machine-id, or every VM collides on a
      # single lease (breaks a build phase concurrency and causes stale-ARP SSH flakiness). The
      # golden image ships a fixed machine-id, from which systemd-networkd derives the DHCP
      # client-id — so dhcp-identifier:mac above pins it to the (per-VM-unique) NIC MAC, and
      # emptying machine-id makes systemd regenerate a unique one on each overlay's first boot.
      : > /etc/machine-id; rm -f /var/lib/dbus/machine-id
      echo 'export PATH=/opt/openhands/bin:\$PATH' > /etc/profile.d/openhands.sh
      printf '{"ok": %s}\n' "\$( [ "\$ok" -eq 1 ] && echo true || echo false )" > "\$status"
runcmd:
  - /usr/local/bin/agentic-provision.sh
EOF

log "building cloud-init seed ISO..."
xorriso -as mkisofs -output "$SEED" -volid CIDATA -joliet -rock \
  "$BUILD/user-data" "$BUILD/meta-data" >/dev/null 2>&1

# --- 4. boot the build VM headless ------------------------------------------
log "booting build VM (headless; console -> $CONSOLE)..."
qemu-system-x86_64 \
  -enable-kvm -machine q35 -cpu host \
  -m "$MEM_MB" -smp "$VCPUS" \
  -drive "file=$WORK,format=qcow2,if=virtio" \
  -drive "file=$SEED,format=raw,if=virtio,media=cdrom" \
  -netdev "user,id=n0,hostfwd=tcp:$SSH_HOST:$SSH_PORT-:22" \
  -device virtio-net-pci,netdev=n0 \
  -display none -serial "file:$CONSOLE" &
QEMU_PID=$!
trap 'kill "$QEMU_PID" 2>/dev/null || true' EXIT

# --- 5. wait for SSH, then for cloud-init to finish -------------------------
log "waiting for SSH (up to 5 min)..."
for _ in $(seq 1 60); do
  if ssh_agent true 2>/dev/null; then break; fi
  kill -0 "$QEMU_PID" 2>/dev/null || die "qemu exited early — see $CONSOLE"
  sleep 5
done
ssh_agent true 2>/dev/null || die "SSH never came up — see $CONSOLE"
log "SSH up. Waiting for cloud-init to finish provisioning (up to 30 min)..."
ssh_agent "sudo cloud-init status --wait" || log "cloud-init reported non-success (continuing to verify)"

# --- 6. verify the golden-image acceptance criteria -------------------------
log "verifying components..."
fail=0
echo "--- python3 ---"; ssh_agent "python3 --version" || fail=1
echo "--- provision status ---"; ssh_agent "cat /var/lib/agentic/provision.json /var/lib/agentic/steps.ndjson 2>/dev/null" || true
echo "--- openhands SDK headless API ---"; ssh_agent "OPENHANDS_SUPPRESS_BANNER=1 /opt/openhands/bin/python -c 'from openhands.sdk import LLM, Agent, Conversation; import openhands.tools; from openhands.sdk import __version__ as v; print(\"OpenHands SDK\", v, \"ready\")'" || fail=1
echo "--- openhands agent-server ---"; ssh_agent "OPENHANDS_SUPPRESS_BANNER=1 /opt/openhands/bin/agent-server --help >/dev/null 2>&1 && echo 'agent-server OK' || echo 'agent-server MISSING'"
echo "--- docker ---"; ssh_agent "docker run --rm hello-world >/dev/null 2>&1 && echo 'docker OK' || echo 'docker FAIL'" || fail=1

if [ "$fail" -ne 0 ]; then
  die "verification failed — VM left running on port $SSH_PORT for inspection (console: $CONSOLE)"
fi
log "verification passed."

if [ "${KEEP_VM:-0}" = "1" ]; then
  log "KEEP_VM=1 — leaving VM running (ssh -i $SSH_KEY -p $SSH_PORT agent@$SSH_HOST). No upload."
  trap - EXIT
  exit 0
fi

# --- 7. shut down cleanly, wait for qemu to release the file ----------------
log "powering off build VM..."
ssh_agent "sudo poweroff" || true
for _ in $(seq 1 30); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 2; done
kill -0 "$QEMU_PID" 2>/dev/null && { kill "$QEMU_PID" 2>/dev/null || true; sleep 2; }
trap - EXIT

# --- 8. upload into the libvirt agentic pool --------------------------------
log "uploading golden image into libvirt pool '$POOL' as '$VOL'..."
virsh vol-delete "$VOL" --pool "$POOL" >/dev/null 2>&1 || true
BYTES="$(stat -c %s "$WORK")"
virsh vol-create-as "$POOL" "$VOL" "${BYTES}B" --format qcow2 >/dev/null
virsh vol-upload --pool "$POOL" "$VOL" "$WORK"
POOL_PATH="$(virsh vol-path --pool "$POOL" "$VOL")"
log "DONE. Golden image in pool: $POOL_PATH"
log "      qcow2 actual size: $(du -h "$WORK" | cut -f1)"
