"""FastAPI application factory for pb explore."""

from __future__ import annotations

import logging
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from pb.api.routes import (
    analysis,
    datawindows,
    diagnostics,
    diagrams,
    index_progress,
    libraries,
    objects,
    procedures,
    queries,
    runtime,
    schema,
    search,
    sql,
    static,
    tables,
)
from pb.api.routes.static import spa_html
from scalar_fastapi import get_scalar_api_reference

STATIC_DIR = Path(__file__).parent / "static"


class _SuppressStatsFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        msg = record.getMessage()
        return "/api/stats" not in msg


def create_app(db_path: str = "pb.duckdb") -> FastAPI:
    logging.getLogger("uvicorn.access").addFilter(_SuppressStatsFilter())

    app = FastAPI(title="pb explore", version="0.1.0")
    app.state.db_path = db_path
    app.state.index_job = None
    app.include_router(analysis.router)
    app.include_router(libraries.router)
    app.include_router(objects.router)
    app.include_router(procedures.router)
    app.include_router(search.router)
    app.include_router(diagrams.router)
    app.include_router(datawindows.router)
    app.include_router(queries.router)
    app.include_router(runtime.router)
    app.include_router(sql.router)
    app.include_router(schema.router)
    app.include_router(tables.router)
    app.include_router(diagnostics.router)
    app.include_router(index_progress.router)
    app.include_router(static.router)
    app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

    @app.get("/api/docs", include_in_schema=False)
    async def scalar_docs():
        return get_scalar_api_reference(openapi_url=app.openapi_url, title=app.title)

    # SPA catch-all: serve index.html (or, while an IndexJob is running,
    # progress.html) for any non-API, non-static path. This must be
    # registered AFTER the API router and static mount.
    @app.get("/{path:path}")
    async def spa_fallback(path: str, request: Request):
        # Don't intercept API or static routes
        if path.startswith("api/") or path.startswith("static/"):
            from fastapi import HTTPException

            raise HTTPException(status_code=404)
        return HTMLResponse(content=spa_html(request))

    return app
