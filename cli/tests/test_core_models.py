from pb_cli.core.models import (
    TABLES,
    ObjectRow,
    RowBatch,
    new_row_batch,
)


def test_object_row_fields():
    r = ObjectRow(file="a.srw", name="w_main", kind="powerscript", ancestor=None, source_text=None)
    assert r.file == "a.srw"
    assert r.name == "w_main"


def test_row_batch_keys():
    batch: RowBatch = new_row_batch()
    assert set(batch.keys()) == set(TABLES)
    for table in TABLES:
        assert batch[table] == []
