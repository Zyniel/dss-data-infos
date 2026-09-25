"""Optional use-case (UC) layer on top of dbmon.

Naming convention: a UC owns the schemas <UC>_DSSWORK and <UC>_DSSOUT, each with a
default tablespace <schema>_DATA and an extra tablespace <schema>_INDEX.

    import dbmon
    from dbmon import uc

    objs = dbmon.objects(conns, owners=uc.owners("SALES"))    # one UC
    objs = dbmon.objects(conns, owner_rx=uc.OWNER_RX)         # every UC
    objs = uc.enrich(objs)                                    # uc, schema_layer, ts_role, placement
    tabs = dbmon.tables(conns, owner_rx=uc.OWNER_RX)
    tabs = tabs.merge(uc.table_placement(objs), on="table_uid", how="left")
"""
import re

import numpy as np

LAYERS = ("DSSWORK", "DSSOUT")
ROLES = ("DATA", "INDEX")
OWNER_RX = "^(.+)_(DSSWORK|DSSOUT)$"
TABLESPACE_RX = "^(.+)_(DSSWORK|DSSOUT)_(DATA|INDEX)$"
DATA_FAMILIES = ("TABLE", "LOB", "LOBINDEX")


def owners(uc):
    """The two schemas of a UC."""
    return [_uc(uc) + "_" + layer for layer in LAYERS]


def tablespaces(uc):
    """The four tablespaces of a UC."""
    return ["%s_%s_%s" % (_uc(uc), layer, role) for layer in LAYERS for role in ROLES]


def enrich(df):
    """Return a copy of a dbmon result with the UC reading of its names.

    owner            -> uc, schema_layer
    tablespace_name  -> ts_uc, ts_layer, ts_role, ts_expected_owner
    objects (family) -> placement: OK, INDEX_IN_DATA_TS (index created without a
                        TABLESPACE clause), DATA_IN_INDEX_TS, FOREIGN_TS (tablespace
                        of another schema or outside the convention)
    """
    out = df.copy()
    if "owner" in out.columns:
        parts = out["owner"].astype(str).str.extract(OWNER_RX)
        out["uc"], out["schema_layer"] = parts[0], parts[1]
    if "tablespace_name" in out.columns:
        parts = out["tablespace_name"].astype(str).str.extract(TABLESPACE_RX)
        out["ts_uc"], out["ts_layer"], out["ts_role"] = parts[0], parts[1], parts[2]
        out["ts_expected_owner"] = parts[0].str.cat(parts[1], sep="_")
        if {"family", "owner"} <= set(out.columns):
            foreign = _flag(out["ts_expected_owner"].isna()) | _flag(out["ts_expected_owner"] != out["owner"])
            data = _flag(out["family"].isin(DATA_FAMILIES))
            out["placement"] = np.select(
                [foreign,
                 data & _flag(out["ts_role"] == "INDEX"),
                 _flag(out["family"] == "INDEX") & _flag(out["ts_role"] == "DATA")],
                ["FOREIGN_TS", "DATA_IN_INDEX_TS", "INDEX_IN_DATA_TS"], default="OK")
    return out


def table_placement(objects):
    """Placement issues of each table from the objects result: columns table_uid, placement_issues."""
    obj = objects if "placement" in objects.columns else enrich(objects)
    issues = obj[(obj["placement"] != "OK") & obj["table_uid"].notna()]
    return (issues.groupby("table_uid")["placement"]
            .agg(lambda s: ",".join(sorted(set(s))))
            .rename("placement_issues").reset_index())


def _uc(uc):
    text = str(uc).strip().upper()
    if not re.match(r"^[A-Z][A-Z0-9_$#]*$", text):
        raise ValueError("uc must be an Oracle identifier, got %r" % (uc,))
    return text


def _flag(series):
    """Boolean numpy array, missing values read as False (pandas 1.x to 3.x)."""
    return series.fillna(False).astype(bool).to_numpy()
