-- Procedures with the most SQL statements, ranked by count.
-- :n INT 10
-- @entity object object
SELECT object, proc_name, count(*) AS sql_count,
       count(*) FILTER (WHERE parse_ok) AS parsed_count,
       array_agg(DISTINCT operation ORDER BY operation) AS operations
FROM sql_statements
GROUP BY object, proc_name
ORDER BY sql_count DESC
LIMIT $n
