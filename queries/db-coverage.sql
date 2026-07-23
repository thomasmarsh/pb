-- Database tables referenced across all DataWindows, ranked by frequency.
-- @entity table_name table
SELECT table_name,
       count(DISTINCT object) AS datawindow_count,
       string_agg(DISTINCT object, ', ' ORDER BY object) AS datawindows
FROM dw_retrieve_tables
GROUP BY table_name
ORDER BY datawindow_count DESC;
