"""Vidy media resolution service (Movies, TV Shows, and Anime).

Supports:
- AniList GraphQL API (free, open, no auth) for Anime.
- TMDB API (if OTT_TMDB_API_KEY is configured) + Curated Entertainment Catalog for Movies & TV.
- Direct ID / route syntax (e.g. "movie 315162", "tv 1396 1 1", "anime 21 1").
"""

import logging
import re
from typing import Literal

import httpx

from app.config import get_settings
from app.videos.router import VideoOut

log = logging.getLogger("ott_ai.vidy")

ANILIST_GRAPHQL_URL = "https://graphql.anilist.co"
ANILIST_QUERY = """
query ($search: String) {
  Page(page: 1, perPage: 6) {
    media(search: $search, type: ANIME, sort: POPULARITY_DESC) {
      id
      title {
        english
        romaji
        native
      }
      coverImage {
        large
        medium
      }
      episodes
      duration
      description
      genres
      averageScore
    }
  }
}
"""

# Curated catalog of iconic titles with authentic TMDB IDs and artwork
CURATED_VIDY_TITLES = [
    # Movies
    {
        "id": "vidy:movie:315162",
        "title": "Puss in Boots: The Last Wish",
        "channel": "Universal Pictures",
        "duration_s": 6120,
        "topic": "Animation • Adventure",
        "thumbnail": "https://image.tmdb.org/t/p/w500/kuf6dutpsT0vSVgvicvEZI76VTT.jpg",
        "provider": "vidy",
        "media_type": "movie",
    },
    {
        "id": "vidy:movie:27205",
        "title": "Inception",
        "channel": "Warner Bros. Pictures",
        "duration_s": 8880,
        "topic": "Sci-Fi • Action",
        "thumbnail": "https://image.tmdb.org/t/p/w500/oYuLEt3zVCKq57qu2F8dT7NIa6f.jpg",
        "provider": "vidy",
        "media_type": "movie",
    },
    {
        "id": "vidy:movie:157336",
        "title": "Interstellar",
        "channel": "Paramount Pictures",
        "duration_s": 10140,
        "topic": "Sci-Fi • Drama",
        "thumbnail": "https://image.tmdb.org/t/p/w500/gEU2QniE6E77NI6lCU6MxlNBvIx.jpg",
        "provider": "vidy",
        "media_type": "movie",
    },
    {
        "id": "vidy:movie:155",
        "title": "The Dark Knight",
        "channel": "Warner Bros. Pictures",
        "duration_s": 9120,
        "topic": "Action • Crime",
        "thumbnail": "https://image.tmdb.org/t/p/w500/qJ2tW6WMUDux911r6m7haRef0WH.jpg",
        "provider": "vidy",
        "media_type": "movie",
    },
    {
        "id": "vidy:movie:569094",
        "title": "Spider-Man: Across the Spider-Verse",
        "channel": "Sony Pictures",
        "duration_s": 8400,
        "topic": "Animation • Action",
        "thumbnail": "https://image.tmdb.org/t/p/w500/8Vt6mWEReuy4Of61Lnj5Xj704m8.jpg",
        "provider": "vidy",
        "media_type": "movie",
    },
    {
        "id": "vidy:movie:872585",
        "title": "Oppenheimer",
        "channel": "Universal Pictures",
        "duration_s": 10800,
        "topic": "Drama • History",
        "thumbnail": "https://image.tmdb.org/t/p/w500/8Gxv8gSFCU0XGDykEGv7zR1n2ua.jpg",
        "provider": "vidy",
        "media_type": "movie",
    },
    {
        "id": "vidy:movie:693134",
        "title": "Dune: Part Two",
        "channel": "Warner Bros. Pictures",
        "duration_s": 9960,
        "topic": "Sci-Fi • Adventure",
        "thumbnail": "https://image.tmdb.org/t/p/w500/1pdfLvkbY9ohJlCjQH2CZjjYVvJ.jpg",
        "provider": "vidy",
        "media_type": "movie",
    },
    {
        "id": "vidy:movie:603",
        "title": "The Matrix",
        "channel": "Warner Bros. Pictures",
        "duration_s": 8160,
        "topic": "Action • Sci-Fi",
        "thumbnail": "https://image.tmdb.org/t/p/w500/f89U3ADr1oiB1s9GkdPOEpXUk5H.jpg",
        "provider": "vidy",
        "media_type": "movie",
    },
    # TV Series
    {
        "id": "vidy:tv:1396/1/1",
        "title": "Breaking Bad",
        "channel": "AMC • Season 1 Episode 1",
        "duration_s": 3480,
        "topic": "Crime • Drama",
        "thumbnail": "https://image.tmdb.org/t/p/w500/ztkUQFLlC19CCMYHW9o1zWhJRNq.jpg",
        "provider": "vidy",
        "media_type": "tv",
        "season": 1,
        "episode": 1,
    },
    {
        "id": "vidy:tv:66732/1/1",
        "title": "Stranger Things",
        "channel": "Netflix • Season 1 Episode 1",
        "duration_s": 3000,
        "topic": "Sci-Fi • Horror",
        "thumbnail": "https://image.tmdb.org/t/p/w500/49WJfeN0moxb9IPfGn8AIqMGskD.jpg",
        "provider": "vidy",
        "media_type": "tv",
        "season": 1,
        "episode": 1,
    },
    {
        "id": "vidy:tv:100088/1/1",
        "title": "The Last of Us",
        "channel": "HBO • Season 1 Episode 1",
        "duration_s": 4800,
        "topic": "Drama • Sci-Fi",
        "thumbnail": "https://image.tmdb.org/t/p/w500/uKvVjHNqB5VmOrdxqAt2V7JMrRI.jpg",
        "provider": "vidy",
        "media_type": "tv",
        "season": 1,
        "episode": 1,
    },
    {
        "id": "vidy:tv:94605/1/1",
        "title": "Arcane",
        "channel": "Netflix • Season 1 Episode 1",
        "duration_s": 2400,
        "topic": "Animation • Action",
        "thumbnail": "https://image.tmdb.org/t/p/w500/fqldf2t8ztc9aiwn397FvFeNz9H.jpg",
        "provider": "vidy",
        "media_type": "tv",
        "season": 1,
        "episode": 1,
    },
    {
        "id": "vidy:tv:70523/1/1",
        "title": "Chernobyl",
        "channel": "HBO • Episode 1",
        "duration_s": 3600,
        "topic": "Drama • History",
        "thumbnail": "https://image.tmdb.org/t/p/w500/hlLXt2tOPT6RRnjiUmoxyG9LTFi.jpg",
        "provider": "vidy",
        "media_type": "tv",
        "season": 1,
        "episode": 1,
    },
    {
        "id": "vidy:tv:93405/1/1",
        "title": "Severance",
        "channel": "Apple TV+ • Season 1 Episode 1",
        "duration_s": 3300,
        "topic": "Sci-Fi • Thriller",
        "thumbnail": "https://image.tmdb.org/t/p/w500/h2tP6hN95F9V0sI9fV9kM65b7Xy.jpg",
        "provider": "vidy",
        "media_type": "tv",
        "season": 1,
        "episode": 1,
    },
]


async def search_anilist(query: str) -> list[VideoOut]:
    """Search anime via AniList GraphQL public API."""
    clean_q = re.sub(r"\b(anime|stream|watch|episode|ep)\b", "", query, flags=re.IGNORECASE).strip()
    if not clean_q:
        clean_q = query.strip()
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.post(
                ANILIST_GRAPHQL_URL,
                json={"query": ANILIST_QUERY, "variables": {"search": clean_q}},
            )
            if resp.status_code != 200:
                return []
            data = resp.json().get("data", {}).get("Page", {}).get("media", [])
            out = []
            for item in data:
                anime_id = item.get("id")
                if not anime_id:
                    continue
                title_obj = item.get("title") or {}
                title = title_obj.get("english") or title_obj.get("romaji") or "Anime"
                cover = (item.get("coverImage") or {}).get("large") or "https://vidy.st/favicon.svg"
                episodes = item.get("episodes") or 1
                duration_m = item.get("duration") or 24
                genres = " • ".join(item.get("genres", [])[:2]) or "Anime"
                score = item.get("averageScore")
                out.append(
                    VideoOut(
                        youtube_id=f"vidy:anime:{anime_id}/1",
                        title=title,
                        channel=f"AniList • {episodes} Ep",
                        duration_s=duration_m * 60,
                        topic=genres,
                        thumbnail=cover,
                        match=int(score) if score else 95,
                        provider="vidy",
                        media_type="anime",
                        season=1,
                        episode=1,
                    )
                )
            return out
    except Exception as e:
        log.warning("AniList search failed for '%s': %s", query, e)
        return []


async def search_tmdb(query: str, api_key: str) -> list[VideoOut]:
    """Search movies and TV shows via TMDB API if key is provided."""
    if not api_key:
        return []
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(
                "https://api.themoviedb.org/3/search/multi",
                params={"api_key": api_key, "query": query, "include_adult": "false"},
            )
            if resp.status_code != 200:
                return []
            results = resp.json().get("results", [])
            out = []
            for r in results:
                mtype = r.get("media_type")
                if mtype not in ("movie", "tv"):
                    continue
                mid = r.get("id")
                title = r.get("title") or r.get("name") or "Title"
                poster_path = r.get("poster_path")
                poster = (
                    f"https://image.tmdb.org/t/p/w500{poster_path}"
                    if poster_path
                    else "https://vidy.st/favicon.svg"
                )
                vote = r.get("vote_average", 0)
                match_pct = int(min(99, max(50, vote * 10))) if vote else None
                if mtype == "movie":
                    vid = f"vidy:movie:{mid}"
                    channel = "TMDB Movie"
                else:
                    vid = f"vidy:tv:{mid}/1/1"
                    channel = "TMDB Series • S1 E1"

                out.append(
                    VideoOut(
                        youtube_id=vid,
                        title=title,
                        channel=channel,
                        duration_s=7200 if mtype == "movie" else 3000,
                        topic=f"{mtype.title()} • TMDB",
                        thumbnail=poster,
                        match=match_pct,
                        provider="vidy",
                        media_type=mtype,
                        season=1 if mtype == "tv" else None,
                        episode=1 if mtype == "tv" else None,
                    )
                )
            return out
    except Exception as e:
        log.warning("TMDB API search failed for '%s': %s", query, e)
        return []


def search_curated_vidy(query: str, source: str = "vidy") -> list[VideoOut]:
    """Search built-in curated titles using token overlap."""
    tokens = set(re.findall(r"\w+", query.lower()))
    is_anime_source = source in ("vidy_anime", "anime")
    is_tv_source = source in ("vidy_tv", "tv")
    is_movie_source = source in ("vidy_movie", "movie")

    scored: list[tuple[dict, float]] = []
    for item in CURATED_VIDY_TITLES:
        if is_anime_source and item["media_type"] != "anime":
            continue
        if is_tv_source and item["media_type"] != "tv":
            continue
        if is_movie_source and item["media_type"] != "movie":
            continue

        item_tokens = set(re.findall(r"\w+", f"{item['title']} {item['topic']} {item['channel']}".lower()))
        overlap = len(tokens & item_tokens)
        score = overlap / max(1, len(tokens))
        if overlap > 0:
            scored.append((item, score))

    scored.sort(key=lambda x: x[1], reverse=True)
    if not scored:
        # Fallback to top curated titles
        scored = [(item, 0.9) for item in CURATED_VIDY_TITLES[:5]]

    return [
        VideoOut(
            youtube_id=item["id"],
            title=item["title"],
            channel=item["channel"],
            duration_s=item["duration_s"],
            topic=item["topic"],
            thumbnail=item["thumbnail"],
            match=int(round(min(99, max(70, score * 100)))),
            provider=item["provider"],
            media_type=item["media_type"],
            season=item.get("season"),
            episode=item.get("episode"),
        )
        for item, score in scored[:6]
    ]


async def search_vidy(query: str, source: str = "vidy") -> list[VideoOut]:
    """Unified entry point for Vidy media searches."""
    q = query.strip()
    if not q:
        return []

    # Check for direct route commands e.g. "movie 315162", "tv 1396 1 1", "anime 21 1"
    direct_match = re.match(
        r"^(?:vidy:)?(movie|tv|anime)(?:\s+|:)(\d+)(?:(?:\s+|/)(\d+))?(?:(?:\s+|/)(\d+))?$",
        q,
        re.IGNORECASE,
    )
    if direct_match:
        mtype = direct_match.group(1).lower()
        mid = direct_match.group(2)
        if mtype == "anime":
            s = 1
            e = int(direct_match.group(3) or 1)
            target_id = f"vidy:anime:{mid}/{e}"
            channel = f"Anime • Ep {e}"
        elif mtype == "tv":
            s = int(direct_match.group(3) or 1)
            e = int(direct_match.group(4) or 1)
            target_id = f"vidy:tv:{mid}/{s}/{e}"
            channel = f"Series • S{s} E{e}"
        else:
            s = 1
            e = 1
            target_id = f"vidy:movie:{mid}"
            channel = "Movie"

        return [
            VideoOut(
                youtube_id=target_id,
                title=f"{mtype.title()} {mid}",
                channel=channel,
                duration_s=7200 if mtype == "movie" else 2400,
                topic="Direct Stream",
                thumbnail="https://vidy.st/favicon.svg",
                match=99,
                provider="vidy",
                media_type=mtype,
                season=s if mtype == "tv" else None,
                episode=e if mtype in ("tv", "anime") else None,
            )
        ]

    # If anime requested, check AniList first
    if "anime" in q.lower() or source in ("vidy_anime", "anime"):
        anime_results = await search_anilist(q)
        if anime_results:
            return anime_results

    # If TMDB API key available, search TMDB
    settings = get_settings()
    tmdb_key = getattr(settings, "tmdb_api_key", "")
    if tmdb_key:
        tmdb_results = await search_tmdb(q, tmdb_key)
        if tmdb_results:
            return tmdb_results

    # Fall back to curated library + AniList
    curated = search_curated_vidy(q, source)
    if curated and any(t in q.lower() for t in ("movie", "puss", "inception", "interstellar", "breaking", "stranger", "batman", "dune", "matrix", "arcane", "last")):
        return curated

    # Try AniList as dynamic fallback
    anime_dynamic = await search_anilist(q)
    if anime_dynamic:
        return anime_dynamic

    return curated
