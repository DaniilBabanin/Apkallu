-- 001_core.sql — Phase 0 control-plane core: job queue + append-only event log.
--   * jobs:   pgmq-style visibility-timeout lease (visible_at) — an expired claim simply
--             becomes claimable again; no janitor daemon (reap_expired is called
--             opportunistically by dispatchers).
--   * events: message-db-shaped — gappy global position, gapless per-stream position,
--             supersession via invalidated_by (append-only "poor man's bi-temporal").
--   * append-only is enforced at the ROLE level (agency_loop grants below), not by
--             convention; plus a write-once trigger on events.invalidated_by.
-- Applied by db/migrate.sh inside ONE transaction — no BEGIN/COMMIT in this file.

-- Restricted role the loop/dispatcher glue connects as (auth wiring: db/README.md).
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'agency_loop') THEN
    CREATE ROLE agency_loop LOGIN;
  END IF;
END
$$;

CREATE TABLE jobs (
  id             uuid PRIMARY KEY DEFAULT uuidv7(),
  project        text NOT NULL DEFAULT 'agency',
  title          text NOT NULL,
  done_condition text NOT NULL,                       -- the /goal contract
  requires       jsonb NOT NULL DEFAULT '{}'::jsonb,  -- {"cloud_credit":true} | {"local_model_class":"coder"} | {"cpu":true}
  blocked_by     uuid REFERENCES jobs(id),
  priority       int  NOT NULL DEFAULT 5,             -- higher = claimed sooner
  state          text NOT NULL DEFAULT 'queued'
                 CHECK (state IN ('queued','running','done','failed','cancelled')),
  attempt        int  NOT NULL DEFAULT 0,
  max_attempts   int  NOT NULL DEFAULT 3,
  visible_at     timestamptz NOT NULL DEFAULT now(),  -- lease: claim sets now()+lease
  claimed_by     text,                                -- last claimer (kept for forensics)
  result_commit  text,                                -- gate-green commit SHA (git stays the verdict store)
  last_error     text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  finished_at    timestamptz
);

CREATE INDEX jobs_claim_idx ON jobs (priority DESC, created_at) WHERE state = 'queued';

CREATE TABLE events (
  global_position bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  stream_name     text NOT NULL,                      -- 'job-<uuid>', 'spend-2026-06', 'decision-D021'
  position        bigint NOT NULL,                    -- gapless per stream (append_event only)
  type            text NOT NULL,                      -- job.claimed, gate.passed, spend.recorded, ...
  schema_version  int  NOT NULL DEFAULT 1,
  data            jsonb NOT NULL,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb, -- actor, machine, model, prompt_hash
  recorded_at     timestamptz NOT NULL DEFAULT now(),
  invalidated_by  bigint REFERENCES events(global_position), -- supersession pointer, NULL = current
  UNIQUE (stream_name, position)
);

-- Write-once guard: the ONLY legal UPDATE on events sets invalidated_by, once.
-- Defense in depth on top of the column-level grant (protects superuser sessions too).
CREATE FUNCTION events_invalidate_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.invalidated_by IS NOT NULL THEN
    RAISE EXCEPTION 'events are append-only: % is already invalidated by %',
      OLD.global_position, OLD.invalidated_by;
  END IF;
  IF (to_jsonb(NEW) - 'invalidated_by') IS DISTINCT FROM (to_jsonb(OLD) - 'invalidated_by') THEN
    RAISE EXCEPTION 'events are append-only: only invalidated_by may change (event %)',
      OLD.global_position;
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER events_invalidate_guard
  BEFORE UPDATE ON events
  FOR EACH ROW EXECUTE FUNCTION events_invalidate_guard();

-- append_event: the single write path for events. Serializes writers per stream with an
-- advisory xact lock so per-stream positions stay gapless; optional optimistic concurrency
-- via p_expected_version (message-db's write_message semantics). Returns global_position.
CREATE FUNCTION append_event(
  p_stream           text,
  p_type             text,
  p_data             jsonb,
  p_metadata         jsonb DEFAULT '{}'::jsonb,
  p_expected_version bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  v_current bigint;
  v_global  bigint;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_stream, 0));
  SELECT COALESCE(MAX(position), 0) INTO v_current FROM events WHERE stream_name = p_stream;
  IF p_expected_version IS NOT NULL AND p_expected_version <> v_current THEN
    RAISE EXCEPTION 'append_event: stream % is at version %, expected %',
      p_stream, v_current, p_expected_version;
  END IF;
  INSERT INTO events (stream_name, position, type, data, metadata)
  VALUES (p_stream, v_current + 1, p_type, p_data, p_metadata)
  RETURNING global_position INTO v_global;
  RETURN v_global;
END
$$;

-- claim_next_job: capability-aware claim. A job is claimable when queued, its lease/backoff
-- has elapsed, its requires are a subset of the claimer's caps, and its blocker (if any) is
-- done. Jobs whose blocker failed/was cancelled stay blocked — Step 3 reconcile reports them.
-- Returns 0 or 1 rows.
CREATE FUNCTION claim_next_job(
  p_claimer text,
  p_caps    jsonb    DEFAULT '{}'::jsonb,
  p_lease   interval DEFAULT interval '30 minutes'
) RETURNS SETOF jobs
LANGUAGE sql AS $$
  UPDATE jobs
     SET state      = 'running',
         attempt    = attempt + 1,
         claimed_by = p_claimer,
         visible_at = now() + p_lease
   WHERE id = (
     SELECT j.id
       FROM jobs j
      WHERE j.state = 'queued'
        AND j.visible_at <= now()
        AND j.requires <@ p_caps
        AND (j.blocked_by IS NULL OR EXISTS (
               SELECT 1 FROM jobs b WHERE b.id = j.blocked_by AND b.state = 'done'))
      ORDER BY j.priority DESC, j.created_at
        FOR UPDATE SKIP LOCKED
      LIMIT 1)
  RETURNING *;
$$;

-- complete_job / fail_job guard on (state, claimed_by): a zombie worker whose lease expired
-- and whose job was reclaimed by someone else gets a no-op (returns NULL), never an overwrite.
CREATE FUNCTION complete_job(p_id uuid, p_claimer text, p_result_commit text)
RETURNS boolean
LANGUAGE sql AS $$
  UPDATE jobs
     SET state = 'done', result_commit = p_result_commit, finished_at = now()
   WHERE id = p_id AND state = 'running' AND claimed_by = p_claimer
  RETURNING true;
$$;

-- fail_job: retry with exponential backoff (2,4,8,... minutes — power(2, attempt), and claim
-- has already bumped attempt to 1 on the first try) until max_attempts, then
-- dead-letter as 'failed'.
CREATE FUNCTION fail_job(p_id uuid, p_claimer text, p_error text)
RETURNS boolean
LANGUAGE sql AS $$
  UPDATE jobs
     SET state       = CASE WHEN attempt >= max_attempts THEN 'failed' ELSE 'queued' END,
         last_error  = p_error,
         finished_at = CASE WHEN attempt >= max_attempts THEN now() END,
         visible_at  = CASE WHEN attempt >= max_attempts THEN visible_at
                            ELSE now() + interval '1 minute' * power(2, attempt) END
   WHERE id = p_id AND state = 'running' AND claimed_by = p_claimer
  RETURNING true;
$$;

-- reap_expired: running jobs whose lease elapsed go back to queued (or dead-letter at
-- max_attempts). No daemon — dispatchers call this before claiming. Returns count reaped.
CREATE FUNCTION reap_expired() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  v_count integer;
BEGIN
  WITH expired AS (
    SELECT id, attempt, max_attempts
      FROM jobs
     WHERE state = 'running' AND visible_at <= now()
       FOR UPDATE SKIP LOCKED
  ), reaped AS (
    UPDATE jobs j
       SET state       = CASE WHEN e.attempt >= e.max_attempts THEN 'failed' ELSE 'queued' END,
           last_error  = CASE WHEN e.attempt >= e.max_attempts
                              THEN coalesce(j.last_error || ' | ', '') || 'lease expired at max_attempts'
                              ELSE j.last_error END,
           finished_at = CASE WHEN e.attempt >= e.max_attempts THEN now() END,
           visible_at  = CASE WHEN e.attempt >= e.max_attempts THEN j.visible_at ELSE now() END
      FROM expired e
     WHERE j.id = e.id
    RETURNING j.id
  )
  SELECT count(*) INTO v_count FROM reaped;
  RETURN v_count;
END
$$;

-- Role-level append-only: agency_loop can read and insert everywhere, UPDATE only the jobs
-- state columns and events.invalidated_by, DELETE nothing. Tests assert permission-denied.
GRANT USAGE ON SCHEMA public TO agency_loop;
GRANT SELECT, INSERT ON jobs   TO agency_loop;
GRANT UPDATE (state, attempt, visible_at, claimed_by, result_commit, last_error, finished_at)
  ON jobs TO agency_loop;
GRANT SELECT, INSERT ON events TO agency_loop;
GRANT UPDATE (invalidated_by) ON events TO agency_loop;
-- Functions: EXECUTE is granted to PUBLIC by default; they run as SECURITY INVOKER, so
-- agency_loop's column grants above are exactly what they can touch.
