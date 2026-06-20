#!/usr/bin/env bash
# local/lineage.sh — eval-results lineage importer + lineage query CLI.
# Usage:
#   local/lineage.sh import [file...]  — import eval results (idempotent, best-effort)
#   local/lineage.sh commit <sha>      — show commit provenance + gate verdict
#   local/lineage.sh model <id>        — list outputs for a model version
#   local/lineage.sh bench [--all]     — show bench verdicts (current-only by default)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

_cmd="${1:-}"
shift || true

# shellcheck source=lib/pg.sh
. lib/pg.sh

_pg_check() {
  if [ "${PG_AVAIL}" != "1" ]; then
    printf 'error: PG unavailable\n' >&2
    exit 1
  fi
}

case "$_cmd" in

# ── import ───────────────────────────────────────────────────────────────────
import)
  [ "${PG_AVAIL}" = "1" ] || exit 0

  if [ $# -eq 0 ]; then
    set -- evals/results/*.ndjson
  fi

  for _f in "$@"; do
    [ -f "$_f" ] || continue

    # Aggregate: one record per (model, category) — min ts, score X/Y, ctx from _load row.
    while IFS= read -r _rec; do
      _model="$(printf '%s' "$_rec" | jq -r '.model')"
      _cat="$(printf '%s' "$_rec" | jq -r '.category')"
      _ts="$(printf '%s' "$_rec" | jq -r '.ts')"
      _score="$(printf '%s' "$_rec" | jq -r '.score')"
      _ctx="$(printf '%s' "$_rec" | jq -r '.ctx')"

      # Stable natural key: sha256 of "model|category|ts"
      _hash="$(printf '%s|%s|%s' "$_model" "$_cat" "$_ts" | sha256sum | cut -c1-64)"

      _mv_id="$(pg_node model_version "$_model" '{}')"
      [ -n "$_mv_id" ] || continue

      # eval_result node attrs: category + score stored for bench_verdicts view;
      # ts stored here so the supersession query can compare without a join.
      _node_a="$(jq -n --arg c "$_cat" --arg s "$_score" --argjson t "$_ts" \
        '{category:$c,score:$s,ts:$t}')"
      _er_id="$(pg_node eval_result "$_hash" "$_node_a")"
      [ -n "$_er_id" ] || continue

      _edge_a="$(jq -n --arg c "$_cat" --arg s "$_score" --argjson t "$_ts" \
        --argjson ctx "$_ctx" '{category:$c,score:$s,ts:$t,ctx:$ctx}')"
      _eid="$(pg_edge "$_mv_id" "$_er_id" produced "$_edge_a")"
      [ -n "$_eid" ] || continue

      # Supersession: mark older produced edges for same (model, category) invalidated.
      # Values bound via psql -v (:'var') — no string interpolation into SQL.
      PGCONNECT_TIMEOUT=3 psql "$(_pg_dsn)" -tAq \
        -v mv="$_mv_id" -v cat="$_cat" -v cur_ts="$_ts" -v new_eid="$_eid" \
        >/dev/null 2>&1 <<'SQL' || true
UPDATE edges
   SET invalidated_by = :'new_eid'::bigint
 WHERE from_node = :'mv'::bigint
   AND label = 'produced'
   AND invalidated_by IS NULL
   AND id != :'new_eid'::bigint
   AND to_node IN (
         SELECT id FROM nodes
          WHERE kind = 'eval_result'
            AND attrs->>'category' = :'cat'
            AND (attrs->>'ts')::bigint < :'cur_ts'::bigint
       );
SQL
    done < <(jq -sc '
      . as $all |
      ( $all | map(select(.category == "_load"))
             | map({(.model): .ctx}) | add // {} ) as $loads |
      $all
      | map(select(.category != "_load" and (.passed != null)))
      | group_by([.model, .category])[]
      | { model:    .[0].model,
          category: .[0].category,
          ts:       (map(.ts) | min),
          score:    ( ( map(select(.passed)) | length | tostring )
                    + "/" + ( length | tostring ) ),
          ctx:      ( $loads[.[0].model] // 0 ) }
    ' "$_f" 2>/dev/null)
  done
  ;;

# ── commit <sha> ─────────────────────────────────────────────────────────────
commit)
  _pg_check
  _sha="${1:-}"
  [ -n "$_sha" ] || { printf 'usage: local/lineage.sh commit <sha>\n' >&2; exit 1; }

  # commit_provenance: job, model, prompt, sandbox_profile, machine
  # Prefix match so a git short-sha resolves (shas are hex; ':'sha' is bound, not interpolated).
  _row="$(PGCONNECT_TIMEOUT=3 psql "$(_pg_dsn)" -tAq -v sha="$_sha" 2>/dev/null <<'SQL'
SELECT commit_sha,
       coalesce(job_id,''),
       coalesce(model_version,''),
       coalesce(prompt_sha,''),
       coalesce(sandbox_profile,''),
       coalesce(machine,'')
FROM commit_provenance WHERE commit_sha LIKE :'sha' || '%' ORDER BY commit_sha LIMIT 1;
SQL
  )"

  if [ -z "$_row" ]; then
    printf 'no provenance for commit: %s\n' "$_sha"
    exit 0
  fi

  IFS='|' read -r _fullsha _job _model _prompt _profile _machine <<< "$_row"

  # Gate verdict: look up the most recent gate event in the job's event stream.
  # Stream convention: 'job-<job_natural_key>' (set by run.sh; matches lineage node key).
  _verdict="none"
  if [ -n "$_job" ]; then
    _v="$(PGCONNECT_TIMEOUT=3 psql "$(_pg_dsn)" -tAq -v s="job-${_job}" 2>/dev/null <<'SQL' || true
SELECT type FROM events
WHERE stream_name = :'s' AND type IN ('gate.passed','gate.failed')
  AND invalidated_by IS NULL
ORDER BY recorded_at DESC LIMIT 1;
SQL
    )"
    [ -n "$_v" ] && _verdict="$_v"
  fi

  printf 'Commit:   %s\n' "${_fullsha:-$_sha}"
  printf '  Job:    %s\n' "${_job:-(none)}"
  printf '  Model:  %s\n' "${_model:-(none)}"
  printf '  Prompt: %s\n' "${_prompt:-(none)}"
  printf '  Profile:%s\n' "${_profile:-(none)}"
  printf '  Machine:%s\n' "${_machine:-(none)}"
  printf '  Gate:   %s\n' "$_verdict"
  ;;

# ── model <id> ───────────────────────────────────────────────────────────────
model)
  _pg_check
  _id="${1:-}"
  [ -n "$_id" ] || { printf 'usage: local/lineage.sh model <id>\n' >&2; exit 1; }

  _rows="$(PGCONNECT_TIMEOUT=3 psql "$(_pg_dsn)" -tAq -v id="$_id" 2>/dev/null <<'SQL'
SELECT kind, natural_key FROM model_outputs WHERE model_version = :'id'
ORDER BY kind, natural_key;
SQL
  )"

  if [ -z "$_rows" ]; then
    printf 'no outputs for model: %s\n' "$_id"
    exit 0
  fi

  printf 'Model: %s\n' "$_id"
  while IFS='|' read -r _k _n; do
    printf '  %-8s %s\n' "$_k" "$_n"
  done <<< "$_rows"
  ;;

# ── bench [--all] ────────────────────────────────────────────────────────────
bench)
  _pg_check
  _all=0
  [ "${1:-}" = "--all" ] && _all=1

  if [ "$_all" = "1" ]; then
    _rows="$(PGCONNECT_TIMEOUT=3 psql "$(_pg_dsn)" -tAq 2>/dev/null <<'SQL'
SELECT model_version, category, score,
       CASE WHEN current THEN 'current' ELSE 'superseded' END
FROM bench_verdicts ORDER BY model_version, category, current DESC;
SQL
    )"
  else
    _rows="$(PGCONNECT_TIMEOUT=3 psql "$(_pg_dsn)" -tAq 2>/dev/null <<'SQL'
SELECT model_version, category, score FROM bench_verdicts WHERE current = true
ORDER BY model_version, category;
SQL
    )"
  fi

  if [ -z "$_rows" ]; then
    printf 'no bench verdicts\n'
    exit 0
  fi

  if [ "$_all" = "1" ]; then
    printf '%-32s %-16s %-10s %s\n' Model Category Score Status
    while IFS='|' read -r _mv _cat _sc _st; do
      printf '%-32s %-16s %-10s %s\n' "$_mv" "$_cat" "$_sc" "$_st"
    done <<< "$_rows"
  else
    printf '%-32s %-16s %s\n' Model Category Score
    while IFS='|' read -r _mv _cat _sc; do
      printf '%-32s %-16s %s\n' "$_mv" "$_cat" "$_sc"
    done <<< "$_rows"
  fi
  ;;

*)
  printf 'usage: local/lineage.sh import|commit|model|bench ...\n' >&2
  exit 1
  ;;

esac
