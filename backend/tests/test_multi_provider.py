import pytest

from app.videos.multi_provider import search_provider


@pytest.mark.asyncio
async def test_search_provider_direct_routes():
    # 2Embed direct movie
    res_movie = await search_provider("movie 550", provider_id="2embed")
    assert len(res_movie) == 1
    assert res_movie[0].youtube_id == "2embed:movie:550"
    assert res_movie[0].provider == "2embed"
    assert res_movie[0].media_type == "movie"

    # Flixer direct TV series with season and episode
    res_tv = await search_provider("tv 1396 2 4", provider_id="flixer")
    assert len(res_tv) == 1
    assert res_tv[0].youtube_id == "flixer:tv:1396/2/4"
    assert res_tv[0].provider == "flixer"
    assert res_tv[0].season == 2
    assert res_tv[0].episode == 4

    # Miruro direct anime with episode
    res_anime = await search_provider("anime 21 3", provider_id="miruro")
    assert len(res_anime) == 1
    assert res_anime[0].youtube_id == "miruro:anime:21/3"
    assert res_anime[0].provider == "miruro"
    assert res_anime[0].media_type == "anime"
    assert res_anime[0].episode == 3


@pytest.mark.asyncio
async def test_search_provider_curated_branding():
    # Inception on bCine
    res = await search_provider("Inception", provider_id="bcine")
    assert len(res) > 0
    assert all(v.provider == "bcine" for v in res)
    assert all(v.youtube_id.startswith("bcine:") for v in res)

    # Breaking Bad on MeowTV
    res_bb = await search_provider("Breaking Bad", provider_id="meowtv")
    assert len(res_bb) > 0
    assert any(v.media_type == "tv" for v in res_bb)
    assert all(v.provider == "meowtv" for v in res_bb)
    assert all(v.youtube_id.startswith("meowtv:") for v in res_bb)


@pytest.mark.asyncio
async def test_multi_provider_chat_endpoint(client):
    reg = await client.post("/api/auth/register", json={"email": "multiprovider@test.com", "password": "Password123!"})
    token = reg.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    # Request chat with active source = "2embed"
    resp = await client.post(
        "/api/chat",
        json={"message": "stream Inception", "source": "2embed"},
        headers=headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["source"] == "2embed"
    assert len(data["videos"]) > 0
    assert data["videos"][0]["provider"] == "2embed"
    assert data["videos"][0]["youtube_id"].startswith("2embed:")


@pytest.mark.asyncio
async def test_all_verified_provider_drivers():
    """Validates each verified provider driver individually for search and ID generation."""
    providers = ["vidy", "2embed", "flixer", "bcine", "meowtv", "miruro", "kaa", "tubi"]
    for pid in providers:
        if pid in ("miruro", "kaa"):
            res = await search_provider("anime 21 1", provider_id=pid)
            assert len(res) >= 1
            assert res[0].provider == pid
            assert res[0].youtube_id == f"{pid}:anime:21/1"
        elif pid == "tubi":
            res = await search_provider("movie 99999", provider_id=pid)
            assert len(res) >= 1
            assert res[0].provider == pid
            assert res[0].youtube_id == f"{pid}:movie:99999"
        else:
            res = await search_provider("Inception", provider_id=pid)
            assert len(res) >= 1
            assert all(v.provider == pid for v in res)
            assert all(v.youtube_id.startswith(f"{pid}:") for v in res)

    # Test unknown provider graceful fallback
    fallback = await search_provider("Inception", provider_id="unknown_provider_xyz")
    assert len(fallback) >= 1
    assert all(v.provider == "vidy" for v in fallback)

