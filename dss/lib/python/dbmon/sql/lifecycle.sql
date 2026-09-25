-- dbmon template "lifecycle".
-- Derived from 03b_table_lifecycle.sql (repository root): no naming convention, the scope is
-- chosen by the caller, identity columns are added by the engine.
-- Rendered by dbmon/queries.py, not runnable as-is. Placeholders:
--   owner_filter     schemas in scope (default: non Oracle-maintained)
--   table_filter     keeps one table in DBA_TABLES
--   object_filter    same, in DBA_OBJECTS
--   mods_filter      same, in DBA_TAB_MODIFICATIONS
WITH
params AS (
  SELECT 10 AS stale_pct                                        -- default STALE_PERCENT
  FROM   dual
),
-- schemas in scope
scope AS (
  SELECT /*+ MATERIALIZE */
         u.username
  FROM   dba_users u
  WHERE  {{owner_filter}}
),
-- same table list as 03 (IOT overflow / mapping and nested storage excluded)
tabs AS (
  SELECT /*+ MATERIALIZE */
         t.owner, t.table_name, t.num_rows, t.last_analyzed
  FROM   dba_tables t
  WHERE  t.owner IN (SELECT s.username FROM scope s)
  AND    t.dropped = 'NO'
  AND    NVL(t.iot_type, 'IOT') = 'IOT'
  AND    t.nested = 'NO'
  {{table_filter}}
),
objs AS (
  SELECT /*+ MATERIALIZE */
         o.owner, o.object_name, o.created, o.last_ddl_time
  FROM   dba_objects o
  WHERE  o.owner IN (SELECT s.username FROM scope s)
  AND    o.object_type = 'TABLE'
  AND    o.subobject_name IS NULL
  {{object_filter}}
),
mods AS (
  SELECT /*+ MATERIALIZE */
         m.table_owner, m.table_name, m.inserts, m.updates, m.deletes, m.truncated,
         m.timestamp                                               AS last_dml_ts
  FROM   dba_tab_modifications m
  WHERE  m.table_owner IN (SELECT s.username FROM scope s)
  AND    m.partition_name    IS NULL
  AND    m.subpartition_name IS NULL
  {{mods_filter}}
)
SELECT /*+ USE_HASH(o m) */
       t.owner,
       t.table_name,
       o.created,
       o.last_ddl_time,
       t.last_analyzed,
       t.num_rows,
       m.inserts                                                   AS dml_inserts,
       m.updates                                                   AS dml_updates,
       m.deletes                                                   AS dml_deletes,
       m.truncated                                                 AS dml_truncated,
       m.last_dml_ts,
       ROUND(100 * (NVL(m.inserts, 0) + NVL(m.updates, 0) + NVL(m.deletes, 0))
             / NULLIF(t.num_rows, 0), 2)                           AS dml_pct_since_stats,
       CASE
         WHEN t.last_analyzed IS NULL THEN NULL
         WHEN m.truncated = 'YES'     THEN 'YES'
         WHEN NVL(m.inserts, 0) + NVL(m.updates, 0) + NVL(m.deletes, 0)
              > NVL(t.num_rows, 0) * p.stale_pct / 100
                                      THEN 'YES'
         ELSE 'NO'
       END                                                         AS stale_est
FROM   tabs t
       CROSS JOIN params p
       LEFT JOIN objs o ON  o.owner       = t.owner
                        AND o.object_name = t.table_name
       LEFT JOIN mods m ON  m.table_owner = t.owner
                        AND m.table_name  = t.table_name
ORDER  BY t.owner, t.table_name
