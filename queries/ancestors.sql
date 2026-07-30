-- Full ancestor chain for an object, from direct parent to root. Unions
-- type_ancestors so $name can also be a nested (within-qualified) control
-- name -- e.g. an implicit system control like an MDI frame's own mdi_1 --
-- not just a top-level object name.
-- :name TEXT
WITH RECURSIVE all_inherits AS (
    SELECT object AS child, ancestor AS parent FROM objects WHERE ancestor IS NOT NULL
  UNION
    SELECT child, parent FROM type_ancestors
), chain AS (
    SELECT child AS obj, parent, 1 AS depth
    FROM all_inherits WHERE child = $name
  UNION ALL
    SELECT chain.obj, i.parent, chain.depth + 1
    FROM all_inherits i JOIN chain ON i.child = chain.parent
)
SELECT depth, parent
FROM chain
ORDER BY depth;
