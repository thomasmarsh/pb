"""Pure recursive walkers over parsed AST JSON — no I/O dependencies."""
from __future__ import annotations

BRANCH_TAGS = {'BsIf', 'BsFor', 'BsDo', 'BsChoose'}


def walk_calls(node) -> list[tuple[str, str]]:
    results = []
    if isinstance(node, dict):
        tag = node.get('tag')
        if tag == 'ExCall':
            segs = node.get('callee', {}).get('segments', [])
            if segs:
                results.append((segs[-1].get('name', ''), 'ExCall'))
        elif tag == 'ExMethodCall':
            results.append((node.get('method', ''), 'ExMethodCall'))
        elif tag == 'ExDispatch':
            name = node.get('contents', {}).get('name', '') or node.get('name', '')
            results.append((name, 'ExDispatch'))
        for v in node.values():
            results.extend(walk_calls(v))
    elif isinstance(node, list):
        for item in node:
            results.extend(walk_calls(item))
    return results


def count_branches(node) -> int:
    count = 0
    if isinstance(node, dict):
        if node.get('tag') in BRANCH_TAGS:
            count += 1
        for v in node.values():
            count += count_branches(v)
    elif isinstance(node, list):
        for item in node:
            count += count_branches(item)
    return count


def walk_bsraw(node):
    if isinstance(node, list):
        for x in node:
            yield from walk_bsraw(x)
    elif isinstance(node, dict):
        if node.get("tag") == "BsRaw":
            text = node.get("contents", "")
            if isinstance(text, str):
                yield text
        for v in node.values():
            if isinstance(v, (dict, list)):
                yield from walk_bsraw(v)


def walk_exraw(node):
    if isinstance(node, list):
        for x in node:
            yield from walk_exraw(x)
    elif isinstance(node, dict):
        if node.get("tag") == "ExRaw":
            toks = node.get("contents", [])
            if toks:
                yield toks[0], toks
        for v in node.values():
            if isinstance(v, (dict, list)):
                yield from walk_exraw(v)
