-- All objects that call a named function or method.
-- :name TEXT
-- @entity caller object
SELECT DISTINCT object AS caller, proc_name, call_type
FROM call_sites
WHERE to_name = $name
ORDER BY caller;
