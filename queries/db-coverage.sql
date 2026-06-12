-- Database tables referenced across all DataWindows, ranked by frequency.
SELECT table_name,
       count(DISTINCT dw_name) AS datawindow_count,
       string_agg(DISTINCT dw_name, ', ' ORDER BY dw_name) AS datawindows
FROM dw_retrieve_tables
GROUP BY table_name
ORDER BY datawindow_count DESC;
