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


class StatementRef(BaseModel):
    file: str
    object: str
    proc_name: str
    line: int


class RitualViolation(StatementRef):
    written_column: FkColumnRef


class CoUpdateRitual(BaseModel):
    column_a: FkColumnRef
    column_b: FkColumnRef
    co_write_support: int
    violations: list[RitualViolation]


class CoUpdateRitualsResponse(BaseModel):
    rituals: list[CoUpdateRitual]


class FkGraphEdge(BaseModel):
    from_column: FkColumnRef
    to_column: FkColumnRef
    constraint_name: str | None
    dw_sources: list[dict[str, str]]


class FkGraphResponse(BaseModel):
    corroborated: list[FkGraphEdge]
    unenforced: list[FkGraphEdge]
    unused: list[FkGraphEdge]


class ColumnUsageResponse(BaseModel):
    dead: list[FkColumnRef]
    write_only: list[FkColumnRef]
    read_only: list[FkColumnRef]
    read_write: list[FkColumnRef]


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
