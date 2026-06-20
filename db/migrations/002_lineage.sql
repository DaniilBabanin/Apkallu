-- 002_lineage.sql — Phase 1 provenance lineage: generic nodes/edges graph + helpers + views.
-- Applied by db/migrate.sh inside ONE transaction — no BEGIN/COMMIT in this file.

CREATE TABLE nodes (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind        text   NOT NULL CHECK (kind IN (
                'commit','job','model_version','prompt','sandbox_profile',
                'machine','eval_result','decision')),
  natural_key text   NOT NULL,
  attrs       jsonb  NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (kind, natural_key)
);

CREATE TABLE edges (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  from_node      bigint NOT NULL REFERENCES nodes(id),
  to_node        bigint NOT NULL REFERENCES nodes(id),
  label          text   NOT NULL,
  attrs          jsonb  NOT NULL DEFAULT '{}'::jsonb,
  created_at     timestamptz NOT NULL DEFAULT now(),
  invalidated_by bigint REFERENCES edges(id),
  UNIQUE (from_node, to_node, label)
);

-- upsert_node: insert or ignore; always returns the id (new or existing).
CREATE FUNCTION upsert_node(p_kind text, p_natural_key text, p_attrs jsonb DEFAULT '{}'::jsonb)
RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO nodes (kind, natural_key, attrs)
  VALUES (p_kind, p_natural_key, p_attrs)
  ON CONFLICT (kind, natural_key) DO NOTHING;
  SELECT id INTO v_id FROM nodes WHERE kind = p_kind AND natural_key = p_natural_key;
  RETURN v_id;
END
$$;

-- add_edge: insert or ignore; returns the id (new or existing).
CREATE FUNCTION add_edge(p_from bigint, p_to bigint, p_label text, p_attrs jsonb DEFAULT '{}'::jsonb)
RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO edges (from_node, to_node, label, attrs)
  VALUES (p_from, p_to, p_label, p_attrs)
  ON CONFLICT (from_node, to_node, label) DO NOTHING;
  SELECT id INTO v_id FROM edges WHERE from_node = p_from AND to_node = p_to AND label = p_label;
  RETURN v_id;
END
$$;

-- commit_provenance: for each commit node, fan out to the job that produced it,
-- then from that job to model_version/prompt/sandbox_profile/machine (star join).
CREATE VIEW commit_provenance AS
WITH RECURSIVE lineage(commit_id, commit_key, job_id, job_key, depth) AS (
  SELECT n.id, n.natural_key, NULL::bigint, NULL::text, 0
  FROM nodes n WHERE n.kind = 'commit'
  UNION ALL
  SELECT l.commit_id, l.commit_key, e.to_node, j.natural_key, l.depth + 1
  FROM lineage l
  JOIN edges e ON e.from_node = l.commit_id AND e.label = 'produced_by' AND e.invalidated_by IS NULL
  JOIN nodes j ON j.id = e.to_node AND j.kind = 'job'
  WHERE l.depth = 0
)
SELECT
  l.commit_key  AS commit_sha,
  l.job_key     AS job_id,
  mv.natural_key AS model_version,
  pr.natural_key AS prompt_sha,
  sp.natural_key AS sandbox_profile,
  mc.natural_key AS machine
FROM lineage l
LEFT JOIN edges e_mv ON e_mv.from_node = l.job_id AND e_mv.label = 'ran_on'        AND e_mv.invalidated_by IS NULL
LEFT JOIN nodes mv   ON mv.id = e_mv.to_node  AND mv.kind = 'model_version'
LEFT JOIN edges e_pr ON e_pr.from_node = l.job_id AND e_pr.label = 'used_prompt'   AND e_pr.invalidated_by IS NULL
LEFT JOIN nodes pr   ON pr.id = e_pr.to_node  AND pr.kind = 'prompt'
LEFT JOIN edges e_sp ON e_sp.from_node = l.job_id AND e_sp.label = 'under_profile' AND e_sp.invalidated_by IS NULL
LEFT JOIN nodes sp   ON sp.id = e_sp.to_node  AND sp.kind = 'sandbox_profile'
LEFT JOIN edges e_mc ON e_mc.from_node = l.job_id AND e_mc.label = 'on_machine'    AND e_mc.invalidated_by IS NULL
LEFT JOIN nodes mc   ON mc.id = e_mc.to_node  AND mc.kind = 'machine'
-- Keep depth-1 rows always; keep the depth-0 anchor ONLY for commits with no
-- producing job (orphan commits) — else a provenanced commit emits a spurious
-- all-NULL row beside its real one.
WHERE l.depth > 0
   OR NOT EXISTS (
        SELECT 1 FROM edges e0
        WHERE e0.from_node = l.commit_id
          AND e0.label = 'produced_by'
          AND e0.invalidated_by IS NULL
      );

-- model_outputs: for each model_version node, list commits and jobs it produced.
CREATE VIEW model_outputs AS
WITH RECURSIVE out_chain(model_id, model_key, target_id, target_kind, target_key, depth) AS (
  SELECT n.id, n.natural_key, n.id, n.kind, n.natural_key, 0
  FROM nodes n WHERE n.kind = 'model_version'
  UNION ALL
  SELECT o.model_id, o.model_key, e.from_node, fn.kind, fn.natural_key, o.depth + 1
  FROM out_chain o
  JOIN edges e  ON e.to_node = o.target_id AND e.label IN ('ran_on','produced_by') AND e.invalidated_by IS NULL
  JOIN nodes fn ON fn.id = e.from_node AND fn.kind IN ('job','commit')
  WHERE o.depth < 5
)
SELECT model_key AS model_version, target_kind AS kind, target_key AS natural_key
FROM out_chain WHERE depth > 0;

-- bench_verdicts: current eval_result rows with their model, category, score;
-- current = the produced edge to this eval_result is not superseded.
CREATE VIEW bench_verdicts AS
SELECT
  mv.natural_key  AS model_version,
  er.attrs->>'category' AS category,
  er.attrs->>'score'    AS score,
  (e.invalidated_by IS NULL) AS current
FROM edges e
JOIN nodes mv ON mv.id = e.from_node AND mv.kind = 'model_version'
JOIN nodes er ON er.id = e.to_node   AND er.kind = 'eval_result'
WHERE e.label = 'produced';

-- Role-level append-only for nodes/edges:
--   SELECT + INSERT: always allowed
--   UPDATE: only edges.invalidated_by (supersession pointer)
--   DELETE: never
GRANT SELECT, INSERT ON nodes TO agency_loop;
GRANT SELECT, INSERT ON edges TO agency_loop;
GRANT UPDATE (invalidated_by) ON edges TO agency_loop;
GRANT SELECT ON commit_provenance TO agency_loop;
GRANT SELECT ON model_outputs     TO agency_loop;
GRANT SELECT ON bench_verdicts    TO agency_loop;
-- Sequence grants so GENERATED ALWAYS AS IDENTITY inserts work
GRANT USAGE ON SEQUENCE nodes_id_seq TO agency_loop;
GRANT USAGE ON SEQUENCE edges_id_seq TO agency_loop;
