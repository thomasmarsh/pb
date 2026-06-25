from pb.pipeline.runner import render_error


def test_render_error_returns_panel():
    obj = {"file": "test.srw", "error": "lex error at line 42"}
    panel = render_error(obj)
    assert panel is not None
