"""SPA entry point."""

from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from pb.pipeline.reporter import VIZ_ROOT_CSS

router = APIRouter()

_STATIC_DIR = Path(__file__).parent.parent / "static"
_INDEX_HTML = _STATIC_DIR / "index.html"
_PROGRESS_HTML = _STATIC_DIR / "progress.html"


def spa_html(request: Request) -> str:
    """Which SPA entry point to serve: the live progress page while an
    IndexJob is attached and still running, otherwise the ordinary explorer.
    Shared by this module's root `/` route and app.py's `{path:path}`
    catch-all — both intercept the browser's very first request for a given
    URL, so both need the same conditional."""
    job = request.app.state.index_job
    if job is not None and not job.done:
        return _PROGRESS_HTML.read_text().replace("%%VIZ_ROOT_CSS%%", VIZ_ROOT_CSS)
    return _INDEX_HTML.read_text()


@router.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return HTMLResponse(content=spa_html(request))
