from pb_cli.core.categorize import categorize


def test_categorize_sql():
    assert categorize("SELECT * FROM t")[0] == "sql"


def test_categorize_ctrl():
    assert categorize("if x > 0 then")[0] == "ctrl"


def test_categorize_decl():
    assert categorize("event clicked")[0] == "decl"


def test_categorize_handled():
    assert categorize("return")[0] == "handled"


def test_categorize_other():
    assert categorize("MessageBox('hi')")[0] == "other"


def test_categorize_empty():
    assert categorize("")[0] == "empty"
