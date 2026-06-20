#!/usr/bin/env bash
# lib/pg.sh — psql wrapper for the agency loop control plane.
# Source this file to get: PG_AVAIL (0/1), pg_query, pg_append_event,
# pg_claim_next_job, pg_insert_job, pg_complete_job, pg_fail_job.
# All functions degrade to no-ops / rc 1 when PG is unavailable.
#
# Values reach SQL only through psql -v variables (:'var' quoting, SQL fed via
# stdin — psql does NOT interpolate variables in -c strings). Never build SQL by
# string interpolation here: titles, error text, and JSON payloads carry model
# output, and a $$ in them would break out of any dollar-quoting.
#
# Target override (tests): AGENCY_PG_HOST/PORT/DB/USER. The gate sets
# AGENCY_PG_PORT=1 (closed port → PG_AVAIL=0) so tests stay off the live DB.
#
# Sandbox auto-bridge: CLAUDE_CODE_HOST_HTTP_PROXY_PORT set → we are inside
# the bwrap worker sandbox. Direct host TCP is blocked; the sandbox ships an
# HTTP CONNECT proxy on that port. A socat tunnel forwards PG connections
# through it. (db/README.md §Sandbox connectivity, proven 2026-06-12.)

PG_HOST="${AGENCY_PG_HOST:-127.0.0.1}"
PG_PORT="${AGENCY_PG_PORT:-5432}"
PG_DB="${AGENCY_PG_DB:-agency}"
PG_USER="${AGENCY_PG_USER:-agency_loop}"
PG_BRIDGE_PID=""
PG_AVAIL="0"

_pg_dsn() {
  printf 'host=%s port=%s dbname=%s user=%s' "${PG_HOST}" "${PG_PORT}" "${PG_DB}" "${PG_USER}"
}

# 36 chars, hex digits and dashes only — enough to make UUID args inert.
_pg_uuid_ok() {
  case "$1" in *[!0-9a-fA-F-]*|"") return 1 ;; esac
  [ "${#1}" -eq 36 ]
}

_pg_init() {
  # In-sandbox: proxy HTTP CONNECT → raw TCP tunnel so psql can reach the host PG.
  if [ -n "${CLAUDE_CODE_HOST_HTTP_PROXY_PORT:-}" ] && command -v socat >/dev/null 2>&1; then
    local target_port="${PG_PORT}"
    PG_PORT=$(( 15432 + ( $$ % 1000 ) ))
    socat "TCP-LISTEN:${PG_PORT},fork,reuseaddr" \
      "PROXY:localhost:${PG_HOST}:${target_port},proxyport=${CLAUDE_CODE_HOST_HTTP_PROXY_PORT}" \
      >/dev/null 2>&1 &
    PG_BRIDGE_PID="$!"
    sleep 1
  fi
  command -v psql >/dev/null 2>&1 || return 0
  if PGCONNECT_TIMEOUT=3 psql "$(_pg_dsn)" -tAc 'SELECT 1' >/dev/null 2>&1; then
    PG_AVAIL="1"
  fi
}

_pg_cleanup() {
  [ -n "${PG_BRIDGE_PID:-}" ] && kill "${PG_BRIDGE_PID}" 2>/dev/null || true
}
trap '_pg_cleanup' EXIT

# pg_query <sql> — run a query, print tuples (unaligned, no header); rc 1 if PG unavail.
# Raw-SQL interface: callers pass CONSTANT statements only, never interpolated data.
pg_query() {
  [ "${PG_AVAIL}" = "1" ] || return 1
  PGCONNECT_TIMEOUT=3 psql "$(_pg_dsn)" -tAc "$1" 2>/dev/null
}

# pg_append_event <stream> <type> <data-json> — best-effort; rc 0 even when PG unavail.
pg_append_event() {
  [ "${PG_AVAIL}" = "1" ] || return 0
  PGCONNECT_TIMEOUT=3 psql "$(_pg_dsn)" -tA -v s="$1" -v t="$2" -v d="$3" \
    >/dev/null 2>&1 <<'SQL' || true
SELECT append_event(:'s', :'t', (:'d')::jsonb);
SQL
}

# pg_claim_next_job <claimer> — claims next queued job; prints JSON row or empty; rc 1 if unavail.
pg_claim_next_job() {
  [ "${PG_AVAIL}" = "1" ] || return 1
  PGCONNECT_TIMEOUT=3 psql "$(_pg_dsn)" -tA -v c="$1" 2>/dev/null <<'SQL'
SELECT row_to_json(r) FROM claim_next_job(:'c') r LIMIT 1;
SQL
}

# pg_insert_job <title> <done_condition> [blocked_by_uuid] — inserts a job row; prints UUID or empty.
pg_insert_job() {
  [ "${PG_AVAIL}" = "1" ] || return 1
  local bb="${3:-}"
  [ "$bb" = "NULL" ] && bb=""
  if [ -n "$bb" ] && ! _pg_uuid_ok "$bb"; then return 1; fi
  # -q: without it psql appends the "INSERT 0 1" command tag to the RETURNING value.
  PGCONNECT_TIMEOUT=3 psql "$(_pg_dsn)" -tAq -v t="$1" -v dc="$2" -v bb="$bb" 2>/dev/null <<'SQL'
INSERT INTO jobs (title, done_condition, blocked_by)
VALUES (:'t', :'dc', NULLIF(:'bb', '')::uuid) RETURNING id;
SQL
}

# pg_complete_job <uuid> <claimer> <commit_sha> — marks job done; best-effort.
pg_complete_job() {
  [ "${PG_AVAIL}" = "1" ] || return 0
  _pg_uuid_ok "$1" || return 0
  PGCONNECT_TIMEOUT=3 psql "$(_pg_dsn)" -tA -v id="$1" -v c="$2" -v rc="$3" \
    >/dev/null 2>&1 <<'SQL' || true
SELECT complete_job(:'id'::uuid, :'c', :'rc');
SQL
}

# pg_fail_job <uuid> <claimer> <error> — marks job failed/requeued; best-effort.
pg_fail_job() {
  [ "${PG_AVAIL}" = "1" ] || return 0
  _pg_uuid_ok "$1" || return 0
  PGCONNECT_TIMEOUT=3 psql "$(_pg_dsn)" -tA -v id="$1" -v c="$2" -v e="$3" \
    >/dev/null 2>&1 <<'SQL' || true
SELECT fail_job(:'id'::uuid, :'c', :'e');
SQL
}

# pg_node <kind> <natural_key> <attrs_json> — upsert lineage node; prints id; best-effort.
# Values bound via psql -v (:'var'), never interpolated — same injection discipline as above.
pg_node() {
  [ "${PG_AVAIL}" = "1" ] || return 0
  local _a; _a="${3:-}"; [ -n "$_a" ] || _a='{}'
  PGCONNECT_TIMEOUT=3 psql "$(_pg_dsn)" -tAq -v k="$1" -v n="$2" -v a="$_a" \
    2>/dev/null <<'SQL' || true
SELECT upsert_node(:'k', :'n', (:'a')::jsonb);
SQL
}

# pg_edge <from_id> <to_id> <label> [attrs_json] — add lineage edge; prints id; best-effort.
pg_edge() {
  [ "${PG_AVAIL}" = "1" ] || return 0
  local _a; _a="${4:-}"; [ -n "$_a" ] || _a='{}'
  PGCONNECT_TIMEOUT=3 psql "$(_pg_dsn)" -tAq -v f="$1" -v t="$2" -v l="$3" -v a="$_a" \
    2>/dev/null <<'SQL' || true
SELECT add_edge(:'f'::bigint, :'t'::bigint, :'l', (:'a')::jsonb);
SQL
}

_pg_init
