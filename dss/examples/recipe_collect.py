# Dataiku Python recipe: storage footprint of every monitored database.
#
# Inputs : monitored_connections  (any dataset with a "connection" column)
# Outputs: db_tablespaces, db_schemas, db_objects, db_tables, db_lifecycle, db_runlog
#
# Which connections to read, and which labels to carry, is decided here, not in dbmon.
import dataiku
import dbmon

targets = dataiku.Dataset("monitored_connections").get_dataframe()
targets = targets[targets["enabled"] == "Y"][["connection", "env"]]   # env becomes a column

dbmon.write(
    {
        "tablespaces": "db_tablespaces",
        "schemas": "db_schemas",
        "objects": "db_objects",
        "tables": "db_tables",
        "lifecycle": "db_lifecycle",
    },
    connections=targets,
    runlog="db_runlog",
    # snapshot_dimension="collection_day",   # if the outputs are partitioned by day
)
