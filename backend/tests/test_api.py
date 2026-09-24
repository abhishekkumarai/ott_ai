from app.videos import service, youtube
from tests.conftest import auth, register

SEED = [
    {"youtube_id": "aaaaaaaaaaa", "title": "Sourdough bread recipe", "topic": "lifestyle",
     "tags": ["bread", "baking"], "description": "bake bread at home", "duration_s": 600},
    {"youtube_id": "bbbbbbbbbbb", "title": "Easy pasta recipe", "topic": "lifestyle",
     "tags": ["pasta", "cooking"], "description": "", "duration_s": 500},
    {"youtube_id": "ccccccccccc", "title": "Black holes explained", "topic": "science",
     "tags": ["space"], "description": "", "duration_s": 700},
]


async def seed_catalog():
    from app.db import SessionLocal

    async with SessionLocal() as db:
        await service.upsert_videos(db, SEED, source="curated")


# ---------- auth ----------

async def test_register_login_me(client):
    tok = await register(client)
    assert "ott_refresh" in client.cookies
    r = await client.get("/api/auth/me", headers=auth(tok["access_token"]))
    assert r.json()["email"] == "user@example.com"
    r = await client.post(
        "/api/auth/login", json={"email": "USER@example.com", "password": "correct horse battery"}
    )
    assert r.status_code == 200


async def test_weak_and_duplicate(client):
    r = await client.post("/api/auth/register", json={"email": "a@example.com", "password": "short"})
    assert r.status_code == 422
    r = await client.post("/api/auth/register", json={"email": "a@example.com", "password": "password123"})
    assert r.status_code == 422
    await register(client, "a@example.com")
    r = await client.post(
        "/api/auth/register", json={"email": "a@example.com", "password": "another long pass"}
    )
    assert r.status_code == 409


async def test_generic_login_error_and_lockout(client):
    await register(client)
    bad = {"email": "user@example.com", "password": "wrong password!!"}
    r = await client.post("/api/auth/login", json={"email": "nobody@example.com", "password": "x"})
    assert r.status_code == 401 and r.json()["detail"] == "Invalid email or password"
    for _ in range(5):
        assert (await client.post("/api/auth/login", json=bad)).status_code == 401
    r = await client.post(
        "/api/auth/login", json={"email": "user@example.com", "password": "correct horse battery"}
    )
    assert r.status_code == 429


async def test_refresh_rotation_and_reuse_detection(client):
    hdr = {"X-Client": "native"}
    r = await client.post(
        "/api/auth/register",
        json={"email": "n@example.com", "password": "correct horse battery"},
        headers=hdr,
    )
    first = r.json()["refresh_token"]
    assert first and "ott_refresh" not in client.cookies
    r = await client.post("/api/auth/refresh", json={"refresh_token": first}, headers=hdr)
    second = r.json()["refresh_token"]
    assert r.status_code == 200 and second != first
    # replaying the old token revokes the family, including the new one
    assert (await client.post("/api/auth/refresh", json={"refresh_token": first})).status_code == 401
    assert (await client.post("/api/auth/refresh", json={"refresh_token": second})).status_code == 401


async def test_protected_routes_require_auth(client):
    for path in ("/api/auth/me", "/api/models", "/api/conversations"):
        assert (await client.get(path)).status_code == 401
    r = await client.get("/api/auth/me", headers=auth("not.a.jwt"))
    assert r.status_code == 401


async def test_admin_requires_admin(client):
    tok = (await register(client))["access_token"]
    assert (await client.get("/api/admin/videos", headers=auth(tok))).status_code == 403


# ---------- chat ----------

async def test_chat_topic_returns_catalog_videos(client):
    await seed_catalog()
    tok = (await register(client))["access_token"]
    r = await client.post("/api/chat", json={"message": "show me sourdough bread"}, headers=auth(tok))
    body = r.json()
    assert r.status_code == 200, body
    assert body["source"] == "catalog"
    assert body["videos"][0]["youtube_id"] == "aaaaaaaaaaa"
    assert body["action"] is None


async def test_chat_commands(client):
    tok = (await register(client))["access_token"]
    h = auth(tok)
    r = await client.post("/api/chat", json={"message": "forward 25 sec", "player_open": True}, headers=h)
    body = r.json()
    assert body["action"] == {"type": "seek", "seconds": 25}
    cid = body["conversation_id"]
    r = await client.post(
        "/api/chat",
        json={"message": "stop", "player_open": True, "conversation_id": cid},
        headers=h,
    )
    assert r.json()["action"]["type"] == "stop"
    r = await client.post("/api/chat", json={"message": "stop", "player_open": False}, headers=h)
    assert r.json()["action"] is None
    msgs = (await client.get(f"/api/conversations/{cid}/messages", headers=h)).json()
    assert [m["role"] for m in msgs] == ["user", "assistant", "user", "assistant"]


async def test_chat_rejects_unlisted_model_and_long_input(client):
    tok = (await register(client))["access_token"]
    h = auth(tok)
    r = await client.post("/api/chat", json={"message": "hi", "model": "evil:latest"}, headers=h)
    assert r.status_code == 422
    r = await client.post("/api/chat", json={"message": "x" * 501}, headers=h)
    assert r.status_code == 422


async def test_conversations_are_private(client):
    a = (await register(client, "a@example.com"))["access_token"]
    b = (await register(client, "b@example.com"))["access_token"]
    cid = (await client.post("/api/chat", json={"message": "hello there"}, headers=auth(a))).json()[
        "conversation_id"
    ]
    r = await client.get(f"/api/conversations/{cid}/messages", headers=auth(b))
    assert r.status_code == 404
    r = await client.post(
        "/api/chat", json={"message": "hi", "conversation_id": cid}, headers=auth(b)
    )
    assert r.status_code == 404


async def test_llm_output_is_plain_text(client):
    tok = (await register(client))["access_token"]
    r = await client.post(
        "/api/chat", json={"message": "<script>alert(1)</script>"}, headers=auth(tok)
    )
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("application/json")


# ---------- youtube fallback & cache ----------

async def test_youtube_fallback_is_cached(client, monkeypatch):
    calls = []

    async def fake_search(q, max_results=8):
        calls.append(q)
        return [{"youtube_id": "zzzzzzzzzzz", "title": "Origami crane", "description": "",
                 "channel": "Paper", "tags": [], "duration_s": 300, "live": False}]

    monkeypatch.setattr(youtube, "search", fake_search)
    tok = (await register(client))["access_token"]
    for _ in range(2):
        r = await client.post("/api/chat", json={"message": "origami crane"}, headers=auth(tok))
        assert r.json()["videos"][0]["youtube_id"] == "zzzzzzzzzzz"
    assert len(calls) == 1


async def test_recommendations(client):
    await seed_catalog()
    tok = (await register(client))["access_token"]
    r = await client.get("/api/videos/aaaaaaaaaaa/recommendations", headers=auth(tok))
    ids = [v["youtube_id"] for v in r.json()]
    assert "aaaaaaaaaaa" not in ids and "bbbbbbbbbbb" in ids
    r = await client.get("/api/videos/bad<id>xxxx/recommendations", headers=auth(tok))
    assert r.status_code == 422


async def test_rate_limit_on_login(client):
    for _ in range(10):
        await client.post("/api/auth/login", json={"email": "x@example.com", "password": "y"})
    r = await client.post("/api/auth/login", json={"email": "x@example.com", "password": "y"})
    assert r.status_code == 429


async def test_body_size_limit(client):
    r = await client.post(
        "/api/auth/login", content=b"x" * 20000, headers={"Content-Type": "application/json"}
    )
    assert r.status_code == 413




# ---------- demo ----------

async def test_demo_session_can_chat_but_not_admin(client):
    r = await client.post("/api/auth/demo")
    assert r.status_code == 201
    body = r.json()
    assert body["user"]["is_demo"] is True and body["user"]["is_admin"] is False
    assert body["user"]["email"].endswith("@demo.invalid")
    assert "ott_refresh" in client.cookies
    h = auth(body["access_token"])
    assert (await client.post("/api/chat", json={"message": "hello"}, headers=h)).status_code == 200
    assert (await client.get("/api/admin/videos", headers=h)).status_code == 403
    # the session refreshes like a normal one
    assert (await client.post("/api/auth/refresh")).status_code == 200


async def test_demo_accounts_expire_and_are_rate_limited(client):
    from datetime import UTC, datetime, timedelta

    from sqlalchemy import select, update

    from app.db import SessionLocal
    from app.models import User

    old = (await client.post("/api/auth/demo")).json()["user"]["id"]
    async with SessionLocal() as db:
        await db.execute(
            update(User).where(User.id == old).values(created_at=datetime.now(UTC) - timedelta(hours=25))
        )
        await db.commit()
    await client.post("/api/auth/demo")  # creating a new demo sweeps expired ones
    async with SessionLocal() as db:
        assert await db.scalar(select(User.id).where(User.id == old)) is None
    for _ in range(3):
        await client.post("/api/auth/demo")
    assert (await client.post("/api/auth/demo")).status_code == 429
