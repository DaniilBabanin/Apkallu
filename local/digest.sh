#!/usr/bin/env bash
# digest.sh — post-iteration director digest.
#
# Gathers the loop's recent state (last 5 commits with --stat, backlog status,
# and any OPEN director decisions), asks the local `general` model (via
# local/llm.sh) to distill it into a short markdown digest, and writes that to
# director/REPORT.md. If NTFY_TOPIC is set, also pushes the digest to ntfy.
# Side effects beyond REPORT.md: refreshes director/STATE.md's binding block
# (local/state-sync.sh) and regenerates director/MAP.md (local/map-gen.sh) —
# both best-effort, never fail the digest.
#
# Meant to be invoked by loop/run.sh after a committed iteration, but is safe to
# run by hand at any time. It never hard-fails the caller: on any missing tool
# or unreachable/degraded model it falls back to a deterministic raw digest, so
# REPORT.md and ntfy still update with real data.
#
# Usage: ./local/digest.sh
#
# Env:
#   NTFY_TOPIC     if set, push the digest to https://ntfy.sh/<topic>
#   LLM_ROLE       local model role for the summary (default: general)
#   DIGEST_LINES   max digest body lines written/pushed (default: 20)
#   DIGEST_VIA_QUEUE  1 (default) = route the summary call through local/queue.sh submit (the
#                     model-aware queue, routing.md §5) instead of calling local/llm.sh directly,
#                     so it shares one serving chokepoint with concurrent local work; 0 = direct
#                     llm.sh. Either way falls back to llm.sh, then to a deterministic raw digest.
#   DIGEST_REPORT  output path (default: director/REPORT.md) — overridable for tests.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

# PG glue (best-effort: PG_AVAIL=0 when PG is down — jobs-today line degrades silently)
# shellcheck source=lib/pg.sh
source "$REPO_DIR/lib/pg.sh" 2>/dev/null || true

LLM_ROLE="${LLM_ROLE:-general}"
DIGEST_LINES="${DIGEST_LINES:-20}"
REPORT="${DIGEST_REPORT:-director/REPORT.md}"

# --- gather inputs ----------------------------------------------------------
GIT_LOG="$(git log -5 --stat 2>/dev/null || true)"
[ -n "$GIT_LOG" ] || GIT_LOG="(no git history)"
GIT_ONELINE="$(git log -5 --oneline 2>/dev/null || true)"
[ -n "$GIT_ONELINE" ] || GIT_ONELINE="(no git history)"

open_count="$(grep -c '^- \[ \]' backlog.md 2>/dev/null || true)"; open_count="${open_count:-0}"
done_count="$(grep -c '^- \[x\]' backlog.md 2>/dev/null || true)"; done_count="${done_count:-0}"
OPEN_TASKS="$(grep '^- \[ \]' backlog.md 2>/dev/null || echo '(none)')"

# Open decisions = D-NNN blocks in DECISIONS.md whose **Answer:** is still blank.
OPEN_DECISIONS="$(
  awk '
    function flush() {
      if (id == "") return
      if (ans ~ /[^[:space:]]/) { id=""; return }   # has an answer -> not open
      printf "%s\n\n", block
      id=""
    }
    /^## D-/             { flush(); id=$0; block=$0; ans=""; inans=0; next }
    id == ""             { next }
    /^---[[:space:]]*$/  { flush(); next }
    {
      block = block "\n" $0
      if ($0 ~ /^\*\*Answer:\*\*/) { inans=1; t=$0; sub(/^\*\*Answer:\*\*/,"",t); ans=ans t }
      else if (inans)              { ans = ans " " $0 }
    }
    END { flush() }
  ' director/DECISIONS.md 2>/dev/null || true
)"
[ -n "$OPEN_DECISIONS" ] || OPEN_DECISIONS="(none open)"

OPEN_DECISION_IDS="$(printf '%s\n' "$OPEN_DECISIONS" \
  | grep -oE '^## D-[0-9]+' | sed 's/^## //' | paste -sd, - 2>/dev/null || true)"
[ -n "$OPEN_DECISION_IDS" ] || OPEN_DECISION_IDS="none"

STAMP="$(date -Iseconds 2>/dev/null || date)"

# --- mechanical agency/client commit split (council review §4: classify commits, don't trust
# the loop's self-grading). loop/enforce.sh counts agency commits (this repo's git history) vs
# client commits (the client-commit ledger) and the days since the last client commit.
# Informational only (the kill switches were removed 2026-06-12, director ruling).
# Best-effort: a missing enforce.sh just omits the line.
COMMIT_SPLIT=""
if [ -x loop/enforce.sh ]; then
  COMMIT_SPLIT="$(loop/enforce.sh counts 2>/dev/null || true)"
fi
agency_commits="$(printf '%s' "$COMMIT_SPLIT" | sed -nE 's/.*agency=([0-9]+).*/\1/p')"
client_commits="$(printf '%s' "$COMMIT_SPLIT" | sed -nE 's/.*client=([0-9]+).*/\1/p')"
last_client="$(printf '%s' "$COMMIT_SPLIT" | sed -nE 's/.*last_client=([^ ]+).*/\1/p')"
days_since="$(printf '%s' "$COMMIT_SPLIT" | sed -nE 's/.*days=([^ ]+).*/\1/p')"
COMMIT_LINE=""
if [ -n "$agency_commits" ]; then
  if [ -n "$last_client" ] && [ "$last_client" != "never" ]; then
    COMMIT_LINE="$(printf '**Commits (mechanical):** agency %s · client %s — last client %s, %sd ago' \
      "$agency_commits" "$client_commits" "$last_client" "$days_since")"
  else
    COMMIT_LINE="$(printf '**Commits (mechanical):** agency %s · client %s — no client commit yet' \
      "$agency_commits" "$client_commits")"
  fi
fi

# --- PG: jobs done/failed today from events (best-effort, one-line) ----------
PG_TODAY_LINE=""
if [ "${PG_AVAIL:-0}" = "1" ]; then
  pg_today_raw="$(pg_query \
    "SELECT type||': '||count(*)::text FROM events WHERE recorded_at>=current_date AND invalidated_by IS NULL AND type IN ('job.completed','gate.failed') GROUP BY type ORDER BY type" \
    || true)"
  if [ -n "$pg_today_raw" ]; then
    pg_today_joined="$(printf '%s\n' "$pg_today_raw" \
      | awk 'NR>1{printf " · "} {printf "%s", $0} END{if(NR>0) print ""}' || true)"
    PG_TODAY_LINE="**PG today:** ${pg_today_joined}"
  fi
fi

# --- PG: lineage this week (best-effort, absent when PG down) ----------------
LINEAGE_SECTION=""
if [ "${PG_AVAIL:-0}" = "1" ]; then
  _lc="$(pg_query "SELECT count(*) FROM nodes WHERE kind='commit' AND created_at >= now() - INTERVAL '7 days'" || true)"
  _lj="$(pg_query "SELECT count(*) FROM nodes WHERE kind='job' AND created_at >= now() - INTERVAL '7 days'" || true)"
  _lm="$(pg_query "SELECT count(DISTINCT n.natural_key) FROM nodes n JOIN edges e ON e.to_node = n.id AND e.label = 'ran_on' JOIN nodes j ON j.id = e.from_node AND j.kind = 'job' WHERE j.created_at >= now() - INTERVAL '7 days'" || true)"
  if [ -n "${_lc}${_lj}${_lm}" ]; then
    _lc="${_lc:-0}"; _lj="${_lj:-0}"; _lm="${_lm:-0}"
    LINEAGE_SECTION="**Lineage this week:** ${_lc} commits · ${_lj} jobs · ${_lm} models"

    # Gate-fail streaks: models with ≥2 consecutive fails at end of history
    _streaks="$(PGCONNECT_TIMEOUT=3 psql "$(_pg_dsn)" -tAq 2>/dev/null <<'SQL' || true
WITH gate_events AS (
  SELECT mv.natural_key AS model,
         ev.type,
         sum(CASE WHEN ev.type = 'gate.passed' THEN 1 ELSE 0 END)
           OVER (PARTITION BY mv.natural_key ORDER BY ev.recorded_at DESC
                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS passes_seen
  FROM events ev
  JOIN nodes job_n ON ev.stream_name = 'job-' || job_n.natural_key AND job_n.kind = 'job'
  JOIN edges ran   ON ran.from_node = job_n.id AND ran.label = 'ran_on' AND ran.invalidated_by IS NULL
  JOIN nodes mv    ON mv.id = ran.to_node AND mv.kind = 'model_version'
  WHERE ev.type IN ('gate.passed', 'gate.failed') AND ev.invalidated_by IS NULL
)
SELECT model || ': ' || count(*)
FROM gate_events
WHERE type = 'gate.failed' AND passes_seen = 0
GROUP BY model HAVING count(*) >= 2
ORDER BY count(*) DESC, model;
SQL
    )"
    if [ -n "$_streaks" ]; then
      _streak_fmt="$(printf '%s' "$_streaks" | tr '\n' ' ' | sed 's/  */ /g; s/ $//')"
      LINEAGE_SECTION="${LINEAGE_SECTION}
**Gate-fail streaks (>=2):** ${_streak_fmt}"
    fi

    # Attempt green-rate by model: per-attempt pass rate (gate.passed / all gate verdicts)
    # attributed via the committed job's ran_on edge. CAVEAT: only jobs that greened >=1x are
    # attributable, so this is "green-rate over jobs that eventually greened", not a raw success
    # rate (full model x profile breakdown: local/lineage.sh greenrate).
    _green="$(PGCONNECT_TIMEOUT=3 psql "$(_pg_dsn)" -tAq 2>/dev/null <<'SQL' || true
SELECT mv.natural_key || ' ' ||
       round(100.0 * sum(CASE WHEN ev.type = 'gate.passed' THEN 1 ELSE 0 END) / count(*)) || '% (' ||
       sum(CASE WHEN ev.type = 'gate.passed' THEN 1 ELSE 0 END) || '/' || count(*) || ')'
FROM events ev
JOIN nodes job_n ON ev.stream_name = 'job-' || job_n.natural_key AND job_n.kind = 'job'
JOIN edges ran   ON ran.from_node = job_n.id AND ran.label = 'ran_on' AND ran.invalidated_by IS NULL
JOIN nodes mv    ON mv.id = ran.to_node AND mv.kind = 'model_version'
WHERE ev.type IN ('gate.passed','gate.failed') AND ev.invalidated_by IS NULL
GROUP BY mv.natural_key
ORDER BY 1;
SQL
    )"
    if [ -n "$_green" ]; then
      _green_fmt="$(printf '%s\n' "$_green" | awk 'NF{a=a sep $0; sep=" · "} END{print a}')"
      LINEAGE_SECTION="${LINEAGE_SECTION}
**Attempt green-rate by model:** ${_green_fmt}"
    fi

    # Bench discard rate: fraction of superseded verdicts
    _discard="$(pg_query "SELECT CASE WHEN count(*) > 0 THEN round(100.0 * count(*) FILTER (WHERE NOT current) / count(*)) ELSE 0 END FROM bench_verdicts" || true)"
    if [ -n "${_discard:-}" ] && [ "${_discard:-0}" != "0" ]; then
      LINEAGE_SECTION="${LINEAGE_SECTION}
**Bench discard rate:** ${_discard}%"
    fi
  fi
fi

# --- ask the local model to distill -----------------------------------------
PROMPT="You are writing a status digest for the director of an autonomous coding loop.
Using ONLY the data below, write a concise markdown digest of AT MOST ${DIGEST_LINES} lines.
Cover, in order: (1) what the recent commits accomplished, (2) backlog status
(${open_count} open / ${done_count} done) and the likely next task, (3) the agency/client
commit split below, (4) PG jobs done/failed today if available, (5) any OPEN decisions
needing the director's attention.
Be specific. No preamble, no closing remarks.

=== COMMIT SPLIT (mechanical) ===
${COMMIT_SPLIT:-(unavailable)}

=== RECENT COMMITS (git log -5 --stat) ===
${GIT_LOG}

=== BACKLOG: ${open_count} open / ${done_count} done ===
${OPEN_TASKS}

=== PG JOBS TODAY ===
${PG_TODAY_LINE:-(unavailable)}

=== OPEN DECISIONS ===
${OPEN_DECISIONS}"

# ONE model attempt, then the deterministic net below. Prefer the model-aware queue (single
# serving chokepoint for all local work, so digest's warm-lane summary doesn't race concurrent
# big-MoE work — routing.md §5); use llm.sh directly only when the queue is absent or
# DIGEST_VIA_QUEUE=0. Deliberately NOT a queue→llm.sh chain: a degraded model would make each
# attempt wait its full timeout (up to 600s queue + 300s llm.sh), so a single attempt drops
# straight to the deterministic raw digest (the load-bearing fallback) instead.
BODY=""
if [ "${DIGEST_VIA_QUEUE:-1}" != "0" ] && [ -x local/queue.sh ]; then
  BODY="$(local/queue.sh submit "$LLM_ROLE" --prompt "$PROMPT" --id digest 2>/dev/null || true)"
elif [ -x local/llm.sh ]; then
  BODY="$(local/llm.sh "$LLM_ROLE" "$PROMPT" 2>/dev/null || true)"
fi

# Fall back to a deterministic digest if the model is unavailable/degraded.
case "$BODY" in
  "" | LLM_ERROR* | LLM_WARN*)
    BODY="_(local model unavailable — raw digest)_

**Recent commits**
${GIT_ONELINE}

**Backlog:** ${open_count} open · ${done_count} done
**Open decisions:** ${OPEN_DECISION_IDS}${PG_TODAY_LINE:+
${PG_TODAY_LINE}}"
    ;;
esac

# Enforce the <=DIGEST_LINES cap (trim trailing blank lines, then cut).
BODY="$(printf '%s\n' "$BODY" | sed -e 's/[[:space:]]*$//' | head -n "$DIGEST_LINES")"

# --- write the report -------------------------------------------------------
mkdir -p "$(dirname "$REPORT")"
{
  printf '# Director Report\n'
  printf '_Generated %s · backlog %s open / %s done · open decisions: %s_\n\n' \
    "$STAMP" "$open_count" "$done_count" "$OPEN_DECISION_IDS"
  if [ -n "$COMMIT_LINE" ]; then printf '%s\n\n' "$COMMIT_LINE"; fi
  if [ -n "$PG_TODAY_LINE" ]; then printf '%s\n\n' "$PG_TODAY_LINE"; fi
  if [ -n "$LINEAGE_SECTION" ]; then printf '%s\n\n' "$LINEAGE_SECTION"; fi
  printf '%s\n' "$BODY"
} > "$REPORT"

echo "[digest] wrote $REPORT ($(printf '%s\n' "$BODY" | wc -l | tr -d ' ') body lines)"

# --- refresh the pinned anchor + repo map (deterministic, no model) ----------
# CM-1/CM-2: keep director/STATE.md's binding block and director/MAP.md in sync every
# iteration so a worker reads a small anchor + index (binding facts + a table of contents)
# instead of the whole ~26k-token NOTES.md. Both are best-effort — a sync failure must
# never wedge the loop, so a non-zero rc here is swallowed (digest itself is `|| true` in run.sh).
if [ -x local/state-sync.sh ] && [ -f director/STATE.md ]; then
  if local/state-sync.sh apply director/STATE.md director/DECISIONS.md; then
    echo "[digest] refreshed director/STATE.md binding block"
  else
    echo "[digest] WARN: STATE.md binding-block refresh skipped (markers missing?)" >&2
  fi
fi
if [ -x local/map-gen.sh ]; then
  if local/map-gen.sh > director/MAP.md.tmp 2>/dev/null; then
    mv director/MAP.md.tmp director/MAP.md
    echo "[digest] wrote director/MAP.md"
  else
    rm -f director/MAP.md.tmp
    echo "[digest] WARN: MAP.md generation skipped" >&2
  fi
fi

# --- ntfy push --------------------------------------------------------------
if [ -n "${NTFY_TOPIC:-}" ]; then
  MSG="$(printf 'backlog %s open / %s done · decisions: %s\n%s' \
    "$open_count" "$done_count" "$OPEN_DECISION_IDS" "$BODY")"
  # --data-raw, not -d: a body starting with "@" must post literally, never read a local file
  curl -s -o /dev/null --max-time 10 \
    -H "Title: agency digest" \
    --data-raw "$(printf '%s' "$MSG" | head -c 1200)" \
    "https://ntfy.sh/${NTFY_TOPIC}" || true
  echo "[digest] pushed to ntfy.sh/${NTFY_TOPIC}"
fi
