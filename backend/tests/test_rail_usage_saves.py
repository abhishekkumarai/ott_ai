"""Recommended rail, per-chat saves, model and token usage (Epic OTTAI-21)."""

import os
import subprocess
import sys

from sqlalchemy import func, select, text

from app import ollama
from app.chat import llm
from app.db import SessionLocal, engine
from app.models import Message, SavedVideo
from tests.conftest import (
    FAKE_CONTEXT,
    FAKE_OUTPUT_TOKENS,
    FAKE_PROMPT_TOKENS,
    ROOT,
    auth,
    register,
)
from tests.test_api import seed_catalog

real_context_length = ollama.context_length  # conftest swaps in a fake per test


async def _chat(client, h, message, **extra):
    r = await client.post("/api/chat", json={"message": message, **extra}, headers=h)
    assert r.status_code == 200, r.text
    return r.json()


# ---------- recommendations stored per reply (OTTAI-22) ----------

async def test_reply_stores_and_returns_its_rail(client):
    await seed_catalog()
    h = auth((await register(client))["access_token"])
    body = await _chat(client, h, "show me recipe")
    main = body["videos"][0]["youtube_id"]
    rail = [v["youtube_id"] for v in body["recommendations"]]
    assert rail and main not in rail
    assert len(rail) == len(set(rail))
    # the reply's other search results are on the rail too
    assert {v["youtube_id"] for v in body["videos"][1:]} <= set(rail)
    matches = [v["match"] or 0 for v in body["recommendations"]]
    assert matches == sorted(matches, reverse=True)

    msgs = (await client.get(f"/api/conversations/{body['conversation_id']}/messages", headers=h)).json()
    assert [v["youtube_id"] for v in msgs[-1]["recommendations"]] == rail
    assert [v["match"] for v in msgs[-1]["recommendations"]] == [
        v["match"] for v in body["recommendations"]
    ]
    assert msgs[0]["recommendations"] is None or msgs[0]["recommendations"] == []


async def test_older_replies_have_no_stored_rail(client):
    await seed_catalog()
    h = auth((await register(client))["access_token"])
    cid = (await _chat(client, h, "hello"))["conversation_id"]
    async with SessionLocal() as db:
        db.add(Message(conversation_id=cid, role="assistant", content="old", video_ids=["aaaaaaaaaaa"]))
        await db.commit()
    msgs = (await client.get(f"/api/conversations/{cid}/messages", headers=h)).json()
    assert msgs[-1]["content"] == "old" and msgs[-1]["recommendations"] is None


async def test_recommendations_and_saves_stay_out_of_the_prompt(client, monkeypatch):
    await seed_catalog()
    h = auth((await register(client))["access_token"])
    cid = (await _chat(client, h, "show me recipe"))["conversation_id"]
    await client.put(f"/api/conversations/{cid}/saved/ccccccccccc", headers=h)
    seen = []

    async def fake(model, messages, schema, num_predict=200, num_ctx=None):
        seen.extend(messages)
        return ollama.ChatResult(data={"topic": "", "reply": "ok"})

    monkeypatch.setattr(ollama, "chat_json", fake)
    await _chat(client, h, "and more?", conversation_id=cid)
    assert all(set(m) == {"role", "content"} for m in seen)
    assert not any("Black holes" in m["content"] for m in seen)


# ---------- model and tokens (OTTAI-27) ----------

async def test_reply_carries_model_and_ollama_token_counts(client):
    await seed_catalog()
    h = auth((await register(client))["access_token"])
    body = await _chat(client, h, "show me sourdough bread")
    assert (body["model"], body["prompt_tokens"], body["output_tokens"]) == (
        "llama3.2:3b", FAKE_PROMPT_TOKENS, FAKE_OUTPUT_TOKENS,
    )
    u = body["usage"]
    assert (u["prompt_tokens"], u["output_tokens"]) == (FAKE_PROMPT_TOKENS, FAKE_OUTPUT_TOKENS)
    assert u["context_limit"] == FAKE_CONTEXT and u["history_window"] == llm.HISTORY_WINDOW
    assert 0 < u["context_tokens"] < FAKE_CONTEXT and u["trimmed"] is False

    # switching the model changes the next reply's model
    cid = body["conversation_id"]
    body = await _chat(client, h, "show me pasta", conversation_id=cid, model="qwen3.5:4b")
    assert body["model"] == "qwen3.5:4b"
    assert body["usage"]["prompt_tokens"] == 2 * FAKE_PROMPT_TOKENS

    msgs = (await client.get(f"/api/conversations/{cid}/messages", headers=h)).json()
    assert [m["model"] for m in msgs if m["role"] == "assistant"] == ["llama3.2:3b", "qwen3.5:4b"]
    assert [m["source"] for m in msgs if m["role"] == "assistant"] == ["catalog", "catalog"]
    conv = (await client.get("/api/conversations", headers=h)).json()[0]
    assert (conv["prompt_tokens"], conv["output_tokens"]) == (
        2 * FAKE_PROMPT_TOKENS, 2 * FAKE_OUTPUT_TOKENS,
    )
    r = await client.get(f"/api/conversations/{cid}/usage", params={"model": "qwen3.5:4b"}, headers=h)
    assert r.json()["output_tokens"] == 2 * FAKE_OUTPUT_TOKENS
    assert r.json()["context_tokens"] > body["usage"]["context_tokens"] - 1


async def test_fallback_and_command_replies_use_no_llm(client, monkeypatch):
    h = auth((await register(client))["access_token"])
    cid = (await _chat(client, h, "hello"))["conversation_id"]

    async def offline(*a, **k):
        return None

    monkeypatch.setattr(ollama, "chat_json", offline)
    body = await _chat(client, h, "something", conversation_id=cid)
    assert (body["model"], body["prompt_tokens"], body["output_tokens"]) == (None, 0, 0)
    assert body["usage"]["prompt_tokens"] == FAKE_PROMPT_TOKENS  # unchanged by the fallback
    body = await _chat(client, h, "pause", conversation_id=cid, player_open=True)
    assert (body["source"], body["model"], body["usage"]["output_tokens"]) == (
        "command", None, FAKE_OUTPUT_TOKENS,
    )
    msgs = (await client.get(f"/api/conversations/{cid}/messages", headers=h)).json()
    assert [(m["source"], m["model"]) for m in msgs if m["role"] == "assistant"] == [
        ("none", "llama3.2:3b"), ("none", None), ("command", None),
    ]


async def test_usage_endpoint_checks_owner_and_model(client):
    a = auth((await register(client, "a@example.com"))["access_token"])
    b = auth((await register(client, "b@example.com"))["access_token"])
    cid = (await _chat(client, a, "hello"))["conversation_id"]
    assert (await client.get(f"/api/conversations/{cid}/usage", headers=b)).status_code == 404
    r = await client.get(f"/api/conversations/{cid}/usage", params={"model": "evil"}, headers=a)
    assert r.status_code == 422


async def test_models_list_their_context(client):
    h = auth((await register(client))["access_token"])
    body = (await client.get("/api/models", headers=h)).json()
    assert body["models"] == [
        {"name": "llama3.2:3b", "context": FAKE_CONTEXT},
        {"name": "qwen3.5:4b", "context": FAKE_CONTEXT},
    ]
    assert body["history_window"] == llm.HISTORY_WINDOW and body["base_context"] > 0


def test_parse_context_prefers_num_ctx():
    assert ollama.parse_context({"parameters": "stop \"<|eot|>\"\nnum_ctx 8192"}) == 8192
    assert ollama.parse_context({"model_info": {"llama.context_length": 131072}}) == 131072
    assert ollama.parse_context({"parameters": "", "model_info": {}}) is None


async def test_context_length_is_capped_and_cached(monkeypatch):
    calls = []

    class Resp:
        def raise_for_status(self):
            pass

        def json(self):
            return {"model_info": {"llama.context_length": 131072}}

    class Client:
        async def post(self, path, json, timeout):
            calls.append(json["model"])
            return Resp()

    monkeypatch.setattr(ollama, "client", lambda: Client())
    monkeypatch.setattr(ollama, "_context", {})
    assert await real_context_length("llama3.2:3b") == 4096  # llm_num_ctx cap
    assert await real_context_length("llama3.2:3b") == 4096
    assert calls == ["llama3.2:3b"]


def test_trim_guard_drops_oldest_history_first():
    history = [{"role": "user" if i % 2 == 0 else "assistant", "content": f"{i} " + "x" * 2000}
               for i in range(8)]
    kept, trimmed = llm.fit_history(history, "next question", ctx=100_000)
    assert not trimmed and kept == history[-llm.HISTORY_WINDOW:]

    kept, trimmed = llm.fit_history(history, "next question", ctx=2048)
    assert trimmed and 0 < len(kept) < llm.HISTORY_WINDOW
    assert kept == history[-len(kept):]  # newest kept, oldest dropped
    prompt = [{"role": "system", "content": llm.SYSTEM}, *kept, {"role": "user", "content": "next question"}]
    assert llm.estimate_tokens(prompt) <= 2048 * llm.CONTEXT_GUARD - llm.NUM_PREDICT


async def test_understand_sends_trimmed_history_and_num_ctx(monkeypatch):
    seen = {}

    async def fake(model, messages, schema, num_predict=200, num_ctx=None):
        seen.update(messages=messages, num_ctx=num_ctx)
        return ollama.ChatResult(data={"topic": "t", "reply": "r"}, prompt_tokens=9, output_tokens=3)

    monkeypatch.setattr(ollama, "chat_json", fake)
    history = [{"role": "user", "content": f"{i} " + "x" * 2000} for i in range(6)]
    u = await llm.understand("q", "llama3.2:3b", history, 2048)
    assert u.trimmed and (u.prompt_tokens, u.output_tokens) == (9, 3)
    assert seen["num_ctx"] == 2048
    assert seen["messages"][1]["content"].startswith(("3 ", "4 ", "5 "))


# ---------- per-chat saves (OTTAI-25) ----------

async def test_saves_roundtrip_in_one_chat(client):
    await seed_catalog()
    h = auth((await register(client))["access_token"])
    cid = (await _chat(client, h, "hello"))["conversation_id"]
    base = f"/api/conversations/{cid}/saved"
    assert (await client.get(base, headers=h)).json() == []
    assert (await client.put(f"{base}/aaaaaaaaaaa", headers=h)).status_code == 204
    assert (await client.put(f"{base}/aaaaaaaaaaa", headers=h)).status_code == 204  # repeat: no-op
    assert (await client.put(f"{base}/ccccccccccc", headers=h)).status_code == 204
    ids = [v["youtube_id"] for v in (await client.get(base, headers=h)).json()]
    assert ids == ["ccccccccccc", "aaaaaaaaaaa"]  # newest first, no duplicate
    assert (await client.put(f"{base}/zzzzzzzzzzz", headers=h)).status_code == 404
    assert (await client.put(f"{base}/bad", headers=h)).status_code == 422
    assert (await client.delete(f"{base}/aaaaaaaaaaa", headers=h)).status_code == 204
    assert [v["youtube_id"] for v in (await client.get(base, headers=h)).json()] == ["ccccccccccc"]
    assert (await client.get("/api/me/saved", headers=h)).status_code == 404  # removed


async def test_saves_roundtrip_for_non_vidy_provider(client):
    """Regression: saving/resolving a non-vidy stream id (e.g. 2embed, flixer) used to
    422 on save and get silently dropped from history/saves (OTTAI-39/40 gap)."""
    h = auth((await register(client))["access_token"])
    cid = (await _chat(client, h, "hello"))["conversation_id"]
    base = f"/api/conversations/{cid}/saved"
    assert (await client.put(f"{base}/2embed:movie:550", headers=h)).status_code == 204
    assert (await client.put(f"{base}/flixer:movie:1396", headers=h)).status_code == 204
    ids = {v["youtube_id"] for v in (await client.get(base, headers=h)).json()}
    assert ids == {"2embed:movie:550", "flixer:movie:1396"}

    msgs_before = len((await client.get(f"/api/conversations/{cid}/messages", headers=h)).json())
    async with SessionLocal() as db:
        db.add(Message(
            conversation_id=cid, role="assistant", content="here", video_ids=["2embed:movie:550"],
        ))
        await db.commit()
    msgs = (await client.get(f"/api/conversations/{cid}/messages", headers=h)).json()
    assert len(msgs) == msgs_before + 1
    assert [v["youtube_id"] for v in msgs[-1]["videos"]] == ["2embed:movie:550"]
    assert msgs[-1]["videos"][0]["provider"] == "2embed"

    assert (await client.delete(f"{base}/2embed:movie:550", headers=h)).status_code == 204
    ids = {v["youtube_id"] for v in (await client.get(base, headers=h)).json()}
    assert ids == {"flixer:movie:1396"}


async def test_saves_belong_to_their_chat(client):
    await seed_catalog()
    h = auth((await register(client))["access_token"])
    a = (await _chat(client, h, "hello"))["conversation_id"]
    b = (await _chat(client, h, "hi again"))["conversation_id"]
    await client.put(f"/api/conversations/{a}/saved/aaaaaaaaaaa", headers=h)
    assert (await client.get(f"/api/conversations/{b}/saved", headers=h)).json() == []
    await client.put(f"/api/conversations/{b}/saved/aaaaaaaaaaa", headers=h)  # separately
    await client.delete(f"/api/conversations/{a}/saved/aaaaaaaaaaa", headers=h)
    assert len((await client.get(f"/api/conversations/{b}/saved", headers=h)).json()) == 1


async def test_saves_check_chat_ownership(client):
    await seed_catalog()
    a = auth((await register(client, "a@example.com"))["access_token"])
    b = auth((await register(client, "b@example.com"))["access_token"])
    cid = (await _chat(client, a, "hello"))["conversation_id"]
    await client.put(f"/api/conversations/{cid}/saved/aaaaaaaaaaa", headers=a)
    base = f"/api/conversations/{cid}/saved"
    assert (await client.get(base, headers=b)).status_code == 404
    assert (await client.put(f"{base}/bbbbbbbbbbb", headers=b)).status_code == 404
    assert (await client.delete(f"{base}/aaaaaaaaaaa", headers=b)).status_code == 404
    assert len((await client.get(base, headers=a)).json()) == 1


async def _saved_rows() -> int:
    async with SessionLocal() as db:
        return await db.scalar(select(func.count()).select_from(SavedVideo))


async def test_saves_go_with_their_chat(client):
    await seed_catalog()
    h = auth((await register(client))["access_token"])
    a = (await _chat(client, h, "hello"))["conversation_id"]
    b = (await _chat(client, h, "hi again"))["conversation_id"]
    for cid in (a, b):
        await client.put(f"/api/conversations/{cid}/saved/aaaaaaaaaaa", headers=h)
    assert await _saved_rows() == 2
    await client.delete(f"/api/conversations/{a}", headers=h)
    assert await _saved_rows() == 1
    await client.delete("/api/conversations", headers=h)
    assert await _saved_rows() == 0


async def test_save_command_reply(client):
    h = auth((await register(client))["access_token"])
    body = await _chat(client, h, "save this", player_open=True)
    assert body["action"]["type"] == "save" and body["reply"] == "Saved to this chat."


# ---------- migration ----------

def _alembic(*args: str) -> None:
    subprocess.run([sys.executable, "-m", "alembic", *args], cwd=ROOT, check=True, env=os.environ)


async def test_migration_deletes_existing_saves(client):
    await seed_catalog()
    h = auth((await register(client))["access_token"])
    uid = (await client.get("/api/auth/me", headers=h)).json()["id"]
    await engine.dispose()
    _alembic("downgrade", "d5b1c7e3a902")
    try:
        async with engine.begin() as conn:
            await conn.execute(
                text(
                    "INSERT INTO saved_videos (id, user_id, youtube_id) "
                    "VALUES (gen_random_uuid(), :u, 'aaaaaaaaaaa'), (gen_random_uuid(), :u, 'bbbbbbbbbbb')"
                ),
                {"u": uid},
            )
        await engine.dispose()
        _alembic("upgrade", "head")
        async with engine.connect() as conn:
            assert await conn.scalar(text("SELECT count(*) FROM saved_videos")) == 0
            nullable = await conn.scalar(
                text(
                    "SELECT is_nullable FROM information_schema.columns "
                    "WHERE table_name = 'saved_videos' AND column_name = 'conversation_id'"
                )
            )
            assert nullable == "NO"
    finally:
        await engine.dispose()
        _alembic("upgrade", "head")


# ---------- recommendations stay on LLMs / ML / data structures ----------

DOMAIN = [
    {"youtube_id": "lllllllllll", "title": "How large language models work", "topic": "LLMs",
     "tags": ["llm", "transformers"], "description": "attention and tokens", "duration_s": 600},
    {"youtube_id": "mmmmmmmmmmm", "title": "Neural networks and gradient descent", "topic": "machine learning",
     "tags": ["neural"], "description": "", "duration_s": 600},
    {"youtube_id": "ddddddddddd", "title": "Hash tables explained", "topic": "data structures",
     "tags": ["hash"], "description": "", "duration_s": 600},
    {"youtube_id": "eeeeeeeeeee", "title": "Transformers and attention for language models", "topic": "LLMs",
     "tags": ["attention"], "description": "", "duration_s": 600},
]


async def _domain(monkeypatch):
    from app.config import get_settings
    from app.videos import service

    monkeypatch.setattr(get_settings(), "recommend_topics", ["LLMs", "Machine Learning", "data structures"])
    await seed_catalog()  # cooking + space videos, outside the topics
    async with SessionLocal() as db:
        await service.upsert_videos(db, DOMAIN, source="curated")


async def test_recommendations_only_come_from_the_topics(client, monkeypatch):
    await _domain(monkeypatch)
    h = auth((await register(client))["access_token"])
    for current in ("aaaaaaaaaaa", "lllllllllll"):  # off-topic and on-topic video
        r = await client.get(f"/api/videos/{current}/recommendations", headers=h)
        ids = [v["youtube_id"] for v in r.json()]
        assert set(ids) == {d["youtube_id"] for d in DOMAIN} - {current}
        again = await client.get(f"/api/videos/{current}/recommendations", headers=h)
        assert [v["youtube_id"] for v in again.json()] == ids  # stable, not random


async def test_rail_drops_off_topic_search_results(client, monkeypatch):
    await _domain(monkeypatch)
    h = auth((await register(client))["access_token"])
    body = await _chat(client, h, "show me recipe")  # sourdough + pasta
    assert body["videos"][0]["youtube_id"] == "aaaaaaaaaaa"
    rail = {v["youtube_id"] for v in body["recommendations"]}
    assert rail and rail <= {d["youtube_id"] for d in DOMAIN}


async def test_fallback_without_embeddings_ranks_by_title_words(client, monkeypatch):
    await _domain(monkeypatch)
    async with engine.begin() as conn:
        await conn.execute(text("UPDATE videos SET embedding = NULL"))
    h = auth((await register(client))["access_token"])
    r = await client.get("/api/videos/lllllllllll/recommendations", headers=h)
    ids = [v["youtube_id"] for v in r.json()]
    # same topic and shared words ("language models") first
    assert ids[0] == "eeeeeeeeeee"
    assert set(ids) == {"eeeeeeeeeee", "mmmmmmmmmmm", "ddddddddddd"}
    assert all(v["match"] is None for v in r.json())


def test_catalog_builder_keeps_english_videos_only():
    from seed.build_catalog import english

    assert english({"title": "Hash tables explained", "channel": "Bro Code"})
    assert not english({"title": "Linked list in Tamil", "channel": "x"})
    assert not english({"title": "Overfitting Explained In Hindi", "channel": "x"})
    assert not english({"title": "[हिन्दी] Fine Tuning LLM", "channel": "x"})
    assert english({"title": "Machine learning explained", "channel": "Behindit"})  # word, not substring
