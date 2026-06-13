"""FastAPI application factory for pb explore."""
from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from pbtools.explorer.api import router

STATIC_DIR = Path(__file__).parent / "static"


def create_app(db_path: str = "pb.duckdb") -> FastAPI:
    app = FastAPI(title="pb explore", version="0.1.0")
    app.state.db_path = db_path
    app.include_router(router)
    app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")
    return app
