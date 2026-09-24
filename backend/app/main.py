import logging
from contextlib import asynccontextmanager
from urllib.parse import urlsplit

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from slowapi.errors import RateLimitExceeded

from app import ollama
from app.admin.router import router as admin_router
from app.auth.router import router as auth_router
from app.chat.router import router as chat_router
from app.config import get_settings
from app.db import engine
from app.deps import limiter
from app.videos.router import router as videos_router

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s %(message)s")
log = logging.getLogger("ott_ai")
settings = get_settings()
MAX_BODY = 16 * 1024


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("database: %s", urlsplit(settings.db_url).path.lstrip("/"))
    yield
    await ollama.close()
    await engine.dispose()


app = FastAPI(
    title="OTT AI",
    lifespan=lifespan,
    docs_url=None if settings.is_prod else "/api/docs",
    redoc_url=None,
    openapi_url=None if settings.is_prod else "/api/openapi.json",
)
app.state.limiter = limiter


@app.exception_handler(RateLimitExceeded)
async def _rate_limited(request: Request, exc: RateLimitExceeded):
    return JSONResponse({"detail": "Too many requests, slow down."}, status_code=429)


@app.middleware("http")
async def _hardening(request: Request, call_next):
    length = request.headers.get("content-length")
    if length and (not length.isdigit() or int(length) > MAX_BODY):
        return JSONResponse({"detail": "Request too large"}, status_code=413)
    response = await call_next(request)
    response.headers.setdefault("Cache-Control", "no-store")
    response.headers["X-Content-Type-Options"] = "nosniff"
    return response


origins = list(settings.cors_origins)
if not settings.is_prod:
    origins.append("http://localhost:8088")
if origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=origins,
        allow_origin_regex=None if settings.is_prod else r"^http://(localhost|127\.0\.0\.1):\d+$",
        allow_credentials=True,
        allow_methods=["GET", "POST", "PATCH", "DELETE"],
        allow_headers=["Authorization", "Content-Type", "X-Client"],
    )

for r in (auth_router, chat_router, videos_router, admin_router):
    app.include_router(r)


@app.get("/api/health")
async def health():
    return {"ok": True}
