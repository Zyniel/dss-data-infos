-- dbmon template "objects".
-- Derived from 02_object_usage.sql (repository root): no naming convention, the scope is
-- chosen by the caller, identity columns are added by the engine.
-- Rendered by dbmon/queries.py, not runnable as-is. Placeholders:
--   owner_filter     schemas in scope (default: non Oracle-maintained)
--   table_filter     keeps the objects of one table
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
-- live segments of the schemas in scope, one row per (sub)partition segment
seg AS (
  SELECT s.owner, s.segment_name, s.partition_name, s.segment_type, s.segment_subtype,
         s.tablespace_name, s.bytes, s.blocks, s.extents, s.cell_flash_cache
  FROM   dba_segments s
         JOIN scope u ON u.username = s.owner
  WHERE  NOT EXISTS (SELECT 1
                     FROM   rb
                     WHERE  rb.owner       = s.owner
                     AND    rb.object_name = s.segment_name)
),
ix AS (
  SELECT i.owner, i.index_name, i.index_type, i.table_owner, i.table_name, i.compression
  FROM   dba_indexes i
         JOIN scope u ON u.username = i.owner
),
lb AS (
  SELECT l.owner, l.segment_name, l.table_name, l.column_name, l.securefile, l.compression
  FROM   dba_lobs l
         JOIN scope u ON u.username = l.owner
),
tb AS (
  SELECT t.owner, t.table_name, t.iot_name, t.compression, t.compress_for
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
-- resolve family, parent table and compression of every segment
seg_res AS (
  SELECT g.owner, g.segment_name, g.partition_name, g.segment_type, g.segment_subtype,
         g.tablespace_name, g.bytes, g.blocks, g.extents, g.cell_flash_cache,
         CASE
           WHEN g.segment_type IN ('LOBSEGMENT', 'LOB PARTITION', 'LOB SUBPARTITION')  THEN 'LOB'
           WHEN g.segment_type = 'LOBINDEX' OR i.index_type = 'LOB'                   THEN 'LOBINDEX'
           WHEN i.index_type = 'IOT - TOP'                                            THEN 'TABLE'
           WHEN g.segment_type IN ('INDEX', 'INDEX PARTITION', 'INDEX SUBPARTITION')  THEN 'INDEX'
           WHEN g.segment_type IN ('TABLE', 'TABLE PARTITION', 'TABLE SUBPARTITION',
                                   'NESTED TABLE', 'CLUSTER')                         THEN 'TABLE'
           ELSE 'OTHER'
         END                                                                          AS family,
         CASE
           WHEN g.segment_type IN ('TABLE', 'TABLE PARTITION', 'TABLE SUBPARTITION')  THEN 'TABLE'
           WHEN g.segment_type = 'LOBINDEX' OR i.index_type = 'LOB'                   THEN 'LOBINDEX'
           WHEN g.segment_type IN ('INDEX', 'INDEX PARTITION', 'INDEX SUBPARTITION')  THEN 'INDEX'
           WHEN g.segment_type IN ('LOBSEGMENT', 'LOB PARTITION', 'LOB SUBPARTITION')  THEN 'LOBSEGMENT'
           ELSE g.segment_type
         END                                                                          AS object_type,
         i.index_type,
         l.column_name                                                                AS lob_column,
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
           WHEN i.index_name IS NOT NULL
             THEN i.compression
           WHEN l.segment_name IS NOT NULL
             THEN DECODE(l.securefile, 'YES', 'SECUREFILE ' || l.compression, 'BASICFILE')
         END                                                                          AS compression,
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
obj AS (
  SELECT c.owner, c.segment_name, c.object_type, c.family, c.index_type, c.lob_column,
         c.parent_owner, c.parent_table, c.tablespace_name, c.ts_kind,
         COUNT(*)                                                                AS n_segments,
         MAX(CASE WHEN c.partition_name IS NOT NULL THEN 'YES' ELSE 'NO' END)    AS partitioned,
         SUM(c.bytes)                                                            AS bytes,
         SUM(c.blocks)                                                           AS blocks,
         SUM(c.extents)                                                          AS extents,
         LISTAGG(DISTINCT c.compression, ',')
           WITHIN GROUP (ORDER BY c.compression)                                 AS compression,
         LISTAGG(DISTINCT c.segment_subtype, ',')
           WITHIN GROUP (ORDER BY c.segment_subtype)                             AS segment_subtype,
         LISTAGG(DISTINCT c.cell_flash_cache, ',')
           WITHIN GROUP (ORDER BY c.cell_flash_cache)                            AS cell_flash_cache
  FROM   seg_res c
  GROUP  BY c.owner, c.segment_name, c.object_type, c.family, c.index_type, c.lob_column,
            c.parent_owner, c.parent_table, c.tablespace_name, c.ts_kind
)
SELECT
       o.owner,
       o.segment_name                                                            AS object_name,
       o.object_type,
       o.family,
       o.index_type,
       o.lob_column,
       o.parent_owner,
       o.parent_table,
       o.tablespace_name,
       o.ts_kind,
       o.partitioned,
       o.n_segments,
       ROUND(o.bytes / 1048576, 3)                                               AS size_mb,
       o.blocks,
       o.extents,
       o.compression,
       o.segment_subtype,
       o.cell_flash_cache
FROM   obj o
{{table_filter}}
ORDER  BY o.owner, o.bytes DESC
