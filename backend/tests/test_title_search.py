"""Title search for the movie/TV aggregators: TMDB settings, query cleaning,
ranking, the strict curated fallback and the source-aware /videos/search."""

import httpx
import pytest

from app.config import Settings, get_settings
from app.videos import vidy
from app.videos.multi_provider import search_provider
from tests.conftest import auth, register


class FakeTmdb:
    """Stands in for httpx.AsyncClient against api.themoviedb.org."""

    def __init__(self, results: list[dict], fail_first: int = 0):
        self.results = results
        self.fail_first = fail_first
        self.calls: list[tuple[str, dict, dict]] = []

    def __call__(self, *a, **kw):
        return self

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        return None

    async def get(self, url, params=None, headers=None):
        self.calls.append((url, dict(params or {}), dict(headers or {})))
        if self.fail_first:
            self.fail_first -= 1
            raise httpx.ConnectError("reset")
        return httpx.Response(200, json={"results": self.results}, request=httpx.Request("GET", url))


DUNES = [
    {"id": 841, "title": "Dune", "release_date": "1984-12-14", "media_type": "movie"},
    {"id": 438631, "title": "Dune", "release_date": "2021-09-15", "media_type": "movie"},
    {"id": 1, "title": "Dune Drifter", "release_date": "2020-01-01", "media_type": "movie"},
    {"id": 2, "title": "Unrelated Picture", "release_date": "2021-01-01", "media_type": "movie"},
]


@pytest.fixture
def tmdb(monkeypatch):
    def install(results, *, key="k3", token="", fail_first=0):
        s = get_settings()
        monkeypatch.setattr(s, "tmdb_api_key", key)
        monkeypatch.setattr(s, "tmdb_read_token", token)
        fake = FakeTmdb(results, fail_first)
        monkeypatch.setattr(vidy.httpx, "AsyncClient", fake)
        vidy._tmdb_cache.clear()
        return fake

    yield install
    vidy._tmdb_cache.clear()


def test_settings_read_unprefixed_tmdb_names(monkeypatch):
    monkeypatch.delenv("OTT_TMDB_API_KEY", raising=False)
    monkeypatch.delenv("OTT_TMDB_READ_TOKEN", raising=False)
    monkeypatch.setenv("TMDB_API_KEY", "plain-key")
    monkeypatch.setenv("TMDB_READ_ACCESS_TOKEN", "plain-token")
    s = Settings()
    assert s.tmdb_api_key == "plain-key"
    assert s.tmdb_read_token == "plain-token"
    assert s.tmdb_enabled


def test_clean_title_query_strips_filler_and_year():
    assert vidy.clean_title_query("watch dune 2021 movie") == ("dune", 2021)
    assert vidy.clean_title_query("the office") == ("the office", None)
    assert vidy.clean_title_query("A Quiet Place") == ("A Quiet Place", None)
    assert vidy.clean_title_query("movie") == ("movie", None)


async def test_tmdb_search_cleans_query_uses_year_and_ranks(tmdb):
    fake = tmdb(DUNES)
    res = await search_provider("watch dune 2021 movie", provider_id="popcorn_movie")
    url, params, _ = fake.calls[0]
    assert url.endswith("/search/movie")
    assert params["query"] == "dune"
    assert params["year"] == 2021
    assert params["api_key"] == "k3"
    assert res[0].youtube_id == "popcorn:movie:438631"
    assert res[0].provider == "popcorn"
    assert res[0].match == 99
    # A title sharing no words with the query is ranked last.
    assert res[-1].title == "Unrelated Picture"


async def test_tmdb_prefers_bearer_token_and_retries_resets(tmdb):
    fake = tmdb(DUNES, token="v4token", fail_first=2)
    res = await search_provider("Dune", provider_id="rive")
    assert res
    assert len(fake.calls) == 3
    _, params, headers = fake.calls[-1]
    assert headers["Authorization"] == "Bearer v4token"
    assert "api_key" not in params
    assert fake.calls[-1][0].endswith("/search/multi")


async def test_tmdb_results_are_cached(tmdb):
    fake = tmdb(DUNES)
    await search_provider("Dune", provider_id="rive")
    await search_provider("dune", provider_id="flixer")
    assert len(fake.calls) == 1


async def test_nothing_found_returns_nothing_not_defaults(tmdb):
    tmdb([])
    assert await search_provider("asdfghqwe", provider_id="2embed") == []


async def test_curated_fallback_ignores_generic_words():
    # TMDB is off in tests: "movie" / "series" must not match every curated title.
    assert await search_provider("movie", provider_id="rive") == []
    assert await search_provider("funny series", provider_id="rive") == []
    res = await search_provider("Inception", provider_id="rive")
    assert [v.title for v in res] == ["Inception"]


async def test_search_endpoint_uses_selected_source(client, tmdb):
    tmdb(DUNES)
    h = auth((await register(client))["access_token"])
    r = await client.get("/api/videos/search", params={"q": "dune 2021", "source": "rive"}, headers=h)
    assert r.status_code == 200
    body = r.json()
    assert body[0]["youtube_id"] == "rive:movie:438631"
    assert body[0]["provider"] == "rive"

    bad = await client.get("/api/videos/search", params={"q": "dune", "source": "nope"}, headers=h)
    assert bad.status_code == 422
    bad = await client.get("/api/videos/search", params={"q": "dune", "source": "../x"}, headers=h)
    assert bad.status_code == 422
