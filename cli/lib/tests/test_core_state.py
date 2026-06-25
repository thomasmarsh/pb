from pb.lib.state import diff_state


def test_diff_state_all_new():
    current = {"a.srw": "aaa", "b.srw": "bbb"}
    stored = {}
    d = diff_state(current, stored)
    assert d.new == ["a.srw", "b.srw"]
    assert d.changed == []
    assert d.deleted == []
    assert d.unchanged == []


def test_diff_state_changed():
    current = {"a.srw": "new_hash"}
    stored = {"a.srw": "old_hash"}
    d = diff_state(current, stored)
    assert d.new == []
    assert d.changed == ["a.srw"]


def test_diff_state_deleted():
    current = {}
    stored = {"a.srw": "hash"}
    d = diff_state(current, stored)
    assert d.deleted == ["a.srw"]


def test_diff_state_unchanged():
    current = {"a.srw": "same"}
    stored = {"a.srw": "same"}
    d = diff_state(current, stored)
    assert d.unchanged == ["a.srw"]
