"""Keyword-driven classification of BsRaw statement text — no I/O dependencies."""

from __future__ import annotations

SQL_KWS = {
    "select",
    "selectblob",
    "insert",
    "update",
    "updateblob",
    "delete",
    "commit",
    "rollback",
    "connect",
    "disconnect",
    "declare",
    "cursor",
    "execute",
    "fetch",
    "prepare",
    "describe",
    "descriptor",
    "from",
    "and",
    "or",
    "into",
    "using",
    "where",
    "having",
    "group",
    "order",
    "join",
    "open",
    "close",
}
CTRL_KWS = {
    "if",
    "else",
    "elseif",
    "end",
    "choose",
    "case",
    "for",
    "do",
    "loop",
    "while",
    "until",
    "try",
    "catch",
    "finally",
}
DECL_KWS = {
    "event",
    "on",
    "function",
    "subroutine",
    "type",
    "variables",
    "forward",
    "prototypes",
}
HANDLED = {"return", "exit", "continue", "call", "destroy", "create", "halt"}

DW_STRUCT_FIELDS = ["name", "band", "id", "x", "y", "width", "height", "visible", "expression", "tabSeq"]


def categorize(text: str) -> tuple[str, str]:
    words = text.strip().split()
    if not words:
        return "empty", ""
    first = words[0].lower().rstrip(";")
    if first in SQL_KWS:
        return "sql", first
    if first in CTRL_KWS:
        return "ctrl", first
    if first in DECL_KWS:
        return "decl", first
    if first in HANDLED or first.endswith(":"):
        return "handled", first
    if text.strip().startswith("{"):
        return "array_init", first
    return "other", first
