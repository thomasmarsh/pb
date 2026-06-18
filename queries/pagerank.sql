-- Most important objects by PageRank (run pb analyze first).
-- :n INT 10
-- @entity object object
SELECT object, round(pagerank, 6) AS pagerank, in_degree, out_degree, max_cyclomatic
FROM object_metrics
ORDER BY pagerank DESC
LIMIT $n;
