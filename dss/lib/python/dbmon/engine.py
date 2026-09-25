"""Runs the dbmon queries on Oracle connections and consolidates the results.

Each call identifies the database behind every connection first. Connections that
reach the same database (another RAC node or service, a Data Guard standby) are
queried once, preferring the primary. Queries then run one at a time and one
database at a time, so a production database never runs two of them at once.
"""
import hashlib
import json
import logging
import time
from datetime import datetime, timezone

import pandas as pd

import dataiku
from dataiku import SQLExecutor2

from . import queries

# Session MODULE on the database, so DBAs can identify these queries (ASH, V$SESSION)
MODULE = "DBMON"

IDENTITY_SQL = """
SELECT d.name                                  AS db_name,
       d.db_unique_name,
       d.cdb,
       SYS_CONTEXT('USERENV', 'CON_NAME')      AS con_name,
       NVL(NULLIF(d.con_dbid, 0), d.dbid)      AS con_dbid,
       d.database_role,
       SYS_CONTEXT('USERENV', 'INSTANCE_NAME') AS instance_name
FROM   v$database d
"""
IDENTITY_COLUMNS = ["db_name", "db_unique_name", "cdb", "con_name", "con_dbid", "database_role"]
RESERVED = {"collected_utc", "dss_connection", "db_uid"} | set(IDENTITY_COLUMNS) | set(queries.UID_COLUMNS)
LOG_COLUMNS = ["dss_connection", "db_uid", "db_unique_name", "con_name", "instance_name",
               "database_role", "query", "filters", "status", "rows", "seconds", "message"]

logger = logging.getLogger("dbmon")


def uid(*parts):
    """Deterministic key: 32 hexadecimal characters of SHA-256 over the exact values."""
    text = json.dumps([str(p) for p in parts], ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:32]


def collect(query, connections, owners=None, owner_rx=None, table=None, tablespaces=None,
            with_log=False):
    """Run one query on every connection and return the consolidated DataFrame.

    connections  a Dataiku connection name, a list of names or of dicts
                 {"connection": name, other keys become label columns}, or a DataFrame
                 with a "connection" column (other columns become labels)
    A database that fails is skipped with a warning. The call raises only when no
    database returned anything. with_log=True also returns the run log.
    """
    filters = queries.check(query, owners=owners, owner_rx=owner_rx, table=table,
                            tablespaces=tablespaces)
    run = _Run(connections)
    frames, errors = [], 0
    for db in run.databases:
        try:
            df, status, seconds = run.fetch(query, db, filters)
        except _Fatal:
            raise
        except Exception as exc:
            errors += 1
            run.error(db, query, filters, exc)
            continue
        frames.append(df)
        run.add_log(db, query, filters, status, rows=len(df), seconds=seconds)
    if not frames and (errors or not run.databases):
        raise RuntimeError("%s returned nothing: %s" % (query, run.problems()))
    result = pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()
    return (result, run.log_frame()) if with_log else result


def write(outputs, connections, owners=None, owner_rx=None, table=None, tablespaces=None,
          runlog=None, snapshot_dimension=None):
    """Recipe helper: consolidate one or several queries, each into its own dataset.

    outputs             {query name: output dataset name}, all declared as recipe outputs
    filters             each query uses the ones it accepts; a filter no query accepts
                        is an error
    runlog              optional output dataset for the run log
    snapshot_dimension  time dimension of the outputs if they are partitioned by day:
                        any partition other than today's is refused, because the queries
                        describe the databases as they are now

    Each database's rows are written as soon as they are fetched. The call raises
    (after writing the run log) only if an output got nothing from any database.
    Returns the run log as a DataFrame.
    """
    if not isinstance(outputs, dict) or not outputs:
        raise TypeError("outputs must map query names to dataset names")
    given = {k: v for k, v in (("owners", owners), ("owner_rx", owner_rx), ("table", table),
                               ("tablespaces", tablespaces)) if v is not None}
    per_query, used = {}, set()
    for query in outputs:
        accepted = {k: v for k, v in given.items() if k in queries.FILTERS.get(query, ())}
        per_query[query] = queries.check(query, **accepted)
        used |= set(accepted)
    if set(given) - used:
        raise ValueError("filter(s) %s apply to none of: %s"
                         % (", ".join(sorted(set(given) - used)), ", ".join(outputs)))
    if snapshot_dimension:
        _check_snapshot_partition(snapshot_dimension)
    run = _Run(connections)
    failed = []
    for query, dataset_name in outputs.items():
        filters = per_query[query]
        dataset = dataiku.Dataset(dataset_name)
        writer, columns, done, errors = None, None, 0, 0
        try:
            for db in run.databases:
                try:
                    df, status, seconds = run.fetch(query, db, filters)
                    if writer is None:
                        columns = list(df.columns)
                        dataset.write_schema_from_dataframe(df)
                        writer = dataset.get_writer()
                    writer.write_dataframe(df[columns])
                except _Fatal:
                    raise
                except Exception as exc:
                    errors += 1
                    run.error(db, query, filters, exc)
                    continue
                done += 1
                run.add_log(db, query, filters, status, rows=len(df), seconds=seconds)
        finally:
            if writer is not None:
                writer.close()
        if not done and (errors or not run.databases):
            failed.append(dataset_name)
    log_df = run.log_frame()
    if runlog:
        dataiku.Dataset(runlog).write_with_schema(log_df)
    if failed:
        raise RuntimeError("No database returned data for %s: %s" % (", ".join(failed), run.problems()))
    return log_df


class _Fatal(ValueError):
    """A configuration error: stop the call instead of skipping a database."""


class _Run(object):
    """One call: its timestamp, its labels, the databases it reaches, and its log."""

    def __init__(self, connections):
        self.collected_utc = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)
        targets = _targets(connections)
        self.label_names = list(dict.fromkeys(k for t in targets for k in t["labels"]))
        self.log = []
        self.databases = self._identify(targets)

    def _identify(self, targets):
        found = []
        for target in targets:
            try:
                df = SQLExecutor2(connection=target["connection"]).query_to_df(IDENTITY_SQL)
                row = {str(c).lower(): v for c, v in df.iloc[0].items()}
                db = dict(target)
                db.update({c: _text(row[c]) for c in IDENTITY_COLUMNS + ["instance_name"]})
                db["con_dbid"] = int(row["con_dbid"])
            except Exception as exc:
                self.error(target, "identity", {}, exc)
                continue
            # logical database: the same across RAC nodes, services, Data Guard role
            # changes and PDB relocation (container name + its DBID)
            db["db_uid"] = uid("database", db["con_name"], db["con_dbid"])
            found.append(db)
        chosen = {}
        for db in found:
            kept = chosen.get(db["db_uid"])
            if kept is None or (db["database_role"] == "PRIMARY" and kept["database_role"] != "PRIMARY"):
                chosen[db["db_uid"]] = db
        databases = []
        for db in found:
            kept = chosen[db["db_uid"]]
            if kept is db:
                databases.append(db)
            else:
                self.add_log(db, "identity", {}, "DUPLICATE_DB", message="same database as " + kept["connection"])
        return databases

    def fetch(self, query, db, filters):
        """One query on one database: (rows, status, seconds), keys and identity in front."""
        started = time.time()
        owners, owner_rx, table = filters.get("owners"), filters.get("owner_rx"), filters.get("table")
        status = "OK"
        if table and not (owners is not None and len(owners) == 1):
            owners, owner_rx = self._table_owners(db, table, owners, owner_rx), None
            if not owners:
                status = "NO_MATCH"
        sql = queries.render(query, owners=owners, owner_rx=owner_rx, table=table,
                             tablespaces=filters.get("tablespaces"))
        df = SQLExecutor2(connection=db["connection"]).query_to_df(
            sql, pre_queries=[_tag_session(query)], infer_from_schema=True)
        df.columns = [str(c).lower() for c in df.columns]
        self._add_front(df, query, db)
        return df, status, round(time.time() - started, 1)

    def _table_owners(self, db, table, owners, owner_rx):
        """Schemas in scope holding the table, looked up once per database and call."""
        cache = db.setdefault("lookups", {})
        key = (table, tuple(owners) if owners is not None else None, owner_rx)
        if key not in cache:
            try:
                found = SQLExecutor2(connection=db["connection"]).query_to_df(
                    queries.owners_lookup_sql(table, owners, owner_rx))
                cache[key] = sorted(str(v) for v in found.iloc[:, 0])
            except Exception as exc:
                cache[key] = exc
        if isinstance(cache[key], Exception):
            raise cache[key]
        return cache[key]

    def _add_front(self, df, query, db):
        clash = [name for name in self.label_names if name in df.columns]
        if clash:
            raise _Fatal("label(s) %s collide with columns of %s" % (", ".join(clash), query))
        front = ([("collected_utc", self.collected_utc)]
                 + [(name, db["labels"].get(name)) for name in self.label_names]
                 + [("dss_connection", db["connection"]), ("db_uid", db["db_uid"])]
                 + [(c, db[c]) for c in IDENTITY_COLUMNS])
        for position, (column, value) in enumerate(front):
            df.insert(position, column, value)
        position = len(front)
        for column, (entity, parts) in queries.KEYS[query].items():
            rows = zip(*(df[c] for c in parts)) if len(df) else []
            df.insert(position, column,
                      [None if any(_missing(v) for v in values) else uid(entity, db["db_uid"], *values)
                       for values in rows])
            position += 1

    def add_log(self, db, query, filters, status, rows=None, seconds=None, message=None):
        entry = {"collected_utc": self.collected_utc}
        entry.update({name: db["labels"].get(name) for name in self.label_names})
        entry.update({"dss_connection": db["connection"], "db_uid": db.get("db_uid"),
                      "db_unique_name": db.get("db_unique_name"), "con_name": db.get("con_name"),
                      "instance_name": db.get("instance_name"),
                      "database_role": db.get("database_role"), "query": query,
                      "filters": _describe(filters), "status": status, "rows": rows,
                      "seconds": seconds, "message": message})
        self.log.append(entry)

    def error(self, db, query, filters, exc):
        self.add_log(db, query, filters, "ERROR", message=_short(exc))
        logger.warning("dbmon %s failed on %s: %s", query, db["connection"], _short(exc))

    def log_frame(self):
        return pd.DataFrame(self.log, columns=["collected_utc"] + self.label_names + LOG_COLUMNS)

    def problems(self):
        errors = ["%s (%s): %s" % (e["dss_connection"], e["query"], e["message"])
                  for e in self.log if e["status"] == "ERROR"]
        return "; ".join(errors) or "no database reached"


def _targets(connections):
    """[{"connection": name, "labels": {...}}] from the connections argument."""
    if isinstance(connections, pd.DataFrame):
        items = connections.to_dict("records")
    elif isinstance(connections, (str, dict)):
        items = [connections]
    else:
        items = list(connections or [])
    targets = []
    for item in items:
        entry = {"connection": item} if isinstance(item, str) else dict(item)
        name = _text(entry.pop("connection", None))
        if not name:
            raise ValueError("every target needs a connection name, got %r" % (item,))
        labels = {str(k): (None if _missing(v) else v) for k, v in entry.items()}
        clash = sorted(set(labels) & RESERVED)
        if clash:
            raise ValueError("label(s) %s are reserved column names" % ", ".join(clash))
        targets.append({"connection": name, "labels": labels})
    if not targets:
        raise ValueError("no connection given")
    return targets


def _tag_session(action):
    return ("BEGIN DBMS_APPLICATION_INFO.SET_MODULE(module_name => '%s', action_name => '%s'); END;"
            % (MODULE[:48], action[:32]))


def _check_snapshot_partition(dimension):
    """Refuse to write today's state into a past partition."""
    variables = getattr(dataiku, "dku_flow_variables", None) or {}
    target = variables.get("DKU_DST_" + dimension)
    if target is None:
        return
    today = {datetime.now().strftime("%Y-%m-%d"), datetime.now(timezone.utc).strftime("%Y-%m-%d")}
    if target not in today:
        raise RuntimeError("Refusing to build partition %s=%s: only today's partition can be "
                           "collected." % (dimension, target))


def _describe(filters):
    parts = []
    for key in ("owners", "owner_rx", "table", "tablespaces"):
        if key in filters:
            value = filters[key]
            parts.append("%s=%s" % (key, ",".join(value) if isinstance(value, list) else value))
    return " ".join(parts) or None


def _missing(value):
    """None, NaN, NaT or pd.NA."""
    try:
        return bool(pd.isna(value))
    except (TypeError, ValueError):
        return False


def _text(value):
    return "" if _missing(value) else str(value).strip()


def _short(exc):
    return " ".join(str(exc).split())[:2000]
