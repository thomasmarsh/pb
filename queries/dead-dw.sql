-- DataWindows never referenced in any procedure call, retrieve spec, or SQL table ref.
-- A DW may still be used via dynamic string at runtime — this is static analysis only.
SELECT
    o.name AS datawindow,
    o.file,
    o.ancestor
FROM compat_objects o
WHERE o.kind = 'datawindow'
  AND NOT EXISTS (
      SELECT 1 FROM compat_calls c
      WHERE lower(c.to_name) = lower(o.name)
  )
  AND NOT EXISTS (
      SELECT 1 FROM all_sql_tables a
      WHERE lower(a.table_name) = lower(o.name)
  )
ORDER BY o.name;
