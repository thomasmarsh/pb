from pb.pipeline.build import _SR_EXT, walk_sr_files


def test_sr_ext_regex():
    assert _SR_EXT.search(".srw")
    assert _SR_EXT.search(".sru")
    assert _SR_EXT.search(".srd")
    assert not _SR_EXT.search(".txt")
    assert not _SR_EXT.search(".sr")


def test_walk_sr_files_empty(tmp_path):
    result = walk_sr_files(tmp_path)
    assert result == []


def test_walk_sr_files_finds_sr(tmp_path):
    (tmp_path / "test.srw").write_text("test")
    (tmp_path / "other.txt").write_text("test")
    result = walk_sr_files(tmp_path)
    assert len(result) == 1
    assert result[0].name == "test.srw"
