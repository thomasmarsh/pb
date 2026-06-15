"""FastAPI application factory for pb explore."""
from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles

from pb_cli.explorer.api import router

STATIC_DIR = Path(__file__).parent / "static"
INDEX_HTML = STATIC_DIR / "index.html"


def create_app(db_path: str = "pb.duckdb") -> FastAPI:
    app = FastAPI(title="pb explore", version="0.1.0")
    app.state.db_path = db_path
    app.include_router(router)
    app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

    # SPA catch-all: serve index.html for any non-API, non-static path
    # This must be registered AFTER the API router and static mount
    @app.get("/{path:path}")
    async def spa_fallback(path: str):
        # Don't intercept API or static routes
        if path.startswith("api/") or path.startswith("static/"):
            from fastapi import HTTPException
            raise HTTPException(status_code=404)
        return HTMLResponse(content=INDEX_HTML.read_text())

    return app
