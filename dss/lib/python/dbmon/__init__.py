"""dbmon: Oracle storage monitoring for Dataiku, as a project library.

    import dbmon
    conns = ["MON_PRD_DB01", {"connection": "MON_UAT_DB01", "env": "UAT"}]
    dbmon.tablespaces(conns)                                # one row per tablespace
    dbmon.tables(conns, owners=["SALES_DSSWORK"])           # one schema
    dbmon.objects("MON_PRD_DB01", table="SALES_orders")     # one table, owner looked up
    dbmon.write({"tables": "db_tables"}, conns, runlog="db_runlog")   # in a recipe

connections: a Dataiku connection name, a list of names or of dicts
{"connection": name, other keys become label columns}, or a DataFrame with a
"connection" column. Choosing and labelling them is the caller's job.
Scope of the schema queries: owners (exact names) and/or owner_rx (regular
expression); by default every schema that is not Oracle-maintained.
The use-case convention is optional: see dbmon.uc.
"""
from . import uc
from .engine import collect, uid, write
from .queries import QUERY_NAMES

__all__ = ["tablespaces", "schemas", "objects", "tables", "lifecycle",
           "collect", "write", "uid", "uc", "QUERY_NAMES"]


def tablespaces(connections, names=None, with_log=False):
    """One row per tablespace: all of them, or the ones named."""
    return collect("tablespaces", connections, tablespaces=names, with_log=with_log)


def schemas(connections, owners=None, owner_rx=None, with_log=False):
    """One row per schema and tablespace it is tied to: default, quotas, recycle bin."""
    return collect("schemas", connections, owners=owners, owner_rx=owner_rx, with_log=with_log)


def objects(connections, owners=None, owner_rx=None, table=None, with_log=False):
    """One row per object and tablespace. table keeps the objects of one table."""
    return collect("objects", connections, owners=owners, owner_rx=owner_rx, table=table,
                   with_log=with_log)


def tables(connections, owners=None, owner_rx=None, table=None, with_log=False):
    """One row per table, with its indexes, LOBs and partitions rolled up."""
    return collect("tables", connections, owners=owners, owner_rx=owner_rx, table=table,
                   with_log=with_log)


def lifecycle(connections, owners=None, owner_rx=None, table=None, with_log=False):
    """Creation, last DDL, statistics age and DML since the last statistics, per table."""
    return collect("lifecycle", connections, owners=owners, owner_rx=owner_rx, table=table,
                   with_log=with_log)
