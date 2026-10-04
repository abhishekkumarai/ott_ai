"""Tiny async client for the local Ollama server (free, runs on the host)."""

import json
import logging
import time
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


async def check_health() -> dict:
    """Check connectivity to Ollama, retrieve version, latency, and installed models."""
    s = get_settings()
    start = time.perf_counter()
    version: str | None = None
    try:
        r_ver = await client().get("/api/version", timeout=3)
        if r_ver.status_code == 200:
            version = r_ver.json().get("version")
    except Exception:
        version = None

    try:
        r = await client().get("/api/tags", timeout=3)
        r.raise_for_status()
        latency_ms = max(1, int((time.perf_counter() - start) * 1000))
        raw_models = r.json().get("models", [])
        installed = [
            m.get("name", "")
            for m in raw_models
            if isinstance(m, dict) and "name" in m and m.get("name")
        ]
        installed_set = set(installed)

        available_models = [m for m in s.allowed_models if m in installed_set]
        embed_prefix = s.embed_model.split(":")[0]
        embed_available = s.embed_model in installed_set or any(
            m.startswith(embed_prefix) for m in installed_set
        )

        status = "healthy"
        if not available_models:
            status = "degraded"
            message = (
                f"Ollama is running (v{version or '?'}), but no allowed chat models "
                f"({', '.join(s.allowed_models)}) are installed."
            )
        elif not embed_available:
            status = "degraded"
            message = (
                f"Ollama is running with {len(available_models)} chat model(s), but embedding model "
                f"'{s.embed_model}' is not installed."
            )
        else:
            message = (
                f"Ollama is running normally (v{version or '?'}) with {len(installed)} model(s) installed."
            )

        return {
            "status": status,
            "ok": True,
            "version": version,
            "models": installed,
            "available_models": available_models,
            "installed_count": len(installed),
            "embed_model": s.embed_model,
            "embed_available": embed_available,
            "ollama_url": s.ollama_url,
            "latency_ms": latency_ms,
            "message": message,
        }
    except Exception as e:
        log.warning("Ollama health check failed: %s", e)
        return {
            "status": "unreachable",
            "ok": False,
            "version": None,
            "models": [],
            "available_models": [],
            "installed_count": 0,
            "embed_model": s.embed_model,
            "embed_available": False,
            "ollama_url": s.ollama_url,
            "latency_ms": None,
            "message": f"Could not connect to Ollama at {s.ollama_url}. Ensure Ollama is running.",
        }


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
