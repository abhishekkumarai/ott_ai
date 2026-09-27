"""Endpoints added for the chat-first redesign (OTTAI-6/7/13/14)."""

from app.chat.intent import parse_command
from app.videos import service
from app.deps import limiter
from tests.conftest import auth, register
from tests.test_api import seed_catalog


# ---------- match % (OTTAI-7) ----------

async def test_chat_and_recommendations_carry_match(client):
    await seed_catalog()
    tok = (await register(client))["access_token"]
    r = await client.post("/api/chat", json={"message": "show me sourdough bread"}, headers=auth(tok))
    first = r.json()["videos"][0]
    assert first["youtube_id"] == "aaaaaaaaaaa"
    assert first["match"] is None or 1 <= first["match"] <= 99
    r = await client.get("/api/videos/aaaaaaaaaaa/recommendations", headers=auth(tok))
    matches = [v["match"] for v in r.json() if v["match"] is not None]
    assert matches and all(1 <= m <= 99 for m in matches)


def test_match_percent_bounds():
    assert service.match_percent(None) is None
    assert service.match_percent(-0.2) is None
    assert service.match_percent(0.734) == 73
    assert service.match_percent(1.0) == 99


# ---------- chapters (OTTAI-6) ----------

def test_parse_chapters_follows_youtube_rules():
    desc = "Learn chords\n0:00 Intro\n1:15 Anchor finger\n(03:40) Dead string buzz\n6:20 - Drill\nBye"
    assert service.parse_chapters(desc, 700) == [
        {"start_s": 0, "title": "Intro"},
        {"start_s": 75, "title": "Anchor finger"},
        {"start_s": 220, "title": "Dead string buzz"},
        {"start_s": 380, "title": "Drill"},
    ]
    assert service.parse_chapters("1:00 a\n2:00 b\n3:00 c") == []  # must start at 0:00
    assert service.parse_chapters("0:00 a\n2:00 b") == []  # fewer than three
    assert service.parse_chapters("0:00 a\n1:00 b\n2:00 c\n9:00 past the end", 300) == [
        {"start_s": 0, "title": "a"}, {"start_s": 60, "title": "b"}, {"start_s": 120, "title": "c"},
    ]


async def test_chapters_endpoint(client):
    from app.db import SessionLocal

    async with SessionLocal() as db:
        await service.upsert_videos(
            db,
            [{"youtube_id": "ccccccccccc", "title": "Chords", "duration_s": 600,
              "description": "0:00 Intro\n1:00 C major\n2:30 G major"}],
            source="curated",
        )
    tok = (await register(client))["access_token"]
    r = await client.get("/api/videos/ccccccccccc/chapters", headers=auth(tok))
    assert [c["title"] for c in r.json()] == ["Intro", "C major", "G major"]
    r = await client.get("/api/videos/zzzzzzzzzzz/chapters", headers=auth(tok))
    assert r.status_code == 404


# ---------- loop / mute commands (OTTAI-13, OTTAI-12) ----------

def test_loop_and_mute_commands():
    assert parse_command("loop this part").action == "loop"
    c = parse_command("loop 3:40 to 5:10")
    assert (c.action, c.start, c.end) == ("loop", 220, 310)
    assert parse_command("loop 5:10 to 3:40") is None
    assert parse_command("stop looping").action == "unloop"
    assert parse_command("mute").action == "mute"
    assert parse_command("unmute").action == "unmute"
    assert parse_command("forward: 10").seconds == 10  # stray colon still ignored
    assert parse_command("how do loops work in python") is None


async def test_loop_command_reply(client):
    tok = (await register(client))["access_token"]
    r = await client.post(
        "/api/chat", json={"message": "loop 1:00 to 1:30", "player_open": True}, headers=auth(tok)
    )
    body = r.json()
    assert body["action"] == {"type": "loop", "seconds": 0, "start": 60, "end": 90}
    assert body["reply"] == "Looping 1:00 to 1:30."


# ---------- settings (OTTAI-14) ----------

async def test_preferences_roundtrip_and_validation(client):
    h = auth((await register(client))["access_token"])
    r = await client.get("/api/me/preferences", headers=h)
    assert r.json()["player_mode"] == "mini" and r.json()["playback_rate"] == 1.0
    r = await client.patch(
        "/api/me/preferences", json={"player_mode": "theater", "playback_rate": 1.5}, headers=h
    )
    assert r.status_code == 200 and r.json()["player_mode"] == "theater"
    assert (await client.get("/api/me/preferences", headers=h)).json()["playback_rate"] == 1.5
    for bad in ({"playback_rate": 3}, {"model": "evil:latest"}, {"nope": 1}, {"voice_language": "<x>"}):
        assert (await client.patch("/api/me/preferences", json=bad, headers=h)).status_code == 422


async def test_change_password_revokes_other_sessions(client):
    first = await register(client)
    other = await client.post(
        "/api/auth/login",
        json={"email": "user@example.com", "password": "correct horse battery"},
        headers={"X-Client": "native"},
    )
    other_refresh = other.json()["refresh_token"]
    h = auth(first["access_token"])
    r = await client.post(
        "/api/auth/change-password",
        json={"current_password": "wrong", "new_password": "a brand new passphrase"},
        headers=h,
    )
    assert r.status_code == 403  # not 401: that would read as "session expired"
    r = await client.post(
        "/api/auth/change-password",
        json={"current_password": "correct horse battery", "new_password": "short"},
        headers=h,
    )
    assert r.status_code == 422
    r = await client.post(
        "/api/auth/change-password",
        json={"current_password": "correct horse battery", "new_password": "a brand new passphrase"},
        headers=h,
    )
    assert r.status_code == 200 and r.json()["access_token"]
    r = await client.post("/api/auth/refresh", json={"refresh_token": other_refresh}, headers={"X-Client": "native"})
    assert r.status_code == 401
    r = await client.post(
        "/api/auth/login", json={"email": "user@example.com", "password": "a brand new passphrase"}
    )
    assert r.status_code == 200


async def test_delete_account_and_clear_history(client):
    tok = (await register(client))["access_token"]
    h = auth(tok)
    await client.post("/api/chat", json={"message": "hello"}, headers=h)
    assert len((await client.get("/api/conversations", headers=h)).json()) == 1
    assert (await client.delete("/api/conversations", headers=h)).status_code == 204
    assert (await client.get("/api/conversations", headers=h)).json() == []
    r = await client.request("DELETE", "/api/auth/account", json={"password": "wrong"}, headers=h)
    assert r.status_code == 403
    r = await client.request(
        "DELETE", "/api/auth/account", json={"password": "correct horse battery"}, headers=h
    )
    assert r.status_code == 204
    assert (await client.get("/api/auth/me", headers=h)).status_code == 401
    r = await client.post(
        "/api/auth/login", json={"email": "user@example.com", "password": "correct horse battery"}
    )
    assert r.status_code == 401


async def test_demo_cannot_change_password_or_delete(client):
    tok = (await client.post("/api/auth/demo")).json()["access_token"]
    h = auth(tok)
    r = await client.post(
        "/api/auth/change-password",
        json={"current_password": "x", "new_password": "a brand new passphrase"},
        headers=h,
    )
    assert r.status_code == 403
    r = await client.request("DELETE", "/api/auth/account", json={"password": "x"}, headers=h)
    assert r.status_code == 403
    # but settings work for the session
    r = await client.patch("/api/me/preferences", json={"autoplay_next": True}, headers=h)
    assert r.status_code == 200


def test_save_command():
    assert parse_command("save this").action == "save"
    assert parse_command("save this video for later").action == "save"
    assert parse_command("save the planet documentary") is None


async def test_password_reentry_locks_out_like_login(client):
    h = auth((await register(client))["access_token"])
    wrong = {"current_password": "nope", "new_password": "a brand new passphrase"}
    for _ in range(5):
        r = await client.post("/api/auth/change-password", json=wrong, headers=h)
        assert r.status_code == 403
        limiter.reset()  # the per-minute rate limit is separate from the lockout
    right = {"current_password": "correct horse battery", "new_password": "a brand new passphrase"}
    r = await client.post("/api/auth/change-password", json=right, headers=h)
    assert r.status_code == 429
    r = await client.request("DELETE", "/api/auth/account", json={"password": "correct horse battery"}, headers=h)
    assert r.status_code == 429


def test_timecode_helper():
    from app.timecode import stamp_seconds

    assert stamp_seconds("0:00") == 0
    assert stamp_seconds("3:40") == 220
    assert stamp_seconds("1:02:03") == 3723


# ---------- curated chapters, transcript and summaries (OTTAI-20) ----------

async def _admin(client):
    from sqlalchemy import update

    from app.db import SessionLocal
    from app.models import User

    tok = (await register(client, "admin@example.com"))["access_token"]
    async with SessionLocal() as db:
        await db.execute(update(User).where(User.email == "admin@example.com").values(is_admin=True))
        await db.commit()
    # A fresh token carries the admin claim.
    r = await client.post(
        "/api/auth/login", json={"email": "admin@example.com", "password": "correct horse battery"}
    )
    return auth(r.json()["access_token"]) if r.status_code == 200 else auth(tok)


async def test_admin_curates_chapters_and_transcript(client):
    await seed_catalog()
    admin = await _admin(client)
    bad = await client.patch(
        "/api/admin/videos/ccccccccccc", json={"chapters_text": "1:00 a\n2:00 b"}, headers=admin
    )
    assert bad.status_code == 422
    r = await client.patch(
        "/api/admin/videos/ccccccccccc",
        json={
            "chapters_text": "0:00 Intro\n1:00 Stars\n3:00 Horizons",
            "transcript": "0:00 Welcome to the show\n1:05 Stars collapse when fuel runs out\n3:10 The horizon",
        },
        headers=admin,
    )
    assert r.status_code == 200 and r.json()["has_chapters"] and r.json()["has_transcript"]
    detail = (await client.get("/api/admin/videos/ccccccccccc", headers=admin)).json()
    assert detail["chapters_text"].startswith("0:00 Intro")

    user = auth((await register(client))["access_token"])
    chapters = (await client.get("/api/videos/ccccccccccc/chapters", headers=user)).json()
    assert [c["title"] for c in chapters] == ["Intro", "Stars", "Horizons"]
    lines = (await client.get("/api/videos/ccccccccccc/transcript", headers=user)).json()
    assert lines[1] == {"start_s": 65, "text": "Stars collapse when fuel runs out"}
    assert (await client.get("/api/videos/aaaaaaaaaaa/transcript", headers=user)).status_code == 404

    # "" clears both fields again
    r = await client.patch(
        "/api/admin/videos/ccccccccccc", json={"chapters_text": "", "transcript": ""}, headers=admin
    )
    assert not r.json()["has_chapters"] and not r.json()["has_transcript"]
    assert (await client.get("/api/videos/ccccccccccc/chapters", headers=user)).json() == []


async def test_summary_of_a_part(client, monkeypatch):
    from app import ollama

    seen = {}

    async def fake_chat_json(model, messages, schema, num_predict=200, num_ctx=None):
        seen["prompt"] = messages[-1]["content"]
        seen["num_ctx"] = num_ctx
        return ollama.ChatResult(
            data={"summary": "Stars collapse when their fuel runs out."},
            prompt_tokens=300,
            output_tokens=40,
        )

    await seed_catalog()
    admin = await _admin(client)
    transcript = "0:00 Welcome to the show and today we look at the sky\n" \
                 "1:05 Stars collapse when fuel runs out and gravity wins over pressure\n" \
                 "3:10 The horizon is the point of no return"
    await client.patch("/api/admin/videos/ccccccccccc", json={"transcript": transcript}, headers=admin)
    user = auth((await register(client))["access_token"])
    conv = (await client.post("/api/chat", json={"message": "hello"}, headers=user)).json()["conversation_id"]

    monkeypatch.setattr(ollama, "chat_json", fake_chat_json)
    r = await client.post(
        "/api/videos/ccccccccccc/summary",
        json={"start_s": 60, "end_s": 180, "label": "Stars", "conversation_id": conv},
        headers=user,
    )
    assert r.status_code == 200 and r.json()["summary"].startswith("Stars collapse")
    assert (r.json()["model"], r.json()["prompt_tokens"], r.json()["output_tokens"]) == (
        "llama3.2:3b", 300, 40,
    )
    assert seen["num_ctx"] == 4096
    assert "gravity wins" in seen["prompt"] and "point of no return" not in seen["prompt"]
    msgs = (await client.get(f"/api/conversations/{conv}/messages", headers=user)).json()
    assert [m["content"] for m in msgs[-2:]] == [
        "Summarize “Stars”",
        "Stars collapse when their fuel runs out.",
    ]
    assert (msgs[-1]["source"], msgs[-1]["model"], msgs[-1]["output_tokens"]) == (
        "summary", "llama3.2:3b", 40,
    )

    async def offline(*a, **k):
        return None

    monkeypatch.setattr(ollama, "chat_json", offline)
    r = await client.post("/api/videos/ccccccccccc/summary", json={}, headers=user)
    assert r.status_code == 503
    r = await client.post("/api/videos/aaaaaaaaaaa/summary", json={}, headers=user)
    assert r.status_code == 404
