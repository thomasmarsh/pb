"""
pb_common — shared DuckDB schema and INSERT statements for pb_index and friends.
"""

TABLES = [
    'objects',
    'procedures',
    'dw_controls',
    'dw_retrieve_tables',
    'dw_retrieve_columns',
    'dw_retrieve_where',
    'dw_arguments',
    'inherits',
]

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS objects (
    file        TEXT NOT NULL,
    name        TEXT NOT NULL,
    kind        TEXT NOT NULL,
    ancestor    TEXT
);

CREATE TABLE IF NOT EXISTS procedures (
    file        TEXT NOT NULL,
    object      TEXT NOT NULL,
    proc_type   TEXT NOT NULL,
    name        TEXT NOT NULL,
    modifiers   TEXT,
    params      TEXT,
    return_type TEXT,
    start_line  INT,
    end_line    INT,
    body_json   JSON
);

CREATE TABLE IF NOT EXISTS dw_controls (
    file         TEXT NOT NULL,
    dw_name      TEXT NOT NULL,
    control_name TEXT,
    control_type TEXT,
    band         TEXT,
    x            INT,
    y            INT,
    width        INT,
    height       INT,
    expression   TEXT,
    tab_seq      INT,
    source_line  INT
);

CREATE TABLE IF NOT EXISTS dw_retrieve_tables (
    file       TEXT NOT NULL,
    dw_name    TEXT NOT NULL,
    table_name TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS dw_retrieve_columns (
    file        TEXT NOT NULL,
    dw_name     TEXT NOT NULL,
    column_fqn  TEXT NOT NULL,
    table_name  TEXT,
    column_name TEXT
);

CREATE TABLE IF NOT EXISTS dw_retrieve_where (
    file    TEXT NOT NULL,
    dw_name TEXT NOT NULL,
    idx     INT  NOT NULL,
    exp1    TEXT,
    op      TEXT,
    exp2    TEXT,
    logic   TEXT
);

CREATE TABLE IF NOT EXISTS dw_arguments (
    file     TEXT NOT NULL,
    dw_name  TEXT NOT NULL,
    arg_name TEXT NOT NULL,
    arg_type TEXT
);

CREATE TABLE IF NOT EXISTS inherits (
    from_object TEXT NOT NULL,
    to_object   TEXT NOT NULL
);
"""

INSERT = {
    'objects':             'INSERT INTO objects VALUES (?,?,?,?)',
    'procedures':          'INSERT INTO procedures VALUES (?,?,?,?,?,?,?,?,?,?)',
    'dw_controls':         'INSERT INTO dw_controls VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
    'dw_retrieve_tables':  'INSERT INTO dw_retrieve_tables VALUES (?,?,?)',
    'dw_retrieve_columns': 'INSERT INTO dw_retrieve_columns VALUES (?,?,?,?,?)',
    'dw_retrieve_where':   'INSERT INTO dw_retrieve_where VALUES (?,?,?,?,?,?,?)',
    'dw_arguments':        'INSERT INTO dw_arguments VALUES (?,?,?,?)',
    'inherits':            'INSERT INTO inherits VALUES (?,?)',
}


def create_schema(conn) -> None:
    for stmt in SCHEMA_SQL.split(';'):
        stmt = stmt.strip()
        if stmt:
            conn.execute(stmt)
