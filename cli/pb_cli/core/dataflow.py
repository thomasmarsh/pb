"""Intra-procedural data flow analysis — def-use chains and reaching definitions.

Pure module — no I/O, no DuckDB.  Uses the CFG from cfg_builder.py.

Public API:
    extract_defs_uses(block, ...) -> BlockDataFlow
    build_gen_kill(cfg, ...) -> dict[str, BlockDataFlow]
    reaching_definitions(cfg, block_df) -> (reaching_in, reaching_out)
    analyze_procedure(body_json, ...) -> ProcDataFlow
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field

from pb_cli.core.cfg_builder import CFG, BasicBlock


@dataclass
class DefSite:
    var_name: str
    block_id: str
    stmt_index: int
    line: int | None
    kind: str  # 'assign' | 'local_var' | 'param' | 'augassign' | 'inc' | 'dec'


@dataclass
class UseSite:
    var_name: str
    block_id: str
    stmt_index: int
    line: int | None
    kind: str  # 'rhs' | 'condition' | 'call_arg' | 'return' | 'loop_var' | 'loop_range'


@dataclass
class BlockDataFlow:
    block_id: str
    gen: set[str] = field(default_factory=set)
    kill: set[str] = field(default_factory=set)
    defs: list[DefSite] = field(default_factory=list)
    uses: list[UseSite] = field(default_factory=list)


@dataclass
class ProcDataFlow:
    proc_key: tuple[str, str]
    blocks: dict[str, BlockDataFlow]
    reaching_in: dict[str, set[str]]
    reaching_out: dict[str, set[str]]
    all_defs: dict[str, list[DefSite]]
    all_uses: dict[str, list[UseSite]]


def _lvar_root(node: dict) -> str | None:
    """Extract root variable name from an lvalue/Lvalue node."""
    if isinstance(node, dict):
        segs = node.get("segments") or node.get("lvSegments") or []
        if segs and isinstance(segs, list) and len(segs) > 0:
            first = segs[0]
            if isinstance(first, dict):
                return first.get("name") or first.get("lvsName")
    return None


import re as _re

_IDENT_RE = _re.compile(r'^[a-zA-Z_][a-zA-Z0-9_]*$')


def _extract_idents_from_tokens(tokens: list) -> set[str]:
    """Extract identifier names from a raw token list.

    Handles both token-dict form {tag: TkIdent, contents: str} and the plain
    string form used in ExCall/ExMethodCall/ExDispatch args (list[str]).
    """
    result: set[str] = set()
    if not isinstance(tokens, list):
        return result
    for t in tokens:
        if isinstance(t, dict) and t.get("tag") == "TkIdent":
            result.add(t.get("contents", ""))
        elif isinstance(t, str) and _IDENT_RE.match(t):
            result.add(t)
    return result


def _walk_expr_idents(expr: dict) -> set[str]:
    """Recursively extract all identifier names from an expression tree."""
    result: set[str] = set()
    if not isinstance(expr, dict):
        return result
    tag = expr.get("tag", "")
    if tag == "ExLvalue":
        lv = expr.get("contents", {})
        root = _lvar_root(lv)
        if root:
            result.add(root)
        # Also extract subscript idents
        segs = lv.get("segments") or lv.get("lvSegments") or []
        for seg in segs:
            if isinstance(seg, dict):
                sub = seg.get("subscript") or seg.get("lvsSubscript")
                if isinstance(sub, list):
                    for t in sub:
                        if isinstance(t, dict) and t.get("tag") == "TkIdent":
                            result.add(t.get("contents", ""))
    elif tag == "ExCall":
        callee = expr.get("callee", {})
        root = _lvar_root(callee)
        if root:
            result.add(root)
        for arg in expr.get("args", []):
            if isinstance(arg, list):
                result |= _extract_idents_from_tokens(arg)
    elif tag == "ExMethodCall":
        receiver = expr.get("receiver", {})
        result |= _walk_expr_idents(receiver)
        for arg in expr.get("args", []):
            if isinstance(arg, list):
                result |= _extract_idents_from_tokens(arg)
    elif tag == "ExBinOp":
        result |= _walk_expr_idents(expr.get("lhs", {}))
        result |= _walk_expr_idents(expr.get("rhs", {}))
    elif tag == "ExNot":
        result |= _walk_expr_idents(expr.get("contents", {}))
    elif tag == "ExNeg":
        result |= _walk_expr_idents(expr.get("contents", {}))
    elif tag == "ExArray":
        for item in expr.get("contents", []):
            result |= _walk_expr_idents(item)
    elif tag == "ExHostVar":
        result |= _walk_expr_idents(expr.get("contents", {}))
    elif tag == "ExDispatch":
        contents = expr.get("contents", {})
        obj = contents.get("object")
        if obj:
            result |= _walk_expr_idents(obj)
        for arg in contents.get("args", []):
            if isinstance(arg, list):
                result |= _extract_idents_from_tokens(arg)
    elif tag == "ExCreateUsing":
        result |= _walk_expr_idents(expr.get("contents", {}))
    elif tag == "ExRaw":
        toks = expr.get("contents", [])
        if isinstance(toks, list):
            result |= _extract_idents_from_tokens(toks)
    # Literals, enums, booleans: no identifiers
    return result


def _walk_expr_tokens(expr: dict) -> set[str]:
    """Walk expression and extract idents from both structured and raw parts."""
    return _walk_expr_idents(expr)


def _extract_def_var_from_stmt(node: dict) -> str | None:
    """Extract the defined variable name from a definition statement."""
    tag = node.get("tag", "")
    if tag == "BsAssign":
        contents = node.get("contents", [])
        if isinstance(contents, (list, tuple)) and len(contents) >= 2:
            lhs = contents[0]
            return _lvar_root(lhs)
    elif tag == "BsLocalVar":
        return node.get("name")
    elif tag == "BsFor":
        contents = node.get("contents", {})
        return _lvar_root(contents.get("var", {}))
    elif tag in ("BsAugAssign", "BsInc", "BsDec"):
        contents = node.get("contents", [])
        if isinstance(contents, (list, tuple)) and len(contents) >= 1:
            tokens = contents[0]
            if isinstance(tokens, list):
                for t in tokens:
                    if isinstance(t, dict) and t.get("tag") == "TkIdent":
                        return t.get("contents")
                if tokens and isinstance(tokens[0], str):
                    return tokens[0]
    return None


def _extract_use_vars_from_stmt(node: dict) -> set[str]:
    """Extract used variable names from a statement (rhs, conditions, args)."""
    tag = node.get("tag", "")
    result: set[str] = set()

    if tag == "BsAssign":
        contents = node.get("contents", [])
        if isinstance(contents, (list, tuple)) and len(contents) >= 2:
            result |= _walk_expr_idents(contents[1])
    elif tag == "BsFor":
        contents = node.get("contents", {})
        # Loop var is a def, but from/to/step are uses
        result |= _walk_expr_idents(contents.get("from", {}))
        result |= _walk_expr_idents(contents.get("to", {}))
        step = contents.get("step")
        if step is not None:
            result |= _walk_expr_idents(step)
    elif tag == "BsIf":
        contents = node.get("contents", {})
        result |= _walk_expr_idents(contents.get("cond", {}))
    elif tag == "BsChoose":
        contents = node.get("contents", {})
        result |= _walk_expr_idents(contents.get("expr", {}))
    elif tag == "BsReturn":
        expr = node.get("contents")
        if expr is not None:
            result |= _walk_expr_idents(expr)
    elif tag == "BsCall":
        expr = node.get("contents", {})
        result |= _walk_expr_idents(expr)
    elif tag == "BsPbCall":
        # PbCall: ancestor[`ctrl] :: event — no var uses extractable
        pass
    elif tag == "BsLocalVar":
        init = node.get("init")
        if init is not None:
            result |= _walk_expr_idents(init)
    elif tag == "BsDestroy":
        contents = node.get("contents", {})
        root = _lvar_root(contents)
        if root:
            result.add(root)
    elif tag == "BsAugAssign":
        contents = node.get("contents", [])
        if isinstance(contents, (list, tuple)) and len(contents) >= 3:
            result |= _extract_idents_from_tokens(contents[2])  # rhs tokens
    elif tag == "BsInc":
        contents = node.get("contents", [])
        if isinstance(contents, list):
            # BsInc is just lhs tokens — the variable itself is both def and use
            pass
    elif tag == "BsDec":
        contents = node.get("contents", [])
        if isinstance(contents, list):
            pass
    elif tag == "BsRaw":
        pass
    elif tag == "BsAssignExpr":
        contents = node.get("contents", [])
        if isinstance(contents, (list, tuple)) and len(contents) >= 2:
            result |= _walk_expr_idents(contents[1])

    # Also walk sub-blocks for conditions inside BsDo
    if tag == "BsDo":
        contents = node.get("contents", {})
        cond = contents.get("cond")
        if cond is not None:
            result |= _walk_expr_idents(cond.get("contents", {}))
        loop = contents.get("loop")
        if loop is not None:
            result |= _walk_expr_idents(loop.get("contents", {}))

    return result


def extract_defs_uses(
    block: BasicBlock,
    proc_object: str,
    proc_name: str,
    file_path: str,
) -> BlockDataFlow:
    """Walk block.stmts to extract definition and use sites."""
    df = BlockDataFlow(block_id=block.id)
    local_defs: dict[str, int] = {}  # var_name → stmt_index (latest def)

    for idx, stmt in enumerate(block.stmts):
        node = stmt.get("node", {})
        tag = node.get("tag", "")
        line = stmt.get("line")

        # Extract definitions
        def_var = _extract_def_var_from_stmt(node)
        if def_var:
            kind_map = {
                "BsAssign": "assign",
                "BsLocalVar": "local_var",
                "BsFor": "for_var",
                "BsAugAssign": "augassign",
                "BsInc": "inc",
                "BsDec": "dec",
            }
            ds = DefSite(
                var_name=def_var,
                block_id=block.id,
                stmt_index=idx,
                line=line,
                kind=kind_map.get(tag, "assign"),
            )
            df.defs.append(ds)
            df.gen.add(def_var)
            local_defs[def_var] = idx

        # Extract uses
        use_vars = _extract_use_vars_from_stmt(node)
        for uv in use_vars:
            if uv:
                kind = "rhs"
                if tag == "BsIf":
                    kind = "condition"
                elif tag == "BsChoose":
                    kind = "condition"
                elif tag == "BsReturn":
                    kind = "return"
                elif tag == "BsCall":
                    kind = "call_arg"
                elif tag == "BsFor":
                    kind = "loop_range"
                df.uses.append(UseSite(
                    var_name=uv,
                    block_id=block.id,
                    stmt_index=idx,
                    line=line,
                    kind=kind,
                ))

    # Build kill set: all variables defined in this block have prior defs killed
    df.kill = set(local_defs.keys())
    return df


def build_gen_kill(
    cfg: CFG,
    proc_object: str,
    proc_name: str,
    file_path: str,
) -> dict[str, BlockDataFlow]:
    """Compute gen/kill sets for every block in the CFG."""
    result: dict[str, BlockDataFlow] = {}
    for bid, block in cfg.blocks.items():
        result[bid] = extract_defs_uses(block, proc_object, proc_name, file_path)
    return result


def _predecessors(cfg: CFG, block_id: str) -> list[str]:
    """Return list of predecessor block ids."""
    return [e.src for e in cfg.edges if e.dst == block_id]


def reaching_definitions(
    cfg: CFG,
    block_df: dict[str, BlockDataFlow],
) -> tuple[dict[str, set[str]], dict[str, set[str]]]:
    """Iterative forward data flow for reaching definitions.

    Returns (reaching_in, reaching_out) mapping block_id → set of variable names.
    """
    # Initialize
    reaching_in: dict[str, set[str]] = {bid: set() for bid in cfg.blocks}
    reaching_out: dict[str, set[str]] = {bid: set() for bid in cfg.blocks}

    # Seed entry block: empty in, gen out
    entry_df = block_df.get(cfg.entry)
    if entry_df:
        reaching_out[cfg.entry] = set(entry_df.gen)

    # Iterate until fixed point
    changed = True
    while changed:
        changed = False
        for bid in cfg.blocks:
            if bid == cfg.entry:
                continue
            preds = _predecessors(cfg, bid)
            new_in: set[str] = set()
            for p in preds:
                new_in |= reaching_out.get(p, set())
            if new_in != reaching_in[bid]:
                reaching_in[bid] = new_in
                changed = True

            bd = block_df.get(bid)
            if bd:
                new_out = bd.gen | (new_in - bd.kill)
            else:
                new_out = new_in
            if new_out != reaching_out[bid]:
                reaching_out[bid] = new_out
                changed = True

    return reaching_in, reaching_out


def analyze_procedure(
    body_json: list,
    proc_object: str,
    proc_name: str,
    file_path: str,
) -> ProcDataFlow:
    """Full intra-procedural analysis for one procedure."""
    from pb_cli.core.cfg_builder import build_cfg

    if not body_json:
        return ProcDataFlow(
            proc_key=(proc_object, proc_name),
            blocks={},
            reaching_in={},
            reaching_out={},
            all_defs={},
            all_uses={},
        )

    cfg = build_cfg(body_json)
    block_df = build_gen_kill(cfg, proc_object, proc_name, file_path)
    reaching_in, reaching_out = reaching_definitions(cfg, block_df)

    all_defs: dict[str, list[DefSite]] = {}
    all_uses: dict[str, list[UseSite]] = {}

    for bd in block_df.values():
        for d in bd.defs:
            all_defs.setdefault(d.var_name, []).append(d)
        for u in bd.uses:
            all_uses.setdefault(u.var_name, []).append(u)

    return ProcDataFlow(
        proc_key=(proc_object, proc_name),
        blocks=block_df,
        reaching_in=reaching_in,
        reaching_out=reaching_out,
        all_defs=all_defs,
        all_uses=all_uses,
    )
