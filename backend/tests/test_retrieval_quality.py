"""Regression and retrieval quality tests for OTTAI-42 epic.

Verifies:
- OTTAI-43: YouTube search non-videoId error resilience
- OTTAI-44: Semantic pure threshold prevents false-positive catalog hijack
- OTTAI-45: Hybrid full-text search with title trigram & token OR fallback
- OTTAI-46: LLM understand preserves concise keywords and falls back on non-greetings
- OTTAI-47: Dynamic recommendation rail incorporates current video topic
"""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from app.chat.llm import SYSTEM, SYSTEM_VIDY, fit_history, understand
from app.models import Video
from app.videos import service, youtube

# conftest replaces youtube.search with a fake per test; keep the real one.
REAL_YOUTUBE_SEARCH = youtube.search


@pytest.mark.asyncio
async def test_youtube_search_handles_items_without_videoid(monkeypatch):
    """OTTAI-43: When YouTube API returns channel or playlist items without videoId,
    ensure no KeyError is raised and valid videoIds are extracted."""
    from app.config import get_settings
    monkeypatch.setattr(get_settings(), "youtube_api_key", "fake_key")

    fake_items = [
        {"id": {"kind": "youtube#channel", "channelId": "UC1234567890"}},
        {"id": {"kind": "youtube#video", "videoId": "dQw4w9WgXcQ"}},
        {"id": "bare_string_id"},
        {"id": {"kind": "youtube#video", "videoId": "jNQXAC9IVRw"}},
    ]
    mock_client = AsyncMock()
    mock_resp = MagicMock()
    mock_resp.raise_for_status = lambda: None  # MagicMock: a 200 response
    mock_resp.json.return_value = {"items": fake_items}
    mock_client.get.return_value = mock_resp
    mock_client.__aenter__.return_value = mock_client
    mock_client.__aexit__.return_value = None

    with patch("httpx.AsyncClient", return_value=mock_client):
        with patch("app.videos.youtube.details", new_callable=AsyncMock) as mock_details:
            mock_details.return_value = [{"youtube_id": "dQw4w9WgXcQ"}, {"youtube_id": "jNQXAC9IVRw"}]
            res = await REAL_YOUTUBE_SEARCH("flutter")
            assert len(res) == 2
            mock_details.assert_called_once_with(["dQw4w9WgXcQ", "jNQXAC9IVRw"])


def test_pure_semantic_threshold_configuration():
    """OTTAI-44: Ensure pure semantic threshold is strict enough (>= 0.74) to prevent
    cosine hallucinations on 768-dim nomic vectors without text overlap."""
    assert service.SEMANTIC_PURE_MIN >= 0.74


def test_recommendation_domain_topics(monkeypatch):
    """OTTAI-47: Ensure recommendation domain topics correctly validate video topic."""
    from app.config import get_settings

    v_on = Video(
        youtube_id="11111111111",
        title="Attention Mechanism",
        topic="Machine Learning",
        description="",
        channel="",
        tags=[],
    )
    v_off = Video(
        youtube_id="22222222222",
        title="Baking Sourdough",
        topic="cooking",
        description="",
        channel="",
        tags=[],
    )
    monkeypatch.setattr(get_settings(), "recommend_topics", ["LLMs", "Machine Learning", "data structures"])
    assert service.in_domain(v_on)
    assert not service.in_domain(v_off)
    # Empty recommend_topics allows any topic
    monkeypatch.setattr(get_settings(), "recommend_topics", [])
    assert service.in_domain(v_off)


@pytest.mark.asyncio
async def test_understand_single_keyword_preservation_and_greetings():
    """OTTAI-46: Verify understand() retains keywords and distinguishes greetings from search topics."""
    with patch("app.ollama.chat_json", new_callable=AsyncMock) as mock_chat:
        # 1. LLM returned empty topic for a keyword query "react"
        mock_chat.return_value = type(
            "Res",
            (),
            {
                "data": {"topic": "", "reply": "Here are some videos."},
                "prompt_tokens": 10,
                "output_tokens": 5,
            },
        )()
        u_react = await understand("react", "llama3.2:3b", [], 4096, source="youtube")
        assert u_react.topic == "react"

        # 2. Pure greeting "hello" should remain an empty topic
        mock_chat.return_value = type(
            "Res",
            (),
            {
                "data": {"topic": "", "reply": "Hello! What would you like to watch?"},
                "prompt_tokens": 10,
                "output_tokens": 5,
            },
        )()
        u_hello = await understand("hello", "llama3.2:3b", [], 4096, source="youtube")
        assert u_hello.topic == ""


@pytest.mark.parametrize(
    "msg,expected",
    [
        ("react", True),
        ("sourdough bread", True),
        ("Inception", True),
        ("how to bake bread", True),
        ("thanks!", False),
        ("ok", False),
        ("hi there", False),
        ("Hello!", False),
        ("how are you doing", False),
        ("cool, thank you", False),
        ("?", False),
        ("please could you find me something interesting to watch tonight", False),
    ],
)
def test_keyword_fallback_skips_small_talk(msg, expected):
    """OTTAI-46: only bare keyword queries become a topic when the LLM returns none."""
    from app.chat.llm import _looks_like_keywords

    assert _looks_like_keywords(msg) is expected


# ---------- catalog search against the test database (OTTAI-44/45) ----------

CATALOG = [
    {"youtube_id": "dddddddddd1", "title": "Docker for beginners", "topic": "devops",
     "tags": ["containers"], "description": "images and containers", "duration_s": 900},
    {"youtube_id": "kkkkkkkkkk1", "title": "Kubernetes deep dive", "topic": "devops",
     "tags": ["clusters"], "description": "pods and services", "duration_s": 1200},
    {"youtube_id": "sssssssss01", "title": "Sourdough bread recipe", "topic": "lifestyle",
     "tags": ["baking"], "description": "bake at home", "duration_s": 600},
    {"youtube_id": "nnnnnnnnnn1", "title": "snake_case naming guide", "topic": "python",
     "tags": [], "description": "", "duration_s": 300},
    {"youtube_id": "nnnnnnnnnn2", "title": "snakeXcase oddities", "topic": "python",
     "tags": [], "description": "", "duration_s": 300},
]


async def _search(query: str) -> list[str]:
    from app.db import SessionLocal

    async with SessionLocal() as db:
        await service.upsert_videos(db, CATALOG, source="curated")
        return [h.video.youtube_id for h in await service.search_catalog(db, query)]


async def test_catalog_single_keyword_finds_title():
    assert (await _search("docker"))[0] == "dddddddddd1"


async def test_catalog_or_fallback_when_no_all_words_match():
    ids = await _search("docker sourdough kubernetes")
    assert {"dddddddddd1", "sssssssss01", "kkkkkkkkkk1"} <= set(ids)


async def test_catalog_drops_weak_vector_only_hits():
    # No text matches; nearest vectors exist but are far below SEMANTIC_PURE_MIN.
    assert await _search("quantum chromodynamics") == []


async def test_catalog_title_match_treats_underscore_literally():
    ids = await _search("snake_case")
    assert "nnnnnnnnnn1" in ids
    assert "nnnnnnnnnn2" not in ids
