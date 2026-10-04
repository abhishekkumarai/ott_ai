"""Vidy media resolution service (Movies, TV Shows, and Anime).

Supports:
- AniList GraphQL API (free, open, no auth) for Anime.
- TMDB API (if a TMDB key or read token is configured) + Curated Entertainment Catalog for Movies & TV.
- Direct ID / route syntax (e.g. "movie 315162", "tv 1396 1 1", "anime 21 1").
"""

import logging
import re
import time
from typing import Literal

import httpx

from app.config import get_settings
from app.videos.router import EpisodeOut, SeasonInfo, SeriesEpisodesOut, VideoOut

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


TMDB_BASE = "https://api.themoviedb.org/3"
TMDB_IMG = "https://image.tmdb.org/t/p/w500"
TMDB_CACHE_TTL_S = 600
TMDB_CACHE_MAX = 256
# Some networks reset TLS handshakes to TMDB intermittently; these are cheap to retry.
TMDB_ATTEMPTS = 3
# Words people wrap around a title that are not part of it ("watch dune 2021 movie").
TITLE_FILLER = {
    "watch", "stream", "streaming", "play", "movie", "movies", "film", "films", "show",
    "shows", "series", "tv", "season", "episode", "ep", "full", "online", "free", "hd",
    "the", "a", "an", "of", "please", "me", "find", "search", "for", "want", "to", "i",
}
# Trimmed from the ends of a query; articles stay since they belong to titles.
EDGE_FILLER = TITLE_FILLER - {"the", "a", "an"}
YEAR_RE = re.compile(r"\b(19[0-9]{2}|20[0-9]{2})\b")
TmdbKind = Literal["multi", "movie", "tv"]

_tmdb_cache: dict[tuple, tuple[float, list[VideoOut]]] = {}


def _words(s: str) -> list[str]:
    return re.findall(r"\w+", s.lower())


def clean_title_query(query: str) -> tuple[str, int | None]:
    """Split a free-text request into (title text, year). Leading and trailing filler
    words are dropped ("watch dune 2021 movie" -> "dune", 2021); inner words are kept
    so "the office" or "a quiet place" survive."""
    q = query.strip()
    m = YEAR_RE.search(q)
    year = int(m.group(1)) if m else None
    if m:
        q = (q[: m.start()] + " " + q[m.end():]).strip()
    words = q.split()
    while len(words) > 1 and words[0].lower().strip(".,!?") in EDGE_FILLER:
        words.pop(0)
    while len(words) > 1 and words[-1].lower().strip(".,!?") in EDGE_FILLER:
        words.pop()
    cleaned = " ".join(words).strip(" .,!?") or query.strip()
    return cleaned[:120], year


def title_similarity(query: str, title: str) -> float:
    """0..1: how well a title matches the words asked for, ignoring filler words."""
    qw = [w for w in _words(query) if w not in TITLE_FILLER] or _words(query)
    tw = [w for w in _words(title) if w not in TITLE_FILLER] or _words(title)
    if not qw or not tw:
        return 0.0
    if qw == tw:
        return 1.0
    shared = len(set(qw) & set(tw))
    if not shared:
        return 0.0
    recall = shared / len(set(qw))
    precision = shared / len(set(tw))
    return round(0.95 * (0.75 * recall + 0.25 * precision), 3)


def _tmdb_auth() -> tuple[dict[str, str], dict[str, str]] | None:
    """(headers, params) for TMDB: the v4 read token if set, else the v3 key."""
    s = get_settings()
    if s.tmdb_read_token:
        return {"Authorization": f"Bearer {s.tmdb_read_token}"}, {}
    if s.tmdb_api_key:
        return {}, {"api_key": s.tmdb_api_key}
    return None


async def tmdb_get(client: httpx.AsyncClient, path: str, params: dict | None = None) -> dict | None:
    """GET a TMDB v3 path. None when TMDB is not configured or the call fails."""
    auth = _tmdb_auth()
    if auth is None:
        return None
    headers, base = auth
    resp = None
    for attempt in range(TMDB_ATTEMPTS):
        try:
            resp = await client.get(f"{TMDB_BASE}{path}", params={**base, **(params or {})}, headers=headers)
            break
        except (httpx.ConnectError, httpx.TimeoutException) as e:
            if attempt == TMDB_ATTEMPTS - 1:
                log.warning("TMDB %s failed after %d tries: %s", path, TMDB_ATTEMPTS, type(e).__name__)
                return None
        except httpx.HTTPError as e:
            log.warning("TMDB %s failed: %s", path, type(e).__name__)
            return None
    if resp is None:
        return None
    if resp.status_code != 200:
        log.warning("TMDB %s returned HTTP %s", path, resp.status_code)
        return None
    try:
        return resp.json()
    except ValueError:
        log.warning("TMDB %s returned invalid JSON", path)
        return None


def _release_year(r: dict) -> int | None:
    d = r.get("release_date") or r.get("first_air_date") or ""
    return int(d[:4]) if len(d) >= 4 and d[:4].isdigit() else None


async def search_tmdb(query: str, kind: TmdbKind = "multi", limit: int = 12) -> list[VideoOut]:
    """Title search on TMDB, ranked by how well each title matches what was asked.

    `kind` narrows to movies or TV. A year in the query filters movies/TV (retrying
    without it if that finds nothing) and breaks ties for multi-search."""
    if _tmdb_auth() is None:
        return []
    title, year = clean_title_query(query)
    if not title:
        return []
    key = (kind, title.lower(), year)
    now = time.monotonic()
    hit = _tmdb_cache.get(key)
    if hit and now - hit[0] < TMDB_CACHE_TTL_S:
        return list(hit[1])

    params: dict[str, str | int] = {"query": title, "include_adult": "false"}
    year_param = {"movie": "year", "tv": "first_air_date_year"}.get(kind)
    if year and year_param:
        params[year_param] = year
    async with httpx.AsyncClient(timeout=5.0) as client:
        data = await tmdb_get(client, f"/search/{kind}", params)
        if data is None:
            return []
        results = data.get("results") or []
        if not results and year_param and year_param in params:
            params.pop(year_param)
            results = (await tmdb_get(client, f"/search/{kind}", params) or {}).get("results") or []

    ranked: list[tuple[float, bool, int, VideoOut]] = []
    for order, r in enumerate(results):
        if not isinstance(r, dict):
            continue
        mtype = r.get("media_type") or kind
        mid = r.get("id")
        name = r.get("title") or r.get("name") or ""
        if mtype not in ("movie", "tv") or not isinstance(mid, int) or not name:
            continue
        original = r.get("original_title") or r.get("original_name") or ""
        score = max(title_similarity(title, name), title_similarity(title, original))
        ry = _release_year(r)
        poster = f"{TMDB_IMG}{r['poster_path']}" if r.get("poster_path") else "https://vidy.st/favicon.svg"
        label = "Movie" if mtype == "movie" else "Series"
        ranked.append(
            (
                score,
                bool(year) and ry != year,
                order,
                VideoOut(
                    youtube_id=f"vidy:movie:{mid}" if mtype == "movie" else f"vidy:tv:{mid}/1/1",
                    title=name,
                    channel="TMDB Movie" if mtype == "movie" else "TMDB Series • S1 E1",
                    duration_s=7200 if mtype == "movie" else 3000,
                    topic=f"{label} • {ry}" if ry else label,
                    thumbnail=poster,
                    match=int(round(50 + 49 * score)),
                    provider="vidy",
                    media_type=mtype,
                    season=1 if mtype == "tv" else None,
                    episode=1 if mtype == "tv" else None,
                ),
            )
        )
    # Best title match first, then the asked-for year, then TMDB's own
    # popularity-aware order.
    ranked.sort(key=lambda x: (-x[0], x[1], x[2]))
    out = [v for *_, v in ranked[:limit]]

    if len(_tmdb_cache) >= TMDB_CACHE_MAX:
        _tmdb_cache.pop(next(iter(_tmdb_cache)))
    _tmdb_cache[key] = (now, out)
    return list(out)


def search_curated_vidy(query: str, source: str = "vidy") -> list[VideoOut]:
    """Offline fallback: the built-in titles whose *title* matches the query.

    Generic words ("movie", "the", "series") never count, so a vague query returns
    nothing rather than the same few defaults."""
    title_q, _ = clean_title_query(query)
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
        score = title_similarity(title_q, item["title"])
        if score >= 0.5:
            scored.append((item, score))

    scored.sort(key=lambda x: x[1], reverse=True)
    return [
        VideoOut(
            youtube_id=item["id"],
            title=item["title"],
            channel=item["channel"],
            duration_s=item["duration_s"],
            topic=item["topic"],
            thumbnail=item["thumbnail"],
            match=int(round(50 + 49 * score)),
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

    tmdb_results = await search_tmdb(q, tmdb_kind(source))
    if tmdb_results:
        return tmdb_results

    # TMDB off or empty: only built-in titles that really match. (AniList is for
    # anime requests above; here it would return unrelated anime.)
    return search_curated_vidy(q, source)


def tmdb_kind(source: str) -> TmdbKind:
    """Which TMDB search a source wants: "rive_movie" / "movie" are movie-only,
    "vidy_tv" / "tv" TV-only, anything else both."""
    suffix = source.rsplit("_", 1)[-1]
    if suffix == "movie":
        return "movie"
    if suffix == "tv":
        return "tv"
    return "multi"


CURATED_TV_EPISODES: dict[str, dict] = {
    "1396": {
        "title": "Breaking Bad",
        "seasons": [
            {"season_number": 1, "name": "Season 1", "episode_count": 7},
            {"season_number": 2, "name": "Season 2", "episode_count": 13},
            {"season_number": 3, "name": "Season 3", "episode_count": 13},
            {"season_number": 4, "name": "Season 4", "episode_count": 13},
            {"season_number": 5, "name": "Season 5", "episode_count": 16},
        ],
        "episodes": {
            1: [
                {"number": 1, "title": "Pilot", "duration_s": 3480, "overview": "When an unassuming chemistry teacher is diagnosed with cancer, he starts cooking meth.", "still": "https://image.tmdb.org/t/p/w500/ztkUQFLlC19CCMYHW9o1zWhJRNq.jpg"},
                {"number": 2, "title": "Cat's in the Bag...", "duration_s": 2880, "overview": "Walt and Jesse attempt to dispose of two bodies in an unconventional manner.", "still": "https://image.tmdb.org/t/p/w500/ztkUQFLlC19CCMYHW9o1zWhJRNq.jpg"},
                {"number": 3, "title": "...And the Bag's in the River", "duration_s": 2880, "overview": "Walt faces a moral dilemma involving Krazy-8.", "still": "https://image.tmdb.org/t/p/w500/ztkUQFLlC19CCMYHW9o1zWhJRNq.jpg"},
                {"number": 4, "title": "Cancer Man", "duration_s": 2880, "overview": "Walt tells his family about his cancer diagnosis at a barbecue.", "still": "https://image.tmdb.org/t/p/w500/ztkUQFLlC19CCMYHW9o1zWhJRNq.jpg"},
                {"number": 5, "title": "Gray Matter", "duration_s": 2880, "overview": "Walt attends a former business partner's birthday party.", "still": "https://image.tmdb.org/t/p/w500/ztkUQFLlC19CCMYHW9o1zWhJRNq.jpg"},
                {"number": 6, "title": "Crazy Handful of Nothin'", "duration_s": 2940, "overview": "The side effects of chemotherapy begin to take a toll on Walt; Heisenberg is born.", "still": "https://image.tmdb.org/t/p/w500/ztkUQFLlC19CCMYHW9o1zWhJRNq.jpg"},
                {"number": 7, "title": "A No-Rough-Stuff-Type Deal", "duration_s": 2820, "overview": "Walt and Jesse make a deal with Tuco Salamanca.", "still": "https://image.tmdb.org/t/p/w500/ztkUQFLlC19CCMYHW9o1zWhJRNq.jpg"},
            ]
        },
    },
    "66732": {
        "title": "Stranger Things",
        "seasons": [
            {"season_number": 1, "name": "Season 1", "episode_count": 8},
            {"season_number": 2, "name": "Season 2", "episode_count": 9},
            {"season_number": 3, "name": "Season 3", "episode_count": 8},
            {"season_number": 4, "name": "Season 4", "episode_count": 9},
        ],
        "episodes": {
            1: [
                {"number": 1, "title": "Chapter One: The Vanishing of Will Byers", "duration_s": 2880, "overview": "On his way home from a friend's house, young Will sees something terrifying.", "still": "https://image.tmdb.org/t/p/w500/49WJfeN0moxb9IPfGn8AIqMGskD.jpg"},
                {"number": 2, "title": "Chapter Two: The Weirdo on Maple Street", "duration_s": 3300, "overview": "Lucas, Mike and Dustin try to talk to the girl they found in the woods.", "still": "https://image.tmdb.org/t/p/w500/49WJfeN0moxb9IPfGn8AIqMGskD.jpg"},
                {"number": 3, "title": "Chapter Three: Holly, Jolly", "duration_s": 3120, "overview": "An increasingly frantic Joyce believes Will is communicating through Christmas lights.", "still": "https://image.tmdb.org/t/p/w500/49WJfeN0moxb9IPfGn8AIqMGskD.jpg"},
                {"number": 4, "title": "Chapter Four: The Body", "duration_s": 3000, "overview": "Refusing to believe Will is dead, Joyce tries to connect with her son.", "still": "https://image.tmdb.org/t/p/w500/49WJfeN0moxb9IPfGn8AIqMGskD.jpg"},
                {"number": 5, "title": "Chapter Five: The Flea and the Acrobat", "duration_s": 3180, "overview": "Hopper breaks into the lab while Mike and the boys ask Mr. Clarke about parallel dimensions.", "still": "https://image.tmdb.org/t/p/w500/49WJfeN0moxb9IPfGn8AIqMGskD.jpg"},
                {"number": 6, "title": "Chapter Six: The Monster", "duration_s": 2820, "overview": "Jonathan searches for Nancy in the darkness, but Steve's looking for her too.", "still": "https://image.tmdb.org/t/p/w500/49WJfeN0moxb9IPfGn8AIqMGskD.jpg"},
                {"number": 7, "title": "Chapter Seven: The Bathtub", "duration_s": 2520, "overview": "El uses her powers to seek out the Upside Down while government agents close in.", "still": "https://image.tmdb.org/t/p/w500/49WJfeN0moxb9IPfGn8AIqMGskD.jpg"},
                {"number": 8, "title": "Chapter Eight: The Upside Down", "duration_s": 3300, "overview": "Jim and Joyce head into the Upside Down to rescue Will.", "still": "https://image.tmdb.org/t/p/w500/49WJfeN0moxb9IPfGn8AIqMGskD.jpg"},
            ]
        },
    },
    "100088": {
        "title": "The Last of Us",
        "seasons": [
            {"season_number": 1, "name": "Season 1", "episode_count": 9},
        ],
        "episodes": {
            1: [
                {"number": 1, "title": "When You're Lost in the Darkness", "duration_s": 4860, "overview": "Twenty years after a fungal outbreak ravages the planet, Joel and Tess are tasked with a mission that could change everything.", "still": "https://image.tmdb.org/t/p/w500/uKvVjHNqB5VmOrdxqAt2V7JMrRI.jpg"},
                {"number": 2, "title": "Infected", "duration_s": 3180, "overview": "Joel, Tess, and Ellie navigate through an abandoned and flooded Boston hotel.", "still": "https://image.tmdb.org/t/p/w500/uKvVjHNqB5VmOrdxqAt2V7JMrRI.jpg"},
                {"number": 3, "title": "Long, Long Time", "duration_s": 4500, "overview": "When a stranger approaches his compound, survivalist Bill forges an unlikely connection.", "still": "https://image.tmdb.org/t/p/w500/uKvVjHNqB5VmOrdxqAt2V7JMrRI.jpg"},
                {"number": 4, "title": "Please Hold to My Hand", "duration_s": 2700, "overview": "Joel and Ellie travel through Kansas City and encounter a ruthless rebel leader.", "still": "https://image.tmdb.org/t/p/w500/uKvVjHNqB5VmOrdxqAt2V7JMrRI.jpg"},
                {"number": 5, "title": "Endure and Survive", "duration_s": 3540, "overview": "Joel and Ellie team up with brothers Henry and Sam to escape Kansas City.", "still": "https://image.tmdb.org/t/p/w500/uKvVjHNqB5VmOrdxqAt2V7JMrRI.jpg"},
                {"number": 6, "title": "Kin", "duration_s": 3540, "overview": "Joel reunites with his brother Tommy in Wyoming.", "still": "https://image.tmdb.org/t/p/w500/uKvVjHNqB5VmOrdxqAt2V7JMrRI.jpg"},
                {"number": 7, "title": "Left Behind", "duration_s": 3360, "overview": "As Joel fights to survive, Ellie remembers the night that changed her life forever.", "still": "https://image.tmdb.org/t/p/w500/uKvVjHNqB5VmOrdxqAt2V7JMrRI.jpg"},
                {"number": 8, "title": "When We Are in Need", "duration_s": 3060, "overview": "Ellie crosses paths with a vengeful group of survivors.", "still": "https://image.tmdb.org/t/p/w500/uKvVjHNqB5VmOrdxqAt2V7JMrRI.jpg"},
                {"number": 9, "title": "Look for the Light", "duration_s": 2580, "overview": "Joel and Ellie reach Salt Lake City and the Fireflies' hospital base.", "still": "https://image.tmdb.org/t/p/w500/uKvVjHNqB5VmOrdxqAt2V7JMrRI.jpg"},
            ]
        },
    },
    "94605": {
        "title": "Arcane",
        "seasons": [
            {"season_number": 1, "name": "Season 1", "episode_count": 9},
            {"season_number": 2, "name": "Season 2", "episode_count": 9},
        ],
        "episodes": {
            1: [
                {"number": 1, "title": "Welcome to the Playground", "duration_s": 2580, "overview": "Orphaned sisters Vi and Powder lead a heist in Piltover's posh upper district.", "still": "https://image.tmdb.org/t/p/w500/fqldf2t8ztc9aiwn397FvFeNz9H.jpg"},
                {"number": 2, "title": "Some Mysteries Are Better Left Unsolved", "duration_s": 2640, "overview": "Idealistic inventor Jayce attempts to harness magic through science.", "still": "https://image.tmdb.org/t/p/w500/fqldf2t8ztc9aiwn397FvFeNz9H.jpg"},
                {"number": 3, "title": "The Base Violence Necessary for Change", "duration_s": 2640, "overview": "An epic showdown between old rivals brings fateful consequences.", "still": "https://image.tmdb.org/t/p/w500/fqldf2t8ztc9aiwn397FvFeNz9H.jpg"},
                {"number": 4, "title": "Happy Progress Day!", "duration_s": 2400, "overview": "With Piltover flourishing on their tech, Jayce and Viktor consider their next move.", "still": "https://image.tmdb.org/t/p/w500/fqldf2t8ztc9aiwn397FvFeNz9H.jpg"},
                {"number": 5, "title": "Everybody Wants to Be My Enemy", "duration_s": 2400, "overview": "Rogue enforcer Caitlyn tours the Undercity to track down Jinx.", "still": "https://image.tmdb.org/t/p/w500/fqldf2t8ztc9aiwn397FvFeNz9H.jpg"},
                {"number": 6, "title": "When These Walls Come Tumbling Down", "duration_s": 2520, "overview": "Vi and Caitlyn discover clues that point to a larger conspiracy.", "still": "https://image.tmdb.org/t/p/w500/fqldf2t8ztc9aiwn397FvFeNz9H.jpg"},
                {"number": 7, "title": "The Boy Savior", "duration_s": 2400, "overview": "Ekko reveals the truth about the Firelights.", "still": "https://image.tmdb.org/t/p/w500/fqldf2t8ztc9aiwn397FvFeNz9H.jpg"},
                {"number": 8, "title": "Oil and Water", "duration_s": 2400, "overview": "Disowned heir Mel and her visiting mother exchange combat philosophies.", "still": "https://image.tmdb.org/t/p/w500/fqldf2t8ztc9aiwn397FvFeNz9H.jpg"},
                {"number": 9, "title": "The Monster You Created", "duration_s": 2640, "overview": "Miraculously alive, Vi seeks out the final confrontation.", "still": "https://image.tmdb.org/t/p/w500/fqldf2t8ztc9aiwn397FvFeNz9H.jpg"},
            ]
        },
    },
    "70523": {
        "title": "Chernobyl",
        "seasons": [{"season_number": 1, "name": "Season 1", "episode_count": 5}],
        "episodes": {
            1: [
                {"number": 1, "title": "1:23:45", "duration_s": 3540, "overview": "Plant workers and firefighters risk their lives to control a catastrophic explosion at a Soviet nuclear plant.", "still": "https://image.tmdb.org/t/p/w500/hlLXt2tOPT6RRnjiUmoxyG9LTFi.jpg"},
                {"number": 2, "title": "Please Remain Calm", "duration_s": 3900, "overview": "With millions at risk, nuclear physicist Ulana Khomyuk desperately tries to warn Legasov.", "still": "https://image.tmdb.org/t/p/w500/hlLXt2tOPT6RRnjiUmoxyG9LTFi.jpg"},
                {"number": 3, "title": "Open Wide, O Earth", "duration_s": 3780, "overview": "Legasov outlines an evacuation plan while coal miners are drafted to dig a protective tunnel.", "still": "https://image.tmdb.org/t/p/w500/hlLXt2tOPT6RRnjiUmoxyG9LTFi.jpg"},
                {"number": 4, "title": "The Happiness of All Mankind", "duration_s": 3600, "overview": "Troops and liquidators remove radioactive debris while Ulana investigates the cause.", "still": "https://image.tmdb.org/t/p/w500/hlLXt2tOPT6RRnjiUmoxyG9LTFi.jpg"},
                {"number": 5, "title": "Vichnaya Pamyat", "duration_s": 4320, "overview": "Valery, Boris, and Ulana risk their lives and reputations to expose the truth.", "still": "https://image.tmdb.org/t/p/w500/hlLXt2tOPT6RRnjiUmoxyG9LTFi.jpg"},
            ]
        },
    },
    "93405": {
        "title": "Severance",
        "seasons": [{"season_number": 1, "name": "Season 1", "episode_count": 9}],
        "episodes": {
            1: [
                {"number": 1, "title": "Good News About Hell", "duration_s": 3420, "overview": "Mark Scout leads a team at Lumon Industries whose employees have undergone a severance procedure.", "still": "https://image.tmdb.org/t/p/w500/h2tP6hN95F9V0sI9fV9kM65b7Xy.jpg"},
                {"number": 2, "title": "Half Loop", "duration_s": 3180, "overview": "The team trains new hire Helly on macrodata refinement.", "still": "https://image.tmdb.org/t/p/w500/h2tP6hN95F9V0sI9fV9kM65b7Xy.jpg"},
                {"number": 3, "title": "In Perpetuity", "duration_s": 3240, "overview": "Mark takes the team on an excursion to the Perpetuity Wing.", "still": "https://image.tmdb.org/t/p/w500/h2tP6hN95F9V0sI9fV9kM65b7Xy.jpg"},
                {"number": 4, "title": "The You You Are", "duration_s": 3180, "overview": "Helly attempts aggressive measures to escape.", "still": "https://image.tmdb.org/t/p/w500/h2tP6hN95F9V0sI9fV9kM65b7Xy.jpg"},
                {"number": 5, "title": "The Grim Barbarity of Optics and Design", "duration_s": 3240, "overview": "Irving forms an unexpected connection in Optics and Design.", "still": "https://image.tmdb.org/t/p/w500/h2tP6hN95F9V0sI9fV9kM65b7Xy.jpg"},
                {"number": 6, "title": "Hide and Seek", "duration_s": 2400, "overview": "Cobel increases vigilance as Mark and his team begin asking questions.", "still": "https://image.tmdb.org/t/p/w500/h2tP6hN95F9V0sI9fV9kM65b7Xy.jpg"},
                {"number": 7, "title": "Defiant Jazz", "duration_s": 3060, "overview": "Milchick treats the refinement department to a Music Dance Experience.", "still": "https://image.tmdb.org/t/p/w500/h2tP6hN95F9V0sI9fV9kM65b7Xy.jpg"},
                {"number": 8, "title": "What's for Dinner?", "duration_s": 2700, "overview": "The team hatches an ambitious plan to wake their innies on the outside.", "still": "https://image.tmdb.org/t/p/w500/h2tP6hN95F9V0sI9fV9kM65b7Xy.jpg"},
                {"number": 9, "title": "The We We Are", "duration_s": 3420, "overview": "The overtime contingency is triggered, plunging the innies into the outside world.", "still": "https://image.tmdb.org/t/p/w500/h2tP6hN95F9V0sI9fV9kM65b7Xy.jpg"},
            ]
        },
    },
}


async def get_series_episodes(media_id: str, season: int | None = None) -> SeriesEpisodesOut | None:
    """Fetch episode list and season metadata for TV shows and Anime."""
    raw = media_id.strip()
    if not raw:
        return None

    # Matches "vidy:tv:1396/1/1", "vidy:tv:1396", "tv 1396 1 1", "vidy:anime:21/1", "vidy:anime:21", "anime 21 1"
    m = re.match(
        r"^(?:vidy:)?(tv|anime)(?::|\s+)([A-Za-z0-9_-]+)(?:(?:/|\s+)(\d+))?(?:(?:/|\s+)(\d+))?$",
        raw,
        re.IGNORECASE,
    )
    if not m:
        return None

    media_type = m.group(1).lower()
    series_id = m.group(2)
    s_arg = int(m.group(3)) if m.group(3) else None
    e_arg = int(m.group(4)) if m.group(4) else None

    if media_type == "tv":
        current_season = season or s_arg or 1
        current_episode = e_arg or 1

        # Check curated TV shows first
        if series_id in CURATED_TV_EPISODES:
            curated = CURATED_TV_EPISODES[series_id]
            title = curated["title"]
            seasons = [SeasonInfo(**s) for s in curated["seasons"]]
            ep_list = curated["episodes"].get(current_season)
            if ep_list:
                episodes = [
                    EpisodeOut(
                        youtube_id=f"vidy:tv:{series_id}/{current_season}/{e['number']}",
                        series_id=series_id,
                        series_title=title,
                        title=f"Episode {e['number']}: {e['title']}",
                        episode_number=e["number"],
                        season_number=current_season,
                        duration_s=e.get("duration_s", 2700),
                        thumbnail=e.get("still") or "https://vidy.st/favicon.svg",
                        overview=e.get("overview") or "",
                        provider="vidy",
                        media_type="tv",
                    )
                    for e in ep_list
                ]
            else:
                season_match = next((s for s in seasons if s.season_number == current_season), None)
                count = season_match.episode_count if season_match else 10
                episodes = [
                    EpisodeOut(
                        youtube_id=f"vidy:tv:{series_id}/{current_season}/{i}",
                        series_id=series_id,
                        series_title=title,
                        title=f"Episode {i}",
                        episode_number=i,
                        season_number=current_season,
                        duration_s=2700,
                        thumbnail="https://vidy.st/favicon.svg",
                        overview=f"Episode {i} of Season {current_season}",
                        provider="vidy",
                        media_type="tv",
                    )
                    for i in range(1, count + 1)
                ]
            return SeriesEpisodesOut(
                series_id=series_id,
                series_title=title,
                media_type="tv",
                current_season=current_season,
                current_episode=current_episode,
                seasons=seasons,
                episodes=episodes,
            )

        # Real seasons/episodes from TMDB when it is configured (ids are numeric)
        if series_id.isdigit() and get_settings().tmdb_enabled:
            try:
                async with httpx.AsyncClient(timeout=5.0) as client:
                    tv_data = await tmdb_get(client, f"/tv/{series_id}")
                    if tv_data is not None:
                        title = tv_data.get("name") or f"Series {series_id}"
                        raw_seasons = tv_data.get("seasons", [])
                        seasons = [
                            SeasonInfo(
                                season_number=s.get("season_number", 1),
                                name=s.get("name") or f"Season {s.get('season_number', 1)}",
                                episode_count=s.get("episode_count", 1),
                            )
                            for s in raw_seasons
                            if s.get("season_number", 0) > 0
                        ]
                        s_data = await tmdb_get(client, f"/tv/{series_id}/season/{current_season}")
                        if s_data is not None:
                            episodes = [
                                EpisodeOut(
                                    youtube_id=f"vidy:tv:{series_id}/{current_season}/{ep.get('episode_number', 1)}",
                                    series_id=series_id,
                                    series_title=title,
                                    title=f"Episode {ep.get('episode_number', 1)}: {ep.get('name', '')}",
                                    episode_number=ep.get("episode_number", 1),
                                    season_number=current_season,
                                    duration_s=(ep.get("runtime") or 45) * 60,
                                    thumbnail=(
                                        f"{TMDB_IMG}{ep['still_path']}"
                                        if ep.get("still_path")
                                        else (
                                            f"{TMDB_IMG}{tv_data['poster_path']}"
                                            if tv_data.get("poster_path")
                                            else "https://vidy.st/favicon.svg"
                                        )
                                    ),
                                    overview=ep.get("overview") or "",
                                    provider="vidy",
                                    media_type="tv",
                                )
                                for ep in s_data.get("episodes", [])
                            ]
                            return SeriesEpisodesOut(
                                series_id=series_id,
                                series_title=title,
                                media_type="tv",
                                current_season=current_season,
                                current_episode=current_episode,
                                seasons=seasons or [SeasonInfo(season_number=1, name="Season 1", episode_count=len(episodes))],
                                episodes=episodes,
                            )
            except Exception as e:
                log.warning("TMDB episodes fetch failed for %s: %s", series_id, e)

        # Fallback for generic TV series
        title = f"Series {series_id}"
        return SeriesEpisodesOut(
            series_id=series_id,
            series_title=title,
            media_type="tv",
            current_season=current_season,
            current_episode=current_episode,
            seasons=[SeasonInfo(season_number=1, name="Season 1", episode_count=10)],
            episodes=[
                EpisodeOut(
                    youtube_id=f"vidy:tv:{series_id}/{current_season}/{i}",
                    series_id=series_id,
                    series_title=title,
                    title=f"Episode {i}",
                    episode_number=i,
                    season_number=current_season,
                    duration_s=2700,
                    thumbnail="https://vidy.st/favicon.svg",
                    overview=f"Episode {i} of Season {current_season}",
                    provider="vidy",
                    media_type="tv",
                )
                for i in range(1, 11)
            ],
        )

    elif media_type == "anime":
        current_episode = s_arg or 1

        title = f"Anime {series_id}"
        episodes_count = 12
        cover = "https://vidy.st/favicon.svg"
        duration_s = 1440

        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                query = """
                query ($id: Int) {
                  Media(id: $id, type: ANIME) {
                    id
                    title {
                      english
                      romaji
                    }
                    episodes
                    duration
                    coverImage {
                      large
                    }
                    description
                  }
                }
                """
                resp = await client.post(
                    ANILIST_GRAPHQL_URL,
                    json={"query": query, "variables": {"id": int(series_id)}},
                )
                if resp.status_code == 200:
                    media = resp.json().get("data", {}).get("Media") or {}
                    t_obj = media.get("title") or {}
                    title = t_obj.get("english") or t_obj.get("romaji") or title
                    episodes_count = min(media.get("episodes") or 12, 50)
                    duration_s = (media.get("duration") or 24) * 60
                    cover = (media.get("coverImage") or {}).get("large") or cover
        except Exception as e:
            log.warning("AniList anime detail fetch failed for %s: %s", series_id, e)

        return SeriesEpisodesOut(
            series_id=series_id,
            series_title=title,
            media_type="anime",
            current_season=1,
            current_episode=current_episode,
            seasons=[SeasonInfo(season_number=1, name="Episodes", episode_count=episodes_count)],
            episodes=[
                EpisodeOut(
                    youtube_id=f"vidy:anime:{series_id}/{i}",
                    series_id=series_id,
                    series_title=title,
                    title=f"Episode {i}",
                    episode_number=i,
                    season_number=1,
                    duration_s=duration_s,
                    thumbnail=cover,
                    overview=f"Episode {i} of {title}",
                    provider="vidy",
                    media_type="anime",
                )
                for i in range(1, episodes_count + 1)
            ],
        )

    return None

