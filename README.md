# UC storage footprint on Oracle 19c

Five standalone queries measure how much space each business use case (UC) takes on an Oracle database, and how it is spread. Each query is run once per database connection. Because every run returns the same columns, the results can be stacked across all environments and databases.

A use case owns two schemas, `<UC>_DSSWORK` and `<UC>_DSSOUT`. Each schema has a default `_DATA` tablespace and an extra `_INDEX` tablespace. The UC is the only business key used. Any mapping to projects or environments happens after stacking.

## Files

| File | One row per | Licence |
|---|---|---|
| `01_tablespace_usage.sql` | tablespace (all of them, UC ones flagged) | none |
| `02_object_usage.sql` | UC object × tablespace (partitions summed) | none |
| `03_table_usage.sql` | UC table, with indexes, LOBs and partitions rolled up | none |
| `03b_table_lifecycle.sql` | UC table: creation, last DDL, statistics age, DML since the last statistics | none |
| `04_awr_tablespace_daily.sql` | tablespace × day, over the AWR retention | Diagnostics Pack |
| `05_awr_object_activity.sql` | UC object seen by AWR over the last N days (I/O, block changes) | Diagnostics Pack |

Every file's header comment documents its columns and stack key.

## Running

- Run each file once per database (non-CDB) or once per PDB. On RAC, one instance is enough: the dictionary covers the whole database. Running it on each instance would duplicate rows.
- Use an account with `SELECT_CATALOG_ROLE` (or `SELECT ANY DICTIONARY`). Don't use the UC schema accounts: they can't read `DBA_` views, and every run would report the whole database again.
- Each file holds exactly one `SELECT` statement. There are no bind or substitution variables, no SQL*Plus commands and no blank lines inside the statement, so it runs unchanged in SQL*Plus and SQLcl. Remove the trailing `;` when you send the text through JDBC or python-oracledb.
- Settings live in the `params` CTE at the top of each file: the naming regexes for schemas and tablespaces, and the AWR window used by 05 (`days_back`, 31 by default).
- If the account can't read `V$ASM_DISKGROUP_STAT`, remove the `asm_dg` CTE and its join from 01. Only the ASM columns are lost.

## Stacking

- Every row starts with the same seven columns: `collected_utc, db_name, db_unique_name, cdb, con_name, con_dbid, database_role`. Map `db_unique_name` / `con_name` to your environment list after stacking.
- If standby databases are collected too, keep `database_role = 'PRIMARY'`.
- Keep appending runs. Two runs of 02 / 03 give exact object and table growth. 04 already covers the full AWR retention; consecutive runs overlap, so keep the latest `collected_utc` for each `(db, tablespace, snap_day)`.

## Conventions

- **UC, layer and role** are parsed from names: schema `<UC>_(DSSWORK|DSSOUT)`, tablespace `<UC>_(DSSWORK|DSSOUT)_(DATA|INDEX)`. A tablespace is expected to belong to the schema of the same name without the `_DATA` / `_INDEX` suffix.
- **Sizes** are in MB (1,048,576 bytes), rounded to 3 decimals.
- **Recycle bin**: excluded from 02 and 03, and reported per tablespace in 01 (`recyclebin_mb`, `_segments`, `_tables`, `_oldest_drop`). Membership is checked against `DBA_RECYCLEBIN`, not the `BIN$` prefix: after `FLASHBACK TABLE ... TO BEFORE DROP`, the restored indexes and LOB segments keep their `BIN$` names.
- **family** (02, 03) is one of:
  - `TABLE`: heap tables, partitions, IOT top index, IOT overflow, nested tables, clusters
  - `INDEX`
  - `LOB`
  - `LOBINDEX`
  - `OTHER`: e.g. the `TEMPORARY` segment of a CTAS still running
- **placement** (02, and `placement_issues` in 03) is one of:
  - `OK`
  - `INDEX_IN_DATA_TS`: index created without a `TABLESPACE` clause. Informational only.
  - `DATA_IN_INDEX_TS`: table or LOB data stored in `_INDEX`
  - `FOREIGN_TS`: segment in a tablespace that isn't its schema's (the other layer, another UC, or a non-UC tablespace)
- **config_issues** (01) lists schema and tablespace set-up problems: missing schema, wrong default tablespace, missing quota, `UNLIMITED TABLESPACE` held, segments owned by another schema. The file header lists them all.

## Oracle behaviours behind the design

- **Recycle bin versus free space.** Oracle reports recycle bin space as free, and reuses it before autoextending a datafile, but those segments still hold blocks. 01 therefore splits space into `live`, `recyclebin` and `free = alloc - live - recyclebin`. It doesn't use `DBA_FREE_SPACE`, which slows down in proportion to the number of objects in the recycle bin.
- **`tum_*` columns** come from `DBA_TABLESPACE_USAGE_METRICS`, the view behind OEM space alerts. `tum_max_mb` is capped by the free space left in storage and, in a PDB, by `MAX_PDB_STORAGE`.
- **Exadata**:
  - `compression` shows HCC levels (`QUERY LOW/HIGH`, `ARCHIVE LOW/HIGH`) per (sub)partition.
  - `est_row_data_mb / table_mb` above 1 means compression gain. Far below 1 on an uncompressed heap table, it means empty space under the high water mark.
  - `raw_alloc_mb` is `alloc_mb` × ASM redundancy (NORMAL = 2, HIGH = 3; FLEX or EXTENDED gives NULL).
  - `dg_usable_file_mb` belongs to the disk group, which tablespaces share. Don't sum it.
  - On sparse disk groups (snapshot copies), `alloc_mb` is the virtual size.
- **RAC.** Dictionary views cover the whole database. AWR deltas are per instance, and 05 sums them.
- **Multitenant and AWR.** Queried from a PDB, `DBA_HIST_*` shows the root snapshots for that PDB, plus PDB-level snapshots when `AWR_PDB_AUTOFLUSH_ENABLED` is on.
  - 04 keeps both series. It uses daily peaks and end-of-day levels, so a second series can't inflate the figures.
  - 05 keeps root snapshots only (`DBID = V$DATABASE.DBID`), so counters aren't doubled.
- **AWR segment statistics are top-N.** 05 shows hotspots, not an inventory: an object missing from it isn't proven idle. Space growth isn't taken from these rows, because every `TRUNCATE`, `MOVE` or re-create starts a new data object id.
- **Deferred segment creation.** Tables that never received a row have no segment. They appear in 03 with 0 MB and `segment_created = NO`.
- **`dml_*` (03b)** comes from `DBA_TAB_MODIFICATIONS`: DML since the last statistics gathering. Oracle flushes it from memory periodically, and the queries don't force the flush.
- **Performance**:
  - 01 scans `DBA_SEGMENTS` once for the whole database.
  - Table lifecycle is a separate query (03b), so a slow dictionary can't block the footprint collection. 03b reads each dictionary view once, restricted to the UC owners and materialised, then hash-joins them. Joined directly, these UNION ALL views can receive the join predicate and be re-run for every table row.
  - `DBA_TAB_STATISTICS` isn't used. Its `STALE_STATS` is computed row by row, and on Exadata real-time statistics add a second row per table (`NOTES = 'STATS_ON_CONVENTIONAL_DML'`). 03b derives `stale_est` from the DML counters instead.
  - If dictionary queries are still slow, gather dictionary and fixed-object statistics.

## References

- [DBA_HIST views in a PDB](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/dba_hist_-views.html), and [CDB-level vs PDB-level AWR snapshots](https://docs.oracle.com/en/database/oracle/oracle-database/19/tgdba/gathering-database-statistics.html)
- [DBA_HIST_SEG_STAT](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/DBA_HIST_SEG_STAT.html) (top segments only) and [pitfalls of segment growth from AWR](https://www.josip-pojatina.com/en/calculating-segment-growth-and-related-issues/)
- [DBA_HIST_TBSPC_SPACE_USAGE](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/DBA_HIST_TBSPC_SPACE_USAGE.html) and [DBA_TABLESPACE_USAGE_METRICS](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/DBA_TABLESPACE_USAGE_METRICS.html)
- DBA_FREE_SPACE slowness caused by the recycle bin: [Connor McDonald](https://connor-mcdonald.com/2020/08/27/finding-free-space-on-your-database-taking-a-long-time/), [Jonathan Lewis](https://jonathanlewis.wordpress.com/2019/08/08/free-space-3/)
- Recycle bin reused before autoextend: [test on 12.1](https://dbamarco.wordpress.com/2018/01/05/recyclebin-vs-autoextend/), [space pressure behaviour](https://www.dbi-services.com/blog/oracle-space-management-a-recycle-bin/)
- [V$DATABASE.DBID vs CON_DBID in a PDB](https://www.petefinnigan.com/weblog/archives/00001454.htm)
- [Join predicate pushdown and why it can be costly](https://blogs.oracle.com/optimizer/optimizer-transformation-join-predicate-pushdown)
- [Real-time statistics (Exadata only): extra rows in *_TAB_STATISTICS](https://oracle-base.com/articles/19c/real-time-statistics-19c)
