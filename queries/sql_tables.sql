-- DB tables accessed by a given object (DataWindow PBSELECT + PowerScript).
-- :object TEXT
SELECT table_name, source, operation, proc_name, stmt_idx
FROM all_sql_tables
WHERE object = $object
ORDER BY source, table_name, proc_name, stmt_idx
