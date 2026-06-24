-- Full ancestor chain for an object, from direct parent to root.
-- :name TEXT
WITH RECURSIVE chain AS (
    SELECT from_object AS obj, to_object AS parent, 1 AS depth
    FROM compat_inherits
    WHERE from_object = $name
  UNION ALL
    SELECT chain.obj, i.to_object, chain.depth + 1
    FROM compat_inherits i
    JOIN chain ON chain.parent = i.from_object
)
SELECT depth, parent
FROM chain
ORDER BY depth;
