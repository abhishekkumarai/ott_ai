"""Tiny async client for the local Ollama server (free, runs on the host)."""

import json
import logging
from dataclasses import dataclass

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


@dataclass
class ChatResult:
    """Parsed JSON content plus Ollama's own token counts for the request."""

    data: dict
    prompt_tokens: int = 0
    output_tokens: int = 0


async def chat_json(
    model: str,
    messages: list[dict],
    schema: dict,
    num_predict: int = 200,
    num_ctx: int | None = None,
) -> ChatResult | None:
    options: dict = {"temperature": 0.3, "num_predict": num_predict}
    if num_ctx:
        options["num_ctx"] = num_ctx
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
                "options": options,
            },
        )
        r.raise_for_status()
        body = r.json()
        data = json.loads(body["message"]["content"])
        if not isinstance(data, dict):
            raise ValueError("not a JSON object")
        return ChatResult(
            data=data,
            prompt_tokens=_count(body.get("prompt_eval_count")),
            output_tokens=_count(body.get("eval_count")),
        )
    except (httpx.HTTPError, KeyError, ValueError) as e:
        log.warning("chat failed (%s): %s", model, e)
        return None


def _count(v: object) -> int:
    return v if isinstance(v, int) and v >= 0 else 0


# ------------------------------------------------------------------ context length

_context: dict[str, int] = {}


def parse_context(info: dict) -> int | None:
    """Context window from an /api/show payload: the Modelfile's num_ctx when set,
    else the model's native ``<arch>.context_length``."""
    for line in str(info.get("parameters") or "").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] == "num_ctx" and parts[1].isdigit():
            return int(parts[1])
    model_info = info.get("model_info")
    if isinstance(model_info, dict):
        for key, value in model_info.items():
            if key.endswith(".context_length") and isinstance(value, int) and value > 0:
                return value
    return None


async def context_length(model: str) -> int:
    """Tokens the app budgets (and sends as num_ctx) for [model]: what Ollama reports,
    capped at ``llm_num_ctx`` so a 128k-native model doesn't allocate a huge KV cache.
    Cached per model once known."""
    cap = get_settings().llm_num_ctx
    if model in _context:
        return _context[model]
    try:
        r = await client().post("/api/show", json={"model": model}, timeout=5)
        r.raise_for_status()
        native = parse_context(r.json())
    except (httpx.HTTPError, ValueError) as e:
        log.warning("context length unavailable (%s): %s", model, e)
        return cap  # not cached: try again next time
    ctx = min(native, cap) if native else cap
    _context[model] = ctx
    return ctx
