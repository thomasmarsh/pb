-- All SQL lint issues (PB.Analysis.SqlLint) with procedure context.
SELECT l.issue_code, l.severity, l.object, l.proc_name, l.line, s.raw_sql
FROM sql_lint_issues l
JOIN sql_statements s
  ON l.file = s.file AND l.object = s.object
 AND l.proc_name = s.proc_name AND l.line = s.line
ORDER BY l.severity DESC, l.issue_code, l.object, l.proc_name;
