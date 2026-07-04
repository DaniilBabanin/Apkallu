#!/usr/bin/env bash
# tui.sh — director cockpit. Full-screen live agency status + control, zero deps.
#
# Built for the director's SSH'd tablet (touch, no DevTools): a single bash
# process, no libraries, refreshes on a timer and on keypress. The data panel is
# `./status.sh` rendered live; the controls drive the existing loop mechanics —
# nothing here owns state, it only invokes scheduler.sh / cascade.sh / decide.sh.
#
# Keys:  s start scheduler (detached)   x stop scheduler+loop   n dispatch next unit
#        r reset a stuck unit   a answer a D-NNN   v ssh into a work VM
#        f follow a work VM's live session events   q quit
# Destructive writes (start/stop/dispatch/reset) ask y/N first — a mistap on a
# tablet must not nuke a live unit. [a]nswer has no extra y/N: it already
# requires typing the D-NNN id and a verdict, so no single mistap can fire it.
#
# Usage: ./tui.sh [-h|--help]
# Env:   COCKPIT_REFRESH   seconds between auto-refreshes (default 5)
#        COCKPIT_SCHED_LOG detached-scheduler log file (default loop/scheduler.log)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

REFRESH="${COCKPIT_REFRESH:-5}"
SCHED_LOG="${COCKPIT_SCHED_LOG:-$REPO_DIR/loop/scheduler.log}"
SSH_KEY="$REPO_DIR/evals/agentic/ssh/agent_id_ed25519"   # [v]ssh / [f]ollow into agentic work VMs

case "${1:-}" in
  -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
esac

if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "tui.sh needs an interactive terminal." >&2
  exit 1
fi

cleanup() {
  tput rmcup 2>/dev/null || true
  tput cnorm 2>/dev/null || true
  stty echo 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Frame-skip state: only write to the terminal when the composed frame changed,
# so an idle loop sends zero bytes over SSH (no flicker, no bandwidth).
LAST_FRAME=""

# Draw the whole frame in ONE pass from cursor-home. No full-screen clear, so there's
# no blank-then-fill flash; each line is overwritten in place and \033[K trims its tail.
render() {
  local rows cols body_n i b header footer hrline frame
  rows="$(tput lines)"
  cols="$(tput cols)"
  header=" AGENCY COCKPIT   $(date '+%F %H:%M')   refresh ${REFRESH}s   q=quit"
  footer=" [s]tart [x]stop [n]dispatch [r]eset [a]nswer [v]ssh [f]ollow  [q]uit"
  hrline="$(printf '%*s' "$cols" '' | tr ' ' '-')"
  body_n=$((rows - 4))
  [ "$body_n" -lt 1 ] && body_n=1
  local body
  mapfile -t body < <(./status.sh 2>/dev/null | head -n "$body_n")
  frame="$(
    printf '\033[H%s\033[K\n' "${header:0:cols}"
    printf '%s\033[K\n' "${hrline:0:cols}"
    for ((i = 0; i < body_n; i++)); do
      b="${body[i]-}"
      printf '%s\033[K\n' "${b:0:cols}"
    done
    printf '%s\033[K\n%s\033[K\033[J' "${hrline:0:cols}" "${footer:0:cols}"
  )"
  [ "$frame" = "$LAST_FRAME" ] && return 0
  LAST_FRAME="$frame"
  printf '%s' "$frame"
}

# read one line of input at the bottom of the screen; echoes what was typed.
prompt_line() {
  local rows ans
  rows="$(tput lines)"
  tput cup $((rows - 1)) 0
  tput el
  tput cnorm
  stty echo
  read -r -p "$1" ans || true
  tput civis
  stty -echo
  printf '%s' "$ans"
}

confirm() {
  local a
  a="$(prompt_line "$1 — confirm? [y/N] ")"
  [ "$a" = "y" ] || [ "$a" = "Y" ]
}

# transient one-line message at the bottom, then a beat to read it.
notify() {
  local rows
  rows="$(tput lines)"
  tput cup $((rows - 1)) 0
  tput el
  printf '%s' "$1"
  sleep 1
  LAST_FRAME=""  # the message dirtied the screen — force a full repaint next cycle
}

act_start() {
  confirm "start scheduler" || { notify "cancelled"; return 0; }
  setsid nohup ./loop/scheduler.sh run >>"$SCHED_LOG" 2>&1 &
  notify "scheduler started (detached) -> $SCHED_LOG"
}

act_stop() {
  confirm "STOP scheduler + loop" || { notify "cancelled"; return 0; }
  # interpreter invocations only — never kill an editor/tail whose cmdline mentions the path
  pkill -f '(^|/)bash [^ ]*loop/scheduler\.sh( |$)' 2>/dev/null || true
  pkill -f '(^|/)bash [^ ]*loop/run\.sh( |$)' 2>/dev/null || true
  notify "stop signal sent"
}

act_dispatch() {
  confirm "dispatch next unit (spends quota)" || { notify "cancelled"; return 0; }
  local out rc=0
  # dispatch returns non-zero for ordinary outcomes (nothing ready etc.) — under set -e a bare
  # assignment would kill the cockpit, so capture the rc and surface it via notify instead.
  out="$(./loop/cascade.sh dispatch 2>&1 | tail -1)" || rc=$?
  notify "dispatch: ${out:-rc=$rc}"
}

act_reset() {
  local id out
  id="$(prompt_line "reset unit id: ")"
  [ -n "$id" ] || { notify "cancelled"; return 0; }
  confirm "reset $id (drops its worktree + branch)" || { notify "cancelled"; return 0; }
  local rc=0
  out="$(./loop/cascade.sh reset "$id" 2>&1 | tail -1)" || rc=$?
  notify "reset: ${out:-rc=$rc}"
}

act_answer() {
  local id verdict note out
  id="$(prompt_line "answer which D-NNN: ")"
  [ -n "$id" ] || { notify "cancelled"; return 0; }
  verdict="$(prompt_line "verdict (yes/no/always/free text): ")"
  [ -n "$verdict" ] || { notify "cancelled"; return 0; }
  note="$(prompt_line "note (optional, enter to skip): ")"
  # apply returns 2 (unknown id) / 3 (already answered) SILENTLY — keep the cockpit alive and
  # show the rc instead of dying on the assignment (set -e).
  local rc=0
  out="$(./local/decide.sh apply "$id" "$verdict" "$note" 2>&1 | tail -1)" || rc=$?
  notify "answered $id: ${out:-rc=$rc}"
}

# Attach to a running agentic work VM: v = interactive shell, f = follow live session events.
# Picks the VM (auto if one, else prompt), resolves its IP via vm._ip (single source of truth),
# drops out of the cockpit for the ssh, restores after. Every path returns 0 and forces a repaint,
# so a missing VM / refused ssh / Ctrl-C can never kill the cockpit (set -e exits on a nonzero return).
_vm_attach() {
  local remote="$1" dom ip
  local -a doms ssh_cmd
  mapfile -t doms < <(virsh list --name 2>/dev/null | grep '^agentic-' || true)
  if [ "${#doms[@]}" -eq 0 ]; then notify "no agentic work VMs running"; return 0; fi
  if [ "${#doms[@]}" -eq 1 ]; then
    dom="${doms[0]}"
  else
    dom="$(prompt_line "VM (${doms[*]}): ")"
    [ -n "$dom" ] || { notify "cancelled"; return 0; }
  fi
  ip="$(python3 -c "import sys;sys.path.insert(0,'$REPO_DIR/evals/agentic');import vm;print(vm._ip('${dom#agentic-}') or '')" 2>/dev/null || true)"
  [ -n "$ip" ] || { notify "no IP for $dom (running?)"; return 0; }
  ssh_cmd=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
           -o ConnectTimeout=10 -o LogLevel=ERROR "agent@$ip")
  if [ -n "$remote" ]; then ssh_cmd+=("$remote"); fi
  tput rmcup 2>/dev/null || true; tput cnorm 2>/dev/null || true; stty echo 2>/dev/null || true
  printf '\n--- %s @ %s --- (exit, or Ctrl-C to stop, returns to the cockpit)\n' "$dom" "$ip"
  trap '' INT                  # Ctrl-C should stop ssh/tail, not trip the cockpit's INT cleanup
  "${ssh_cmd[@]}" || true
  trap cleanup INT
  tput smcup 2>/dev/null || true; tput civis 2>/dev/null || true; stty -echo 2>/dev/null || true
  tput clear 2>/dev/null || true
  LAST_FRAME=""                # mandatory: force a full repaint after the screen was taken over
}

act_vmssh()  { _vm_attach ""; }
act_follow() { _vm_attach "tail -n 40 -f ~/out/events.log"; }

tput smcup
tput civis
stty -echo
tput clear  # one clean clear at startup; render() never clears again

key=""
while true; do
  render
  key=""
  if read -rsn1 -t "$REFRESH" key; then
    case "$key" in
      s) act_start ;;
      x) act_stop ;;
      n) act_dispatch ;;
      r) act_reset ;;
      a) act_answer ;;
      v) act_vmssh ;;
      f) act_follow ;;
      q) break ;;
      *) : ;;
    esac
  fi
done
