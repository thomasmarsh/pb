"""Unit tests for pb_cli.shell.env.ShellEnv — field wiring and substitution."""

from pathlib import Path

from pb_cli.shell.build import find_repo
from pb_cli.shell.env import BuildEnv, RunnerEnv, ShellEnv, StorageEnv
from pb_cli.shell.reporter import LiveReporter, RecordingReporter


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
    assert callable(b.generate_ast_python)


def test_runner_env_defaults_are_real_functions():
    r = RunnerEnv()
    assert callable(r.parse_stream)
    assert callable(r.render_error)


def test_storage_env_defaults_are_real_functions():
    s = StorageEnv()
    assert callable(s.db_connection)
    assert callable(s.create_schema)
    assert callable(s.drop_tables)
    assert callable(s.load_file_state)
    assert callable(s.delete_file_rows)
    assert callable(s.save_file_state)
    assert callable(s.build_subset_tmpdir)
    assert callable(s.import_batch)
    assert callable(s.run_from_jsonl_lines)
    assert callable(s.compute_dit)
    assert callable(s.compute_metrics)
    assert callable(s.connect)


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


def test_runner_field_substitution():
    def fake_parse_stream(src_dir, binary, *, remap_from=None, remap_to=None):
        return iter([(False, {"file": "test.srw"})])

    e = ShellEnv()
    e.runner.parse_stream = fake_parse_stream
    results = list(e.runner.parse_stream(Path("/fake"), Path("/fake/bin")))
    assert len(results) == 1
    assert results[0] == (False, {"file": "test.srw"})


def test_storage_field_substitution():
    sentinel = {"a.srw": "hash1"}

    def fake_load_file_state(conn):
        return sentinel

    e = ShellEnv()
    e.storage.load_file_state = fake_load_file_state
    assert e.storage.load_file_state(None) is sentinel


def test_field_swap_does_not_affect_global_env():
    original = env_global_find_repo()

    e = ShellEnv()
    e.build.find_repo = lambda repo=None: Path("/swapped")
    # global env unchanged
    assert env_global_find_repo() is original


def env_global_find_repo():
    from pb_cli.shell.env import env

    return env.build.find_repo
