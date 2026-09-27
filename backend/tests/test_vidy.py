import pytest
from app.chat.llm import SYSTEM_VIDY, fit_history
from app.videos.vidy import search_curated_vidy, search_vidy


@pytest.mark.asyncio
async def test_direct_route_matching():
    res = await search_vidy("movie 315162")
    assert len(res) == 1
    assert res[0].youtube_id == "vidy:movie:315162"
    assert res[0].provider == "vidy"
    assert res[0].media_type == "movie"

    res_tv = await search_vidy("tv 1396 2 4")
    assert len(res_tv) == 1
    assert res_tv[0].youtube_id == "vidy:tv:1396/2/4"
    assert res_tv[0].media_type == "tv"
    assert res_tv[0].season == 2
    assert res_tv[0].episode == 4

    res_anime = await search_vidy("anime 21 5")
    assert len(res_anime) == 1
    assert res_anime[0].youtube_id == "vidy:anime:21/5"
    assert res_anime[0].media_type == "anime"
    assert res_anime[0].episode == 5


def test_curated_library_matching():
    res = search_curated_vidy("Inception")
    assert any("Inception" in v.title for v in res)
    assert all(v.provider == "vidy" for v in res)

    res_bb = search_curated_vidy("Breaking Bad")
    assert any("Breaking Bad" in v.title for v in res_bb)
    assert any(v.media_type == "tv" for v in res_bb)


def test_fit_history_vidy_system_prompt():
    history = [{"role": "user", "content": "hello"}]
    kept, trimmed = fit_history(history, "stream Oppenheimer", 4096, system_prompt=SYSTEM_VIDY)
    assert not trimmed
    assert len(kept) == 1
