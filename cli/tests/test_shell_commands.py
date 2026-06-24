"""Unit tests for pb_cli.shell.commands — corpus."""

from __future__ import annotations

from unittest.mock import patch

import pytest

# ── corpus.run build routing ──────────────────────────────────────────────────


def test_corpus_routes_to_build_runner(monkeypatch, tmp_path):
    """corpus.run(no_build=False) calls build_runner, not find_binary."""
    from pb_cli.shell.commands import corpus

    built = []

    def fake_find_repo(repo=None):
        return tmp_path

    def fake_build_runner(repo, verbose=False):
        built.append(repo)
        return tmp_path / "pb-runner"

    monkeypatch.setattr("pb_cli.shell.commands.corpus.env.build.find_repo", fake_find_repo)
    monkeypatch.setattr("pb_cli.shell.commands.corpus.env.build.build_runner", fake_build_runner)

    # Create corpus source dirs so run() doesn't skip
    (tmp_path / "example" / "PowerBuilder-Example-extract").mkdir(parents=True)
    (tmp_path / "example" / "openpay-0.1.1b-extract").mkdir(parents=True)

    with patch("pb_cli.shell.commands.corpus.subprocess.run") as mock_run:
        mock_run.return_value.returncode = 1
        mock_run.return_value.stderr = "fail"
        with pytest.raises(SystemExit):
            corpus.run(no_build=False)

    assert len(built) == 1


def test_corpus_routes_to_find_binary(monkeypatch, tmp_path):
    """corpus.run(no_build=True) calls find_binary, not build_runner."""
    from pb_cli.shell.commands import corpus

    found = []

    def fake_find_repo(repo=None):
        return tmp_path

    def fake_find_binary(repo):
        found.append(repo)
        return tmp_path / "pb-runner"

    monkeypatch.setattr("pb_cli.shell.commands.corpus.env.build.find_repo", fake_find_repo)
    monkeypatch.setattr("pb_cli.shell.commands.corpus.env.build.find_binary", fake_find_binary)

    (tmp_path / "example" / "PowerBuilder-Example-extract").mkdir(parents=True)
    (tmp_path / "example" / "openpay-0.1.1b-extract").mkdir(parents=True)

    with patch("pb_cli.shell.commands.corpus.subprocess.run") as mock_run:
        mock_run.return_value.returncode = 1
        mock_run.return_value.stderr = "fail"
        with pytest.raises(SystemExit):
            corpus.run(no_build=True)

    assert len(found) == 1
