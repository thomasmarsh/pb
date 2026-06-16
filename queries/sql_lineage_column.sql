-- Column-level lineage: every object that references a specific column.
-- :table_name TEXT
-- :column_name TEXT

SELECT
    'datawindow' AS source,
    dw_name      AS object,
    NULL         AS proc_name,
    'SELECT'     AS operation
FROM dw_retrieve_columns
WHERE table_name  = $table_name
  AND column_name = $column_name

UNION ALL

SELECT
    'powerscript' AS source,
    object,
    proc_name,
    operation
FROM sql_statements
WHERE $table_name  = ANY(tables)
  AND $column_name = ANY(columns)

ORDER BY source, object, proc_name
