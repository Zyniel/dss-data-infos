"""SQL templates of dbmon, their filters and their keys.

The templates in dbmon/sql contain placeholders replaced here by predicates. The
Dataiku SQL executor has no bind variables, so every value is validated and
quoted before it reaches the SQL text.
"""
import os
import re

# query name -> template file in dbmon/sql
TEMPLATES = {
    "tablespaces": "tablespaces.sql",
    "schemas": "schemas.sql",
    "objects": "objects.sql",
    "tables": "tables.sql",
    "lifecycle": "lifecycle.sql",
}
QUERY_NAMES = tuple(TEMPLATES)

# filters each query accepts
FILTERS = {
    "tablespaces": ("tablespaces",),
    "schemas": ("owners", "owner_rx"),
    "objects": ("owners", "owner_rx", "table"),
    "tables": ("owners", "owner_rx", "table"),
    "lifecycle": ("owners", "owner_rx", "table"),
}

# Keys added by the engine: uid column -> (entity, columns). The same entity with
# the same values gets the same uid in every result, so one column joins them
# (objects.table_uid = tables.table_uid, ...).
KEYS = {
    "tablespaces": {"tablespace_uid": ("tablespace", ["tablespace_name"])},
    "schemas": {"schema_uid": ("schema", ["owner"]),
                "tablespace_uid": ("tablespace", ["tablespace_name"])},
    "objects": {"object_uid": ("object", ["owner", "object_name", "object_type", "tablespace_name"]),
                "table_uid": ("table", ["parent_owner", "parent_table"]),
                "schema_uid": ("schema", ["owner"]),
                "tablespace_uid": ("tablespace", ["tablespace_name"])},
    "tables": {"table_uid": ("table", ["owner", "table_name"]),
               "schema_uid": ("schema", ["owner"])},
    "lifecycle": {"table_uid": ("table", ["owner", "table_name"]),
                  "schema_uid": ("schema", ["owner"])},
}
UID_COLUMNS = sorted({c for keys in KEYS.values() for c in keys})

# single-table filter of each template: placeholder -> predicate
_TABLE_FILTERS = {
    "objects": {"table_filter": "WHERE o.parent_table = %s"},
    "tables": {"table_filter": "WHERE COALESCE(t.table_name, r.table_name) = %s"},
    "lifecycle": {"table_filter": "AND t.table_name = %s",
                  "object_filter": "AND o.object_name = %s",
                  "mods_filter": "AND m.table_name = %s"},
}

_PLACEHOLDER = re.compile(r"\{\{(\w+)\}\}")
_SQL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sql")
_templates = {}


def check(query, owners=None, owner_rx=None, table=None, tablespaces=None):
    """Validate a query name and its filters; returns the given filters normalised."""
    if query not in TEMPLATES:
        raise ValueError("unknown query %r, expected one of: %s" % (query, ", ".join(QUERY_NAMES)))
    given = {k: v for k, v in (("owners", owners), ("owner_rx", owner_rx),
                               ("table", table), ("tablespaces", tablespaces)) if v is not None}
    unsupported = sorted(set(given) - set(FILTERS[query]))
    if unsupported:
        raise ValueError("%s does not accept the filter(s): %s" % (query, ", ".join(unsupported)))
    if "owners" in given:
        given["owners"] = _names(given["owners"], "owners")
    if "tablespaces" in given:
        given["tablespaces"] = _names(given["tablespaces"], "tablespaces")
    if "table" in given:
        given["table"] = _name(given["table"], "table")
    if "owner_rx" in given:
        rx = given["owner_rx"]
        if not isinstance(rx, str) or not rx or len(rx.encode("utf-8")) > 512:
            raise ValueError("owner_rx must be a regular expression of at most 512 bytes")
    return given


def render(query, owners=None, owner_rx=None, table=None, tablespaces=None):
    """SQL text of a query with its filters applied (see owner_filter for the scope)."""
    if query == "tablespaces":
        values = {"ts_filter": _where_in("t.tablespace_name", tablespaces),
                  "seg_filter": _where_in("s.tablespace_name", tablespaces)}
    else:
        values = {"owner_filter": owner_filter(owners, owner_rx)}
        for placeholder, predicate in _TABLE_FILTERS.get(query, {}).items():
            values[placeholder] = predicate % literal(table) if table else ""
    sql = _template(query)
    found = set(_PLACEHOLDER.findall(sql))
    if found != set(values):
        raise RuntimeError("placeholders of %s do not match the renderer: %s"
                           % (TEMPLATES[query], sorted(found)))
    for key, value in values.items():
        sql = sql.replace("{{%s}}" % key, value)
    return sql


def owner_filter(owners=None, owner_rx=None):
    """Condition on DBA_USERS (alias u) selecting the schemas in scope.

    owners: exact names ([] selects none). owner_rx: Oracle regular expression.
    Without either, every schema that is not Oracle-maintained is in scope.
    """
    conditions = []
    if owners is not None:
        conditions.append(_in("u.username", owners))
    if owner_rx is not None:
        conditions.append("REGEXP_LIKE(u.username, %s)" % literal(owner_rx))
    return " AND ".join(conditions) or "u.oracle_maintained = 'N'"


def owners_lookup_sql(table, owners=None, owner_rx=None):
    """Schemas in scope that hold a table of that name (run before a single-table query)."""
    return ("SELECT t.owner FROM dba_tables t WHERE t.table_name = %s AND t.owner IN "
            "(SELECT u.username FROM dba_users u WHERE %s)" % (literal(table), owner_filter(owners, owner_rx)))


def literal(value):
    """Oracle string literal."""
    return "'" + str(value).replace("'", "''") + "'"


def _in(column, values):
    """column IN (...), split in chunks of 1000 (ORA-01795); an empty list selects nothing."""
    if not values:
        return "1 = 0"
    chunks = [values[i:i + 1000] for i in range(0, len(values), 1000)]
    parts = ["%s IN (%s)" % (column, ", ".join(literal(v) for v in chunk)) for chunk in chunks]
    return parts[0] if len(parts) == 1 else "(" + " OR ".join(parts) + ")"


def _where_in(column, values):
    return "" if values is None else "WHERE " + _in(column, values)


def _template(query):
    if query not in _templates:
        with open(os.path.join(_SQL_DIR, TEMPLATES[query]), encoding="utf-8") as f:
            _templates[query] = f.read()
    return _templates[query]


def _name(value, what):
    """An Oracle object name, matched exactly (quoted names can be mixed-case)."""
    if not isinstance(value, str) or not value.strip() or len(value) > 128 or "\x00" in value:
        raise ValueError("%s must be a name of 1 to 128 characters, got %r" % (what, value))
    return value


def _names(values, what):
    if isinstance(values, str):
        values = [values]
    return list(dict.fromkeys(_name(v, what) for v in values))
