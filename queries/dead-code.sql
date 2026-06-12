-- Non-public procedures never called from anywhere in the codebase.
SELECT p.object, p.proc_type, p.name, p.start_line
FROM procedures p
LEFT JOIN calls c ON c.to_name = p.name
WHERE c.to_name IS NULL
  AND p.proc_type IN ('function', 'subroutine')
  AND (p.modifiers IS NULL OR p.modifiers NOT LIKE '%public%')
ORDER BY p.object, p.name;
