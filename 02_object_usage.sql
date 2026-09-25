-- =============================================================================
-- 02_object_usage.sql
-- One row per storage object and tablespace, for the UC schemas only.
-- -----------------------------------------------------------------------------
-- Stack key : db_unique_name, con_dbid, collected_utc,
--             owner, object_name, object_type, tablespace_name
-- Object    : a table, index, LOB segment or LOB index, all its partitions and
--             subpartitions summed. An object whose partitions sit in several
--             tablespaces gives one row per tablespace.
-- Scope     : live segments only. Recycle bin segments are excluded by matching
--             DBA_RECYCLEBIN, not by the BIN$ prefix: after FLASHBACK TABLE ...
--             TO BEFORE DROP the restored indexes and LOB segments keep BIN$ names.
-- Needs     : SELECT_CATALOG_ROLE or SELECT ANY DICTIONARY. No AWR view used.
--
-- family       TABLE     heap table, (sub)partitions, IOT top index, IOT overflow,
--                        nested table storage, cluster
--              INDEX     index (sub)partitions
--              LOB       LOB segment (sub)partitions
--              LOBINDEX  LOB index, always stored with its LOB segment
--              OTHER     e.g. TEMPORARY segment of a CTAS / index build in progress
-- parent_*     table the object belongs to (index, LOB, IOT overflow -> table)
-- placement    OK
--              INDEX_IN_DATA_TS  index created without TABLESPACE clause (informative)
--              DATA_IN_INDEX_TS  table / LOB data stored in the _INDEX tablespace
--              FOREIGN_TS        tablespace not owned by the object's schema
--                                (other layer, other UC, or non-UC tablespace)
-- compression  table: per (sub)partition, NONE / BASIC / ADVANCED / QUERY LOW|HIGH /
--                     ARCHIVE LOW|HIGH (Exadata HCC)
--              index: DBA_INDEXES.COMPRESSION
--              LOB:   SECUREFILE <level> or BASICFILE (table level, from DBA_LOBS)
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
-- tablespace -> role (DATA / INDEX) and schema it belongs to (<UC>_<LAYER>)
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
-- live segments of the UC schemas, one row per (sub)partition segment
seg AS (
  SELECT s.owner, s.segment_name, s.partition_name, s.segment_type, s.segment_subtype,
         s.tablespace_name, s.bytes, s.blocks, s.extents, s.cell_flash_cache
  FROM   dba_segments s
         JOIN uc_schema u ON u.username = s.owner
  WHERE  NOT EXISTS (SELECT 1
                     FROM   rb
                     WHERE  rb.owner       = s.owner
                     AND    rb.object_name = s.segment_name)
),
ix AS (
  SELECT i.owner, i.index_name, i.index_type, i.table_owner, i.table_name, i.compression
  FROM   dba_indexes i
         JOIN uc_schema u ON u.username = i.owner
),
lb AS (
  SELECT l.owner, l.segment_name, l.table_name, l.column_name, l.securefile, l.compression
  FROM   dba_lobs l
         JOIN uc_schema u ON u.username = l.owner
),
tb AS (
  SELECT t.owner, t.table_name, t.iot_name, t.compression, t.compress_for
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
obj AS (
  SELECT c.owner, c.segment_name, c.object_type, c.family, c.index_type, c.lob_column,
         c.parent_owner, c.parent_table, c.tablespace_name, c.ts_role, c.placement,
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
  FROM   seg_cls c
  GROUP  BY c.owner, c.segment_name, c.object_type, c.family, c.index_type, c.lob_column,
            c.parent_owner, c.parent_table, c.tablespace_name, c.ts_role, c.placement
)
SELECT h.collected_utc, h.db_name, h.db_unique_name, h.cdb, h.con_name, h.con_dbid, h.database_role,
       u.uc,
       u.schema_layer,
       o.owner,
       o.segment_name                                                            AS object_name,
       o.object_type,
       o.family,
       o.index_type,
       o.lob_column,
       o.parent_owner,
       o.parent_table,
       o.tablespace_name,
       o.ts_role,
       o.placement,
       o.partitioned,
       o.n_segments,
       ROUND(o.bytes / 1048576, 3)                                               AS size_mb,
       o.blocks,
       o.extents,
       o.compression,
       o.segment_subtype,
       o.cell_flash_cache
FROM   obj o
       JOIN uc_schema u ON u.username = o.owner
       CROSS JOIN hdr h
ORDER  BY u.uc, u.schema_layer, o.bytes DESC;
