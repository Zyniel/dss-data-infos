-- =============================================================================
-- 05_awr_object_activity.sql
-- One row per UC object seen by AWR segment statistics over the last
-- params.days_back days: the I/O and block changes it generated on the database.
-- -----------------------------------------------------------------------------
-- Stack key : db_unique_name, con_dbid, collected_utc, owner, object_name, object_type
-- Needs     : Diagnostics Pack licence (DBA_HIST_* views) + SELECT_CATALOG_ROLE.
-- Source    : DBA_HIST_SEG_STAT + DBA_HIST_SEG_STAT_OBJ, partitions summed into
--             their object (object_type TABLE / INDEX / LOB ...).
-- CAUTION   : AWR keeps only the top segments of each snapshot (by reads, writes,
--             block changes, ...). This is a hotspot view, not an inventory: an
--             object absent from it is not proven idle. Space growth is not taken
--             from these rows (top-N sampling, and every TRUNCATE / MOVE / re-create
--             starts a new data object id): use 04 and the stacked history of 02 / 03.
-- RAC       : deltas are per instance and summed over all instances.
-- Multitenant: only root-level snapshots are used (DBID = V$DATABASE.DBID), so that
--             PDB-level snapshots, when enabled, do not double the figures.
--
-- parent_table        table of the object, resolved against the CURRENT dictionary
--                     (NULL when the object no longer exists, see exists_now)
-- n_incarnations      distinct (obj#, dataobj#) seen: re-creates and truncates
-- phys_* / direct_*   converted from blocks with the tablespace block size
-- optimized_phys_reads  read requests served by flash cache
--                     (Exadata: flash cache or storage index)
-- gc_blocks_received  RAC interconnect traffic (CR + current blocks)
-- =============================================================================
WITH
params AS (
  SELECT '^(.+)_(DSSWORK|DSSOUT)$' AS schema_rx,                -- UC schemas
         31                        AS days_back                 -- analysis window
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
blk AS (
  SELECT TO_NUMBER(v.value) AS db_block_size
  FROM   v$parameter v
  WHERE  v.name = 'db_block_size'
),
snap AS (
  SELECT sn.snap_id, sn.dbid, sn.instance_number, sn.end_interval_time
  FROM   dba_hist_snapshot sn
         JOIN db ON db.dbid = sn.dbid
         CROSS JOIN params p
  WHERE  sn.end_interval_time >= SYSDATE - p.days_back
),
so AS (
  SELECT o.dbid,
         NVL(NULLIF(o.con_dbid, 0), o.dbid)                        AS con_dbid,
         o.ts#, o.obj#, o.dataobj#,
         o.owner, o.object_name, o.object_type, o.tablespace_name
  FROM   dba_hist_seg_stat_obj o
         JOIN db ON  db.dbid     = o.dbid
                 AND db.con_dbid = NVL(NULLIF(o.con_dbid, 0), o.dbid)
         CROSS JOIN params p
  WHERE  REGEXP_LIKE(o.owner, p.schema_rx)
),
ss AS (
  SELECT so.owner,
         so.object_name,
         REGEXP_REPLACE(so.object_type, ' (SUB)?PARTITION$')       AS object_type,
         so.tablespace_name,
         st.snap_id, st.obj#, st.dataobj#,
         sn.end_interval_time,
         NVL(t.block_size, b.db_block_size)                        AS block_size,
         st.logical_reads_delta,
         st.physical_reads_delta,
         st.physical_read_requests_delta,
         st.optimized_physical_reads_delta,
         st.physical_reads_direct_delta,
         st.physical_writes_delta,
         st.physical_write_requests_delta,
         st.physical_writes_direct_delta,
         st.db_block_changes_delta,
         st.table_scans_delta,
         NVL(st.gc_cr_blocks_received_delta, 0)
           + NVL(st.gc_cu_blocks_received_delta, 0)                AS gc_blocks_received_delta
  FROM   dba_hist_seg_stat st
         JOIN snap sn ON  sn.snap_id         = st.snap_id
                      AND sn.dbid            = st.dbid
                      AND sn.instance_number = st.instance_number
         JOIN so      ON  so.dbid     = st.dbid
                      AND so.con_dbid = NVL(NULLIF(st.con_dbid, 0), st.dbid)
                      AND so.ts#      = st.ts#
                      AND so.obj#     = st.obj#
                      AND so.dataobj# = st.dataobj#
         LEFT JOIN dba_hist_tablespace t
                      ON  t.dbid = st.dbid
                      AND t.ts#  = st.ts#
                      AND NVL(NULLIF(t.con_dbid, 0), t.dbid) = NVL(NULLIF(st.con_dbid, 0), st.dbid)
         CROSS JOIN blk b
),
agg AS (
  SELECT s.owner, s.object_name, s.object_type,
         LISTAGG(DISTINCT s.tablespace_name, ',')
           WITHIN GROUP (ORDER BY s.tablespace_name)               AS tablespaces,
         COUNT(DISTINCT s.snap_id)                                 AS snaps_captured,
         COUNT(DISTINCT s.obj# || '.' || s.dataobj#)               AS n_incarnations,
         MIN(s.end_interval_time)                                  AS first_captured,
         MAX(s.end_interval_time)                                  AS last_captured,
         SUM(s.logical_reads_delta)                                AS logical_reads,
         SUM(s.physical_reads_delta * s.block_size)                AS phys_read_bytes,
         SUM(s.physical_read_requests_delta)                       AS phys_read_requests,
         SUM(s.optimized_physical_reads_delta)                     AS optimized_phys_reads,
         SUM(s.physical_reads_direct_delta * s.block_size)         AS direct_read_bytes,
         SUM(s.physical_writes_delta * s.block_size)               AS phys_write_bytes,
         SUM(s.physical_write_requests_delta)                      AS phys_write_requests,
         SUM(s.physical_writes_direct_delta * s.block_size)        AS direct_write_bytes,
         SUM(s.db_block_changes_delta)                             AS db_block_changes,
         SUM(s.table_scans_delta)                                  AS table_scans,
         SUM(s.gc_blocks_received_delta)                           AS gc_blocks_received
  FROM   ss s
  GROUP  BY s.owner, s.object_name, s.object_type
),
-- current dictionary, to attach indexes / LOBs to their table
cur_tab AS (
  SELECT t.owner, t.table_name
  FROM   dba_tables t
         CROSS JOIN params p
  WHERE  REGEXP_LIKE(t.owner, p.schema_rx)
  AND    t.dropped = 'NO'
),
cur_ix AS (
  SELECT i.owner, i.index_name, i.table_name
  FROM   dba_indexes i
         CROSS JOIN params p
  WHERE  REGEXP_LIKE(i.owner, p.schema_rx)
),
cur_lob AS (
  SELECT l.owner, l.segment_name, l.table_name
  FROM   dba_lobs l
         CROSS JOIN params p
  WHERE  REGEXP_LIKE(l.owner, p.schema_rx)
)
SELECT h.collected_utc, h.db_name, h.db_unique_name, h.cdb, h.con_name, h.con_dbid, h.database_role,
       REGEXP_SUBSTR(a.owner, p.schema_rx, 1, 1, NULL, 1)                        AS uc,
       REGEXP_SUBSTR(a.owner, p.schema_rx, 1, 1, NULL, 2)                        AS schema_layer,
       a.owner,
       a.object_name,
       a.object_type,
       CASE a.object_type
         WHEN 'TABLE' THEN a.object_name
         WHEN 'INDEX' THEN ci.table_name
         WHEN 'LOB'   THEN cl.table_name
       END                                                                       AS parent_table,
       CASE WHEN COALESCE(ct.table_name, ci.index_name, cl.segment_name) IS NOT NULL
            THEN 'Y' ELSE 'N'
       END                                                                       AS exists_now,
       a.tablespaces,
       p.days_back                                                               AS window_days,
       a.snaps_captured,
       a.n_incarnations,
       a.first_captured,
       a.last_captured,
       a.logical_reads,
       ROUND(a.phys_read_bytes    / 1048576, 3)                                  AS phys_read_mb,
       a.phys_read_requests,
       a.optimized_phys_reads,
       ROUND(a.direct_read_bytes  / 1048576, 3)                                  AS direct_read_mb,
       ROUND(a.phys_write_bytes   / 1048576, 3)                                  AS phys_write_mb,
       a.phys_write_requests,
       ROUND(a.direct_write_bytes / 1048576, 3)                                  AS direct_write_mb,
       a.db_block_changes,
       a.table_scans,
       a.gc_blocks_received
FROM   agg a
       CROSS JOIN hdr h
       CROSS JOIN params p
       LEFT JOIN cur_tab ct ON  a.object_type  = 'TABLE'
                            AND ct.owner       = a.owner
                            AND ct.table_name  = a.object_name
       LEFT JOIN cur_ix  ci ON  a.object_type  = 'INDEX'
                            AND ci.owner       = a.owner
                            AND ci.index_name  = a.object_name
       LEFT JOIN cur_lob cl ON  a.object_type  = 'LOB'
                            AND cl.owner        = a.owner
                            AND cl.segment_name = a.object_name
ORDER  BY a.owner, a.logical_reads DESC NULLS LAST;
