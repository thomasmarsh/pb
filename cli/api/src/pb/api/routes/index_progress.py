"""Live index-run progress polling endpoint (Plan 181 Phase 3)."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Request

router = APIRouter()


@router.get("/api/index-progress")
async def get_index_progress(request: Request) -> dict[str, Any]:
    job = request.app.state.index_job
    if job is None:
        return {"active": False}
    return {"active": True, **job.snapshot()}
