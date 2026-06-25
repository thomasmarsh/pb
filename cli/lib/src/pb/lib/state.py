"""Pure file-state diffing — no I/O dependencies."""

from __future__ import annotations

from typing import NamedTuple


class FileDiff(NamedTuple):
    new: list[str]
    changed: list[str]
    deleted: list[str]
    unchanged: list[str]


def diff_state(current: dict[str, str], stored: dict[str, str]) -> FileDiff:
    new = [f for f in current if f not in stored]
    changed = [f for f in current if f in stored and current[f] != stored[f]]
    deleted = [f for f in stored if f not in current]
    unchanged = [f for f in current if f in stored and current[f] == stored[f]]
    return FileDiff(new=new, changed=changed, deleted=deleted, unchanged=unchanged)
