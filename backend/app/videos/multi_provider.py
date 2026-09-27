import logging
import re
from typing import Any

from app.videos.provider_pipeline import StreamProviderConfig, provider_registry
from app.videos.router import VideoOut
from app.videos.vidy import search_anilist, search_curated_vidy, search_tmdb

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

    # 2. Search based on provider search_type
    results: list[VideoOut] = []

    if provider.search_type == "anilist" or provider.category == "anime" or "anime" in clean_q.lower():
        anime_items = await search_anilist(clean_q)
        if anime_items:
            # Rebrand provider ID on items
            results = [
                VideoOut(
                    youtube_id=v.youtube_id.replace("vidy:", f"{pid}:"),
                    title=v.title,
                    channel=v.channel,
                    duration_s=v.duration_s,
                    topic=v.topic,
                    thumbnail=v.thumbnail,
                    match=v.match,
                    provider=pid,
                    media_type=v.media_type,
                    season=v.season,
                    episode=v.episode,
                )
                for v in anime_items
            ]
            return results

    # TMDB or fallback
    from app.config import get_settings
    settings = get_settings()
    tmdb_key = getattr(settings, "tmdb_api_key", "")
    if tmdb_key:
        tmdb_items = await search_tmdb(clean_q, tmdb_key)
        if tmdb_items:
            results = [
                VideoOut(
                    youtube_id=v.youtube_id.replace("vidy:", f"{pid}:"),
                    title=v.title,
                    channel=v.channel,
                    duration_s=v.duration_s,
                    topic=v.topic,
                    thumbnail=v.thumbnail,
                    match=v.match,
                    provider=pid,
                    media_type=v.media_type,
                    season=v.season,
                    episode=v.episode,
                )
                for v in tmdb_items
            ]
            return results

    # Fallback to curated library
    curated = search_curated_vidy(clean_q, source=provider_id)
    if curated:
        results = [
            VideoOut(
                youtube_id=v.youtube_id.replace("vidy:", f"{pid}:"),
                title=v.title,
                channel=v.channel,
                duration_s=v.duration_s,
                topic=v.topic,
                thumbnail=v.thumbnail,
                match=v.match,
                provider=pid,
                media_type=v.media_type,
                season=v.season,
                episode=v.episode,
            )
            for v in curated
        ]
        return results

    # Fallback to AniList
    dynamic_anime = await search_anilist(clean_q)
    if dynamic_anime:
        return [
            VideoOut(
                youtube_id=v.youtube_id.replace("vidy:", f"{pid}:"),
                title=v.title,
                channel=v.channel,
                duration_s=v.duration_s,
                topic=v.topic,
                thumbnail=v.thumbnail,
                match=v.match,
                provider=pid,
                media_type=v.media_type,
                season=v.season,
                episode=v.episode,
            )
            for v in dynamic_anime
        ]

    return []
