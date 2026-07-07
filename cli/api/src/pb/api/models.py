"""Pydantic response models for API endpoints."""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel


class WiringDiagramResponse(BaseModel):
    term: dict[str, Any]
    sharedBlocks: dict[str, Any]
    sourceOriginal: str | None
    procStartLine: int | None


class FkColumnRef(BaseModel):
    namespace: str | None
    table: str
    column: str


class FkGraphEdge(BaseModel):
    from_column: FkColumnRef
    to_column: FkColumnRef
    constraint_name: str | None
    dw_sources: list[dict[str, str]]


class FkGraphResponse(BaseModel):
    corroborated: list[FkGraphEdge]
    unenforced: list[FkGraphEdge]
    unused: list[FkGraphEdge]


class ColumnTouch(BaseModel):
    namespace: str | None
    table: str
    column: str
    is_write: bool


class FilterTouch(BaseModel):
    namespace: str | None
    table: str
    column: str
    op: str
    values_json: str | None


class UnresolvedRef(BaseModel):
    line: int
    raw_name: str


class StatementFootprint(BaseModel):
    line: int
    file: str
    columns: list[ColumnTouch]
    filters: list[FilterTouch]


class ProcedureFootprintResponse(BaseModel):
    object: str
    proc_name: str
    statements: list[StatementFootprint]
    unresolved: list[UnresolvedRef]


class ColumnManagerRef(BaseModel):
    kind: str
    file: str
    object: str | None = None
    proc_name: str | None = None
    dw_name: str | None = None
    line: int | None = None
    is_write: bool | None = None
