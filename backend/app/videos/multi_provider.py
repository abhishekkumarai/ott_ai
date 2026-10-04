import logging
import re

from app.videos.provider_pipeline import StreamProviderConfig, provider_registry
from app.videos.router import VideoOut
from app.videos.vidy import search_anilist, search_curated_vidy, search_tmdb, tmdb_kind

log = logging.getLogger(__name__)

DIRECT_MOVIE_RE = re.compile(r"^movie\s+(\d+)$", re.IGNORECASE)
DIRECT_TV_RE = re.compile(r"^tv\s+(\d+)(?:\s+(\d+)\s+(\d+))?$", re.IGNORECASE)
DIRECT_ANIME_RE = re.compile(r"^anime\s+(\d+)(?:\s+(\d+))?$", re.IGNORECASE)


async def search_provider(q: str, provider_id: str = "vidy") -> list[VideoOut]:
    """Unified search adapter that maps user queries to specific verified streaming providers.

    Supports TMDB multi-search, AniList GraphQL, curated catalog, and direct route syntax."""
    clean_q = q.strip()
    if not clean_q:
        return []

    # Map aliases e.g. "vidy_movie" -> base provider "vidy"
    base_id = provider_id.split("_")[0] if "_" in provider_id else provider_id
    provider = provider_registry.get_provider(base_id)
    if provider is None:
        provider = provider_registry.get_provider("vidy") or StreamProviderConfig(
            id="vidy",
            name="Vidy",
            category="movies_tv",
            base_url="https://vidy.st",
            embed_pattern="https://www.vidy.st/embed/{media_type}/{id}",
            search_type="tmdb",
        )

    pid = provider.id

    # 1. Direct route matching
    m_movie = DIRECT_MOVIE_RE.match(clean_q)
    if m_movie:
        mid = m_movie.group(1)
        return [
            VideoOut(
                youtube_id=f"{pid}:movie:{mid}",
                title=f"Movie {mid}",
                channel="Movie Stream",
                duration_s=7200,
                topic="Direct Stream",
                thumbnail="https://vidy.st/favicon.svg",
                match=99,
                provider=pid,
                media_type="movie",
            )
        ]

    m_tv = DIRECT_TV_RE.match(clean_q)
    if m_tv:
        tid = m_tv.group(1)
        s = int(m_tv.group(2) or 1)
        e = int(m_tv.group(3) or 1)
        return [
            VideoOut(
                youtube_id=f"{pid}:tv:{tid}/{s}/{e}",
                title=f"TV Series {tid} S{s}E{e}",
                channel="TV Stream",
                duration_s=2700,
                topic="Direct Stream",
                thumbnail="https://vidy.st/favicon.svg",
                match=99,
                provider=pid,
                media_type="tv",
                season=s,
                episode=e,
            )
        ]

    m_anime = DIRECT_ANIME_RE.match(clean_q)
    if m_anime:
        aid = m_anime.group(1)
        ep = int(m_anime.group(2) or 1)
        return [
            VideoOut(
                youtube_id=f"{pid}:anime:{aid}/{ep}",
                title=f"Anime {aid} EP {ep}",
                channel="Anime Stream",
                duration_s=1440,
                topic="Direct Stream",
                thumbnail="https://vidy.st/favicon.svg",
                match=99,
                provider=pid,
                media_type="anime",
                episode=ep,
            )
        ]

    # 2. Title search: AniList for anime sources, TMDB for movie/TV sources, and the
    # built-in titles only when they genuinely match. Nothing found -> nothing returned.
    is_anime = provider.search_type == "anilist" or provider.category == "anime"
    if is_anime or "anime" in clean_q.lower():
        anime_items = await search_anilist(clean_q)
        if anime_items or is_anime:
            return _rebrand(anime_items, pid)

    items = await search_tmdb(clean_q, tmdb_kind(provider_id))
    return _rebrand(items or search_curated_vidy(clean_q, source=provider_id), pid)


def _rebrand(items: list[VideoOut], pid: str) -> list[VideoOut]:
    """Re-label results (built as vidy:...) for the chosen provider."""
    return [
        v.model_copy(update={"youtube_id": v.youtube_id.replace("vidy:", f"{pid}:", 1), "provider": pid})
        for v in items
    ]
