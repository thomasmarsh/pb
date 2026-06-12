-- All objects that directly or transitively extend a base class.
-- :name TEXT
WITH RECURSIVE sub AS (
    SELECT from_object, to_object FROM inherits WHERE to_object = $name
  UNION ALL
    SELECT i.from_object, i.to_object
    FROM inherits i JOIN sub ON i.to_object = sub.from_object
)
SELECT DISTINCT from_object AS descendant
FROM sub
ORDER BY 1;
