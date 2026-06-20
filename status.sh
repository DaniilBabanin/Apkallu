#!/usr/bin/env bash
# status.sh — one-glance agency status: what runs, for how long, what waits on the director.
#
# Sections:
#   RUNNING            scheduler/loop/cascade/worker-claude processes with uptime
#   VMS                agentic-* KVM work VMs (running, mem, egress), pool overlays, inference proxy
#   ACTIVE UNITS       current_tasks/*.claim — claimed cascade units, age, dispatcher liveness
#   NEXT UP            first unclaimed open backlog task + open/done counts
#   QUESTIONS WAITING  director/DECISIONS.md entries with an empty **Answer:** OR a
#                      system-picked default the director hasn't confirmed (convention:
#                      director answers contain "director" or "RESOLVED")
#   RECENT             last commit, last scheduler log line, working-tree dirt
#
# Known limit: run from a sandboxed shell (PID namespace) RUNNING can't see host processes;
# the scheduler flock check still works across namespaces, so a held lock = scheduler alive.
#
# Plain stdout, no colors, no args — same output for the director, claude, and the TUI.
#
# Usage: ./status.sh
# Env:
#   STATUS_REPO  operate on this repo instead of the script's own (tests / fixtures)
#   STATE_DIR    scheduler lock + log dir (same default as loop/scheduler.sh)
# Exit: 0 always — status reporting must never fail its caller.

set -euo pipefail

_STATUS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${STATUS_REPO:-$_STATUS_SCRIPT_DIR}"
cd "$REPO_DIR"

# PG glue (best-effort: PG_AVAIL=0 when PG is down — QUEUE section degrades silently)
# shellcheck source=lib/pg.sh
source "$_STATUS_SCRIPT_DIR/lib/pg.sh" 2>/dev/null || true

STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agency-scheduler}"
NOW_EPOCH="$(date +%s)"

# seconds -> compact duration: 45s · 12m · 3h12m · 2d7h
fmt_dur() {
  local s="$1"
  if [ "$s" -ge 86400 ]; then printf '%dd%dh' "$((s / 86400))" "$((s % 86400 / 3600))"
  elif [ "$s" -ge 3600 ]; then printf '%dh%dm' "$((s / 3600))" "$((s % 3600 / 60))"
  elif [ "$s" -ge 60 ]; then printf '%dm' "$((s / 60))"
  else printf '%ds' "$s"
  fi
}

# truncate to n chars (default 100) with ellipsis
trunc() {
  local s="$1" n="${2:-100}"
  if [ "${#s}" -gt "$n" ]; then printf '%s...' "${s:0:n}"; else printf '%s' "$s"; fi
}

# print one line per live process matching an ERE: "  <label>  pid <p>  up <dur>  [cwd]"
# cwd shown only when it differs from the repo (locates worktree workers).
print_procs() {
  local label="$1" pattern="$2" pid secs cwd suffix found=1
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    secs="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -n "$secs" ] || continue
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    suffix=""
    if [ -n "$cwd" ] && [ "$cwd" != "$REPO_DIR" ]; then suffix="  ($cwd)"; fi
    printf '  %-14s pid %-7s up %s%s\n' "$label" "$pid" "$(fmt_dur "$secs")" "$suffix"
    found=0
  done < <(pgrep -f "$pattern" 2>/dev/null || true)
  return "$found"
}

# The agentic KVM work VMs (evals/agentic): running domains + mem + egress profile, pool overlays
# (orphan/disk indicator), and the key-off-VM inference proxy. Best-effort — no libvirt, or any
# virsh hiccup, degrades cleanly (caller runs this as `print_vms || true`, so it can't abort status).
print_vms() {
  echo
  echo "VMS"
  if ! command -v virsh >/dev/null 2>&1; then echo "  (libvirt unavailable)"; return 0; fi
  local dom xml mem_kib vcpu egress mem ovl proxy n=0
  while IFS= read -r dom; do
    case "$dom" in agentic-*) ;; *) continue ;; esac
    n=$((n + 1))
    xml="$(virsh dumpxml "$dom" 2>/dev/null || true)"
    mem_kib="$(grep -oE "<memory unit='KiB'>[0-9]+" <<<"$xml" | grep -oE '[0-9]+$' | head -1)"
    vcpu="$(grep -oE '<vcpu[^>]*>[0-9]+' <<<"$xml" | grep -oE '[0-9]+$' | head -1)"
    egress="$(grep -oE 'agentic-(open|restricted|none)' <<<"$xml" | head -1 | sed 's/agentic-//')"
    if [ -n "$mem_kib" ]; then mem="$((mem_kib / 1024))MB"; else mem="?"; fi
    printf '  %-16s running  %-7s %svcpu  egress=%s\n' "$dom" "$mem" "${vcpu:-?}" "${egress:-?}"
  done < <(virsh list --name 2>/dev/null || true)
  [ "$n" -eq 0 ] && echo "  none running."
  ovl="$(virsh vol-list agentic 2>/dev/null | grep -cE 'agentic-.*\.qcow2' || true)"
  proxy="down"; if (exec 3<>/dev/tcp/127.0.0.1/18081) 2>/dev/null; then proxy="up"; fi
  printf '  overlays: %s in pool · proxy(:18081): %s\n' "${ovl:-0}" "$proxy"
}

echo "agency status — $(date '+%F %H:%M')"

# --- RUNNING ---------------------------------------------------------------------------------
echo
echo "RUNNING"
running=1
print_procs "scheduler.sh" 'loop/scheduler\.sh' && running=0
print_procs "run.sh" 'loop/run\.sh' && running=0
print_procs "cascade.sh" 'loop/cascade\.sh' && running=0
# headless workers only (-p/--print); the interactive session doesn't match
print_procs "claude -p" '(^|/)claude (.* )?(-p|--print)( |$)' && running=0
if [ "$running" -ne 0 ]; then echo "  idle — nothing running."; fi
# scheduler lock state (flock in scheduler.sh): held = a scheduler is alive somewhere,
# even when its process is invisible (sandboxed PID namespace).
if [ -e "$STATE_DIR/lock" ] && ! flock -n "$STATE_DIR/lock" true 2>/dev/null; then
  echo "  scheduler lock: HELD — a scheduler is alive ($STATE_DIR/lock)"
fi

# --- VMS (agentic KVM work VMs) ----------------------------------------------------------------
print_vms || true

# --- ACTIVE UNITS (cascade claims) -------------------------------------------------------------
echo
echo "ACTIVE UNITS"
claims=0
for f in current_tasks/*.claim; do
  [ -e "$f" ] || continue
  claims=$((claims + 1))
  unit="$(sed -n 's/^unit: //p' "$f")"
  branch="$(sed -n 's/^branch: //p' "$f")"
  ts="$(sed -n 's/^claimed: //p' "$f")"
  pid="$(sed -n 's/^pid: //p' "$f")"
  claim_epoch="$(date -d "$ts" +%s 2>/dev/null || printf '%s' "$NOW_EPOCH")"
  age="$(fmt_dur "$((NOW_EPOCH - claim_epoch))")"
  live="dispatcher gone — stale claim?"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then live="dispatcher alive (pid $pid)"; fi
  task="$(grep -E "<!-- cascade: id=$unit " backlog.md 2>/dev/null \
            | head -1 | sed -e 's/^- \[.\] //' -e 's/<!--.*-->//' -e 's/\*\*//g' || true)"
  printf '  %s  claimed %s ago  branch %s  [%s]\n' "$unit" "$age" "$branch" "$live"
  if [ -n "$task" ]; then printf '    %s\n' "$(trunc "$task")"; fi
done
if [ "$claims" -eq 0 ]; then echo "  none."; fi

# --- QUEUE (PG job queue) -----------------------------------------------------------------------
echo
echo "QUEUE"
if [ "${PG_AVAIL:-0}" = "1" ]; then
  pgq_counts="$(pg_query \
    "SELECT state||': '||count(*)::text FROM jobs GROUP BY state ORDER BY state" \
    || true)"
  if [ -n "$pgq_counts" ]; then
    while IFS= read -r pgq_row; do
      [ -n "$pgq_row" ] && printf '  %s\n' "$pgq_row"
    done <<<"$pgq_counts"
  else
    echo "  (no jobs)"
  fi
  pgq_oldest="$(pg_query \
    "SELECT title FROM jobs WHERE state='queued' ORDER BY created_at LIMIT 1" \
    || true)"
  [ -n "$pgq_oldest" ] && printf '  oldest queued: %s\n' "$(trunc "$pgq_oldest" 80)"
  pgq_flight="$(pg_query \
    "SELECT count(*)::text FROM jobs WHERE state='running'" \
    | tr -d ' ' || true)"
  printf '  leases in flight: %s\n' "${pgq_flight:-0}"
else
  echo "  (PG unavail)"
fi

# --- NEXT UP -----------------------------------------------------------------------------------
echo
echo "NEXT UP"
next=""
while IFS= read -r line; do
  id="$(sed -nE 's/.*<!-- cascade: id=([^ ]+).*/\1/p' <<<"$line")"
  if [ -n "$id" ] && [ -f "current_tasks/$id.claim" ]; then continue; fi
  next="$line"
  break
done < <(grep '^- \[ \]' backlog.md 2>/dev/null || true)
if [ -n "$next" ]; then
  printf '  %s\n' "$(trunc "$(sed -e 's/^- \[ \] //' -e 's/<!--.*-->//' -e 's/\*\*//g' <<<"$next")" 140)"
else
  echo "  backlog empty."
fi
open_n="$(grep -c '^- \[ \]' backlog.md 2>/dev/null || true)"
done_n="$(grep -c '^- \[x\]' backlog.md 2>/dev/null || true)"
printf '  backlog: %s open / %s done\n' "${open_n:-0}" "${done_n:-0}"

# --- QUESTIONS WAITING (unanswered DECISIONS entries) ------------------------------------------
echo
# Two tiers (see header): UNANSWERED = empty answer block · DEFAULTED = answer block carries
# only a system-picked default ("Default picked by ...") with no director resolution marker
# ("DIRECTOR OVERRIDE" / "— director" / "by director" / "RESOLVED").
pending="$(awk '
  function scan(s,  l) {
    l = tolower(s)
    if (l ~ /[^ \t]/) answered = 1
    if (l ~ /default picked by/) defpicked = 1
    if (l ~ /director override|— director|- director|by director|resolved/) bydir = 1
  }
  function flush() {
    if (hdr == "") return
    if (answered == 0) print "UNANSWERED\t" hdr "\t" meta
    else if (defpicked == 1 && bydir == 0) print "DEFAULTED\t" hdr "\t" meta
  }
  /^## D-[0-9]+/ { flush(); hdr = $0; sub(/^## /, "", hdr); meta = ""; inans = 0; answered = 0; defpicked = 0; bydir = 0; next }
  /^\*\*Asked:/ { if (hdr != "") { meta = $0; gsub(/\*\*/, "", meta) } next }
  /^\*\*Answer:\*\*/ {
    inans = 1
    rest = $0; sub(/^\*\*Answer:\*\*[ ]*/, "", rest)
    scan(rest)
    next
  }
  inans == 1 && /^---/ { inans = 0; next }
  inans == 1 { scan($0) }
  END { flush() }
' director/DECISIONS.md 2>/dev/null || true)"
if [ -n "$pending" ]; then
  echo "QUESTIONS WAITING ($(wc -l <<<"$pending" | tr -d ' '))"
  while IFS=$'\t' read -r tier hdr meta; do
    tag=""
    if [ "$tier" = "DEFAULTED" ]; then tag="  [default recorded — override open]"; fi
    printf '  %s%s\n' "$(trunc "$hdr" 120)" "$tag"
    if [ -n "$meta" ]; then printf '    %s\n' "$meta"; fi
  done <<<"$pending"
  echo "  answer: edit director/DECISIONS.md **Answer:** lines"
else
  echo "QUESTIONS WAITING (0)"
  echo "  none — all decisions answered."
fi

# --- RECENT ------------------------------------------------------------------------------------
echo
echo "RECENT"
printf '  last commit: %s\n' "$(git log -1 --format='%h %s (%cr)' 2>/dev/null || echo 'no commits')"
if [ -f "$STATE_DIR/scheduler.log" ]; then
  printf '  scheduler:   %s\n' "$(tail -1 "$STATE_DIR/scheduler.log")"
fi
dirty="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
printf '  working tree: %s changed/untracked file(s)\n' "${dirty:-0}"

exit 0
