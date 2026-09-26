"""Tiny async client for the local Ollama server (free, runs on the host)."""

import json
import logging

import httpx

from app.config import get_settings

log = logging.getLogger("ott_ai.ollama")
_client: httpx.AsyncClient | None = None


def client() -> httpx.AsyncClient:
    global _client
    if _client is None:
        s = get_settings()
        _client = httpx.AsyncClient(base_url=s.ollama_url, timeout=s.llm_timeout_s)
    return _client


async def close() -> None:
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None


async def embed(texts: list[str]) -> list[list[float]] | None:
    """Return embeddings, or None when Ollama is unavailable (search degrades to FTS)."""
    s = get_settings()
    try:
        r = await client().post(
            "/api/embed", json={"model": s.embed_model, "input": texts, "keep_alive": "30m"}
        )
        r.raise_for_status()
        return r.json()["embeddings"]
    except (httpx.HTTPError, KeyError, ValueError) as e:
        log.warning("embedding failed: %s", e)
        return None


async def embed_one(text: str) -> list[float] | None:
    out = await embed([text])
    return out[0] if out else None


async def installed_models() -> set[str]:
    try:
        r = await client().get("/api/tags", timeout=3)
        r.raise_for_status()
        return {m["name"] for m in r.json().get("models", [])}
    except (httpx.HTTPError, KeyError, ValueError):
        return set()


async def chat_json(
    model: str, messages: list[dict], schema: dict, num_predict: int = 200
) -> dict | None:
    try:
        r = await client().post(
            "/api/chat",
            json={
                "model": model,
                "messages": messages,
                "format": schema,
                "stream": False,
                "think": False,
                "keep_alive": "30m",
                "options": {"temperature": 0.3, "num_predict": num_predict},
            },
        )
        r.raise_for_status()
        return json.loads(r.json()["message"]["content"])
    except (httpx.HTTPError, KeyError, ValueError) as e:
        log.warning("chat failed (%s): %s", model, e)
        return None
