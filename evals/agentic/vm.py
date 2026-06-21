#!/usr/bin/env python3
"""vm.py — host-side controller for ephemeral, isolated work VMs.

Each session runs in a fresh qcow2 overlay off the golden base (libvirt `agentic` pool),
booted as a *transient* libvirt domain on the default NAT network with a per-profile
nwfilter applied. The VM is the security boundary (see PLAN.md): no host FS mounts,
host + LAN blocked, public egress per profile, ephemeral overlay reverted per session.
All host<->VM interaction is host-initiated over SSH (never a guest-mounted host dir).

Profiles (egress):
  open       (default) public internet reachable; the host's own services and the whole
             RFC1918 / link-local LAN are blocked (the VM must not reach host ports or
             nearby devices even though it can reach the internet).
  restricted new TCP/UDP/ICMP egress is dropped; only the host allowlist proxy (a new TCP
             connection to it) is reachable, so pip/git/your provider traffic goes through the proxy,
             which enforces a domain allowlist. SOFT control: an allowed domain can still be a
             tunnel, and a *crafted non-SYN TCP* packet isn't dropped (no handshake completes).
             Satisfies the "private repo" opt-in intent, not a hard exfil guarantee.
  none       new TCP/UDP/ICMP egress is dropped; only DHCP (so it leases) + inbound host SSH.
             Near-airgapped (your provider unreachable → a test/airgap profile, not a usable session
             mode); same crafted-non-SYN-TCP residual as restricted — a soft control, not a
             cryptographic airgap.

Why these mechanisms: nwfilter is applied by libvirtd, so it needs no sudo (same reason the
pool volume ops work). The gateway 192.168.122.1 is both the host and the DNS resolver, so the
open filter must allow DNS/DHCP to it, then drop every *other* port on it (else host services
are exposed), then drop the rest of RFC1918/link-local, then allow the public internet — in
that order.

CLI (stateless — every call rediscovers the domain IP from its DHCP lease):
  vm.py up    --name N [--egress open|restricted|none] [--mem MB] [--vcpus K]
  vm.py run   --name N -- CMD ...
  vm.py put   --name N --src DIR [--dest workspace]
  vm.py get   --name N --src PATH --dest LOCAL
  vm.py branch --name N [--workdir workspace] --out FILE.bundle
  vm.py snapshot --name N --tag T          # live disk checkpoint (crash-safety; resume in a build phase)
  vm.py revert  --name N                   # discard the overlay -> pristine base
  vm.py destroy --name N
  vm.py reap                               # kill/clean orphaned agentic-* domains, overlays, proxy
"""
import argparse
import fcntl
import os
import shlex
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

POOL = "agentic"
BASE_VOL = "base.qcow2"
NET = "default"
GW = "192.168.122.1"          # libvirt default-net gateway == this host == the guest's DNS resolver
PROXY_PORT = 18080            # host allowlist proxy (restricted profile)
SSH_USER = "agent"
HERE = os.path.dirname(os.path.abspath(__file__))
SSH_KEY = os.path.join(HERE, "ssh", "agent_id_ed25519")
PROXY_PY = os.path.join(HERE, "egress_proxy.py")
# inference host (LLM_BASE_URL host wins, else LLM_UPSTREAM_HOST); added to the allowlist only when
# set — the local lane needs none.
_UPSTREAM = urlsplit(os.environ["LLM_BASE_URL"]).hostname if os.environ.get("LLM_BASE_URL") \
    else os.environ.get("LLM_UPSTREAM_HOST")
ALLOWLIST = "pypi.org,files.pythonhosted.org,github.com,codeload.github.com," \
            "objects.githubusercontent.com,raw.githubusercontent.com" \
            + ("," + _UPSTREAM if _UPSTREAM else "")  # inference host (restricted profile)

SSH_OPTS = [
    "-i", SSH_KEY, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
    "-o", "ConnectTimeout=10", "-o", "LogLevel=ERROR",
]


def sh(cmd, check=True, capture=False, input_=None):
    """Run a host command (list form). Returns CompletedProcess."""
    return subprocess.run(
        cmd, check=check, text=True, input=input_,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def virsh(*args, check=True, capture=True):
    return sh(["virsh", *args], check=check, capture=capture)


def dom(name):
    return f"agentic-{name}"


def overlay(name):
    return f"agentic-{name}.qcow2"


# --- networking ------------------------------------------------------------------

def _filter_xml(profile):
    """nwfilter XML for an egress profile (lower priority number = evaluated first).

    The gateway 192.168.122.1 is the host, the DNS resolver, AND the next hop, and host->VM
    SSH/rsync *replies* are destined to it — so we can neither blanket-drop gateway traffic
    (that hangs the whole control plane) nor blanket-accept it (that exposes host services).
    Instead we drop only the connections the VM *initiates* to the host (TCP SYN-only packets +
    UDP) and accept the remaining host-bound traffic, which is the return path of host-initiated
    sessions (SSH/rsync ACKs). We deliberately do NOT filterref clean-traffic: it embeds a
    gateway accept that would expose host services. Anti-spoof is a a build phase multi-tenant concern;
    our drops match by destination, so a spoofed source can't bypass them."""
    rules = [
        # ARP must flow both ways or the host can't resolve the VM's MAC (DHCP leases without it,
        # but every IP packet afterwards needs it — missing this is what broke the drop-all
        # profiles: the VM leased an IP but answered no ARP, so host->VM SSH got "no route").
        "  <rule action='accept' direction='inout' priority='40'><arp/></rule>",
        # DHCP DISCOVER/REQUEST are broadcast, so match the server port (not the gateway IP) or
        # the drop-all (restricted/none) profiles never lease.
        "  <rule action='accept' direction='out' priority='50'><udp dstportstart='67' dstportend='67'/></rule>",
    ]
    if profile == "open":
        # DNS to the gateway resolver (NEW queries)
        rules.append(f"  <rule action='accept' direction='out' priority='60'><udp dstipaddr='{GW}' dstportstart='53' dstportend='53'/></rule>")
        rules.append(f"  <rule action='accept' direction='out' priority='61'><tcp dstipaddr='{GW}' dstportstart='53' dstportend='53'/></rule>")
    if profile == "restricted":
        # the host allowlist proxy is the only host port the VM may NEWLY connect to
        rules.append(f"  <rule action='accept' direction='out' priority='90'><tcp dstipaddr='{GW}' dstportstart='{PROXY_PORT}' dstportend='{PROXY_PORT}'/></rule>")
    # The host-block + LAN/internet-block work by dropping only the FIRST packet of a NEW
    # VM-initiated connection (TCP SYN-only, matched by flags='SYN,ACK/SYN', plus UDP). Replies
    # to host-initiated sessions are SYN+ACK/ACK, never SYN-only, so they fall through to the
    # final accept-all — and that <all/> accept is the ONLY reliable return path: an
    # <ip dstipaddr=gateway> accept does NOT match the VM's replies to the host (verified — ICMP
    # and TCP to the gateway are dropped despite such a rule), whereas <all/> does. So we must
    # never blanket-drop the gateway or its /16 (that would kill the SSH return) — SYN-drop them.
    syn = "flags='SYN,ACK/SYN'"
    rules.append(f"  <rule action='drop' direction='out' priority='100'><tcp dstipaddr='{GW}' {syn}/></rule>")
    rules.append(f"  <rule action='drop' direction='out' priority='101'><udp dstipaddr='{GW}'/></rule>")
    if profile == "open":
        # block NEW connections to the private LAN + link-local; allow the public internet. The
        # gateway lives in 192.168/16, so SYN-drop that range (don't blanket-drop -> would kill
        # the SSH return); the other ranges carry no host-initiated sessions, so blanket-drop.
        rules.append("  <rule action='drop' direction='out' priority='300'><ip dstipaddr='10.0.0.0' dstipmask='8'/></rule>")
        rules.append("  <rule action='drop' direction='out' priority='301'><ip dstipaddr='172.16.0.0' dstipmask='12'/></rule>")
        rules.append("  <rule action='drop' direction='out' priority='302'><ip dstipaddr='169.254.0.0' dstipmask='16'/></rule>")
        rules.append(f"  <rule action='drop' direction='out' priority='303'><tcp dstipaddr='192.168.0.0' dstipmask='16' {syn}/></rule>")
        rules.append("  <rule action='drop' direction='out' priority='304'><udp dstipaddr='192.168.0.0' dstipmask='16'/></rule>")
    else:
        # restricted/none: block NEW connections to EVERYTHING (restricted's proxy is allowed at
        # priority 90 above; return traffic is not SYN-only and reaches the accept-all). ICMP must
        # be dropped explicitly — it matches none of the SYN/UDP drops and would otherwise hit the
        # accept-all, leaving an open bidirectional ICMP-tunnel exfil channel out of the VM. The
        # remaining residual is a *crafted* non-SYN TCP packet (no handshake completes, so it is
        # not a normal channel): these profiles are a soft egress control, not a cryptographic
        # airgap.
        rules.append(f"  <rule action='drop' direction='out' priority='200'><tcp {syn}/></rule>")
        rules.append("  <rule action='drop' direction='out' priority='201'><udp/></rule>")
        rules.append("  <rule action='drop' direction='out' priority='202'><icmp/></rule>")
    rules.append("  <rule action='accept' direction='out' priority='500'><all/></rule>")
    name = {"open": "agentic-open", "restricted": "agentic-restricted", "none": "agentic-none"}[profile]
    return f"<filter name='{name}' chain='root'>\n" + "\n".join(rules) + "\n</filter>\n"


def _define_filter(profile):
    name = {"open": "agentic-open", "restricted": "agentic-restricted", "none": "agentic-none"}[profile]
    # Redefine idempotently: nwfilter-define won't replace an existing name on some libvirt
    # versions, so undefine first (harmless if absent; fails harmlessly while a concurrent
    # domain still binds it, in which case we keep whatever definition is already live).
    virsh("nwfilter-undefine", name, check=False)
    xml = _filter_xml(profile)
    with tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False) as f:
        f.write(xml)
        path = f.name
    try:
        r = virsh("nwfilter-define", path, check=False)
    finally:
        os.unlink(path)
    if r.returncode != 0 and name not in (virsh("nwfilter-list", check=False).stdout or ""):
        raise SystemExit(f"nwfilter-define {name} failed: {r.stderr}")
    return name


def _port_open(host, port):
    import socket
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(1)
        return s.connect_ex((host, int(port))) == 0


def _ensure_proxy():
    """Start the host allowlist proxy if it isn't already listening."""
    if _port_open(GW, PROXY_PORT):
        return
    log = open(os.path.join(HERE, "build", "egress_proxy.log"), "ab")
    subprocess.Popen(
        [sys.executable, PROXY_PY, "--host", GW, "--port", str(PROXY_PORT), "--allow", ALLOWLIST],
        stdout=log, stderr=log, start_new_session=True,
    )
    for _ in range(20):
        if _port_open(GW, PROXY_PORT):
            return
        time.sleep(0.5)
    raise SystemExit("egress proxy failed to start")


# --- lifecycle -------------------------------------------------------------------

def _mac(name):
    out = virsh("domiflist", dom(name), check=False).stdout or ""
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 5 and ":" in parts[4]:
            return parts[4]
    return None


def _ip(name, wait=0):
    """Resolve the domain's IP from its DHCP lease; optionally wait up to `wait` seconds."""
    mac = _mac(name)
    if not mac:
        return None
    deadline = time.time() + wait
    while True:
        out = virsh("net-dhcp-leases", NET, check=False).stdout or ""
        for line in out.splitlines():
            if mac in line:
                for tok in line.split():
                    if "/" in tok and tok[0].isdigit():
                        return tok.split("/")[0]
        if time.time() >= deadline:
            return None
        time.sleep(3)


def ssh(name, command, check=False, capture=True, timeout=None):
    ip = _ip(name)
    if not ip:
        raise SystemExit(f"{dom(name)}: no IP (not running?)")
    cmd = ["ssh", *SSH_OPTS, f"{SSH_USER}@{ip}", command]
    return subprocess.run(cmd, text=True, check=check, timeout=timeout,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.STDOUT if capture else None)


def up(name, egress="open", mem=4096, vcpus=4):
    if egress == "restricted":
        _ensure_proxy()
    # Serialize the boot-critical section across concurrent dispatcher children (a build phase). The
    # nwfilter is redefined under a shared per-profile name (undefine+define); a peer's undefine
    # landing between our define and the virt-install that *binds* the filter would fail the boot.
    # An fcntl lock (cross-process — children are separate run_session.py processes) is held only
    # for these few seconds; the slow DHCP/SSH waits below run fully concurrently. Once virt-install
    # returns, our domain references the filter, so a peer's undefine fails harmlessly thereafter.
    with open(os.path.join(HERE, "build", ".vm-up.lock"), "w") as _lk:
        fcntl.flock(_lk, fcntl.LOCK_EX)
        filt = _define_filter(egress)
        # fresh overlay off the golden base
        virsh("vol-create-as", POOL, overlay(name), "30G", "--format", "qcow2",
              "--backing-vol", BASE_VOL, "--backing-vol-format", "qcow2")
        sh(["virt-install", "--import", "--name", dom(name),
            "--memory", f"{mem},maxmemory={mem}", "--vcpus", str(vcpus),
            "--disk", f"vol={POOL}/{overlay(name)},bus=virtio",
            "--network", f"network={NET},filterref={filt}",
            "--osinfo", "detect=on,require=off",
            "--graphics", "none", "--noautoconsole", "--transient"])
    ip = _ip(name, wait=120)
    if not ip:
        raise SystemExit(f"{dom(name)}: no DHCP lease in 120s")
    for _ in range(20):
        if ssh(name, "true").returncode == 0:
            break
        time.sleep(3)
    else:
        raise SystemExit(f"{dom(name)}: SSH never came up at {ip}")
    if egress == "restricted":
        proxy = f"http://{GW}:{PROXY_PORT}"
        env = (f"http_proxy={proxy}\nhttps_proxy={proxy}\n"
               f"HTTP_PROXY={proxy}\nHTTPS_PROXY={proxy}\n")
        ssh(name, f"echo {shlex.quote(env)} | sudo tee -a /etc/environment >/dev/null")
    print(f"{dom(name)} up at {ip} (egress={egress})")
    return ip


def _delete_vols(name):
    """Delete every pool volume for this VM — the overlay AND any disk-snapshot overlays. The
    trailing dot in the prefix keeps `name` from matching a different VM whose name shares a
    prefix (e.g. deleting 'sn' must not touch 'sn2')."""
    out = virsh("vol-list", POOL, check=False).stdout or ""
    pfx = f"agentic-{name}."
    for line in out.splitlines():
        v = line.split()[0] if line.split() else ""
        if v != BASE_VOL and v.startswith(pfx):
            virsh("vol-delete", v, "--pool", POOL, check=False)


def destroy(name):
    virsh("destroy", dom(name), check=False)
    virsh("undefine", dom(name), check=False)          # no-op for transient, safe otherwise
    _delete_vols(name)


def revert(name, egress="open", mem=4096, vcpus=4):
    """Discard the overlay (and any snapshots) and recreate a pristine VM off the base."""
    destroy(name)
    return up(name, egress=egress, mem=mem, vcpus=vcpus)


def snapshot(name, tag):
    """Live disk checkpoint for crash-safety: an external, disk-only libvirt snapshot. qemu
    freezes the current overlay as the checkpoint and writes onward to a fresh top overlay, so a
    crash leaves the snapshot recoverable on disk (vol-clone can't do this — qemu holds a write
    lock on the live overlay). Primary session resumability is git-branch checkpoints (PLAN.md);
    rolling a running VM back onto a snapshot is wired in a build phase."""
    virsh("snapshot-create-as", dom(name), tag, "--disk-only", "--atomic", "--no-metadata")
    print(f"snapshot {dom(name)}@{tag}")


def put_repo(name, src, dest="workspace"):
    ip = _ip(name)
    ssh(name, f"mkdir -p {shlex.quote(dest)}")
    rsync_e = "ssh " + " ".join(shlex.quote(o) for o in SSH_OPTS)
    sh(["rsync", "-a", "--delete", "-e", rsync_e,
        src.rstrip("/") + "/", f"{SSH_USER}@{ip}:{dest}/"])
    print(f"put {src} -> {dom(name)}:{dest}")


def get_files(name, src, dest):
    ip = _ip(name)
    rsync_e = "ssh " + " ".join(shlex.quote(o) for o in SSH_OPTS)
    sh(["rsync", "-a", "-e", rsync_e, f"{SSH_USER}@{ip}:{src}", dest])
    print(f"get {dom(name)}:{src} -> {dest}")


def get_branch(name, out, workdir="workspace"):
    """Extract all git refs as a bundle (the reviewable result of a session)."""
    r = ssh(name, f"cd {shlex.quote(workdir)} && git bundle create /tmp/agentic.bundle --all")
    if r.returncode != 0:
        raise SystemExit(f"git bundle failed: {r.stdout}")
    get_files(name, "/tmp/agentic.bundle", out)
    print(f"branch bundle -> {out}")


def reap():
    """Kill/clean any leftover agentic-* domains + overlays, and the proxy if unused."""
    out = virsh("list", "--all", "--name", check=False).stdout or ""
    names = [n for n in out.split() if n.startswith("agentic-")]
    for d in names:
        print(f"reaping {d}")
        virsh("destroy", d, check=False)
        virsh("undefine", d, check=False)
    vols = (virsh("vol-list", POOL, check=False).stdout or "").splitlines()
    for line in vols:
        v = line.split()[0] if line.split() else ""
        # overlays (agentic-<name>.qcow2) and disk-snapshot overlays (agentic-<name>.<tag>)
        if v.startswith("agentic-") and v != BASE_VOL:
            virsh("vol-delete", v, "--pool", POOL, check=False)
            print(f"deleted overlay {v}")
    if not names and _port_open(GW, PROXY_PORT):
        subprocess.run(["pkill", "-f", "egress_proxy.py"], check=False)
        print("stopped egress proxy")


def main():
    p = argparse.ArgumentParser(description="ephemeral isolated work-VM controller")
    sub = p.add_subparsers(dest="cmd", required=True)

    def add_name(sp):
        sp.add_argument("--name", required=True)

    sp = sub.add_parser("up"); add_name(sp)
    sp.add_argument("--egress", default="open", choices=["open", "restricted", "none"])
    sp.add_argument("--mem", type=int, default=4096); sp.add_argument("--vcpus", type=int, default=4)
    sp = sub.add_parser("run"); add_name(sp); sp.add_argument("argv", nargs=argparse.REMAINDER)
    sp = sub.add_parser("put"); add_name(sp); sp.add_argument("--src", required=True); sp.add_argument("--dest", default="workspace")
    sp = sub.add_parser("get"); add_name(sp); sp.add_argument("--src", required=True); sp.add_argument("--dest", required=True)
    sp = sub.add_parser("branch"); add_name(sp); sp.add_argument("--workdir", default="workspace"); sp.add_argument("--out", required=True)
    sp = sub.add_parser("snapshot"); add_name(sp); sp.add_argument("--tag", required=True)
    sp = sub.add_parser("revert"); add_name(sp); sp.add_argument("--egress", default="open", choices=["open", "restricted", "none"])
    sp = sub.add_parser("destroy"); add_name(sp)
    sub.add_parser("reap")

    a = p.parse_args()
    if a.cmd == "up":
        up(a.name, a.egress, a.mem, a.vcpus)
    elif a.cmd == "run":
        argv = a.argv[1:] if a.argv and a.argv[0] == "--" else a.argv
        # shlex.join so a compound command (e.g. `bash -lc 'a && b'`) survives the round-trip:
        # the remote shell re-parses the string back into these exact tokens.
        r = ssh(a.name, shlex.join(argv), capture=False)
        sys.exit(r.returncode)
    elif a.cmd == "put":
        put_repo(a.name, a.src, a.dest)
    elif a.cmd == "get":
        get_files(a.name, a.src, a.dest)
    elif a.cmd == "branch":
        get_branch(a.name, a.out, a.workdir)
    elif a.cmd == "snapshot":
        snapshot(a.name, a.tag)
    elif a.cmd == "revert":
        revert(a.name, a.egress)
    elif a.cmd == "destroy":
        destroy(a.name)
    elif a.cmd == "reap":
        reap()


if __name__ == "__main__":
    main()
