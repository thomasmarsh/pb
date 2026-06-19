CREATE TABLE IF NOT EXISTS objects (
    file        TEXT NOT NULL,
    name        TEXT NOT NULL,
    kind        TEXT NOT NULL,
    ancestor    TEXT,
    source_text TEXT
);

CREATE TABLE IF NOT EXISTS procedures (
    file             TEXT NOT NULL,
    object           TEXT NOT NULL,
    proc_type        TEXT NOT NULL,
    name             TEXT NOT NULL,
    modifiers        TEXT,
    params           TEXT,
    return_type      TEXT,
    start_line       INT,
    end_line         INT,
    body_json        JSON,
    source_rendered  TEXT,
    cyclomatic       INT
);

CREATE TABLE IF NOT EXISTS calls (
    file       TEXT,
    object     TEXT,
    from_proc  TEXT,
    to_name    TEXT,
    call_type  TEXT
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

CREATE TABLE IF NOT EXISTS sql_statements (
    file        TEXT NOT NULL,
    object      TEXT NOT NULL,
    proc_name   TEXT NOT NULL,
    line        INT  NOT NULL,
    operation   TEXT,
    raw_sql     TEXT,
    parsed_json JSON,
    tables      TEXT[],
    columns     TEXT[],
    has_into    BOOLEAN,
    has_cursor  BOOLEAN,
    parse_ok    BOOLEAN
);

CREATE TABLE IF NOT EXISTS parse_errors (
    file        TEXT NOT NULL,
    error_kind  TEXT NOT NULL,
    message     TEXT NOT NULL,
    object      TEXT,
    proc_name   TEXT,
    line        INT,
    snippet     TEXT
);

CREATE TABLE IF NOT EXISTS local_variables (
    file        TEXT NOT NULL,
    object      TEXT NOT NULL,
    proc_name   TEXT NOT NULL,
    var_name    TEXT NOT NULL,
    var_type    TEXT NOT NULL,
    start_line  INT
);

CREATE TABLE IF NOT EXISTS user_types (
    file        TEXT NOT NULL,
    type_name   TEXT NOT NULL,
    ancestor    TEXT,
    within_type TEXT
);

CREATE TABLE IF NOT EXISTS global_vars (
    file        TEXT NOT NULL,
    object      TEXT NOT NULL,
    var_name    TEXT NOT NULL,
    var_type    TEXT NOT NULL,
    modifiers   TEXT,
    scope       TEXT
);

CREATE TABLE IF NOT EXISTS resolved_types (
    file            TEXT NOT NULL,
    object          TEXT NOT NULL,
    proc_name       TEXT NOT NULL,
    var_name        TEXT NOT NULL,
    raw_type        TEXT NOT NULL,
    resolved_kind   TEXT NOT NULL,
    resolved_target TEXT,
    is_parameter    BOOLEAN NOT NULL DEFAULT FALSE,
    scope_line      INT
);

CREATE TABLE IF NOT EXISTS resolved_calls (
    file            TEXT NOT NULL,
    object          TEXT NOT NULL,
    from_proc       TEXT NOT NULL,
    to_name         TEXT NOT NULL,
    call_type       TEXT NOT NULL,
    call_line       INT,
    target_object   TEXT,
    target_proc     TEXT,
    resolution_kind TEXT NOT NULL,
    confidence      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS metadata (
    key   TEXT PRIMARY KEY,
    value TEXT
);
