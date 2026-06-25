"""Unit tests for pb.pipeline.commands.clean."""

from __future__ import annotations

import pytest
from pb.pipeline.commands import clean


def test_clean_ui_removes_known_dirs(tmp_path):
    (tmp_path / "ui" / "node_modules" / "x").mkdir(parents=True)
    (tmp_path / "cli" / "pb_cli" / "explorer" / "static" / "dist").mkdir(parents=True)

    removed = clean._clean_ui(tmp_path)

    assert not (tmp_path / "ui" / "node_modules").exists()
    assert not (tmp_path / "cli" / "pb_cli" / "explorer" / "static" / "dist").exists()
    assert len(removed) == 2


def test_clean_ui_noop_when_absent(tmp_path):
    assert clean._clean_ui(tmp_path) == []


def test_clean_python_caches_removes_known_dirs(tmp_path):
    (tmp_path / ".pytest_cache").mkdir()
    (tmp_path / "cli" / ".ruff_cache").mkdir(parents=True)
    pycache = tmp_path / "pb_cli" / "core" / "__pycache__"
    pycache.mkdir(parents=True)

    removed = clean._clean_python_caches(tmp_path)

    assert not (tmp_path / ".pytest_cache").exists()
    assert not (tmp_path / "cli" / ".ruff_cache").exists()
    assert not pycache.exists()
    assert len(removed) == 3


def test_clean_python_caches_skips_dunder_pycache_inside_venv(tmp_path):
    """__pycache__ dirs inside .venv belong to installed packages, not this repo's
    own build output — removing them would just make uv re-extract them next run."""
    pycache = tmp_path / ".venv" / "lib" / "site-packages" / "foo" / "__pycache__"
    pycache.mkdir(parents=True)

    clean._clean_python_caches(tmp_path)

    assert pycache.exists()


def test_clean_venv_removes_both_venvs(tmp_path):
    (tmp_path / ".venv" / "bin").mkdir(parents=True)
    (tmp_path / "cli" / ".venv" / "bin").mkdir(parents=True)

    removed = clean._clean_venv(tmp_path)

    assert not (tmp_path / ".venv").exists()
    assert not (tmp_path / "cli" / ".venv").exists()
    assert len(removed) == 2


def test_run_rejects_unknown_target(tmp_path, monkeypatch):
    monkeypatch.setattr("pb.pipeline.commands.clean.env.build.find_repo", lambda repo: tmp_path)
    with pytest.raises(SystemExit):
        clean.run(repo=tmp_path, targets=["bogus"])


def test_run_only_invokes_requested_targets(tmp_path, monkeypatch):
    monkeypatch.setattr("pb.pipeline.commands.clean.env.build.find_repo", lambda repo: tmp_path)
    calls: list[str] = []
    monkeypatch.setattr(clean, "_clean_cabal", lambda repo: calls.append("cabal") or [])
    monkeypatch.setattr(clean, "_clean_ui", lambda repo: calls.append("ui") or [])
    monkeypatch.setattr(clean, "_clean_python_caches", lambda repo: calls.append("python") or [])
    monkeypatch.setattr(clean, "_clean_venv", lambda repo: calls.append("venv") or [])

    clean.run(repo=tmp_path, targets=["ui", "venv"])

    assert calls == ["ui", "venv"]


def test_run_defaults_to_all_targets(tmp_path, monkeypatch):
    monkeypatch.setattr("pb.pipeline.commands.clean.env.build.find_repo", lambda repo: tmp_path)
    calls: list[str] = []
    monkeypatch.setattr(clean, "_clean_cabal", lambda repo: calls.append("cabal") or [])
    monkeypatch.setattr(clean, "_clean_ui", lambda repo: calls.append("ui") or [])
    monkeypatch.setattr(clean, "_clean_python_caches", lambda repo: calls.append("python") or [])
    monkeypatch.setattr(clean, "_clean_venv", lambda repo: calls.append("venv") or [])

    clean.run(repo=tmp_path)

    assert calls == ["cabal", "ui", "python", "venv"]
