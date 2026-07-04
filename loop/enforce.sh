#!/usr/bin/env bash
# enforce.sh — mechanical agency/client commit bookkeeping. The council's vision review
# (a design review, §4 "Move enforcement into the harness, out of
# the prose") ruled: classify commits mechanically in the digest, not in a doc the model
# reinterprets. This script is that harness layer.
#
# History note (2026-06-12, director): the VISION kill switches this script used to enforce
# (the gate milestone deadline, 14-day no-client-commit rule) were REMOVED — pen-support shipped and the
# director ruled out deadline self-pressure on a side project. The bookkeeping (ledger, counts,
# sanitizer, project-commit) stays: it is informational and serves external-project mode.
#
# It owns ONE mechanical fact the rest of the loop cannot fake: the client-commit ledger
# (client-commits.tsv) — an append-only record of commits that landed on a CLIENT project branch
# (real, non-meta work), written by run.sh's external-project mode. The digest's agency/client
# split derives from that ledger plus the agency repo's own git history. No claude, no network —
# so tests/ drive it directly.
#
# Subcommands:
#   record <proj> <br> <sha> <subject>
#                              append one client-commit line to the ledger (external-project mode).
#   project-commit <dir> <branch> <gate-cmd> <message...>
#                              external-project mode's commit flow: ensure the isolated <branch> in
#                              the project checkout <dir>, run the project's OWN gate, and on green
#                              commit there with a SANITIZED message (no agency refs, no Claude
#                              attribution) + record the client commit in the agency ledger. The
#                              project repo stays agency-agnostic (VISION). rc 0 committed ·
#                              1 gate failed · 2 nothing to commit.
#   counts                     print "agency=<n> client=<n> last_client=<date|never> days=<n|->"
#                              — the mechanical agency/client split for the digest.
#   sanitize                   stdin -> stdout: strip agency references + Claude/AI attribution
#                              from a commit message (used by project-commit; exposed for tests).
#
# Env:
#   ENFORCE_REPO            agency repo to operate on (default: this script's repo).
#   CLIENT_LEDGER           client-commit ledger path (default client-commits.tsv, git-tracked).
#   ENFORCE_TODAY           override "today" as YYYY-MM-DD (tests only).
#
# Exit: 0 ok · 1 usage/gate-fail · 2 nothing to commit.

set -euo pipefail

REPO_DIR="${ENFORCE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO_DIR"

CLIENT_LEDGER="${CLIENT_LEDGER:-client-commits.tsv}"  # tracked ledger, NOT a transient .log

# usage(): print the header comment block (everything up to `set -euo`), comment markers stripped.
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

# --- date helpers (ENFORCE_TODAY lets tests pin "now") ---------------------------------------
today_str() { printf '%s' "${ENFORCE_TODAY:-$(date +%F)}"; }
to_epoch()  { date -d "$1" +%s 2>/dev/null || printf '0'; }
days_between() { # $1 earlier, $2 later -> whole days (may be negative)
  local a b
  a="$(to_epoch "$1")"; b="$(to_epoch "$2")"
  printf '%s' "$(( (b - a) / 86400 ))"
}

# --- ledger readers -------------------------------------------------------------------------
ledger_count() {
  if [ -f "$CLIENT_LEDGER" ]; then awk 'END{print NR+0}' "$CLIENT_LEDGER"; else printf '0'; fi
}
last_client_date() { # date (YYYY-MM-DD) of the most recent ledger line, or empty
  [ -f "$CLIENT_LEDGER" ] || return 0
  tail -n1 "$CLIENT_LEDGER" 2>/dev/null | cut -f1 | cut -dT -f1
}
agency_commits() { git rev-list --count HEAD 2>/dev/null || printf '0'; }

# --- client-commit ledger -------------------------------------------------------------------
cmd_record() {
  local proj="${1:-}" branch="${2:-}" sha="${3:-}" subject="${4:-}"
  if [ -z "$proj" ] || [ -z "$branch" ]; then
    echo "[enforce] record: need <project> <branch> <sha> <subject>" >&2
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "$proj" "$branch" "$sha" "$subject" >> "$CLIENT_LEDGER"
  echo "[enforce] recorded client commit: ${proj}@${branch} ${sha}"
}

# --- commit-message sanitizer ---------------------------------------------------------------
# Strip AI/agency attribution + agency-internal references so a project commit reads as ordinary
# dev work (VISION: project repos stay agency-agnostic; user git policy: no Co-Authored-By). Always
# exits 0 (an all-filtered message is legal — project-commit substitutes a generic subject).
cmd_sanitize() {
  sed -E -e 's/^(loop|cascade|agency|ops): *//I' \
    | grep -viE '(co-authored-by|generated with|🤖|claude|anthropic|\bagency\b|\bcascade\b|NOTES\.md|backlog\.md|D-[0-9]{3}|/goal)' \
    | sed -e '/./,$!d' || true
}

# --- external-project mode: commit flow -----------------------------------------------------
cmd_project_commit() {
  local dir="${1:-}" branch="${2:-}" gate_cmd="${3:-}"
  local message=""
  if [ "$#" -gt 3 ]; then shift 3; message="$*"; fi
  if [ -z "$dir" ] || [ -z "$branch" ]; then
    echo "[enforce] project-commit: need <dir> <branch> <gate-cmd> <message...>" >&2
    return 1
  fi
  if [ ! -d "$dir/.git" ]; then
    echo "[enforce] project-commit: '$dir' is not a git checkout." >&2
    return 1
  fi

  # Isolated work branch — client work never lands on the project's default branch (VISION:
  # "isolated branch of atomic commits, merged at review time").
  local cur
  cur="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  if [ "$cur" != "$branch" ]; then
    if git -C "$dir" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
      git -C "$dir" checkout -q "$branch"
    else
      git -C "$dir" checkout -q -b "$branch"
    fi
  fi

  if [ -z "$(git -C "$dir" status --porcelain)" ]; then
    echo "[enforce] project-commit: no changes in $dir — nothing to commit." >&2
    return 2
  fi

  # The project's OWN gate decides green (independent re-run, same as run.sh re-runs ./gate.sh).
  if [ -n "$gate_cmd" ]; then
    echo "[enforce] project-commit: running project gate: $gate_cmd"
    if ! ( cd "$dir" && bash -c "$gate_cmd" ); then
      echo "[enforce] project-commit: project gate FAILED — not committing." >&2
      return 1
    fi
  fi

  local clean
  clean="$(printf '%s\n' "$message" | cmd_sanitize)"
  [ -n "$clean" ] || clean="update"

  git -C "$dir" add -A
  git -C "$dir" commit -q -m "$clean"
  local sha
  sha="$(git -C "$dir" rev-parse --short HEAD)"
  echo "[enforce] project-commit: committed $sha on $branch (project gate green)."

  # Agency-side bookkeeping: record the client commit in the agency ledger (the mechanical signal
  # for the digest split; the 14-day kill switch that also read it was removed 2026-06-12, see
  # header). The project repo itself stays agency-agnostic.
  cmd_record "$(basename "$dir")" "$branch" "$sha" "$(printf '%s' "$clean" | head -n1)"
}

# --- digest split ---------------------------------------------------------------------------
cmd_counts() {
  local agency client last today days
  agency="$(agency_commits)"
  client="$(ledger_count)"
  last="$(last_client_date)"
  today="$(today_str)"
  if [ -n "$last" ]; then days="$(days_between "$last" "$today")"; else days="-"; fi
  printf 'agency=%s client=%s last_client=%s days=%s\n' "$agency" "$client" "${last:-never}" "$days"
}

# --- dispatch -------------------------------------------------------------------------------
case "${1:-}" in
  record)         shift; cmd_record "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
  project-commit) shift; cmd_project_commit "$@" ;;
  counts)         cmd_counts ;;
  sanitize)       cmd_sanitize ;;
  -h|--help|"")   usage ;;
  *) echo "[enforce] unknown subcommand: $1" >&2; usage; exit 1 ;;
esac
