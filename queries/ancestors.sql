-- Full ancestor chain for an object, from direct parent to root.
-- :name TEXT
WITH RECURSIVE chain AS (
    SELECT object AS obj, ancestor AS parent, 1 AS depth
    FROM objects WHERE object = $name AND ancestor IS NOT NULL
  UNION ALL
    SELECT chain.obj, o.ancestor, chain.depth + 1
    FROM objects o JOIN chain ON o.object = chain.parent
    WHERE o.ancestor IS NOT NULL
)
SELECT depth, parent
FROM chain
ORDER BY depth;
