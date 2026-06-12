-- Object pairs with the most cross-calls (most tightly coupled).
-- :n INT 20
SELECT object AS caller, to_name AS callee, count(*) AS edge_count
FROM calls
WHERE object != to_name
GROUP BY object, to_name
HAVING count(*) > 3
ORDER BY edge_count DESC
LIMIT $n;
