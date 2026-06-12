-- Objects with both high fan-in (in_degree) and high cyclomatic complexity.
-- Scale thresholds to your codebase; defaults suit a medium corpus.
-- :min_degree INT 5
-- :min_cyclomatic INT 3
SELECT m.object, m.in_degree, m.max_cyclomatic, m.avg_cyclomatic,
       count(p.name) AS proc_count
FROM object_metrics m
JOIN procedures p ON p.object = m.object
GROUP BY m.object, m.in_degree, m.max_cyclomatic, m.avg_cyclomatic
HAVING m.in_degree >= $min_degree AND m.max_cyclomatic >= $min_cyclomatic
ORDER BY m.in_degree * m.max_cyclomatic DESC;
