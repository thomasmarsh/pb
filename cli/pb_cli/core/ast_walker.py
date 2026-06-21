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
from typing import Any, cast

from pb_cli.core.ast_generated import (
    BodyStmt,
    DoCondition,
    DwBandKind,
    DwRetrieveOrRaw,
    Expr,
    PbType,
    ProtoDecl,
)

TaggedNode = Expr | PbType | DoCondition | BodyStmt | ProtoDecl | DwBandKind | DwRetrieveOrRaw


def _walk_tagged_raw(node: Any, line: int | None = None) -> Iterator[tuple[str, dict[str, Any], int | None]]:
    """Internal walker yielding raw dicts. Callers narrow via tag string."""
    if isinstance(node, dict):
        cur_line = node["line"] if isinstance(node.get("line"), int) else line
        tag = node.get("tag")
        if tag is not None:
            yield tag, node, cur_line
        for v in node.values():
            yield from _walk_tagged_raw(v, cur_line)
    elif isinstance(node, list):
        for item in node:
            yield from _walk_tagged_raw(item, line)


def walk_tagged(node: Any, line: int | None = None) -> Iterator[tuple[str, TaggedNode, int | None]]:
    """Yield (tag, node, line) for every tagged node anywhere under `node`.

    `line` tracks the nearest enclosing Located.line (propagated downward
    whenever a dict carries an integer "line" field) so callers can report
    a real source location instead of a synthetic position.

    Callers narrow on the tag string to access typed fields:
        for tag, n, line in walk_tagged(node):
            if tag == "ExCall":
                callee = n.get("callee", {})
    """
    for tag, raw, line_ in _walk_tagged_raw(node, line):
        yield tag, cast(TaggedNode, raw), line_


def walk_calls(node: Any) -> list[tuple[str, str]]:
    """Extract call names from AST nodes. Used by streaming import path (no JSON files)."""
    results = []
    for tag, n, _line in _walk_tagged_raw(node):
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


def walk_bsraw(node: Any) -> Iterator[str]:
    """Yield the raw text of every BsRaw statement anywhere under `node`."""
    for text, _line in walk_bsraw_located(node):
        yield text


def walk_bsraw_located(node: Any) -> Iterator[tuple[str, int | None]]:
    """Yield (text, line) for every BsRaw statement anywhere under `node`."""
    for tag, n, line in _walk_tagged_raw(node):
        if tag == "BsRaw":
            text = n.get("contents", "")
            if isinstance(text, str) and text:
                yield text, line


def walk_excall_arg_calls(node: Any) -> Iterator[str]:
    """Yield bare function names that appear as nested calls in ExCall arg token arrays.

    ExCall args are serialised as [[String]] — lists of raw token strings.
    Pattern: an identifier immediately followed by "(" that is NOT preceded
    by "." (to skip method-chain segments like obj.method()).
    Only bare names (no dot in the name itself) are yielded.
    """
    for tag, n, _line in _walk_tagged_raw(node):
        if tag == "ExCall":
            for arg_toks in (n.get("args") or []):
                if not isinstance(arg_toks, list):
                    continue
                for i, tok in enumerate(arg_toks):
                    if (
                        isinstance(tok, str)
                        and tok not in (".", "(", ")")
                        and i + 1 < len(arg_toks)
                        and arg_toks[i + 1] == "("
                        and (i == 0 or arg_toks[i - 1] != ".")
                    ):
                        yield tok.lower()


def walk_exraw(node: Any) -> Iterator[tuple[str, list[str]]]:
    """Yield (leading_token, tokens) for every ExRaw expression anywhere under `node`."""
    for tag, n, _line in _walk_tagged_raw(node):
        if tag == "ExRaw":
            toks = n.get("contents", [])
            if isinstance(toks, list) and toks:
                yield toks[0], toks
