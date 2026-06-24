-- DataWindows never referenced in any procedure call, retrieve spec, or SQL table ref.
-- A DW may still be used via dynamic string at runtime — this is static analysis only.
SELECT
    o.object AS datawindow,
    o.file
FROM dw_objects o
WHERE NOT EXISTS (
    SELECT 1 FROM call_sites c WHERE lower(c.to_name) = lower(o.object)
)
AND NOT EXISTS (
    SELECT 1 FROM all_sql_tables a WHERE lower(a.table_name) = lower(o.object)
)
ORDER BY o.object;
