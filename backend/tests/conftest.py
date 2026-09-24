import os
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import pytest

# Point everything at the dedicated test database *before* the app is imported.
_base = os.environ.get("OTT_DATABASE_URL") or ""
if not _base:
    _env = Path(__file__).resolve().parents[2] / ".env"
    for line in _env.read_text(encoding="utf-8").splitlines():
        if line.startswith("OTT_DATABASE_URL="):
            _base = line.split("=", 1)[1].strip()
_p = urlsplit(_base)
os.environ["OTT_DATABASE_URL"] = urlunsplit((_p.scheme, _p.netloc, "/ott_ai_db_test", "", ""))
os.environ["OTT_EXPECTED_DB_NAME"] = "ott_ai_db_test"
os.environ["OTT_YOUTUBE_API_KEY"] = "test-key"
os.environ["OTT_ENV"] = "test"

ROOT = Path(__file__).resolve().parents[1]
subprocess.run(
    [sys.executable, "-m", "alembic", "upgrade", "head"], cwd=ROOT, check=True, env=os.environ
)

import httpx  # noqa: E402
from sqlalchemy import text  # noqa: E402

from app import ollama  # noqa: E402
from app.db import engine  # noqa: E402
from app.deps import limiter  # noqa: E402
from app.main import app  # noqa: E402
from app.videos import youtube  # noqa: E402

VEC_DIM = 768


def fake_vec(text_: str) -> list[float]:
    """Deterministic bag-of-words embedding so semantic search is testable offline."""
    v = [0.0] * VEC_DIM
    for w in text_.lower().replace(":", " ").replace(".", " ").split():
        if w in {"search_query", "search_document"}:
            continue
        v[hash(w) % VEC_DIM] += 1.0
    if not any(v):
        v[0] = 1.0
    return v


@pytest.fixture(autouse=True)
def _offline(monkeypatch):
    async def embed(texts):
        return [fake_vec(t) for t in texts]

    async def models():
        return {"llama3.2:3b", "qwen3.5:4b"}

    async def chat_json(model, messages, schema):
        msg = messages[-1]["content"]
        return {"topic": msg.replace("show me", "").strip(), "reply": "Here you go."}

    async def yt_search(q, max_results=8):
        return []

    monkeypatch.setattr(ollama, "embed", embed)
    monkeypatch.setattr(ollama, "installed_models", models)
    monkeypatch.setattr(ollama, "chat_json", chat_json)
    monkeypatch.setattr(youtube, "search", yt_search)
    limiter.reset()


@pytest.fixture(autouse=True)
async def _clean_db():
    yield
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "TRUNCATE users, refresh_tokens, videos, youtube_query_cache, "
                "conversations, messages, watch_history CASCADE"
            )
        )
    await engine.dispose()


@pytest.fixture
async def client():
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="https://test") as c:
        yield c


async def register(client, email="user@example.com", password="correct horse battery"):
    r = await client.post("/api/auth/register", json={"email": email, "password": password})
    assert r.status_code == 201, r.text
    return r.json()


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}
