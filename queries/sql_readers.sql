-- Objects that SELECT from a DB table.
-- :table_name TEXT
-- @entity object object
SELECT DISTINCT object, source
FROM all_sql_tables
WHERE table_name = $table_name AND operation IN ('SELECT', 'retrieve')
ORDER BY source, object
