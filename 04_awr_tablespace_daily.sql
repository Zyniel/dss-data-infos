-- =============================================================================
-- 04_awr_tablespace_daily.sql
-- One row per tablespace and day, over the whole AWR retention.
-- -----------------------------------------------------------------------------
-- Stack key : db_unique_name, con_dbid, tablespace_name, snap_day
--             Consecutive runs overlap (same days seen again): when stacking,
--             keep the row of the latest collected_utc for each key.
-- Needs     : Diagnostics Pack licence (DBA_HIST_* views) + SELECT_CATALOG_ROLE.
-- Source    : DBA_HIST_TBSPC_SPACE_USAGE, written at every AWR snapshot for every
--             tablespace: a complete history, not a top-N sample.
--             Values are converted from blocks with the tablespace block size.
--   alloc_mb      tablespace size (datafiles) at the last snapshot of the day
--   max_mb        maximum size recorded by AWR at the last snapshot of the day
--   used_mb       used space at the last snapshot of the day
--   used_peak_mb  highest used space seen during the day
--   *_delta_mb    change against the previous day present in AWR
--                 (days_since_prev tells whether days are missing)
-- Multitenant : in a PDB, DBA_HIST_* returns the root snapshots for this PDB, plus
--               the PDB-level snapshots when AWR_PDB_AUTOFLUSH_ENABLED is set. Both
--               are kept: daily peaks / end-of-day levels are not inflated by a
--               second snapshot series. AWR imported from other databases is
--               filtered out (CON_DBID of the connected container).
-- =============================================================================
WITH
params AS (
  SELECT '^(.+)_(DSSWORK|DSSOUT)_(DATA|INDEX)$' AS ts_rx        -- UC tablespaces
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
-- CON_DBID may be 0 (non-CDB) or NULL depending on the view: normalised to DBID
db AS (
  SELECT d.dbid, NVL(NULLIF(d.con_dbid, 0), d.dbid) AS con_dbid
  FROM   v$database d
),
tsu AS (
  SELECT t.tsname                                                  AS tablespace_name,
         t.contents,
         t.block_size,
         u.snap_id,
         TO_DATE(u.rtime DEFAULT NULL ON CONVERSION ERROR,
                 'MM/DD/YYYY HH24:MI:SS')                          AS rtime,
         u.tablespace_size,
         u.tablespace_maxsize,
         u.tablespace_usedsize
  FROM   dba_hist_tbspc_space_usage u
         JOIN db ON NVL(NULLIF(u.con_dbid, 0), u.dbid) = db.con_dbid
         JOIN dba_hist_tablespace t
           ON  t.dbid = u.dbid
           AND t.ts#  = u.tablespace_id
           AND NVL(NULLIF(t.con_dbid, 0), t.dbid) = NVL(NULLIF(u.con_dbid, 0), u.dbid)
),
daily AS (
  SELECT s.tablespace_name,
         s.contents,
         TRUNC(s.rtime)                                            AS snap_day,
         COUNT(*)                                                  AS n_samples,
         MAX(s.tablespace_usedsize * s.block_size)                 AS used_peak_bytes,
         MAX(s.tablespace_usedsize * s.block_size)
           KEEP (DENSE_RANK LAST ORDER BY s.rtime, s.snap_id)      AS used_bytes,
         MAX(s.tablespace_size * s.block_size)
           KEEP (DENSE_RANK LAST ORDER BY s.rtime, s.snap_id)      AS alloc_bytes,
         MAX(s.tablespace_maxsize * s.block_size)
           KEEP (DENSE_RANK LAST ORDER BY s.rtime, s.snap_id)      AS max_bytes
  FROM   tsu s
  WHERE  s.rtime IS NOT NULL
  GROUP  BY s.tablespace_name, s.contents, TRUNC(s.rtime)
)
SELECT h.collected_utc, h.db_name, h.db_unique_name, h.cdb, h.con_name, h.con_dbid, h.database_role,
       d.tablespace_name,
       CASE WHEN REGEXP_LIKE(d.tablespace_name, p.ts_rx) THEN 'Y' ELSE 'N' END   AS is_uc_ts,
       REGEXP_SUBSTR(d.tablespace_name, p.ts_rx, 1, 1, NULL, 1)                  AS uc,
       REGEXP_SUBSTR(d.tablespace_name, p.ts_rx, 1, 1, NULL, 2)                  AS schema_layer,
       REGEXP_SUBSTR(d.tablespace_name, p.ts_rx, 1, 1, NULL, 3)                  AS ts_role,
       d.contents,
       d.snap_day,
       d.n_samples,
       ROUND(d.alloc_bytes     / 1048576, 3)                                     AS alloc_mb,
       ROUND(d.max_bytes       / 1048576, 3)                                     AS max_mb,
       ROUND(d.used_bytes      / 1048576, 3)                                     AS used_mb,
       ROUND(d.used_peak_bytes / 1048576, 3)                                     AS used_peak_mb,
       d.snap_day - LAG(d.snap_day)
                      OVER (PARTITION BY d.tablespace_name ORDER BY d.snap_day)  AS days_since_prev,
       ROUND((d.used_bytes - LAG(d.used_bytes)
                               OVER (PARTITION BY d.tablespace_name ORDER BY d.snap_day))
             / 1048576, 3)                                                       AS used_delta_mb,
       ROUND((d.alloc_bytes - LAG(d.alloc_bytes)
                                OVER (PARTITION BY d.tablespace_name ORDER BY d.snap_day))
             / 1048576, 3)                                                       AS alloc_delta_mb
FROM   daily d
       CROSS JOIN hdr h
       CROSS JOIN params p
ORDER  BY CASE WHEN REGEXP_LIKE(d.tablespace_name, p.ts_rx) THEN 0 ELSE 1 END,
          d.tablespace_name, d.snap_day;
