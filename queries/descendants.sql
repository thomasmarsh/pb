-- All objects that directly or transitively extend a base class.
-- :name TEXT
-- @entity descendant object
WITH RECURSIVE sub AS (
    SELECT object AS from_object, ancestor AS to_object
    FROM objects WHERE ancestor = $name
  UNION ALL
    SELECT o.object AS from_object, o.ancestor AS to_object
    FROM objects o JOIN sub ON o.ancestor = sub.from_object
    WHERE o.ancestor IS NOT NULL
)
SELECT DISTINCT from_object AS descendant
FROM sub
ORDER BY 1;
