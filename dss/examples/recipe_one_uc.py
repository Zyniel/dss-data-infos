# Dataiku Python recipe: one use case, read through the optional UC layer.
#
# Inputs : monitored_connections
# Outputs: uc_tables
#
# The UC comes from a project variable. Objects and tables share table_uid, so the
# table-level placement issues are computed from the objects and merged on one column.
import dataiku
import dbmon
from dbmon import uc

name = dataiku.get_custom_variables()["uc"]
targets = dataiku.Dataset("monitored_connections").get_dataframe()
targets = targets[targets["enabled"] == "Y"][["connection", "env"]]

objs = dbmon.objects(targets, owners=uc.owners(name))
tabs = dbmon.tables(targets, owners=uc.owners(name))
tabs = uc.enrich(tabs).merge(uc.table_placement(objs), on="table_uid", how="left")

dataiku.Dataset("uc_tables").write_with_schema(tabs)
