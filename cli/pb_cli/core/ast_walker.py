"""Pure recursive walkers over parsed AST JSON — no I/O dependencies.

JSON shape (verified against PB.Pipeline.Serialise — no constructorTagModifier
is set, so tags are literal Haskell constructor names):
  - Located BodyStmt -> {"line": Int, "node": {...}}
  - single positional-field constructors (e.g. BsRaw Text, ExRaw [Text]) ->
    {"tag": "...", "contents": <value>}
  - multi-field record constructors (e.g. ExCall, ExMethodCall) -> fields
    flattened alongside "tag", no "contents" wrapper

walk_tagged() does not special-case any of this: it recurses into every dict
value and list item unconditionally, so it can't miss a tag regardless of
which fields a future constructor nests its children under.
"""

from __future__ import annotations

from collections.abc import Iterator

BRANCH_TAGS = {"BsIf", "BsFor", "BsDo", "BsChoose"}


def walk_tagged(node, line: int | None = None) -> Iterator[tuple[str, dict, int | None]]:
    """Yield (tag, node, line) for every tagged node anywhere under `node`.

    `line` tracks the nearest enclosing Located.line (propagated downward
    whenever a dict carries an integer "line" field) so callers can report
    a real source location instead of a synthetic position.
    """
    if isinstance(node, dict):
        cur_line = node["line"] if isinstance(node.get("line"), int) else line
        tag = node.get("tag")
        if tag is not None:
            yield tag, node, cur_line
        for v in node.values():
            yield from walk_tagged(v, cur_line)
    elif isinstance(node, list):
        for item in node:
            yield from walk_tagged(item, line)


def walk_calls(node) -> list[tuple[str, str]]:
    results = []
    for tag, n, _line in walk_tagged(node):
        if tag == "ExCall":
            segs = n.get("callee", {}).get("segments", [])
            if segs:
                results.append((segs[-1].get("name", ""), "ExCall"))
        elif tag == "ExMethodCall":
            results.append((n.get("method", ""), "ExMethodCall"))
        elif tag == "ExDispatch":
            contents = n.get("contents", {})
            name = contents.get("name", "") or n.get("name", "")
            results.append((name, "ExDispatch"))
    return results


def count_branches(node) -> int:
    return sum(1 for tag, _n, _line in walk_tagged(node) if tag in BRANCH_TAGS)


def walk_bsraw(node) -> Iterator[str]:
    """Yield the raw text of every BsRaw statement anywhere under `node`."""
    for text, _line in walk_bsraw_located(node):
        yield text


def walk_bsraw_located(node) -> Iterator[tuple[str, int | None]]:
    """Yield (text, line) for every BsRaw statement anywhere under `node`."""
    for tag, n, line in walk_tagged(node):
        if tag == "BsRaw":
            text = n.get("contents", "")
            if isinstance(text, str) and text:
                yield text, line


def walk_exraw(node) -> Iterator[tuple[str, list[str]]]:
    """Yield (leading_token, tokens) for every ExRaw expression anywhere under `node`."""
    for tag, n, _line in walk_tagged(node):
        if tag == "ExRaw":
            toks = n.get("contents", [])
            if isinstance(toks, list) and toks:
                yield toks[0], toks
