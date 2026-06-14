"""AST body_json → readable PowerScript rendering.

All tag names match the genericToJSON constructor encoding from pb-runner
(e.g. "BsIf", "ExCall", "ExLvalue"). Fields follow the same encoding:
  - single-value constructors wrap their payload in "contents"
  - record constructors put fields at the same level as "tag"
  - Lvalue records are plain {"segments": [...]} with no "tag"
"""
from __future__ import annotations

import json
from typing import Any

_BINOP = {
    "BopAdd": "+", "BopSub": "-", "BopMul": "*", "BopDiv": "/", "BopPow": "^",
    "BopEq": "=", "BopNe": "<>", "BopLt": "<", "BopGt": ">", "BopLe": "<=", "BopGe": ">=",
    "BopAnd": "and", "BopOr": "or", "BopXor": "xor",
}
_AUGOP = {
    "AugAdd": "+=", "AugSub": "-=", "AugMul": "*=", "AugDiv": "/=",
}


def render_body(body_json: str | list) -> str:
    """Render a body_json value (JSON string or list) to PowerScript text."""
    if isinstance(body_json, str):
        body = json.loads(body_json)
    else:
        body = body_json
    lines: list[str] = []
    for stmt in body:
        rendered = _render_stmt(stmt, indent=0)
        if rendered is not None:
            lines.append(rendered)
    return "\n".join(lines)


def _render_stmt(stmt: dict[str, Any], indent: int) -> str | None:
    tag = stmt.get("tag", "")
    pad = "    " * indent
    c = stmt.get("contents")

    if tag == "BsCall":
        return pad + _render_expr(c)

    if tag == "BsReturn":
        if c is None:
            return pad + "return"
        return pad + "return " + _render_expr(c)

    if tag == "BsAssign":
        lhs, rhs = c[0], c[1]
        return pad + _render_lvalue(lhs) + " = " + _render_expr(rhs)

    if tag == "BsAugAssign":
        lhs_toks, op, rhs_toks = c[0], c[1], c[2]
        op_str = _AUGOP.get(op, op)
        return pad + " ".join(str(t) for t in lhs_toks) + " " + op_str + " " + " ".join(str(t) for t in rhs_toks)

    if tag == "BsInc":
        return pad + " ".join(str(t) for t in c) + "++"

    if tag == "BsDec":
        return pad + " ".join(str(t) for t in c) + "--"

    if tag == "BsLocalVar":
        return pad + " ".join(str(t) for t in c)

    if tag == "BsIf":
        return _render_if(c, indent)

    if tag == "BsFor":
        return _render_for(c, indent)

    if tag == "BsDo":
        return _render_do(c, indent)

    if tag == "BsChoose":
        return _render_choose(c, indent)

    if tag == "BsExit":
        return pad + "exit"

    if tag == "BsContinue":
        return pad + "continue"

    if tag == "BsDestroy":
        return pad + "destroy " + _render_lvalue(c)

    if tag == "BsRaw":
        text = c if isinstance(c, str) else ""
        stripped = text.strip()
        return (pad + stripped) if stripped else None

    if tag == "BsPbCall":
        if isinstance(c, dict):
            ancestor = c.get("ancestor", "")
            event = c.get("event", "")
            ctrl = c.get("ctrl")
            ctrl_part = f"`{ctrl}" if ctrl else ""
            return pad + f"call {ancestor}{ctrl_part} :: {event}"
        return pad + f"/* BsPbCall: {c} */"

    return pad + f"/* unknown: {tag} */"


def _render_if(c: dict[str, Any], indent: int) -> str:
    pad = "    " * indent
    cond = _render_expr(c.get("cond", {}))
    then_body = _render_body_list(c.get("then", []), indent + 1)
    parts = [f"{pad}if {cond} then"]
    parts.append(then_body)

    for elif_clause in c.get("elseIfs", []):
        # encoded as [Expr, [BodyStmt]] (2-tuple → array)
        if isinstance(elif_clause, (list, tuple)) and len(elif_clause) == 2:
            eif_cond, eif_body = elif_clause
        else:
            eif_cond = elif_clause.get("cond", {})
            eif_body = elif_clause.get("body", [])
        parts.append(f"{pad}elseif {_render_expr(eif_cond)} then")
        parts.append(_render_body_list(eif_body, indent + 1))

    else_body = c.get("else")
    if else_body:
        parts.append(f"{pad}else")
        parts.append(_render_body_list(else_body, indent + 1))

    parts.append(f"{pad}end if")
    return "\n".join(parts)


def _render_for(c: dict[str, Any], indent: int) -> str:
    pad = "    " * indent
    var = _render_lvalue(c.get("var", {}))
    from_e = _render_expr(c.get("from", {}))
    to_e = _render_expr(c.get("to", {}))
    step_e = c.get("step")
    step_part = f" step {_render_expr(step_e)}" if step_e else ""
    header = f"{pad}for {var} = {from_e} to {to_e}{step_part}"
    body = _render_body_list(c.get("body", []), indent + 1)
    return f"{header}\n{body}\n{pad}next"


def _render_do(c: dict[str, Any], indent: int) -> str:
    pad = "    " * indent
    cond_node = c.get("cond")
    loop_node = c.get("loop")
    body = _render_body_list(c.get("body", []), indent + 1)

    if cond_node:
        kind = "while" if cond_node.get("tag") == "DoWhile" else "until"
        expr = _render_expr(cond_node.get("contents", {}))
        return f"{pad}do {kind} {expr}\n{body}\n{pad}loop"

    if loop_node:
        kind = "while" if loop_node.get("tag") == "DoWhile" else "until"
        expr = _render_expr(loop_node.get("contents", {}))
        return f"{pad}do\n{body}\n{pad}loop {kind} {expr}"

    return f"{pad}do\n{body}\n{pad}loop"


def _render_choose(c: dict[str, Any], indent: int) -> str:
    pad = "    " * indent
    expr = _render_expr(c.get("expr", {}))
    parts = [f"{pad}choose case {expr}"]
    for clause in c.get("clauses", []):
        cc_expr = clause.get("expr")
        cc_body = _render_body_list(clause.get("body", []), indent + 1)
        if cc_expr is not None:
            case_text = " ".join(str(t) for t in cc_expr) if isinstance(cc_expr, list) else str(cc_expr)
            parts.append(f"{pad}case {case_text}")
        else:
            parts.append(f"{pad}case else")
        parts.append(cc_body)
    parts.append(f"{pad}end choose")
    return "\n".join(parts)


def _render_body_list(body: list, indent: int) -> str:
    lines = []
    for stmt in body:
        if isinstance(stmt, dict):
            rendered = _render_stmt(stmt, indent)
            if rendered is not None:
                lines.append(rendered)
    return "\n".join(lines)


def _render_expr(expr: Any) -> str:
    if expr is None:
        return ""
    if isinstance(expr, bool):
        return "true" if expr else "false"
    if isinstance(expr, (int, float)):
        return str(expr)
    if isinstance(expr, str):
        return expr
    if not isinstance(expr, dict):
        return str(expr)

    tag = expr.get("tag", "")
    c = expr.get("contents")

    if tag == "ExCall":
        # record constructor — fields at tag level
        callee = expr.get("callee", {})
        args = expr.get("args", [])
        name = _render_lvalue(callee)
        return _fmt_call(name, args)

    if tag == "ExMethodCall":
        # record constructor
        receiver = _render_expr(expr.get("receiver", {}))
        method = expr.get("method", "")
        args = expr.get("args", [])
        return _fmt_call(f"{receiver}.{method}", args)

    if tag == "ExDispatch":
        contents = c if isinstance(c, dict) else {}
        parts = []
        if contents.get("dynamic"):
            parts.append("DYNAMIC")
        mode = contents.get("mode", "")
        if mode == "DmPost":
            parts.append("POST")
        elif mode == "DmTrigger":
            parts.append("TRIGGER")
        if contents.get("event"):
            parts.append("EVENT")
        name = contents.get("name", "")
        obj = contents.get("object")
        qualifier = " ".join(parts)
        if obj:
            ref = _render_lvalue(obj) + "::" + name
        else:
            ref = name
        return (qualifier + " " + ref).strip()

    if tag == "ExLvalue":
        return _render_lvalue(c if isinstance(c, dict) else {})

    if tag in ("ExBool",):
        if c is True:
            return "true"
        if c is False:
            return "false"
        return str(c)

    if tag in ("ExInt", "ExReal", "ExStr", "ExDate", "ExTime"):
        return str(c) if c is not None else ""

    if tag == "ExNull":
        return "null"

    if tag == "ExEnum":
        return str(c) + "!" if c else ""

    if tag == "ExNot":
        return "not " + _render_expr(c)

    if tag == "ExBinOp":
        # record constructor
        lhs = _render_expr(expr.get("lhs", {}))
        op = _BINOP.get(expr.get("op", ""), expr.get("op", ""))
        rhs = _render_expr(expr.get("rhs", {}))
        return f"{lhs} {op} {rhs}"

    if tag == "ExNeg":
        return "-" + _render_expr(c)

    if tag == "ExHostVar":
        return ":" + _render_lvalue(c if isinstance(c, dict) else {})

    if tag == "ExCreate":
        return "create " + str(c) if c else "create"

    if tag == "ExArray":
        items = [_render_expr(e) for e in (c or [])]
        return "{" + ", ".join(items) + "}"

    if tag == "ExRaw":
        toks = c if isinstance(c, list) else []
        return " ".join(str(t) for t in toks)

    # Fallback: bare Lvalue or ExCall shape without the correct tag
    if expr.get("callee"):
        return _fmt_call(_render_lvalue(expr.get("callee", {})), expr.get("args", []))
    if expr.get("segments"):
        return _render_lvalue(expr)

    return json.dumps(expr)


def _fmt_call(name: str, args: list) -> str:
    if not args:
        return f"{name}()"
    arg_strs = [
        " ".join(str(t) for t in a) if isinstance(a, list) else _render_expr(a)
        for a in args
    ]
    return f"{name}({', '.join(arg_strs)})"


def _render_lvalue(lval: dict[str, Any]) -> str:
    if not isinstance(lval, dict):
        return str(lval)
    segments = lval.get("segments", [])
    if not segments:
        return lval.get("name", str(lval))
    parts = []
    for seg in segments:
        name = seg.get("name", "")
        sub = seg.get("subscript")
        if sub:
            sub_text = ", ".join(str(s) for s in sub)
            parts.append(f"{name}[{sub_text}]")
        else:
            parts.append(name)
    return ".".join(parts)
