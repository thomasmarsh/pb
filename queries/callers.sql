-- All objects that call a named function or method.
-- :name TEXT
-- @entity caller object
SELECT DISTINCT object AS caller, from_proc, call_type
FROM compat_calls
WHERE to_name = $name
ORDER BY caller;
