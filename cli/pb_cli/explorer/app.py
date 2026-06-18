"""FastAPI application factory for pb explore."""

from __future__ import annotations

import logging
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles

from pb_cli.explorer.routes import (
    analysis,
    datawindows,
    diagrams,
    errors,
    libraries,
    objects,
    procedures,
    queries,
    search,
    static,
    tables,
)

STATIC_DIR = Path(__file__).parent / "static"
INDEX_HTML = STATIC_DIR / "index.html"


class _SuppressStatsFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        msg = record.getMessage()
        return "/api/stats" not in msg


def create_app(db_path: str = "pb.duckdb") -> FastAPI:
    logging.getLogger("uvicorn.access").addFilter(_SuppressStatsFilter())

    app = FastAPI(title="pb explore", version="0.1.0")
    app.state.db_path = db_path
    app.include_router(analysis.router)
    app.include_router(libraries.router)
    app.include_router(objects.router)
    app.include_router(procedures.router)
    app.include_router(search.router)
    app.include_router(diagrams.router)
    app.include_router(datawindows.router)
    app.include_router(queries.router)
    app.include_router(tables.router)
    app.include_router(errors.router)
    app.include_router(static.router)
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
