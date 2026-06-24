-- Most complex procedures by cyclomatic complexity.
-- :n INT 15
-- @entity object object
-- @entity name procedure
SELECT object, name, proc_type, cyclomatic
FROM compat_procedures
ORDER BY cyclomatic DESC
LIMIT $n;
