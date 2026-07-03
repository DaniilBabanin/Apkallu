-- 003_reap_idx.sql — partial index for reap_expired()'s lease scan (001_core.sql):
-- jobs WHERE state = 'running' AND visible_at <= now(). 001 only indexes the queued
-- claim path (jobs_claim_idx); the running-lease scan was a seq scan.
-- Applied by db/migrate.sh inside ONE transaction — no BEGIN/COMMIT in this file.

CREATE INDEX jobs_reap_idx ON jobs (visible_at) WHERE state = 'running';
