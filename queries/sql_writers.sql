-- Objects that INSERT, UPDATE, or DELETE from a DB table.
-- :table_name TEXT
SELECT DISTINCT object, proc_name, operation, source
FROM all_sql_tables
WHERE table_name = $table_name AND operation IN ('INSERT', 'UPDATE', 'DELETE')
ORDER BY operation, object, proc_name
