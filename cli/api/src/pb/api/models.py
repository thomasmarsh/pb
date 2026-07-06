"""Pydantic response models for API endpoints."""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel


class WiringDiagramResponse(BaseModel):
    term: dict[str, Any]
    sharedBlocks: dict[str, Any]
    sourceOriginal: str | None
    procStartLine: int | None
