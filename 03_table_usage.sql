-- =============================================================================
-- 03_table_usage.sql
-- One row per table of the UC schemas, every dependent segment rolled up:
-- table (sub)partitions, indexes, LOB segments, LOB indexes, IOT overflow and
-- nested table storage, in whichever tablespace they are stored.
-- -----------------------------------------------------------------------------
-- Stack key : db_unique_name, con_dbid, collected_utc, owner, table_name
-- Scope     : live objects only (recycle bin excluded the same way as in 02).
--             Tables without any segment (deferred segment creation, global
--             temporary, external) are listed with 0 MB. Segments that cannot be
--             tied to a table (cluster, TEMPORARY segment of a CTAS in progress)
--             get their own row, table_kind showing the segment type.
-- Needs     : SELECT_CATALOG_ROLE or SELECT ANY DICTIONARY. No AWR view used.
--
-- in_data_ts_mb / in_index_ts_mb / in_foreign_ts_mb
--      split of total_mb by location: the owner's _DATA tablespace, the owner's
--      _INDEX tablespace, anywhere else (see placement in 02).
-- est_row_data_mb
--      num_rows * avg_row_len from optimizer statistics. Against table_mb:
--      ratio above 1 = compression gain (HCC), ratio far below 1 on an uncompressed
--      heap table = empty space below the high water mark.
-- Lifecycle (creation, last DDL, DML since last statistics) is collected by
-- 03b_table_lifecycle.sql, same stack key.
-- =============================================================================
WITH
params AS (
  SELECT '^(.+)_(DSSWORK|DSSOUT)$'              AS schema_rx,   -- UC schemas
         '^(.+)_(DSSWORK|DSSOUT)_(DATA|INDEX)$' AS ts_rx        -- UC tablespaces
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
  SELECT u.username,
         REGEXP_SUBSTR(u.username, p.schema_rx, 1, 1, NULL, 1)     AS uc,
         REGEXP_SUBSTR(u.username, p.schema_rx, 1, 1, NULL, 2)     AS schema_layer
  FROM   dba_users u
         CROSS JOIN params p
  WHERE  REGEXP_LIKE(u.username, p.schema_rx)
),
ts_map AS (
  SELECT t.tablespace_name,
         REGEXP_SUBSTR(t.tablespace_name, p.ts_rx, 1, 1, NULL, 3)  AS ts_role,
         CASE WHEN REGEXP_LIKE(t.tablespace_name, p.ts_rx)
              THEN REGEXP_REPLACE(t.tablespace_name, '_(DATA|INDEX)$')
         END                                                       AS ts_schema
  FROM   dba_tablespaces t
         CROSS JOIN params p
),
rb AS (
  SELECT DISTINCT r.owner, r.object_name
  FROM   dba_recyclebin r
),
seg AS (
  SELECT s.owner, s.segment_name, s.partition_name, s.segment_type,
         s.tablespace_name, s.bytes
  FROM   dba_segments s
         JOIN uc_schema u ON u.username = s.owner
  WHERE  NOT EXISTS (SELECT 1
                     FROM   rb
                     WHERE  rb.owner       = s.owner
                     AND    rb.object_name = s.segment_name)
),
ix AS (
  SELECT i.owner, i.index_name, i.index_type, i.table_owner, i.table_name
  FROM   dba_indexes i
         JOIN uc_schema u ON u.username = i.owner
),
lb AS (
  SELECT l.owner, l.segment_name, l.table_name
  FROM   dba_lobs l
         JOIN uc_schema u ON u.username = l.owner
),
tb AS (
  SELECT t.owner, t.table_name, t.dropped, t.nested, t.iot_type, t.iot_name,
         t.temporary, t.cluster_name, t.partitioned, t.segment_created,
         t.compression, t.compress_for,
         t.num_rows, t.avg_row_len, t.last_analyzed
  FROM   dba_tables t
         JOIN uc_schema u ON u.username = t.owner
),
nt AS (
  SELECT n.owner, n.table_name, n.parent_table_name
  FROM   dba_nested_tables n
         JOIN uc_schema u ON u.username = n.owner
),
tp AS (
  SELECT p.table_owner, p.table_name, p.partition_name, p.compression, p.compress_for
  FROM   dba_tab_partitions p
         JOIN uc_schema u ON u.username = p.table_owner
),
tsp AS (
  SELECT sp.table_owner, sp.table_name, sp.subpartition_name, sp.compression, sp.compress_for
  FROM   dba_tab_subpartitions sp
         JOIN uc_schema u ON u.username = sp.table_owner
),
-- same resolution rules as 02_object_usage.sql
seg_res AS (
  SELECT g.owner, g.segment_name, g.partition_name, g.segment_type,
         g.tablespace_name, g.bytes,
         CASE
           WHEN g.segment_type IN ('LOBSEGMENT', 'LOB PARTITION', 'LOB SUBPARTITION')  THEN 'LOB'
           WHEN g.segment_type = 'LOBINDEX' OR i.index_type = 'LOB'                   THEN 'LOBINDEX'
           WHEN i.index_type = 'IOT - TOP'                                            THEN 'TABLE'
           WHEN g.segment_type IN ('INDEX', 'INDEX PARTITION', 'INDEX SUBPARTITION')  THEN 'INDEX'
           WHEN g.segment_type IN ('TABLE', 'TABLE PARTITION', 'TABLE SUBPARTITION',
                                   'NESTED TABLE', 'CLUSTER')                         THEN 'TABLE'
           ELSE 'OTHER'
         END                                                                          AS family,
         COALESCE(i.table_owner, g.owner)                                             AS parent_owner,
         COALESCE(l.table_name,
                  i.table_name,
                  t.iot_name,
                  n.parent_table_name,
                  CASE WHEN g.segment_type IN ('TABLE', 'TABLE PARTITION', 'TABLE SUBPARTITION',
                                               'NESTED TABLE')
                       THEN g.segment_name
                  END)                                                                AS parent_table,
         CASE
           WHEN g.segment_type = 'TABLE SUBPARTITION'
             THEN DECODE(sp.compression, 'ENABLED', sp.compress_for, 'NONE')
           WHEN g.segment_type = 'TABLE PARTITION'
             THEN DECODE(p.compression, 'ENABLED', p.compress_for, 'NONE')
           WHEN g.segment_type IN ('TABLE', 'NESTED TABLE')
             THEN DECODE(t.compression, 'ENABLED', t.compress_for, 'NONE')
         END                                                                          AS table_compression,
         m.ts_role,
         m.ts_schema
  FROM   seg g
         LEFT JOIN ix  i  ON  g.segment_type IN ('INDEX', 'INDEX PARTITION', 'INDEX SUBPARTITION', 'LOBINDEX')
                          AND i.owner      = g.owner
                          AND i.index_name = g.segment_name
         LEFT JOIN lb  l  ON  g.segment_type IN ('LOBSEGMENT', 'LOB PARTITION', 'LOB SUBPARTITION')
                          AND l.owner        = g.owner
                          AND l.segment_name = g.segment_name
         LEFT JOIN tb  t  ON  g.segment_type IN ('TABLE', 'TABLE PARTITION', 'TABLE SUBPARTITION', 'NESTED TABLE')
                          AND t.owner      = g.owner
                          AND t.table_name = g.segment_name
         LEFT JOIN nt  n  ON  g.segment_type = 'NESTED TABLE'
                          AND n.owner      = g.owner
                          AND n.table_name = g.segment_name
         LEFT JOIN tp  p  ON  g.segment_type = 'TABLE PARTITION'
                          AND p.table_owner    = g.owner
                          AND p.table_name     = g.segment_name
                          AND p.partition_name = g.partition_name
         LEFT JOIN tsp sp ON  g.segment_type = 'TABLE SUBPARTITION'
                          AND sp.table_owner       = g.owner
                          AND sp.table_name        = g.segment_name
                          AND sp.subpartition_name = g.partition_name
         LEFT JOIN ts_map m ON m.tablespace_name = g.tablespace_name
),
seg_cls AS (
  SELECT r.*,
         CASE
           WHEN r.ts_schema IS NULL OR r.ts_schema <> r.owner                    THEN 'FOREIGN_TS'
           WHEN r.family IN ('TABLE', 'LOB', 'LOBINDEX') AND r.ts_role = 'INDEX' THEN 'DATA_IN_INDEX_TS'
           WHEN r.family = 'INDEX' AND r.ts_role = 'DATA'                        THEN 'INDEX_IN_DATA_TS'
           ELSE 'OK'
         END                                                                     AS placement
  FROM   seg_res r
),
-- roll every segment up to its table
tab_roll AS (
  SELECT c.parent_owner                                                          AS owner,
         NVL(c.parent_table, c.segment_name)                                     AS table_name,
         MAX(CASE WHEN c.parent_table IS NULL THEN c.segment_type END)           AS unresolved_type,
         COUNT(*)                                                                AS n_segments,
         SUM(c.bytes)                                                            AS total_bytes,
         SUM(CASE WHEN c.family = 'TABLE'    THEN c.bytes ELSE 0 END)            AS table_bytes,
         SUM(CASE WHEN c.family = 'INDEX'    THEN c.bytes ELSE 0 END)            AS index_bytes,
         SUM(CASE WHEN c.family = 'LOB'      THEN c.bytes ELSE 0 END)            AS lob_bytes,
         SUM(CASE WHEN c.family = 'LOBINDEX' THEN c.bytes ELSE 0 END)            AS lobindex_bytes,
         SUM(CASE WHEN c.family = 'OTHER'    THEN c.bytes ELSE 0 END)            AS other_bytes,
         SUM(CASE WHEN c.placement <> 'FOREIGN_TS' AND c.ts_role = 'DATA'
                  THEN c.bytes ELSE 0 END)                                       AS in_data_ts_bytes,
         SUM(CASE WHEN c.placement <> 'FOREIGN_TS' AND c.ts_role = 'INDEX'
                  THEN c.bytes ELSE 0 END)                                       AS in_index_ts_bytes,
         SUM(CASE WHEN c.placement = 'FOREIGN_TS'
                  THEN c.bytes ELSE 0 END)                                       AS in_foreign_ts_bytes,
         COUNT(DISTINCT c.tablespace_name)                                       AS n_tablespaces,
         LISTAGG(DISTINCT c.tablespace_name, ',')
           WITHIN GROUP (ORDER BY c.tablespace_name)                             AS tablespaces,
         LISTAGG(DISTINCT NULLIF(c.placement, 'OK'), ',')
           WITHIN GROUP (ORDER BY NULLIF(c.placement, 'OK'))                     AS placement_issues,
         COUNT(DISTINCT CASE WHEN c.family = 'INDEX' THEN c.segment_name END)    AS n_indexes,
         COUNT(DISTINCT CASE WHEN c.family = 'LOB'   THEN c.segment_name END)    AS n_lob_segments,
         SUM(CASE WHEN c.family = 'TABLE' AND c.partition_name IS NOT NULL
                  THEN 1 ELSE 0 END)                                             AS n_table_partitions,
         LISTAGG(DISTINCT c.table_compression, ',')
           WITHIN GROUP (ORDER BY c.table_compression)                           AS table_compression
  FROM   seg_cls c
  GROUP  BY c.parent_owner, NVL(c.parent_table, c.segment_name)
),
-- table list: IOT overflow / mapping tables and nested table storage are
-- already rolled up into their parent, so they are not listed on their own
tabs AS (
  SELECT t.*
  FROM   tb t
  WHERE  t.dropped = 'NO'
  AND    NVL(t.iot_type, 'IOT') = 'IOT'
  AND    t.nested = 'NO'
)
SELECT h.collected_utc, h.db_name, h.db_unique_name, h.cdb, h.con_name, h.con_dbid, h.database_role,
       u.uc,
       u.schema_layer,
       COALESCE(t.owner, r.owner)                                                AS owner,
       COALESCE(t.table_name, r.table_name)                                      AS table_name,
       CASE
         WHEN t.table_name IS NULL        THEN NVL(r.unresolved_type, 'UNRESOLVED')
         WHEN t.temporary = 'Y'           THEN 'GLOBAL TEMPORARY'
         WHEN t.iot_type = 'IOT'          THEN 'IOT'
         WHEN t.cluster_name IS NOT NULL  THEN 'CLUSTERED'
         WHEN t.partitioned = 'YES'       THEN 'PARTITIONED'
         ELSE 'HEAP'
       END                                                                       AS table_kind,
       t.segment_created,
       NVL(r.n_segments, 0)                                                      AS n_segments,
       -- footprint by segment family
       ROUND(NVL(r.total_bytes,    0) / 1048576, 3)                              AS total_mb,
       ROUND(NVL(r.table_bytes,    0) / 1048576, 3)                              AS table_mb,
       ROUND(NVL(r.index_bytes,    0) / 1048576, 3)                              AS index_mb,
       ROUND(NVL(r.lob_bytes,      0) / 1048576, 3)                              AS lob_mb,
       ROUND(NVL(r.lobindex_bytes, 0) / 1048576, 3)                              AS lobindex_mb,
       ROUND(NVL(r.other_bytes,    0) / 1048576, 3)                              AS other_mb,
       -- footprint by location
       ROUND(NVL(r.in_data_ts_bytes,    0) / 1048576, 3)                         AS in_data_ts_mb,
       ROUND(NVL(r.in_index_ts_bytes,   0) / 1048576, 3)                         AS in_index_ts_mb,
       ROUND(NVL(r.in_foreign_ts_bytes, 0) / 1048576, 3)                         AS in_foreign_ts_mb,
       NVL(r.n_tablespaces, 0)                                                   AS n_tablespaces,
       r.tablespaces,
       r.placement_issues,
       -- structure
       NVL(r.n_indexes, 0)                                                       AS n_indexes,
       NVL(r.n_lob_segments, 0)                                                  AS n_lob_segments,
       NVL(r.n_table_partitions, 0)                                              AS n_table_partitions,
       r.table_compression,
       -- optimizer statistics (DBA_TABLES, already read above)
       t.num_rows,
       t.avg_row_len,
       ROUND(t.num_rows * t.avg_row_len / 1048576, 3)                            AS est_row_data_mb,
       t.last_analyzed
FROM   tabs t
       FULL OUTER JOIN tab_roll r ON  r.owner      = t.owner
                                  AND r.table_name = t.table_name
       CROSS JOIN hdr h
       LEFT JOIN uc_schema u ON u.username = COALESCE(t.owner, r.owner)
ORDER  BY u.uc, u.schema_layer, NVL(r.total_bytes, 0) DESC;
