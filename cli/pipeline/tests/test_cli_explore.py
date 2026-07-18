"""Unit tests for pb.pipeline.cli.explore()'s background-index wiring (Plan 181 Phase 4).

Exercises explore()'s control flow directly (bypassing Typer's CLI dispatch --
calling the decorated function with explicit keyword args works exactly like
test_shell_commands.py does for corpus.run()) with every side-effecting env
field and module-level dependency monkeypatched.
"""

from __future__ import annotations

from contextlib import contextmanager
from types import SimpleNamespace

from pb.pipeline import cli


def _patch_common(monkeypatch, tmp_path, *, port_in_use: bool = False):
    monkeypatch.setattr(cli, "_port_in_use", lambda host, port: port_in_use)
    monkeypatch.setattr(cli.env.build, "find_repo", lambda repo=None: tmp_path)
    monkeypatch.setattr(cli.env.build, "ensure_explorer_built", lambda repo, verbose=False: None)
    monkeypatch.setattr(cli.env.build, "find_binary", lambda repo: tmp_path / "pbc")


def _explore_kwargs(tmp_path, input_dir, **overrides):
    kwargs = dict(
        input_path=input_dir,
        db=str(tmp_path / "out.duckdb"),
        host="127.0.0.1",
        port=8000,
        open_browser=False,
        no_build=True,
        reset=True,
        sql_dialect="oracle",
        repo=None,
        ddl=[],
        default_namespace=None,
        diagnostics_report=None,
    )
    kwargs.update(overrides)
    return kwargs


def test_explore_attaches_index_job_and_starts_before_uvicorn_run(monkeypatch, tmp_path):
    _patch_common(monkeypatch, tmp_path)

    call_order: list[str] = []
    constructed: list[object] = []

    class _FakeIndexJob:
        def __init__(self, src_dir, db, binary, **kwargs):
            self.src_dir = src_dir
            self.db = db
            self.binary = binary
            self.kwargs = kwargs
            constructed.append(self)

        def start(self):
            call_order.append("start")

    monkeypatch.setattr(cli, "IndexJob", _FakeIndexJob, raising=False)

    @contextmanager
    def fake_resolve_source_dir(path, reporter):
        yield path

    monkeypatch.setattr(cli, "resolve_source_dir", fake_resolve_source_dir)

    fake_app = SimpleNamespace(state=SimpleNamespace(index_job=None))
    monkeypatch.setattr("pb.api.create_app", lambda db: fake_app)

    def fake_uvicorn_run(app, **kwargs):
        call_order.append("uvicorn_run")

    monkeypatch.setattr(cli.uvicorn, "run", fake_uvicorn_run)

    input_dir = tmp_path / "src"
    input_dir.mkdir()

    cli.explore(**_explore_kwargs(tmp_path, input_dir))

    assert len(constructed) == 1
    assert fake_app.state.index_job is constructed[0]
    assert call_order == ["start", "uvicorn_run"]


def test_explore_skips_index_job_when_db_current(monkeypatch, tmp_path, capsys):
    _patch_common(monkeypatch, tmp_path)
    monkeypatch.setattr(cli, "db_is_current", lambda input_path, db: True)

    constructed: list[object] = []

    class _FakeIndexJob:
        def __init__(self, *a, **k):
            constructed.append(self)

        def start(self):
            pass

    monkeypatch.setattr(cli, "IndexJob", _FakeIndexJob, raising=False)

    fake_app = SimpleNamespace(state=SimpleNamespace(index_job=None))
    monkeypatch.setattr("pb.api.create_app", lambda db: fake_app)
    monkeypatch.setattr(cli.uvicorn, "run", lambda app, **kwargs: None)

    input_dir = tmp_path / "src"
    input_dir.mkdir()

    cli.explore(**_explore_kwargs(tmp_path, input_dir, reset=False))

    assert constructed == []
    assert fake_app.state.index_job is None
    assert "up-to-date" in capsys.readouterr().out


def test_explore_already_running_server_returns_before_index_job(monkeypatch, tmp_path):
    _patch_common(monkeypatch, tmp_path, port_in_use=True)

    def fail_create_app(db):
        raise AssertionError("create_app should not be called when port already in use")

    monkeypatch.setattr("pb.api.create_app", fail_create_app)

    class _FailIndexJob:
        def __init__(self, *a, **k):
            raise AssertionError("IndexJob should not be constructed when port already in use")

    monkeypatch.setattr(cli, "IndexJob", _FailIndexJob, raising=False)

    input_dir = tmp_path / "src"
    input_dir.mkdir()

    cli.explore(**_explore_kwargs(tmp_path, input_dir))
