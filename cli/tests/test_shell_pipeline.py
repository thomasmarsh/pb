"""Smoke test for pb_cli.shell.pipeline — full integration behavior is covered by
tests/test_explorer.py.
"""
import inspect

from pb_cli.shell.pipeline import run


def test_pipeline_run_exists():
    sig = inspect.signature(run)
    params = list(sig.parameters.keys())
    assert "src_dir" in params
    assert "db" in params
    assert "binary" in params
