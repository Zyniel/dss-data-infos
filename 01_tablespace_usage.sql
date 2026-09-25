-- =============================================================================
-- 01_tablespace_usage.sql
-- One row per tablespace of the connected database (non-CDB) or PDB.
-- -----------------------------------------------------------------------------
-- Stack key : db_unique_name, con_dbid, collected_utc, tablespace_name
-- Scope     : every tablespace. UC tablespaces <UC>_{DSSWORK|DSSOUT}_{DATA|INDEX}
--             are flagged is_uc_ts = 'Y', the others give the database context
--             (total size, share taken by the use cases).
-- Needs     : SELECT_CATALOG_ROLE or SELECT ANY DICTIONARY. No AWR view used.
--
-- Space model (PERMANENT / UNDO)
--   alloc_mb       current size of the datafiles
--   max_mb         declared ceiling: autoextend MAXSIZE, or current size without autoextend
--   live_mb        segments that are NOT in the recycle bin
--   recyclebin_mb  segments in the recycle bin. Oracle reports them as free and reuses
--                  them before autoextending a datafile, but they still hold blocks.
--   free_mb        alloc - live - recyclebin (also contains the file header and
--                  space bitmap blocks, a few MB at most per file)
--   tum_*          DBA_TABLESPACE_USAGE_METRICS, the view behind OEM space alerts:
--                  tum_max_mb is capped by the free space left in the storage
-- TEMPORARY tablespaces: live / recyclebin do not apply, current usage is tum_used_mb.
-- DBA_FREE_SPACE is deliberately not used: it becomes very slow when the recycle bin
-- holds many objects.
--
-- config_issues (UC tablespaces, comma separated, NULL when clean)
--   SCHEMA_MISSING              expected owner <UC>_<LAYER> does not exist
--   NOT_SCHEMA_DEFAULT_TS       _DATA tablespace is not the owner's default tablespace
--   INDEX_TS_IS_SCHEMA_DEFAULT  _INDEX tablespace is the owner's default tablespace
--   NO_QUOTA                    owner has no quota on it (and no UNLIMITED TABLESPACE)
--   UNLIMITED_TABLESPACE_PRIV   owner holds UNLIMITED TABLESPACE (quotas are bypassed)
--   OTHER_UC_SCHEMA_SEGMENTS    another UC schema stores segments in it
--   NON_UC_SEGMENTS             a non-UC schema stores segments in it
--   UC_SEGMENTS_IN_NON_UC_TS    (non-UC tablespace) UC schemas store segments in it
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
  SELECT u.username, u.default_tablespace
  FROM   dba_users u
         CROSS JOIN params p
  WHERE  REGEXP_LIKE(u.username, p.schema_rx)
),
ts AS (
  SELECT t.tablespace_name, t.contents, t.status, t.bigfile, t.block_size,
         t.extent_management, t.segment_space_management, t.encrypted,
         t.def_tab_compression,
         t.compress_for                                            AS def_compress_for,
         REGEXP_SUBSTR(t.tablespace_name, p.ts_rx, 1, 1, NULL, 1)  AS uc,
         REGEXP_SUBSTR(t.tablespace_name, p.ts_rx, 1, 1, NULL, 2)  AS schema_layer,
         REGEXP_SUBSTR(t.tablespace_name, p.ts_rx, 1, 1, NULL, 3)  AS ts_role,
         CASE WHEN REGEXP_LIKE(t.tablespace_name, p.ts_rx)
              THEN REGEXP_REPLACE(t.tablespace_name, '_(DATA|INDEX)$')
         END                                                       AS ts_schema
  FROM   dba_tablespaces t
         CROSS JOIN params p
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
-- recycle bin membership, by name (see README for why not the BIN$ prefix)
rb AS (
  SELECT DISTINCT r.owner, r.object_name
  FROM   dba_recyclebin r
),
seg AS (
  SELECT s.tablespace_name, s.owner, s.bytes,
         CASE WHEN rb.object_name IS NULL THEN 'N' ELSE 'Y' END    AS in_rb
  FROM   dba_segments s
         LEFT JOIN rb ON rb.owner = s.owner AND rb.object_name = s.segment_name
),
seg_agg AS (
  SELECT s.tablespace_name,
         SUM(CASE WHEN s.in_rb = 'N' THEN s.bytes ELSE 0 END)      AS live_bytes,
         SUM(CASE WHEN s.in_rb = 'N' THEN 1       ELSE 0 END)      AS live_segments,
         SUM(CASE WHEN s.in_rb = 'Y' THEN s.bytes ELSE 0 END)      AS rb_bytes,
         SUM(CASE WHEN s.in_rb = 'Y' THEN 1       ELSE 0 END)      AS rb_segments,
         SUM(CASE WHEN s.in_rb = 'N' AND s.owner = t.ts_schema
                  THEN s.bytes ELSE 0 END)                         AS live_schema_bytes,
         SUM(CASE WHEN s.in_rb = 'N' AND u.username IS NOT NULL
                   AND s.owner <> NVL(t.ts_schema, '-')
                  THEN s.bytes ELSE 0 END)                         AS live_other_uc_bytes,
         SUM(CASE WHEN s.in_rb = 'N' AND u.username IS NULL
                  THEN s.bytes ELSE 0 END)                         AS live_non_uc_bytes
  FROM   seg s
         JOIN ts t             ON t.tablespace_name = s.tablespace_name
         LEFT JOIN uc_schema u ON u.username        = s.owner
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
ts_quota AS (
  SELECT q.username, q.tablespace_name, q.bytes, q.max_bytes
  FROM   dba_ts_quotas q
  WHERE  q.dropped = 'NO'
),
-- UNLIMITED TABLESPACE cannot be granted through a role: direct grants are enough
unl AS (
  SELECT DISTINCT sp.grantee
  FROM   dba_sys_privs sp
  WHERE  sp.privilege = 'UNLIMITED TABLESPACE'
)
SELECT h.collected_utc, h.db_name, h.db_unique_name, h.cdb, h.con_name, h.con_dbid, h.database_role,
       -- identity
       t.tablespace_name,
       CASE WHEN t.ts_role IS NULL THEN 'N' ELSE 'Y' END                          AS is_uc_ts,
       t.uc,
       t.schema_layer,
       t.ts_role,
       t.ts_schema                                                                AS expected_owner,
       -- configuration checks
       RTRIM(   CASE WHEN t.ts_role IS NOT NULL AND o.username IS NULL
                     THEN 'SCHEMA_MISSING,' END
             || CASE WHEN t.ts_role = 'DATA'  AND o.default_tablespace <> t.tablespace_name
                     THEN 'NOT_SCHEMA_DEFAULT_TS,' END
             || CASE WHEN t.ts_role = 'INDEX' AND o.default_tablespace =  t.tablespace_name
                     THEN 'INDEX_TS_IS_SCHEMA_DEFAULT,' END
             || CASE WHEN o.username IS NOT NULL AND x.grantee IS NULL
                      AND (q.username IS NULL OR q.max_bytes = 0)
                     THEN 'NO_QUOTA,' END
             || CASE WHEN x.grantee IS NOT NULL
                     THEN 'UNLIMITED_TABLESPACE_PRIV,' END
             || CASE WHEN t.ts_role IS NOT NULL AND sa.live_other_uc_bytes > 0
                     THEN 'OTHER_UC_SCHEMA_SEGMENTS,' END
             || CASE WHEN t.ts_role IS NOT NULL AND sa.live_non_uc_bytes > 0
                     THEN 'NON_UC_SEGMENTS,' END
             || CASE WHEN t.ts_role IS NULL AND sa.live_other_uc_bytes > 0
                     THEN 'UC_SEGMENTS_IN_NON_UC_TS,' END
           , ',')                                                                 AS config_issues,
       CASE WHEN t.ts_role IS NULL                               THEN NULL
            WHEN x.grantee IS NOT NULL OR q.max_bytes = -1       THEN 'UNLIMITED'
            WHEN q.username IS NULL OR q.max_bytes = 0           THEN 'NONE'
            ELSE 'LIMITED'
       END                                                                        AS quota_status,
       ROUND(CASE WHEN q.max_bytes > 0 THEN q.max_bytes END / 1048576, 3)         AS quota_max_mb,
       ROUND(q.bytes / 1048576, 3)                                                AS quota_used_mb,
       -- tablespace properties
       t.contents,
       t.status,
       t.bigfile,
       t.block_size,
       t.extent_management,
       t.segment_space_management,
       t.encrypted,
       t.def_tab_compression,
       t.def_compress_for,
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
       -- who owns the live segments
       CASE WHEN t.ts_role IS NOT NULL
            THEN ROUND(NVL(sa.live_schema_bytes, 0) / 1048576, 3) END             AS live_expected_owner_mb,
       ROUND(NVL(sa.live_other_uc_bytes, 0) / 1048576, 3)                         AS live_other_uc_mb,
       CASE WHEN t.ts_role IS NOT NULL
            THEN ROUND(NVL(sa.live_non_uc_bytes, 0) / 1048576, 3) END             AS live_non_uc_mb,
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
       CROSS JOIN hdr h
       LEFT JOIN file_agg  f  ON f.tablespace_name  = t.tablespace_name
       LEFT JOIN seg_agg   sa ON sa.tablespace_name = t.tablespace_name
       LEFT JOIN rb_ts     r  ON r.tablespace_name  = t.tablespace_name
       LEFT JOIN tum       m  ON m.tablespace_name  = t.tablespace_name
       LEFT JOIN uc_schema o  ON o.username         = t.ts_schema
       LEFT JOIN ts_quota  q  ON q.username         = t.ts_schema
                             AND q.tablespace_name  = t.tablespace_name
       LEFT JOIN unl       x  ON x.grantee          = t.ts_schema
ORDER  BY CASE WHEN t.ts_role IS NULL THEN 1 ELSE 0 END,
          t.uc, t.schema_layer, t.ts_role, t.tablespace_name;
