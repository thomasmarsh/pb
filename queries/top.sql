-- Most complex procedures by cyclomatic complexity.
-- :n INT 15
SELECT object, name, proc_type, cyclomatic
FROM procedures
ORDER BY cyclomatic DESC
LIMIT $n;
