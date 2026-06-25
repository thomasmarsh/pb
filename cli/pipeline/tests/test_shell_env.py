"""Unit tests for pb.pipeline.env.ShellEnv — field wiring and substitution."""

from pathlib import Path

from pb.pipeline.build import find_repo
from pb.pipeline.env import BuildEnv, RunnerEnv, ShellEnv, StorageEnv
from pb.pipeline.reporter import LiveReporter, RecordingReporter


def test_default_reporter_is_live():
    assert isinstance(ShellEnv().reporter, LiveReporter)


def test_reporter_is_swappable():
    e = ShellEnv()
    e.reporter = RecordingReporter()
    assert isinstance(e.reporter, RecordingReporter)


# ── sub-env defaults ──────────────────────────────────────────────────────────


def test_build_env_defaults_are_real_functions():
    b = BuildEnv()
    assert b.find_repo is find_repo
    assert callable(b.get_queries_dir)
    assert callable(b.find_binary)
    assert callable(b.build_runner)
    assert callable(b.walk_sr_files)
    assert callable(b.count_sr_files)
    assert callable(b.hash_source_dir)
    assert callable(b.ensure_explorer_built)


def test_runner_env_defaults_are_real_functions():
    r = RunnerEnv()
    assert callable(r.render_error)


def test_storage_env_defaults_are_real_functions():
    s = StorageEnv()
    assert callable(s.db_connection)
    assert callable(s.count_sql_parse_failures)


def test_shell_env_has_all_sub_envs():
    e = ShellEnv()
    assert isinstance(e.build, BuildEnv)
    assert isinstance(e.runner, RunnerEnv)
    assert isinstance(e.storage, StorageEnv)


# ── field substitution ────────────────────────────────────────────────────────


def test_build_field_substitution():
    sentinel = Path("/fake/repo")

    def fake_find_repo(repo=None):
        return sentinel

    e = ShellEnv()
    e.build.find_repo = fake_find_repo
    assert e.build.find_repo() is sentinel


def test_field_swap_does_not_affect_global_env():
    original = env_global_find_repo()

    e = ShellEnv()
    e.build.find_repo = lambda repo=None: Path("/swapped")
    # global env unchanged
    assert env_global_find_repo() is original


def env_global_find_repo():
    from pb.pipeline.env import env

    return env.build.find_repo
