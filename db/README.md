# db/ — the Postgres control plane (Phase 0)

PostgreSQL 18, OS package, localhost-only, one database `agency`.
Design and rationale: `docs/analysis/implementation-plan.md` (Step 1 DDL, decided options)
and `docs/analysis/research-2026-06-12.md` §2. Schema lives in `migrations/`, applied by
`./migrate.sh` (idempotent, one transaction per migration, `schema_migrations` table).

## Roles & auth

| Role | Auth | Used by | Can |
|---|---|---|---|
| `db` | peer (unix socket) | migrations, admin psql | owns the `agency` DB and its tables |
| `agency_loop` | scram over TCP 127.0.0.1, password in `~/.pgpass` | all loop/dispatcher glue (`lib/pg.sh`, Step 2) | SELECT/INSERT everywhere; UPDATE only jobs state columns + `events.invalidated_by`; no DELETE |

Append-only on `events` is a permission, not a convention, plus a write-once trigger on
`invalidated_by`. Tests (Step 4) assert permission-denied. The default Ubuntu hba line
`host all all 127.0.0.1/32 scram-sha-256` covers `agency_loop`, so no pg_hba/pg_ident edits.

## Install runbook (fresh box)

```bash
sudo apt-get install -y postgresql-18                      # cluster auto-created, socket auth = peer
sudo -u postgres createuser db --createdb --createrole     # admin role = OS user (peer)
# tuning: this box also loads 48GB models — modest shared_buffers (restart required).
# OOM protection needs nothing: Ubuntu's packaged unit already ships OOMScoreAdjust=-900.
printf 'shared_buffers = 4GB\n' | sudo tee /etc/postgresql/18/main/conf.d/agency.conf
sudo systemctl restart postgresql@18-main
```

Then, as `db` (no sudo):

```bash
createdb -O db agency
./db/migrate.sh                                            # creates schema + agency_loop role
psql -d agency -qc "ALTER ROLE agency_loop PASSWORD '$(openssl rand -hex 24)'"   # then put it in ~/.pgpass:
# echo '127.0.0.1:*:agency:agency_loop:<that password>' >> ~/.pgpass && chmod 600 ~/.pgpass
psql 'host=127.0.0.1 dbname=agency user=agency_loop' -tAc 'SELECT current_user'  # → agency_loop
psql 'host=127.0.0.1 dbname=agency user=agency_loop' -c 'DELETE FROM events'     # MUST fail: permission denied
```

Status on tux (2026-06-12): all steps complete. shared_buffers=4GB live (director
paste confirmed), schema v1 live, nightly pg_dump timer wired (Step 5).

## Connecting

- Admin/migrations: `psql -d agency` (peer over unix socket as OS user `db`).
- Glue, unsandboxed (dispatcher side): `psql 'host=127.0.0.1 dbname=agency user=agency_loop'`;
  `.pgpass` supplies the password.
- Glue, inside the worker sandbox: see below.

## Sandbox connectivity (Step 0 — SOLVED 2026-06-12)

Findings from the spike (probed inside the real bwrap sandbox via a nested `claude -p`):

- Unix sockets are impossible in-sandbox. seccomp denies `socket(AF_UNIX)` at the syscall
  level (EPERM before any path is involved), so no path-scoped allow can exist;
  `sandbox.network.allowUnixSockets` + `filesystem.allowWrite` had no effect (tested,
  reverted). This also explains the bare `psql: error:` with empty detail.
- Direct TCP to host loopback is dead too (sandbox netns), but the sandbox ships an HTTP
  CONNECT proxy on `localhost:3128` (and SOCKS5 on `:1080`) whose allowlist includes
  `127.0.0.1`, and socat can tunnel raw TCP through it.

The recipe (what `lib/pg.sh` should do when it sees sandbox proxy env, e.g.
`CLAUDE_CODE_HOST_HTTP_PROXY_PORT`):

```bash
socat TCP-LISTEN:15432,fork,reuseaddr PROXY:localhost:127.0.0.1:5432,proxyport=3128 &
psql 'host=127.0.0.1 port=15432 dbname=agency user=agency_loop' ...
```

Auth is the same `~/.pgpass` scram entry (port-wildcarded `127.0.0.1:*:...`; home is
readable in-sandbox). Verified end-to-end in-sandbox: `SELECT current_user` →
`agency_loop`; `claim_next_job()` callable; `DELETE FROM events` → permission denied.
Pick the listen port per worker (e.g. 15432+worker-id) so concurrent workers don't collide.

## Backups

Nightly `pg_dump -Fc` via the 15-min `agency-watcher.timer` (first tick after midnight).
`local/watcher.sh` `do_backup()` function: checks `$STATE_DIR/last_backup_date`; if
today's dump hasn't run yet, writes `$AGENCY_BACKUP_DIR/agency-$(date +%F).dump`.

Env (set in `~/.config/agency/watcher.env` or system defaults):
- `AGENCY_BACKUP_DIR` — dump destination (default: `~/backups/agency`)
- `AGENCY_BACKUP_DB`  — database to dump (default: `agency`)

Auth: runs as OS user `db` (peer unix socket, no password). Logs `[watcher] backup: …`
each run. Fails safe: if `pg_dump` missing or fails, logs but never aborts the health cycle.

Restore drill (quarterly):
```bash
createdb agency_restore_test
pg_restore -d agency_restore_test ~/backups/agency/agency-YYYY-MM-DD.dump
psql -d agency_restore_test -tAc 'SELECT count(*) FROM events;'
dropdb agency_restore_test
```

## Lineage (Phase 1 — `db/migrations/002_lineage.sql`)

Generic provenance graph: nodes + edges, with supersession via `invalidated_by`.

### Schema

**`nodes`** — one row per named entity:

| Column | Type | Notes |
|---|---|---|
| `id` | bigint identity | surrogate PK |
| `kind` | text | `commit`, `job`, `model_version`, `prompt`, `sandbox_profile`, `machine`, `eval_result`, `decision` |
| `natural_key` | text | stable identifier (git SHA, UUID, model id string, sha256 hash, …) |
| `attrs` | jsonb | kind-specific metadata (e.g. `{"subject":"…"}` for commits, `{"score":"14/15"}` for eval_results) |
| `created_at` | timestamptz | insert timestamp |
| UNIQUE | (kind, natural_key) | upsert via `ON CONFLICT DO NOTHING` — same entity never duplicates |

**`edges`** — directed labelled connections:

| Column | Type | Notes |
|---|---|---|
| `id` | bigint identity | surrogate PK |
| `from_node` | bigint FK nodes | source |
| `to_node` | bigint FK nodes | target |
| `label` | text | e.g. `produced_by`, `ran_on`, `used_prompt`, `under_profile`, `on_machine`, `produced` |
| `attrs` | jsonb | edge payload (category/score/ts on `produced` edges) |
| `invalidated_by` | bigint FK edges | supersession pointer — set to the newer edge id when a verdict is superseded; NULL = current |
| UNIQUE | (from_node, to_node, label) | idempotent add via `ON CONFLICT DO NOTHING` |

Append-only enforcement: `agency_loop` has SELECT + INSERT on both tables; UPDATE is permitted **only** on `edges.invalidated_by` (column-level grant). No DELETE. Supersession never destroys data: older verdicts remain queryable via `bench_verdicts WHERE current = false`.

### SQL helpers

```sql
SELECT upsert_node('commit', '<sha>', '{"subject":"…"}'::jsonb);  -- returns bigint id
SELECT add_edge(<from_id>, <to_id>, 'produced_by', '{}'::jsonb);  -- returns bigint id
```

Both follow the insert-then-select pattern (not `RETURNING`) because `ON CONFLICT DO NOTHING RETURNING id` returns 0 rows on conflict.

### Views

| View | What it answers |
|---|---|
| `commit_provenance` | For each commit: the job that produced it + model, prompt, sandbox_profile, machine (recursive CTE, depth ≤ 1 commit→job then star-join) |
| `model_outputs` | All nodes a model version linked to (via any outgoing edge from its job nodes) |
| `bench_verdicts` | Per-(model, category): score, `current` boolean (false = superseded by a newer import) |

### CLI queries

```bash
local/lineage.sh commit <sha>      # prefix-matched; prints job/model/prompt/profile/machine/gate-verdict
local/lineage.sh model <id>        # all outputs for a model version
local/lineage.sh bench             # current verdicts only
local/lineage.sh bench --all       # current + superseded (shows invalidation history)
```

### Import (eval results)

```bash
local/lineage.sh import [file...]  # default: evals/results/*.ndjson
```

Aggregates per `(model, category)` via `jq -sc`, upserts `model_version` + `eval_result` nodes (natural key = `sha256(model|category|ts)`), adds `produced` edges with `{category, score, ts, ctx}` attrs. Idempotent: re-importing the same file adds 0 rows. Supersession: when a newer-ts result for the same `(model, category)` is imported, the older `produced` edge's `invalidated_by` is set; the older verdict is retained, not deleted.
