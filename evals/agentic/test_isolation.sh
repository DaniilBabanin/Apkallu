#!/usr/bin/env bash
# test_isolation.sh — prove the work VM is a real boundary (PLAN.md a build phase must-pass).
#
# Checks, against a live VM driven by vm.py:
#   FS        no host FS passthrough (no 9p/virtiofs mounts).
#   open      public internet reachable; the host's own services AND the RFC1918/link-local
#             LAN unreachable (a real listener is started on the host and proven unreachable
#             from the VM — both via the gateway IP and the host's LAN IP).
#   restricted only the allowlist proxy works (pypi OK, example.com 403); direct egress dropped.
#   none      no egress at all, but host->VM SSH still works.
#   revert    discarding the overlay wipes session state (a marker file is gone after revert).
#   forkbomb  guest fork pressure leaves the HOST process count steady (the security property;
#             a host cgroup can't limit guest-internal forks — the VM boundary + RAM cap do).
#   disk      the guest disk is capped (~30G), so a disk-fill can't exhaust the host's free space.
#
# Exit 0 = all green. Any FAIL -> exit 1.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
VM=iso
KEY=ssh/agent_id_ed25519
PORT=18099            # throwaway host listener used to prove host services are unreachable
HTTP_PID=""
fail=0

ok()   { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }
check(){ if [ "$1" = "$2" ]; then ok "$3 ($1)"; else bad "$3 (got '$1' want '$2')"; fi; }

ip_of() {
  local mac; mac=$(virsh domiflist "agentic-$VM" 2>/dev/null | awk '/network/{print $5}')
  virsh net-dhcp-leases default 2>/dev/null | awk -v m="$mac" '$0 ~ m {print $5}' | cut -d/ -f1
}
ssh_vm() {
  ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 -o LogLevel=ERROR "agent@$(ip_of)" "$@"
}
# curl in the guest -> prints the HTTP code (000 if no response). $1=url, rest=extra curl args.
http_code() { local url="$1"; shift; ssh_vm "curl -s -m 12 -o /dev/null -w '%{http_code}' $* '$url' 2>/dev/null; true"; }

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null
  ./vm.py destroy --name "$VM" >/dev/null 2>&1
  pkill -f egress_proxy.py 2>/dev/null
}
trap cleanup EXIT

is_rfc1918() { case "$1" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0;; *) return 1;; esac; }
HOST_LAN=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')

echo "===== boot (egress=open) ====="
./vm.py up --name "$VM" --egress open || { echo "boot failed"; exit 1; }

echo "===== FS isolation ====="
mounts=$(ssh_vm "mount | grep -Ec '9p|virtiofs' || true")
check "${mounts:-0}" "0" "no host FS passthrough mounts"

echo "===== open: public internet reachable ====="
check "$(http_code https://example.com)" "200" "open: example.com reachable (DNS+egress)"

echo "===== open: host + LAN unreachable ====="
python3 -m http.server "$PORT" --bind 0.0.0.0 >/dev/null 2>&1 &
HTTP_PID=$!
sleep 1
# the host's own service via the gateway IP must be refused/timed out
c=$(http_code "http://192.168.122.1:$PORT")
if [ "$c" != "200" ]; then ok "open: host service via gateway blocked ($c)"; else bad "open: host service via gateway REACHABLE"; fi
# and via the host's real LAN IP (nearby-device surface)
if [ -n "$HOST_LAN" ] && is_rfc1918 "$HOST_LAN"; then
  c=$(http_code "http://$HOST_LAN:$PORT")
  if [ "$c" != "200" ]; then ok "open: host service via LAN IP $HOST_LAN blocked ($c)"; else bad "open: host service via LAN IP REACHABLE"; fi
else
  echo "SKIP: host LAN IP '$HOST_LAN' not RFC1918 — gateway test covers host"
fi

echo "===== disk cap (host can't be filled) ====="
groot=$(ssh_vm "df -BG --output=size / | tail -1 | tr -dc 0-9")
hfree=$(df -BG --output=avail . | tail -1 | tr -dc 0-9)
if [ "${groot:-999}" -le 31 ] && [ "${hfree:-0}" -gt 100 ]; then
  ok "disk capped: guest=${groot}G, host free=${hfree}G"
else
  bad "disk cap (guest=${groot}G host_free=${hfree}G)"
fi

echo "===== vCPU / RAM caps (libvirt-enforced) ====="
gcpu=$(ssh_vm "nproc")
gmem=$(ssh_vm "awk '/MemTotal/{print int(\$2/1024)}' /proc/meminfo")
if [ "${gcpu:-99}" -le 4 ] && [ "${gmem:-99999}" -le 4200 ]; then
  ok "vCPU/RAM capped (guest sees ${gcpu} cpu, ${gmem}MB RAM)"
else
  bad "vCPU/RAM cap (cpu=${gcpu} mem=${gmem}MB)"
fi

echo "===== marker for revert test ====="
if ssh_vm "touch /home/agent/MARKER && ls /home/agent/MARKER" >/dev/null; then ok "marker created"; else bad "marker create"; fi

echo "===== revert -> restricted (also proves overlay wipe) ====="
./vm.py revert --name "$VM" --egress restricted || bad "revert to restricted"
m=$(ssh_vm "test -e /home/agent/MARKER && echo present || echo gone")
check "$m" "gone" "revert wiped session state (marker)"
check "$(http_code https://pypi.org/simple/)" "200" "restricted: pypi reachable via proxy"
ec=$(http_code https://example.com)
if [ "$ec" != "200" ]; then ok "restricted: example.com denied by allowlist (code=$ec)"; else bad "restricted: example.com not denied (got $ec)"; fi
dc=$(ssh_vm "curl -s -m 6 --noproxy '*' -o /dev/null https://1.1.1.1 >/dev/null 2>&1; echo \$?")
if [ "$dc" != "0" ]; then ok "restricted: direct (non-proxy) egress dropped (rc=$dc)"; else bad "restricted: direct egress NOT dropped"; fi

echo "===== revert -> none ====="
./vm.py revert --name "$VM" --egress none || bad "revert to none"
nc=$(ssh_vm "curl -s -m 8 -o /dev/null https://example.com >/dev/null 2>&1; echo \$?")
if [ "$nc" != "0" ]; then ok "none: TCP egress blocked (rc=$nc)"; else bad "none: TCP egress NOT blocked"; fi
# ICMP is not a new-TCP/UDP connection, so it must be dropped explicitly or it tunnels out.
ic=$(ssh_vm "ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; echo \$?")
if [ "$ic" != "0" ]; then ok "none: ICMP egress blocked (rc=$ic)"; else bad "none: ICMP egress NOT blocked (exfil channel)"; fi
if ssh_vm true >/dev/null 2>&1; then ok "none: host->VM SSH still works"; else bad "none: SSH broken"; fi

echo "===== fork-bomb containment (host unaffected) ====="
hb=$(ps -e --no-headers | wc -l)
ssh_vm "ulimit -u 2000; timeout 8 bash -c ':(){ :|:& };:' >/dev/null 2>&1; true" >/dev/null 2>&1 || true
sleep 2
ha=$(ps -e --no-headers | wc -l)
delta=$(( ha > hb ? ha - hb : hb - ha ))
if [ "$delta" -lt 60 ]; then ok "host process count steady across guest fork bomb (${hb}->${ha})"; else bad "host procs moved ${hb}->${ha}"; fi

echo
if [ "$fail" -eq 0 ]; then echo "ISOLATION: ALL PASS"; else echo "ISOLATION: FAILURES PRESENT"; fi
exit "$fail"
