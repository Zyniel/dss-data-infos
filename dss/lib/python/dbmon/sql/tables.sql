-- dbmon template "tables".
-- Derived from 03_table_usage.sql (repository root): no naming convention, the scope is
-- chosen by the caller, identity columns are added by the engine.
-- Rendered by dbmon/queries.py, not runnable as-is. Placeholders:
--   owner_filter     schemas in scope (default: non Oracle-maintained)
--   table_filter     keeps one table
WITH
-- schemas in scope, with their default tablespace
scope AS (
  SELECT u.username, u.default_tablespace
  FROM   dba_users u
  WHERE  {{owner_filter}}
),
-- tablespaces where each schema holds a quota, besides its default one
quotas AS (
  SELECT q.username, q.tablespace_name
  FROM   dba_ts_quotas q
  WHERE  q.dropped = 'NO'
  AND    q.max_bytes <> 0
  AND    q.username IN (SELECT s.username FROM scope s)
),
rb AS (
  SELECT DISTINCT r.owner, r.object_name
  FROM   dba_recyclebin r
),
seg AS (
  SELECT s.owner, s.segment_name, s.partition_name, s.segment_type,
         s.tablespace_name, s.bytes
  FROM   dba_segments s
         JOIN scope u ON u.username = s.owner
  WHERE  NOT EXISTS (SELECT 1
                     FROM   rb
                     WHERE  rb.owner       = s.owner
                     AND    rb.object_name = s.segment_name)
),
ix AS (
  SELECT i.owner, i.index_name, i.index_type, i.table_owner, i.table_name
  FROM   dba_indexes i
         JOIN scope u ON u.username = i.owner
),
lb AS (
  SELECT l.owner, l.segment_name, l.table_name
  FROM   dba_lobs l
         JOIN scope u ON u.username = l.owner
),
tb AS (
  SELECT t.owner, t.table_name, t.dropped, t.nested, t.iot_type, t.iot_name,
         t.temporary, t.cluster_name, t.partitioned, t.segment_created,
         t.compression, t.compress_for,
         t.num_rows, t.avg_row_len, t.last_analyzed
  FROM   dba_tables t
         JOIN scope u ON u.username = t.owner
),
nt AS (
  SELECT n.owner, n.table_name, n.parent_table_name
  FROM   dba_nested_tables n
         JOIN scope u ON u.username = n.owner
),
tp AS (
  SELECT p.table_owner, p.table_name, p.partition_name, p.compression, p.compress_for
  FROM   dba_tab_partitions p
         JOIN scope u ON u.username = p.table_owner
),
tsp AS (
  SELECT sp.table_owner, sp.table_name, sp.subpartition_name, sp.compression, sp.compress_for
  FROM   dba_tab_subpartitions sp
         JOIN scope u ON u.username = sp.table_owner
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
         CASE
           WHEN g.tablespace_name = sc.default_tablespace THEN 'DEFAULT'
           WHEN q.tablespace_name IS NOT NULL            THEN 'QUOTA'
           ELSE 'OTHER'
         END                                                                          AS ts_kind
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
         JOIN scope sc ON sc.username = g.owner
         LEFT JOIN quotas q ON  q.username        = g.owner
                           AND q.tablespace_name = g.tablespace_name
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
         SUM(CASE WHEN c.ts_kind = 'DEFAULT' THEN c.bytes ELSE 0 END)            AS in_default_ts_bytes,
         SUM(CASE WHEN c.ts_kind = 'QUOTA'   THEN c.bytes ELSE 0 END)            AS in_quota_ts_bytes,
         SUM(CASE WHEN c.ts_kind = 'OTHER'   THEN c.bytes ELSE 0 END)            AS in_other_ts_bytes,
         COUNT(DISTINCT c.tablespace_name)                                       AS n_tablespaces,
         LISTAGG(DISTINCT c.tablespace_name, ',')
           WITHIN GROUP (ORDER BY c.tablespace_name)                             AS tablespaces,
         COUNT(DISTINCT CASE WHEN c.family = 'INDEX' THEN c.segment_name END)    AS n_indexes,
         COUNT(DISTINCT CASE WHEN c.family = 'LOB'   THEN c.segment_name END)    AS n_lob_segments,
         SUM(CASE WHEN c.family = 'TABLE' AND c.partition_name IS NOT NULL
                  THEN 1 ELSE 0 END)                                             AS n_table_partitions,
         LISTAGG(DISTINCT c.table_compression, ',')
           WITHIN GROUP (ORDER BY c.table_compression)                           AS table_compression
  FROM   seg_res c
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
SELECT
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
       ROUND(NVL(r.in_default_ts_bytes, 0) / 1048576, 3)                         AS in_default_ts_mb,
       ROUND(NVL(r.in_quota_ts_bytes,   0) / 1048576, 3)                         AS in_quota_ts_mb,
       ROUND(NVL(r.in_other_ts_bytes,   0) / 1048576, 3)                         AS in_other_ts_mb,
       NVL(r.n_tablespaces, 0)                                                   AS n_tablespaces,
       r.tablespaces,
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
{{table_filter}}
ORDER  BY COALESCE(t.owner, r.owner), NVL(r.total_bytes, 0) DESC
