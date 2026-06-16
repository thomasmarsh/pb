"""Unit tests for pb_cli.shell.env.ShellEnv — field wiring, not behavior."""

from pb_cli.reporter import LiveReporter, RecordingReporter
from pb_cli.shell.env import ShellEnv


def test_default_reporter_is_live():
    assert isinstance(ShellEnv().reporter, LiveReporter)


def test_reporter_is_swappable():
    e = ShellEnv()
    e.reporter = RecordingReporter()
    assert isinstance(e.reporter, RecordingReporter)
