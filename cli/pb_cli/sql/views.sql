CREATE OR REPLACE VIEW all_sql_tables AS
    SELECT
        t.file,
        t.dw_name   AS object,
        'datawindow' AS source,
        'retrieve'   AS operation,
        t.table_name,
        NULL         AS proc_name,
        NULL::INT    AS line
    FROM dw_retrieve_tables t

    UNION ALL

    SELECT
        s.file,
        s.object,
        'powerscript' AS source,
        s.operation,
        unnest(s.tables) AS table_name,
        s.proc_name,
        s.line
    FROM sql_statements s
    WHERE s.tables IS NOT NULL AND len(s.tables) > 0
