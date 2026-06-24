-- Column-level lineage: every object that references a specific column.
-- :table_name TEXT
-- :column_name TEXT

SELECT
    'powerscript' AS source,
    object,
    proc_name,
    operation
FROM sql_statements
WHERE list_contains(string_split(tables, ','), $table_name)
  AND list_contains(string_split(columns, ','), $column_name)

ORDER BY source, object, proc_name
