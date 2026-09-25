-- =============================================================================
-- 03b_table_lifecycle.sql
-- One row per table of the UC schemas: creation, last DDL, statistics age and
-- DML volume since the last statistics gathering.
-- -----------------------------------------------------------------------------
-- Stack key : db_unique_name, con_dbid, collected_utc, owner, table_name
--             Same key and same table list as 03: join the two after stacking.
-- Needs     : SELECT_CATALOG_ROLE or SELECT ANY DICTIONARY. No AWR view used.
--
-- Performance design
--   Each dictionary view is read ONCE, restricted to the UC owners, and
--   materialised before the hash joins. Joined directly, DBA_OBJECTS and
--   DBA_TAB_MODIFICATIONS (UNION ALL views over obj$ and friends) can receive the
--   join predicate and be re-evaluated for every table row.
--   DBA_TAB_STATISTICS is not used: its STALE_STATS column is computed row by row,
--   and on Exadata real-time statistics add a second row per table
--   (NOTES = STATS_ON_CONVENTIONAL_DML) that would duplicate rows.
--
-- created / last_ddl_time  DBA_OBJECTS. A drop + re-create resets created,
--                          last_ddl_time also moves on grants and other DDL.
-- last_analyzed / num_rows DBA_TABLES, last gathered statistics.
-- dml_*                    DBA_TAB_MODIFICATIONS: DML since the last statistics
--                          gathering, flushed from memory periodically (not
--                          forced here, the query is read-only).
-- dml_pct_since_stats      100 * (inserts + updates + deletes) / num_rows
-- stale_est                YES when truncated, or when the DML exceeds
--                          params.stale_pct of num_rows (10 = Oracle default
--                          STALE_PERCENT, table-level preferences are ignored).
--                          NULL when the table was never analysed.
-- =============================================================================
WITH
params AS (
  SELECT '^(.+)_(DSSWORK|DSSOUT)$' AS schema_rx,                -- UC schemas
         10                        AS stale_pct                 -- default STALE_PERCENT
  FROM   dual
),
hdr AS (
  SELECT CAST(SYS_EXTRACT_UTC(SYSTIMESTAMP) AS DATE) AS collected_utc,
         d.name                                     AS db_name,
         d.db_unique_name,
         d.cdb,
         SYS_CONTEXT('USERENV', 'CON_NAME')         AS con_name,
         NVL(NULLIF(d.con_dbid, 0), d.dbid)         AS con_dbid,
         d.database_role
  FROM   v$database d
),
uc_schema AS (
  SELECT /*+ MATERIALIZE */
         u.username,
         REGEXP_SUBSTR(u.username, p.schema_rx, 1, 1, NULL, 1)     AS uc,
         REGEXP_SUBSTR(u.username, p.schema_rx, 1, 1, NULL, 2)     AS schema_layer
  FROM   dba_users u
         CROSS JOIN params p
  WHERE  REGEXP_LIKE(u.username, p.schema_rx)
),
-- same table list as 03 (IOT overflow / mapping and nested storage excluded)
tabs AS (
  SELECT /*+ MATERIALIZE */
         t.owner, t.table_name, t.num_rows, t.last_analyzed
  FROM   dba_tables t
  WHERE  t.owner IN (SELECT s.username FROM uc_schema s)
  AND    t.dropped = 'NO'
  AND    NVL(t.iot_type, 'IOT') = 'IOT'
  AND    t.nested = 'NO'
),
objs AS (
  SELECT /*+ MATERIALIZE */
         o.owner, o.object_name, o.created, o.last_ddl_time
  FROM   dba_objects o
  WHERE  o.owner IN (SELECT s.username FROM uc_schema s)
  AND    o.object_type = 'TABLE'
  AND    o.subobject_name IS NULL
),
mods AS (
  SELECT /*+ MATERIALIZE */
         m.table_owner, m.table_name, m.inserts, m.updates, m.deletes, m.truncated,
         m.timestamp                                               AS last_dml_ts
  FROM   dba_tab_modifications m
  WHERE  m.table_owner IN (SELECT s.username FROM uc_schema s)
  AND    m.partition_name    IS NULL
  AND    m.subpartition_name IS NULL
)
SELECT /*+ USE_HASH(o m) */
       h.collected_utc, h.db_name, h.db_unique_name, h.cdb, h.con_name, h.con_dbid, h.database_role,
       u.uc,
       u.schema_layer,
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
       JOIN uc_schema u ON u.username = t.owner
       CROSS JOIN hdr h
       CROSS JOIN params p
       LEFT JOIN objs o ON  o.owner       = t.owner
                        AND o.object_name = t.table_name
       LEFT JOIN mods m ON  m.table_owner = t.owner
                        AND m.table_name  = t.table_name
ORDER  BY u.uc, u.schema_layer, t.table_name;
