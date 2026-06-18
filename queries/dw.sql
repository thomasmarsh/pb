-- Tables and columns retrieved by a DataWindow.
-- :name TEXT
-- @entity table_name table
SELECT dt.table_name,
       string_agg(dc.column_name, ', ' ORDER BY dc.column_name) AS columns
FROM dw_retrieve_tables dt
JOIN dw_retrieve_columns dc
  ON dc.dw_name = dt.dw_name AND dc.table_name = dt.table_name
WHERE dt.dw_name = $name
GROUP BY dt.table_name;