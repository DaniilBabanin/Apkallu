#!/usr/bin/env bash
# watcher.sh — health monitor for the autonomous loop (ARCHITECTURE.md a build phase watchdog, v0).
#
# Runs on a 15-minute systemd user timer (see local/agency-watcher.{service,timer} and the
# `install` subcommand below). Each cycle it gathers a few cheap, DETERMINISTIC health facts:
#   - stalled loop?            a loop/run.sh process is alive but no git commit for a long time
#   - decisions past deadline? an OPEN director decision whose **Default applies:** date is <= today
#   - disk / VRAM pressure?    repo filesystem use% high, or GPU memory near full
# It then asks the local `triage` model (local/llm.sh) whether the director GENUINELY needs to be
# pinged now (a noise filter), and pushes to ntfy only when warranted. Critical facts (disk
# critical, a decision already past its deadline) ALWAYS alert and cannot be suppressed by the
# model. A state file in $STATE_DIR dedups repeat alerts, so an ongoing condition pings once — not
# every 15 minutes.
#
# Subcommands:
#   (none) | run   one monitoring cycle; ping ntfy if needed; always exits 0 (systemd oneshot).
#   check          dry run: print concerns + verdict, no ntfy, no state writes. Exit 10 if it
#                  WOULD alert, else 0. Used by tests/ and for manual inspection.
#   install        symlink the systemd user units into ~/.config/systemd/user and enable the timer.
#   -h | --help    usage.
#
# Env (all optional):
#   NTFY_TOPIC          ntfy.sh topic for alerts (unset -> never pushes, just logs).
#   DECISIONS_FILE      decisions file (default: director/DECISIONS.md).
#   LLM_ROLE            local model role for the judgment (default: triage).
#   WATCHER_NO_MODEL=1  skip the model; decide from deterministic facts only.
#   WATCHER_DISK_PCT    repo-fs use% that warns (default 90); WATCHER_DISK_CRIT crits (default 97).
#   WATCHER_VRAM_PCT    GPU memory use% that warns (default 95).
#   WATCHER_STALL_SECS  loop-alive-but-no-commit age in seconds that warns (default 2700 = 45min).
#   WATCHER_HEARTBEAT_URL  dead-man switch: GET-pinged once per run tick; point at a
#                          healthchecks.io check so a silently-dead watcher raises an alert.
#   REALERT_SECS        re-ping an UNCHANGED alert only after this many seconds (default 14400 = 4h).
#   STATE_DIR           dedup state dir (default: ${XDG_STATE_HOME:-~/.local/state}/agency-watcher).
#   WATCHER_NOW         override "today" as YYYY-MM-DD (for testing the deadline check).
#   AGENCY_BACKUP_DIR   directory for nightly pg_dump files (default: ~/backups/agency).
#   AGENCY_BACKUP_DB    postgres database to dump (default: agency).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

DECISIONS_FILE="${DECISIONS_FILE:-director/DECISIONS.md}"
LLM_ROLE="${LLM_ROLE:-triage}"
WATCHER_DISK_PCT="${WATCHER_DISK_PCT:-90}"
WATCHER_DISK_CRIT="${WATCHER_DISK_CRIT:-97}"
WATCHER_VRAM_PCT="${WATCHER_VRAM_PCT:-95}"
WATCHER_STALL_SECS="${WATCHER_STALL_SECS:-2700}"
REALERT_SECS="${REALERT_SECS:-14400}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agency-watcher}"
TODAY="${WATCHER_NOW:-$(date +%F)}"
AGENCY_BACKUP_DIR="${AGENCY_BACKUP_DIR:-${HOME}/backups/agency}"
AGENCY_BACKUP_DB="${AGENCY_BACKUP_DB:-agency}"

CONCERNS=()
SIGS=()
HAVE_CRIT=0
MODEL_DECISION="UNKNOWN"
MODEL_REASON=""

# $1 = human text (pushed body — may carry live numbers); $2 (optional) = dedup signature:
# concern kind + threshold with the measured numbers stripped, so a growing counter or a
# boundary-flickering percentage doesn't defeat the REALERT dedup. Defaults to $1.
add_crit() { CONCERNS+=("[crit] $1"); SIGS+=("[crit] ${2:-$1}"); HAVE_CRIT=1; }
add_warn() { CONCERNS+=("[warn] $1"); SIGS+=("[warn] ${2:-$1}"); }

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# sha256 of stdin (portable: sha256sum -> shasum -> cksum).
hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else cksum | awk '{print $1}'; fi
}

# --- check: decisions past their auto-apply deadline ------------------------
# OPEN decision = a "## D-NNN" block whose **Answer:** is still blank. We extract the first
# YYYY-MM-DD on its "Default applies:" line; if today >= that date, the default has (or is about
# to) auto-apply without the director ever weighing in — that genuinely needs a heads-up.
check_decisions() {
  [ -f "$DECISIONS_FILE" ] || return 0
  local open
  open="$(awk '
    function flush() {
      if (id == "") return
      if (ans ~ /[^[:space:]]/) { id=""; return }   # has an answer -> not open
      printf "%s\t%s\n", deadline, header
      id=""
    }
    /^## D-/ {
      flush()
      header=$0; sub(/^## /,"",header)
      id=header; sub(/ .*/,"",id)
      ans=""; inans=0; deadline=""
      next
    }
    id == ""             { next }
    /^---[[:space:]]*$/  { flush(); next }
    {
      if (deadline == "" && $0 ~ /Default applies:/) {
        # take the first date AFTER the marker — "**Asked:** <date> · **Default applies:** <date>"
        # sits on one line, and the first date on the line is the WRONG one (found via D-005)
        t = $0; sub(/.*Default applies:/, "", t)
        if (match(t, /[0-9]{4}-[0-9]{2}-[0-9]{2}/)) deadline = substr(t, RSTART, RLENGTH)
      }
      if ($0 ~ /^\*\*Answer:\*\*/) { inans=1; t=$0; sub(/^\*\*Answer:\*\*/,"",t); ans=ans t }
      else if (inans)              { ans = ans " " $0 }
    }
    END { flush() }
  ' "$DECISIONS_FILE" 2>/dev/null || true)"

  [ -n "$open" ] || return 0
  local dline header id
  while IFS=$'\t' read -r dline header; do
    [ -n "$header" ] || continue
    id="${header%% *}"
    # No deadline date (e.g. outward-facing "answer when you can") -> never auto-applies, no alert.
    if [ -n "$dline" ] && ! [[ "$TODAY" < "$dline" ]]; then
      add_crit "decision $id past deadline ($dline) and unanswered — default auto-applies"
    fi
  done <<<"$open"
}

# --- check: disk pressure on the repo filesystem ----------------------------
check_disk() {
  command -v df >/dev/null 2>&1 || return 0
  local pct
  pct="$(df -P "$REPO_DIR" 2>/dev/null | awk 'NR==2 { gsub(/%/,"",$5); print $5 }')"
  [[ "$pct" =~ ^[0-9]+$ ]] || return 0
  if [ "$pct" -ge "$WATCHER_DISK_CRIT" ]; then
    add_crit "disk ${pct}% full on repo filesystem (>= ${WATCHER_DISK_CRIT}%) — commits may fail" \
             "disk >= ${WATCHER_DISK_CRIT}% full on repo filesystem"
  elif [ "$pct" -ge "$WATCHER_DISK_PCT" ]; then
    add_warn "disk ${pct}% full on repo filesystem (>= ${WATCHER_DISK_PCT}%)" \
             "disk >= ${WATCHER_DISK_PCT}% full on repo filesystem"
  fi
}

# --- check: GPU memory pressure ---------------------------------------------
check_vram() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0   # no GPU tooling -> silently skip
  local pct
  pct="$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null \
         | awk -F'[, ]+' 'NR==1 && $2 > 0 { printf "%d", $1*100/$2 }')"
  [[ "$pct" =~ ^[0-9]+$ ]] || return 0
  if [ "$pct" -ge "$WATCHER_VRAM_PCT" ]; then
    add_warn "VRAM ${pct}% used (>= ${WATCHER_VRAM_PCT}%) — a model may be stuck resident" \
             "VRAM >= ${WATCHER_VRAM_PCT}% used"
  fi
}

# --- check: loop alive but not committing (possible stall) ------------------
check_stall() {
  command -v pgrep >/dev/null 2>&1 || return 0
  # interpreter invocations only — a `vim loop/run.sh` must not count as a running loop
  pgrep -f '(^|/)bash [^ ]*loop/run\.sh( |$)' >/dev/null 2>&1 || return 0   # loop not running -> nothing to stall
  local last now age
  last="$(git log -1 --format=%ct 2>/dev/null || true)"
  [[ "$last" =~ ^[0-9]+$ ]] || return 0
  now="$(date +%s)"
  age=$(( now - last ))
  if [ "$age" -ge "$WATCHER_STALL_SECS" ]; then
    add_warn "loop running but no commit in $(( age / 60 ))min (possible stall)" \
             "loop running but no commit >= ${WATCHER_STALL_SECS}s (possible stall)"
  fi
}

# --- triage model: should we genuinely alert? -------------------------------
# Sets MODEL_DECISION (ALERT|OK|UNKNOWN) and MODEL_REASON. UNKNOWN = skipped or model unavailable,
# in which case the caller fails safe (alerts on any concern rather than going quiet).
run_model() {
  MODEL_DECISION="UNKNOWN"; MODEL_REASON=""
  [ "${WATCHER_NO_MODEL:-0}" = "1" ] && return 0
  [ -x local/llm.sh ] || return 0
  local prompt out first
  prompt="You monitor an autonomous coding loop. Below are health concerns detected this cycle.
Decide if the director GENUINELY needs to be alerted now; ignore minor or transient noise.
Reply with exactly one line: either
  OK
or
  ALERT: <reason, max 140 chars>

CONCERNS:
$(printf '%s\n' "${CONCERNS[@]}")"
  out="$(local/llm.sh "$LLM_ROLE" "$prompt" 2>/dev/null || true)"
  first="$(printf '%s\n' "$out" | head -1)"
  case "$first" in
    LLM_ERROR*|LLM_WARN*|"")  return 0 ;;                          # unavailable/degraded -> UNKNOWN
    [Aa][Ll][Ee][Rr][Tt]*)    MODEL_DECISION="ALERT"; MODEL_REASON="${first#*:}" ;;
    [Oo][Kk]*)                MODEL_DECISION="OK" ;;
    *)                        MODEL_DECISION="UNKNOWN" ;;
  esac
  MODEL_REASON="$(printf '%s' "$MODEL_REASON" | sed 's/^[[:space:]]*//')"
}

# --- ntfy push (with dedup) -------------------------------------------------
push_ntfy() {
  if [ -z "${NTFY_TOPIC:-}" ]; then
    echo "[watcher] NTFY_TOPIC unset — would alert but cannot push."
    return 0
  fi
  local title prio body
  if [ "$HAVE_CRIT" -eq 1 ]; then title="agency watcher: CRITICAL"; prio="high"
  else                            title="agency watcher: attention"; prio="default"; fi
  body=""
  if [ -n "$MODEL_REASON" ]; then body="${MODEL_REASON}"$'\n'; fi
  body="${body}$(printf '%s\n' "${CONCERNS[@]}")"
  # --data-raw, not -d: the body starts with model output, and a body beginning with "@" would
  # make -d read that local file and post it to the public topic (prompt-injection exfil).
  curl -s -o /dev/null --max-time 10 \
    -H "Title: ${title}" \
    -H "Priority: ${prio}" \
    --data-raw "$(printf '%s' "$body" | head -c 1200)" \
    "https://ntfy.sh/${NTFY_TOPIC}" || true
  echo "[watcher] pushed alert to ntfy.sh/${NTFY_TOPIC}"
}

# --- nightly pg_dump backup (once per day, first tick after midnight) -------
# Runs as the OS user (peer auth over unix socket — no password needed).
# State file $STATE_DIR/last_backup_date gates "already ran today" without a
# time-of-day check, so it fires at the first 15-min tick after midnight.
do_backup() {
  local state last_date out size
  mkdir -p "$STATE_DIR" 2>/dev/null || true   # dedup state must be writable on the healthy path too
  state="$STATE_DIR/last_backup_date"
  last_date="$(cat "$state" 2>/dev/null || true)"
  [ "$last_date" = "$TODAY" ] && { echo "[watcher] backup: already ran today — skip."; return 0; }
  if ! command -v pg_dump >/dev/null 2>&1; then
    echo "[watcher] backup: pg_dump not on PATH — skip."
    return 0
  fi
  mkdir -p "$AGENCY_BACKUP_DIR" 2>/dev/null || {
    echo "[watcher] backup: cannot create $AGENCY_BACKUP_DIR — skip." >&2
    return 0
  }
  out="$AGENCY_BACKUP_DIR/agency-${TODAY}.dump"
  if pg_dump -Fc "$AGENCY_BACKUP_DB" > "$out" 2>/dev/null; then
    size="$(du -h "$out" 2>/dev/null | cut -f1 || echo '?')"
    echo "$TODAY" > "$state"
    echo "[watcher] backup: $out written (${size})."
  else
    rm -f "$out" 2>/dev/null || true
    echo "[watcher] backup: pg_dump failed — no dump written." >&2
  fi
}

maybe_ping() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  local state sig now prev_sig prev_ts
  state="$STATE_DIR/last_alert"
  # hash the normalized signatures, not the display text — an ongoing condition keeps one sig
  sig="$(printf '%s\n' "${SIGS[@]}" | sort | hash_stdin)"
  now="$(date +%s)"
  prev_sig=""; prev_ts=0
  if [ -f "$state" ]; then
    IFS= read -r prev_sig <"$state" || true
    prev_ts="$(sed -n '2p' "$state" 2>/dev/null || true)"
    [[ "$prev_ts" =~ ^[0-9]+$ ]] || prev_ts=0
  fi
  if [ "$sig" = "$prev_sig" ] && [ "$(( now - prev_ts ))" -lt "$REALERT_SECS" ]; then
    echo "[watcher] alert unchanged since last ping ($(( (now - prev_ts) / 60 ))min ago) — suppressed."
    return 0
  fi
  push_ntfy
  printf '%s\n%s\n' "$sig" "$now" >"$state" 2>/dev/null || true
}

# --- one monitoring cycle ---------------------------------------------------
# mode = run | check. Returns 10 in check mode when it would alert (else 0); 0 in run mode.
main_cycle() {
  local mode="$1"
  # dead-man switch: the watcher can alert on everything except its own death — an external
  # heartbeat monitor fires when these pings STOP. run mode only (check is the TUI probe).
  if [ "$mode" = "run" ] && [ -n "${WATCHER_HEARTBEAT_URL:-}" ]; then
    curl -fsS --max-time 10 -o /dev/null "$WATCHER_HEARTBEAT_URL" || true
  fi
  check_decisions
  check_disk
  check_vram
  check_stall

  local n="${#CONCERNS[@]}"
  if [ "$n" -eq 0 ]; then
    # all clear: drop dedup state so a future re-occurrence pings immediately
    if [ "$mode" = "run" ]; then rm -f "$STATE_DIR/last_alert" 2>/dev/null || true; fi
    echo "[watcher] OK — no concerns."
    return 0
  fi

  run_model

  local should=0
  if [ "$HAVE_CRIT" -eq 1 ]; then
    should=1                                       # critical: alert regardless of the model
  elif [ "$MODEL_DECISION" = "ALERT" ] || [ "$MODEL_DECISION" = "UNKNOWN" ]; then
    should=1                                       # warn-only: alert unless the model says OK
  fi

  printf '[watcher] %d concern(s); crit=%d model=%s would_alert=%d\n' \
    "$n" "$HAVE_CRIT" "$MODEL_DECISION" "$should"
  printf '%s\n' "${CONCERNS[@]}"

  if [ "$mode" = "check" ]; then
    if [ "$should" -eq 1 ]; then return 10; fi
    return 0
  fi

  if [ "$should" -ne 1 ]; then
    echo "[watcher] concerns present but model judged them noise — no ping."
    return 0
  fi
  maybe_ping
  return 0
}

# --- install the systemd user units -----------------------------------------
do_install() {
  local unit_src dst
  unit_src="$REPO_DIR/local"
  dst="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$dst"
  # Render units with this checkout's path (clone-anywhere: the shipped files carry no
  # hardcoded path, so we substitute __REPO_DIR__ at install time instead of symlinking).
  sed "s|__REPO_DIR__|$REPO_DIR|g" "$unit_src/agency-watcher.service" >"$dst/agency-watcher.service"
  sed "s|__REPO_DIR__|$REPO_DIR|g" "$unit_src/agency-watcher.timer"   >"$dst/agency-watcher.timer"
  systemctl --user daemon-reload
  systemctl --user enable --now agency-watcher.timer
  echo "[watcher] installed + enabled. Set NTFY_TOPIC in ~/.config/agency/watcher.env to get pings."
  systemctl --user list-timers agency-watcher.timer --no-pager || true
}

# --- entrypoint -------------------------------------------------------------
case "${1:-run}" in
  -h|--help|help) usage; exit 0 ;;
  install)        do_install; exit $? ;;
  check)
    set +e; main_cycle check; rc=$?; set -e
    exit "$rc"
    ;;
  run|"")
    main_cycle run
    do_backup || true
    exit 0
    ;;
  *)              echo "unknown subcommand: $1" >&2; usage; exit 64 ;;
esac
