"""Live index-run progress endpoints (polling + SSE)."""

from __future__ import annotations

import asyncio
import json
import queue
from queue import Empty
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import StreamingResponse

router = APIRouter()


@router.get("/api/index-progress")
async def get_index_progress(request: Request) -> dict[str, Any]:
    job = request.app.state.index_job
    if job is None:
        return {"active": False}
    return {"active": True, **job.snapshot()}


def _sse(data: dict) -> str:
    return f"data: {json.dumps(data)}\n\n"


@router.get("/api/index-events")
async def stream_index_events(request: Request) -> StreamingResponse:
    job = request.app.state.index_job
    if job is None:

        async def empty():
            yield _sse({"active": False})

        return StreamingResponse(empty(), media_type="text/event-stream")

    q: queue.Queue = queue.Queue(maxsize=256)
    collector = job._collector
    collector.subscribe(q)

    async def generate():
        loop = asyncio.get_running_loop()
        try:
            # Send full snapshot on initial connection
            yield _sse({"active": True, **job.snapshot()})
            while True:
                if await request.is_disconnected():
                    break
                try:
                    _snap = await asyncio.wait_for(
                        loop.run_in_executor(None, q.get, True, 1.0),
                        timeout=2.0,
                    )
                except (asyncio.TimeoutError, Empty):
                    yield ": keepalive\n\n"
                    continue
                snap = job.snapshot()
                done = job.done
                yield _sse({"active": True, **snap})
                if done:
                    break
        finally:
            collector.unsubscribe(q)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
