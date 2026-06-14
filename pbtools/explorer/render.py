"""AST body_json → readable PowerScript rendering."""
from __future__ import annotations

import json
from typing import Any


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

    if tag == "call":
        inner = stmt.get("expr", {})
        return pad + _render_expr(inner)

    if tag == "call_expr":
        return pad + _render_call_expr(stmt)

    if tag == "method_call":
        return pad + _render_method_call(stmt)

    if tag == "dispatch":
        return pad + _render_dispatch(stmt)

    if tag == "return":
        expr = stmt.get("value") or stmt.get("expr")
        if expr:
            return pad + "return " + _render_expr(expr)
        return pad + "return"

    if tag == "assign":
        lhs = _render_lvalue(stmt.get("lhs", {}))
        rhs = _render_expr(stmt.get("rhs", {}))
        return pad + f"{lhs} = {rhs}"

    if tag == "aug_assign":
        lhs = " ".join(str(t) for t in stmt.get("lhs", []))
        op = stmt.get("op", "+=")
        rhs = " ".join(str(t) for t in stmt.get("rhs", []))
        return pad + f"{lhs} {op} {rhs}"

    if tag == "inc":
        lhs = " ".join(str(t) for t in stmt.get("lhs", []))
        return pad + f"{lhs}++"

    if tag == "dec":
        lhs = " ".join(str(t) for t in stmt.get("lhs", []))
        return pad + f"{lhs}--"

    if tag == "local_var":
        tokens = stmt.get("tokens", [])
        return pad + " ".join(str(t) for t in tokens)

    if tag == "if":
        return pad + _render_if(stmt, indent)

    if tag == "for":
        return pad + _render_for(stmt, indent)

    if tag == "do":
        return pad + _render_do(stmt, indent)

    if tag == "choose":
        return pad + _render_choose(stmt, indent)

    if tag == "exit":
        return pad + "exit"

    if tag == "continue":
        return pad + "continue"

    if tag == "destroy":
        lval = stmt.get("lvalue", {})
        name = _render_lvalue(lval) if lval else _tokens_to_text(stmt.get("tokens", []))
        return pad + f"destroy {name}"

    if tag == "raw":
        text = stmt.get("text", "")
        if text:
            return pad + text.strip()
        tokens = stmt.get("tokens", [])
        if tokens:
            return pad + _tokens_to_text(tokens)
        return None

    return pad + f"/* unknown: {tag} */"


def _render_if(stmt: dict[str, Any], indent: int) -> str:
    pad = "    " * indent
    cond = _render_expr(stmt.get("cond", {}))
    then_body = _render_body_list(stmt.get("then", []), indent + 1)
    parts = [f"{pad}if {cond} then"]
    parts.append(then_body)

    for elif_clause in stmt.get("elseIfs", []):
        if isinstance(elif_clause, (list, tuple)) and len(elif_clause) == 2:
            eif_cond, eif_body = elif_clause
        else:
            eif_cond = elif_clause.get("cond", "")
            eif_body = elif_clause.get("body", [])
        eif_cond_text = _render_expr(eif_cond) if isinstance(eif_cond, dict) else str(eif_cond)
        eif_body_text = _render_body_list(eif_body, indent + 1)
        parts.append(f"{pad}elseif {eif_cond_text} then")
        parts.append(eif_body_text)

    else_body = stmt.get("else")
    if else_body:
        parts.append(f"{pad}else")
        parts.append(_render_body_list(else_body, indent + 1))

    parts.append(f"{pad}end if")
    return "\n".join(parts)


def _render_for(stmt: dict[str, Any], indent: int) -> str:
    pad = "    " * indent
    var = _render_lvalue(stmt.get("var", {}))
    from_e = _render_expr(stmt.get("from", {}))
    to_e = _render_expr(stmt.get("to", {}))
    step_e = stmt.get("step")
    step_part = f" step {_render_expr(step_e)}" if step_e else ""
    header = f"{pad}for {var} = {from_e} to {to_e}{step_part}"
    body = _render_body_list(stmt.get("body", []), indent + 1)
    return f"{header}\n{body}\n{pad}next"


def _render_do(stmt: dict[str, Any], indent: int) -> str:
    pad = "    " * indent
    cond = stmt.get("cond")
    loop = stmt.get("loop")
    body = _render_body_list(stmt.get("body", []), indent + 1)

    if cond:
        kind = cond.get("tag", "while")
        expr = _render_expr(cond.get("expr", {}))
        header = f"{pad}do {kind} {expr}"
    elif loop:
        kind = loop.get("tag", "while")
        expr = _render_expr(loop.get("expr", {}))
        header = f"{pad}do"
        footer = f"{pad}loop {kind} {expr}"
        return f"{header}\n{body}\n{footer}"
    else:
        header = f"{pad}do"

    return f"{header}\n{body}\n{pad}loop"


def _render_choose(stmt: dict[str, Any], indent: int) -> str:
    pad = "    " * indent
    expr = _render_expr(stmt.get("expr", {}))
    parts = [f"{pad}choose case {expr}"]
    for clause in stmt.get("clauses", []):
        cc_expr = clause.get("expr")
        cc_body = _render_body_list(clause.get("body", []), indent + 1)
        if cc_expr:
            case_text = _tokens_to_text(cc_expr) if isinstance(cc_expr, list) else str(cc_expr)
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
    if isinstance(expr, str):
        return expr
    if isinstance(expr, (int, float)):
        return str(expr)
    if not isinstance(expr, dict):
        return str(expr)

    tag = expr.get("tag", "")

    if tag == "call_expr":
        return _render_call_expr(expr)

    if tag == "method_call":
        return _render_method_call(expr)

    if tag == "dispatch":
        return _render_dispatch(expr)

    if tag == "lvalue":
        return _render_lvalue(expr)

    if tag == "lit":
        lit = expr.get("value", expr.get("text", ""))
        return str(lit)

    if tag == "enum":
        return expr.get("name", "") + "!"

    if tag == "not":
        return "not " + _render_expr(expr.get("expr", {}))

    if tag == "binop":
        left = _render_expr(expr.get("lhs", {}))
        op = expr.get("op", "")
        right = _render_expr(expr.get("rhs", {}))
        return f"{left} {op} {right}"

    if tag == "neg":
        return "-" + _render_expr(expr.get("expr", {}))

    if tag == "host_var":
        return ":" + _render_lvalue(expr.get("lvalue", expr))

    if tag == "create":
        return "create " + str(expr.get("class", ""))
    if tag == "create_using":
        return "create using " + _render_expr(expr.get("expr", {}))

    if tag == "array":
        items = [_render_expr(e) for e in expr.get("elements", expr.get("items", []))]
        return "{" + ", ".join(items) + "}"

    if tag == "raw":
        tokens = expr.get("tokens", [])
        if tokens:
            return _tokens_to_text(tokens)
        text = expr.get("text", "")
        return text

    callee = expr.get("callee")
    if callee:
        return _render_call_expr(expr)

    segments = expr.get("segments")
    if segments:
        return _render_lvalue(expr)

    return json.dumps(expr)


def _render_call_expr(expr: dict[str, Any]) -> str:
    callee = expr.get("callee", {})
    name = _render_lvalue(callee) if isinstance(callee, dict) else str(callee)
    args_lists = expr.get("args", [])
    if not args_lists:
        return f"{name}()"
    arg_strs = [_render_expr(a) if isinstance(a, dict) else _tokens_to_text(a) if isinstance(a, list) else str(a) for a in args_lists]
    return f"{name}({', '.join(arg_strs)})"


def _render_method_call(expr: dict[str, Any]) -> str:
    receiver = _render_expr(expr.get("receiver", {}))
    method = expr.get("method", "")
    args_lists = expr.get("args", [])
    if not args_lists:
        return f"{receiver}.{method}()"
    arg_strs = [_render_expr(a) if isinstance(a, dict) else _tokens_to_text(a) if isinstance(a, list) else str(a) for a in args_lists]
    return f"{receiver}.{method}({', '.join(arg_strs)})"


def _render_dispatch(expr: dict[str, Any]) -> str:
    parts = []
    for key in ("post", "trigger", "dynamic", "event"):
        if expr.get(key):
            parts.append(key.upper())
    name = expr.get("name", "")
    receiver = expr.get("receiver")
    if receiver:
        return " ".join(parts) + " " + _render_expr(receiver) + "::" + name
    return " ".join(parts) + " " + name


def _render_lvalue(lval: dict[str, Any]) -> str:
    segments = lval.get("segments", [])
    if not segments:
        return lval.get("name", str(lval))
    parts = []
    for seg in segments:
        name = seg.get("name", "")
        sub = seg.get("subscript")
        if sub:
            sub_text = ", ".join(_render_expr(s) if isinstance(s, dict) else _tokens_to_text(s) if isinstance(s, list) else str(s) for s in sub)
            parts.append(f"{name}[{sub_text}]")
        else:
            parts.append(name)
    return ".".join(parts)


def _tokens_to_text(tokens: list) -> str:
    parts = []
    for t in tokens:
        if isinstance(t, dict):
            parts.append(t.get("text", t.get("value", str(t))))
        else:
            parts.append(str(t))
    return " ".join(parts)
