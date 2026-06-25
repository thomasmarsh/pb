SELECT count(*)
FROM sql_statements
WHERE NOT parse_ok
  AND operation NOT IN ('CONNECT', 'DISCONNECT', 'EXECUTE', 'OPEN', 'FETCH', 'CLOSE')
  AND NOT (
    operation = 'DECLARE'
    AND regexp_matches(raw_sql, 'DYNAMIC\s+CURSOR\s+FOR\s+\w+\s*;?\s*$', 'i')
  )
  AND NOT (
    operation = 'DECLARE'
    AND regexp_matches(raw_sql, '\w+\s+PROCEDURE\s+FOR\s+\w+', 'i')
  )
