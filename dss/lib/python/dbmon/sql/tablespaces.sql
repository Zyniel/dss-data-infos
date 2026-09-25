-- dbmon template "tablespaces": one row per tablespace of the database.
-- Derived from 01_tablespace_usage.sql (repository root), without the use-case
-- checks: capacity, occupation, recycle bin, usage metrics and ASM storage.
-- Identity columns are added by the engine.
-- Rendered by dbmon/queries.py, not runnable as-is. Placeholders:
--   ts_filter        tablespaces returned (default: all)
--   seg_filter       same restriction on the segment scan
--
-- Space model (PERMANENT / UNDO)
--   alloc_mb       current size of the datafiles
--   max_mb         declared ceiling: autoextend MAXSIZE, or current size without autoextend
--   live_mb        segments that are not in the recycle bin
--   recyclebin_mb  segments in the recycle bin: reported free by Oracle and reused before
--                  autoextending a datafile, but still holding blocks
--   free_mb        alloc - live - recyclebin (also contains file header and bitmap blocks)
--   tum_*          DBA_TABLESPACE_USAGE_METRICS, the view behind OEM space alerts:
--                  tum_max_mb is capped by the free space left in the storage
-- TEMPORARY tablespaces: live / recyclebin do not apply, current usage is tum_used_mb.
-- DBA_FREE_SPACE is not used: it becomes very slow with a large recycle bin.
WITH
ts AS (
  SELECT t.tablespace_name, t.contents, t.status, t.bigfile, t.block_size,
         t.extent_management, t.segment_space_management, t.encrypted,
         t.def_tab_compression,
         t.compress_for                                            AS def_compress_for
  FROM   dba_tablespaces t
  {{ts_filter}}
),
-- datafiles + tempfiles, with the ASM disk group taken from the file name
files AS (
  SELECT f.tablespace_name,
         f.bytes,
         f.autoextensible,
         CASE WHEN f.autoextensible = 'YES' THEN GREATEST(f.maxbytes, f.bytes)
              ELSE f.bytes
         END                                                       AS max_bytes,
         REGEXP_SUBSTR(f.file_name, '^\+([^/]+)', 1, 1, NULL, 1)   AS dg_name
  FROM  (SELECT tablespace_name, file_name, bytes, maxbytes, autoextensible FROM dba_data_files
         UNION ALL
         SELECT tablespace_name, file_name, bytes, maxbytes, autoextensible FROM dba_temp_files) f
),
-- _STAT variant: no disk discovery, safe to query from a database instance
asm_dg AS (
  SELECT g.name                                                    AS dg_name,
         MAX(g.type)                                               AS dg_redundancy,
         MAX(CASE g.type WHEN 'EXTERN' THEN 1
                         WHEN 'NORMAL' THEN 2
                         WHEN 'HIGH'   THEN 3
             END)                                                  AS raw_factor,
         MAX(g.usable_file_mb)                                     AS usable_file_mb
  FROM   v$asm_diskgroup_stat g
  GROUP  BY g.name
),
file_agg AS (
  SELECT f.tablespace_name,
         COUNT(*)                                                  AS n_files,
         MAX(f.autoextensible)                                     AS autoextensible,
         SUM(f.bytes)                                              AS alloc_bytes,
         SUM(f.max_bytes)                                          AS max_bytes,
         CASE WHEN COUNT(g.raw_factor) = COUNT(*)
              THEN SUM(f.bytes * g.raw_factor)
         END                                                       AS raw_alloc_bytes,
         LISTAGG(DISTINCT f.dg_name, ',')
           WITHIN GROUP (ORDER BY f.dg_name)                       AS asm_diskgroups,
         LISTAGG(DISTINCT g.dg_redundancy, ',')
           WITHIN GROUP (ORDER BY g.dg_redundancy)                 AS asm_redundancy,
         MIN(g.usable_file_mb)                                     AS dg_usable_file_mb
  FROM   files f
         LEFT JOIN asm_dg g ON g.dg_name = f.dg_name
  GROUP  BY f.tablespace_name
),
tum AS (
  SELECT m.tablespace_name, m.used_space, m.tablespace_size, m.used_percent
  FROM   dba_tablespace_usage_metrics m
),
-- recycle bin membership, by name (restored indexes and LOBs keep BIN$ names)
rb AS (
  SELECT DISTINCT r.owner, r.object_name
  FROM   dba_recyclebin r
),
seg AS (
  SELECT s.tablespace_name, s.owner, s.bytes,
         CASE WHEN rb.object_name IS NULL THEN 'N' ELSE 'Y' END    AS in_rb
  FROM   dba_segments s
         LEFT JOIN rb ON rb.owner = s.owner AND rb.object_name = s.segment_name
  {{seg_filter}}
),
seg_agg AS (
  SELECT s.tablespace_name,
         SUM(CASE WHEN s.in_rb = 'N' THEN s.bytes ELSE 0 END)      AS live_bytes,
         SUM(CASE WHEN s.in_rb = 'N' THEN 1       ELSE 0 END)      AS live_segments,
         COUNT(DISTINCT CASE WHEN s.in_rb = 'N' THEN s.owner END)  AS live_owners,
         SUM(CASE WHEN s.in_rb = 'Y' THEN s.bytes ELSE 0 END)      AS rb_bytes,
         SUM(CASE WHEN s.in_rb = 'Y' THEN 1       ELSE 0 END)      AS rb_segments
  FROM   seg s
  GROUP  BY s.tablespace_name
),
rb_ts AS (
  SELECT r.ts_name                                                 AS tablespace_name,
         SUM(CASE WHEN r.type = 'TABLE' THEN 1 ELSE 0 END)         AS rb_tables,
         MIN(r.droptime)                                           AS rb_oldest_droptime
  FROM   dba_recyclebin r
  WHERE  r.ts_name IS NOT NULL
  GROUP  BY r.ts_name
),
-- application schemas (not Oracle-maintained) using the tablespace as default
default_ts AS (
  SELECT u.default_tablespace                                      AS tablespace_name,
         COUNT(*)                                                  AS default_for_schemas
  FROM   dba_users u
  WHERE  u.oracle_maintained = 'N'
  GROUP  BY u.default_tablespace
)
SELECT t.tablespace_name,
       t.contents,
       t.status,
       t.bigfile,
       t.block_size,
       t.extent_management,
       t.segment_space_management,
       t.encrypted,
       t.def_tab_compression,
       t.def_compress_for,
       NVL(d.default_for_schemas, 0)                                              AS default_for_schemas,
       -- datafiles / tempfiles
       f.n_files,
       f.autoextensible,
       ROUND(f.alloc_bytes / 1048576, 3)                                          AS alloc_mb,
       ROUND(f.max_bytes   / 1048576, 3)                                          AS max_mb,
       -- occupation
       CASE WHEN t.contents <> 'TEMPORARY'
            THEN ROUND(NVL(sa.live_bytes, 0) / 1048576, 3) END                    AS live_mb,
       CASE WHEN t.contents <> 'TEMPORARY'
            THEN NVL(sa.live_segments, 0) END                                     AS live_segments,
       CASE WHEN t.contents <> 'TEMPORARY'
            THEN NVL(sa.live_owners, 0) END                                       AS live_owners,
       CASE WHEN t.contents <> 'TEMPORARY'
            THEN ROUND(NVL(sa.rb_bytes, 0) / 1048576, 3) END                      AS recyclebin_mb,
       CASE WHEN t.contents <> 'TEMPORARY'
            THEN NVL(sa.rb_segments, 0) END                                       AS recyclebin_segments,
       r.rb_tables                                                                AS recyclebin_tables,
       TO_DATE(r.rb_oldest_droptime DEFAULT NULL ON CONVERSION ERROR,
               'YYYY-MM-DD:HH24:MI:SS')                                           AS recyclebin_oldest_drop,
       ROUND(CASE WHEN t.contents = 'TEMPORARY'
                  THEN f.alloc_bytes - m.used_space * t.block_size
                  ELSE f.alloc_bytes - NVL(sa.live_bytes, 0) - NVL(sa.rb_bytes, 0)
             END / 1048576, 3)                                                    AS free_mb,
       CASE WHEN t.contents <> 'TEMPORARY'
            THEN ROUND(100 * NVL(sa.live_bytes, 0) / NULLIF(f.alloc_bytes, 0), 2) END AS live_pct_of_alloc,
       CASE WHEN t.contents <> 'TEMPORARY'
            THEN ROUND(100 * NVL(sa.live_bytes, 0) / NULLIF(f.max_bytes, 0), 2)   END AS live_pct_of_max,
       -- Oracle tablespace metrics (OEM / alert semantics)
       ROUND(m.used_space      * t.block_size / 1048576, 3)                       AS tum_used_mb,
       ROUND(m.tablespace_size * t.block_size / 1048576, 3)                       AS tum_max_mb,
       ROUND(m.used_percent, 2)                                                   AS tum_used_pct,
       -- ASM / Exadata storage
       f.asm_diskgroups,
       f.asm_redundancy,
       ROUND(f.raw_alloc_bytes / 1048576, 3)                                      AS raw_alloc_mb,
       f.dg_usable_file_mb
FROM   ts t
       LEFT JOIN file_agg   f  ON f.tablespace_name  = t.tablespace_name
       LEFT JOIN seg_agg    sa ON sa.tablespace_name = t.tablespace_name
       LEFT JOIN rb_ts      r  ON r.tablespace_name  = t.tablespace_name
       LEFT JOIN tum        m  ON m.tablespace_name  = t.tablespace_name
       LEFT JOIN default_ts d  ON d.tablespace_name  = t.tablespace_name
ORDER  BY t.tablespace_name
