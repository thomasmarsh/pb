from pb_cli.core.ingestion import ingest_file
from pb_cli.core.models import new_row_batch


def test_ingest_powerscript_object():
    obj = {
        "file": "test.srw", "kind": "powerscript",
        "meta": {"object": "w_main", "ancestor": "w_base"},
        "functions": [{"sig": {"name": "uf_init", "modifiers": ["public"], "params": "()",
                               "returnType": "void"},
                       "body": [{"tag": "BsReturn", "contents": {}}]}],
    }
    rows = new_row_batch()
    ingest_file(obj, rows)
    assert len(rows["objects"]) == 1
    assert rows["objects"][0].name == "w_main"
    assert rows["objects"][0].ancestor == "w_base"
    assert len(rows["inherits"]) == 1
    assert len(rows["procedures"]) == 1
    assert rows["procedures"][0].name == "uf_init"


def test_ingest_datawindow_object():
    obj = {
        "file": "d_test.srd", "kind": "datawindow",
        "meta": {"object": "d_test"},
        "controls": [{"name": "col_1", "type": "column", "band": "detail",
                      "x": 10, "y": 20, "width": 100, "height": 24}],
    }
    rows = new_row_batch()
    ingest_file(obj, rows)
    assert len(rows["dw_controls"]) == 1
    assert rows["dw_controls"][0].control_name == "col_1"
