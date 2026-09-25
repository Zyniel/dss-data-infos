# dbmon: Oracle storage monitoring for Dataiku

`dbmon` is a Python package for a Dataiku project library, called from recipes and notebooks. It measures where the space of Oracle databases goes: tablespaces, schemas, objects and tables, plus the lifecycle of tables.

- It works on any schema: no naming convention is built in.
- The use-case (UC) convention is an optional layer, `dbmon.uc`.
- The caller decides which connections to read. The library never reads a project dataset on its own.

The queries at the repository root stay there as history. The AWR ones (04, 05) aren't part of the library.

## Layout

```
dss/
├── lib/python/dbmon/        project library package
│   ├── __init__.py          public functions
│   ├── engine.py            identity, keys, consolidation, run log
│   ├── queries.py           templates, filters, key definitions
│   ├── uc.py                optional use-case layer
│   └── sql/                 tablespaces, schemas, objects, tables, lifecycle
└── examples/                recipe_collect.py, recipe_one_uc.py
```

## Install

- **Library:** copy `dss/lib/python/dbmon` to the project library as `lib/python/dbmon`. Alternatively, import this repository as a Git reference with subpath `dss/lib/python/dbmon` and target path `python/dbmon`.
- **Other projects:** add this project to `importLibrariesFromProjects` in their `external-libraries.json`.
- **Oracle account:** each monitored connection needs an account with `SELECT_CATALOG_ROLE`.

## Functions

| Function | One row per | Filters |
|---|---|---|
| `tablespaces(connections, names)` | tablespace | tablespace names |
| `schemas(connections, owners, owner_rx)` | schema and tablespace it is tied to (default, quota, recycle bin) | scope |
| `objects(connections, owners, owner_rx, table)` | object and tablespace, partitions summed | scope, table |
| `tables(connections, owners, owner_rx, table)` | table, with indexes, LOBs and partitions rolled up | scope, table |
| `lifecycle(connections, owners, owner_rx, table)` | table: creation, last DDL, statistics age, DML | scope, table |
| `write(outputs, connections, ...)` | recipes: one dataset per query | each query takes the filters it accepts |
| `uid(*parts)` | the key function, for your own entities | none |

- **`connections`:** one of:
  - a Dataiku connection name;
  - a list of names or `{"connection": ..., <label>: ...}` dicts;
  - a DataFrame with a `connection` column.

  Extra keys or columns, such as `env`, become label columns on every row. Reading, filtering and labelling the list is the caller's job.
- **Scope:** `owners` takes exact schema names; `owner_rx` takes an Oracle regular expression. Use either, or both. Without them, the scope is every schema that isn't Oracle-maintained.
- **`table`:** one table, by exact name. Without a single owner, each database first gets one small `DBA_TABLES` lookup, and only the schemas holding the table are read. Databases without it are logged as `NO_MATCH`.
- **`with_log=True`:** the read functions also return the run log.
- **Validation:** Dataiku's SQL executor has no bind variables, so every value is validated and quoted. `IN` lists are split every 1000 names (`ORA-01795`).

## Keys

Every row carries `db_uid` plus a key per entity it describes. A key is a hash of the entity type, the database, and the entity's exact names. As a result, one column joins the results together:

| Key | Built from | Found in |
|---|---|---|
| `db_uid` | container name + its DBID | all |
| `tablespace_uid` | db + tablespace name | tablespaces, schemas, objects |
| `schema_uid` | db + owner | schemas, objects, tables, lifecycle |
| `table_uid` | db + owner + table name (for objects: their parent table) | objects, tables, lifecycle |
| `object_uid` | db + owner + name + type + tablespace | objects |

- **Stability of `db_uid`:** it doesn't change across RAC nodes, services, Data Guard role changes or PDB relocation. `db_unique_name` isn't part of it, because it changes on switchover.
- **Clones:** a clone that received a new DBID gets a new `db_uid`. Storage-level clones that keep both name and DBID would share it; if you collect those, keep a label in your joins.
- **Rebuilt tables:** a table dropped and recreated under the same name keeps its `table_uid`, which is what you want for datasets Dataiku rebuilds. Renaming it changes the key.
- **History:** `(key, collected_utc)` identifies a snapshot row. Growth is a join of two runs on the key.

## Placement, without a convention

`objects.ts_kind` says where each object sits relative to its owner:
- `DEFAULT`: the owner's default tablespace;
- `QUOTA`: another tablespace where the owner holds a quota;
- `OTHER`: anywhere else.

`tables` sums its sizes into `in_default_ts_mb`, `in_quota_ts_mb` and `in_other_ts_mb`.

## Optional use-case layer

```python
import dbmon
from dbmon import uc

objs = dbmon.objects(conns, owners=uc.owners("SALES"))    # one UC
objs = dbmon.objects(conns, owner_rx=uc.OWNER_RX)         # every UC
objs = uc.enrich(objs)                                    # uc, schema_layer, ts_role, placement
tabs = uc.enrich(dbmon.tables(conns, owner_rx=uc.OWNER_RX))
tabs = tabs.merge(uc.table_placement(objs), on="table_uid", how="left")
```

- **`uc.enrich`:** adds `uc` and `schema_layer` from the owner; `ts_uc`, `ts_layer`, `ts_role` and `ts_expected_owner` from the tablespace. For objects it also adds `placement`: `OK`, `INDEX_IN_DATA_TS`, `DATA_IN_INDEX_TS` or `FOREIGN_TS`.
- **`uc.table_placement`:** rolls those flags up to `table_uid`.
- **`uc.tablespaces(uc)`:** gives the four tablespace names, for `tablespaces(conns, names=...)`.

## Chaining instead of fetching twice

- **Live space per schema and tablespace:** sum `objects.size_mb` on `(schema_uid, tablespace_uid)`. `schemas` deliberately doesn't scan `DBA_SEGMENTS` again.
- **Table placement:** comes from the objects, merged on `table_uid`, as shown above.

## Behaviour

- **Duplicates:** each call identifies the database behind every connection first. Connections that reach the same database (another node or service, a standby) are queried once, keeping the primary. The others are logged as `DUPLICATE_DB`.
- **Load on the databases:** queries run one at a time, one database at a time. Sessions are tagged `MODULE = DBMON`, `ACTION = <query>` for ASH and `V$SESSION`.
- **Failures:**
  - A failing database is skipped with a warning, and the read functions raise only when no database returned anything.
  - A label that collides with a result column stops the call.
  - `write` raises only if an output got nothing from any database, and only after writing the other outputs and the run log.
- **Run log statuses:** `OK`, `NO_MATCH`, `ERROR`, `DUPLICATE_DB`.

## Recipes

See [examples/recipe_collect.py](examples/recipe_collect.py) and [examples/recipe_one_uc.py](examples/recipe_one_uc.py). Declare as recipe outputs every dataset passed to `write`, plus the run log.

Choose a history mode per output:
- **Overwrite** (the default): latest state only.
- **Append** (the "Append instead of overwrite" option on the recipe output): every run is kept.
- **Partitioned by day:** pass `snapshot_dimension`. Past partitions are then refused, because the queries describe the databases as they are now.

## SQL templates

`objects`, `tables` and `lifecycle` were derived from 02, 03 and 03b by a scripted edit, with every edit checked for its expected count:
- the use-case naming logic was removed;
- the scope became the `owner_filter` placeholder;
- placement became `ts_kind`, computed from `DBA_USERS.DEFAULT_TABLESPACE` and `DBA_TS_QUOTAS`;
- the identity columns moved to the engine.

`tablespaces` is 01 without the use-case checks. `schemas` is new. From now on, change the templates; the root files are history.
