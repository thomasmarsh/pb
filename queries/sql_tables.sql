-- DB tables accessed by a given object (DataWindow PBSELECT + PowerScript).
-- :object TEXT
-- @entity table_name table
-- @entity proc_name procedure
-- @entity object object
SELECT table_name, source, operation, proc_name, $object AS object, line
FROM all_sql_tables
WHERE object = $object
ORDER BY source, table_name, proc_name, line
