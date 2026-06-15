-- Full lineage: every object that reads or writes a DB table.
-- :table_name TEXT
SELECT object, proc_name, operation, source
FROM all_sql_tables
WHERE table_name = $table_name
ORDER BY operation, object, proc_name
