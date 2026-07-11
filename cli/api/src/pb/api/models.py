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


class ColumnManagerRef(BaseModel):
    kind: str
    file: str
    object: str | None = None
    proc_name: str | None = None
    dw_name: str | None = None
    line: int | None = None
    is_write: bool | None = None


class DendrogramMerge(BaseModel):
    similarity: float
    members: list[str]


class ColumnAffinityFields(BaseModel):
    columns: list[str]
    co_access_matrix: list[list[int]]
    dendrogram: list[DendrogramMerge]


class ColumnAffinityResponse(ColumnAffinityFields):
    table: str
    namespace: str | None


class SchemaObjectRef(BaseModel):
    kind: str
    file: str | None = None
    object: str | None = None
    proc_name: str | None = None
    line: int | None = None
    dw_name: str | None = None
    namespace: str | None = None
    table: str | None = None
    column: str | None = None


class DecompositionEvidenceLeg(BaseModel):
    from_object: SchemaObjectRef
    to_object: SchemaObjectRef
    leg_kind: str


class DecompositionEvidencePath(BaseModel):
    target: SchemaObjectRef
    direction: str
    legs: list[DecompositionEvidenceLeg]


class DecompositionCandidate(BaseModel):
    columns: list[str]
    similarity: float
    ritual_support: int
    ritual_pairs: list[CoUpdateRitual]
    unenforced_fk_count: int
    coslice_size: int
    score: float | None
    paths: list[DecompositionEvidencePath]


class DecompositionCandidatesResponse(BaseModel):
    table: str
    namespace: str | None
    affinity: ColumnAffinityFields
    candidates: list[DecompositionCandidate]


class FootprintColumnRef(BaseModel):
    namespace: str | None
    table: str
    column: str


class FootprintLeg(BaseModel):
    column: FootprintColumnRef
    leg_kind: str
    leg_source: str


class FootprintStatement(BaseModel):
    stmt_key: str
    file: str
    line: int | None
    legs: list[FootprintLeg]


class FootprintResponse(BaseModel):
    object: str
    proc_name: str | None
    kind: str
    statements: list[FootprintStatement]
    blast_radius: list[DecompositionEvidencePath]


class LatticeConcept(BaseModel):
    extent: list[str]
    intent: list[str]


class LatticeCover(BaseModel):
    upper: int
    lower: int


class WindowTableLatticeResponse(BaseModel):
    windows: list[str]
    tables: list[str]
    pairs: int
    concepts: list[LatticeConcept]
    covers: list[LatticeCover]
