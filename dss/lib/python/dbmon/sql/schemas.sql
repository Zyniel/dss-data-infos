-- dbmon template "schemas": one row per schema and tablespace it is tied to:
-- its default tablespace, the tablespaces where it holds a quota, and those where
-- it still has dropped objects in the recycle bin.
-- Live space per schema and tablespace is not read here: sum the objects result on
-- (schema_uid, tablespace_uid) instead of scanning DBA_SEGMENTS a second time.
-- Identity columns are added by the engine.
-- Rendered by dbmon/queries.py, not runnable as-is. Placeholders:
--   owner_filter     schemas in scope (default: non Oracle-maintained)
--
--   is_default_ts      Y for the schema's default tablespace
--   quota_status       UNLIMITED (quota -1 or UNLIMITED TABLESPACE), LIMITED or NONE
--   unlimited_ts_priv  Y when the schema holds UNLIMITED TABLESPACE. It can only be
--                      granted directly (never through a role), so DBA_SYS_PRIVS is enough.
--   recyclebin_*       dropped objects still in the recycle bin (size from DBA_RECYCLEBIN.SPACE)
WITH
scope AS (
  SELECT u.username, u.account_status, u.default_tablespace, u.temporary_tablespace
  FROM   dba_users u
  WHERE  {{owner_filter}}
),
quotas AS (
  SELECT q.username, q.tablespace_name, q.bytes, q.max_bytes
  FROM   dba_ts_quotas q
  WHERE  q.dropped = 'NO'
  AND    q.username IN (SELECT s.username FROM scope s)
),
unl AS (
  SELECT DISTINCT sp.grantee
  FROM   dba_sys_privs sp
  WHERE  sp.privilege = 'UNLIMITED TABLESPACE'
),
rbin AS (
  SELECT r.owner,
         r.ts_name                                                 AS tablespace_name,
         COUNT(*)                                                  AS rb_objects,
         SUM(CASE WHEN r.type = 'TABLE' THEN 1 ELSE 0 END)         AS rb_tables,
         SUM(r.space)                                              AS rb_blocks,
         MIN(r.droptime)                                           AS rb_oldest_droptime
  FROM   dba_recyclebin r
  WHERE  r.owner IN (SELECT s.username FROM scope s)
  AND    r.ts_name IS NOT NULL
  GROUP  BY r.owner, r.ts_name
),
-- every (schema, tablespace) pair the schema is tied to
pairs AS (
  SELECT s.username AS owner, s.default_tablespace AS tablespace_name FROM scope s
  UNION
  SELECT q.username, q.tablespace_name FROM quotas q
  UNION
  SELECT r.owner, r.tablespace_name FROM rbin r
)
SELECT p.owner,
       s.account_status,
       s.default_tablespace,
       s.temporary_tablespace,
       CASE WHEN x.grantee IS NULL THEN 'N' ELSE 'Y' END                          AS unlimited_ts_priv,
       p.tablespace_name,
       CASE WHEN p.tablespace_name = s.default_tablespace THEN 'Y' ELSE 'N' END   AS is_default_ts,
       CASE WHEN x.grantee IS NOT NULL OR q.max_bytes = -1 THEN 'UNLIMITED'
            WHEN q.username IS NULL OR q.max_bytes = 0     THEN 'NONE'
            ELSE 'LIMITED'
       END                                                                        AS quota_status,
       ROUND(CASE WHEN q.max_bytes > 0 THEN q.max_bytes END / 1048576, 3)         AS quota_max_mb,
       ROUND(q.bytes / 1048576, 3)                                                AS quota_used_mb,
       NVL(r.rb_objects, 0)                                                       AS recyclebin_objects,
       NVL(r.rb_tables, 0)                                                        AS recyclebin_tables,
       ROUND(NVL(r.rb_blocks, 0) * t.block_size / 1048576, 3)                     AS recyclebin_mb,
       TO_DATE(r.rb_oldest_droptime DEFAULT NULL ON CONVERSION ERROR,
               'YYYY-MM-DD:HH24:MI:SS')                                           AS recyclebin_oldest_drop
FROM   pairs p
       JOIN scope s                ON  s.username        = p.owner
       LEFT JOIN quotas q          ON  q.username        = p.owner
                                   AND q.tablespace_name = p.tablespace_name
       LEFT JOIN rbin r            ON  r.owner           = p.owner
                                   AND r.tablespace_name = p.tablespace_name
       LEFT JOIN unl x             ON  x.grantee         = p.owner
       LEFT JOIN dba_tablespaces t ON  t.tablespace_name = p.tablespace_name
ORDER  BY p.owner, p.tablespace_name
