"""SPA entry point."""

from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter
from fastapi.responses import HTMLResponse

router = APIRouter()


@router.get("/", response_class=HTMLResponse)
async def index():
    html_path = Path(__file__).parent.parent / "static" / "index.html"
    return HTMLResponse(content=html_path.read_text())
