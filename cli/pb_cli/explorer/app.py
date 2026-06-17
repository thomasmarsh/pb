"""FastAPI application factory for pb explore."""

from __future__ import annotations

import logging
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.base import BaseHTTPMiddleware

from pb_cli.explorer.routes import (
    datawindows,
    diagrams,
    errors,
    objects,
    procedures,
    queries,
    search,
    static,
    tables,
)

STATIC_DIR = Path(__file__).parent / "static"
INDEX_HTML = STATIC_DIR / "index.html"

_access_log = logging.getLogger("uvicorn.access")


class _SuppressStatsLogMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        if request.url.path == "/api/stats":
            _access_log.setLevel(logging.WARNING)
            try:
                return await call_next(request)
            finally:
                _access_log.setLevel(logging.INFO)
        return await call_next(request)


def create_app(db_path: str = "pb.duckdb") -> FastAPI:
    app = FastAPI(title="pb explore", version="0.1.0")
    app.state.db_path = db_path
    app.add_middleware(_SuppressStatsLogMiddleware)
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
