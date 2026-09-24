"""YouTube Data API v3 client (free quota). The key never leaves the backend."""

import logging
import re

import httpx

from app.config import get_settings

log = logging.getLogger("ott_ai.youtube")
API = "https://www.googleapis.com/youtube/v3"
OEMBED = "https://www.youtube.com/oembed"
YOUTUBE_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
_DUR = re.compile(r"^P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$")


def parse_duration(iso: str) -> int:
    m = _DUR.match(iso or "")
    if not m:
        return 0
    d, h, mi, s = (int(x) if x else 0 for x in m.groups())
    return d * 86400 + h * 3600 + mi * 60 + s


async def search(query: str, max_results: int = 8) -> list[dict]:
    """Search embeddable videos and return full metadata. Costs ~101 quota units."""
    key = get_settings().youtube_api_key
    if not key:
        return []
    async with httpx.AsyncClient(timeout=8) as c:
        try:
            r = await c.get(
                f"{API}/search",
                params={
                    "part": "id",
                    "q": query,
                    "type": "video",
                    "videoEmbeddable": "true",
                    "videoSyndicated": "true",
                    "safeSearch": "moderate",
                    "maxResults": max_results,
                    "key": key,
                },
            )
            r.raise_for_status()
            ids = [i["id"]["videoId"] for i in r.json().get("items", [])]
        except (httpx.HTTPError, KeyError, ValueError) as e:
            log.warning("youtube search failed: %s", type(e).__name__)
            return []
    return await details(ids)


async def details(ids: list[str]) -> list[dict]:
    key = get_settings().youtube_api_key
    ids = [i for i in ids if YOUTUBE_ID.match(i)]
    if not key or not ids:
        return []
    async with httpx.AsyncClient(timeout=8) as c:
        try:
            r = await c.get(
                f"{API}/videos",
                params={
                    "part": "snippet,contentDetails,status",
                    "id": ",".join(ids[:50]),
                    "key": key,
                },
            )
            r.raise_for_status()
            items = r.json().get("items", [])
        except (httpx.HTTPError, ValueError) as e:
            log.warning("youtube details failed: %s", type(e).__name__)
            return []
    out = []
    for it in items:
        sn, st = it.get("snippet", {}), it.get("status", {})
        if not st.get("embeddable", False) or st.get("privacyStatus") != "public":
            continue
        out.append(
            {
                "youtube_id": it["id"],
                "title": sn.get("title", "")[:300],
                "description": sn.get("description", "")[:2000],
                "channel": sn.get("channelTitle", "")[:200],
                "tags": [t[:60] for t in sn.get("tags", [])[:15]],
                "duration_s": parse_duration(it.get("contentDetails", {}).get("duration", "")),
                "live": sn.get("liveBroadcastContent", "none") != "none",
            }
        )
    return out


async def oembed(youtube_id: str) -> dict | None:
    """Free, keyless metadata lookup; also confirms the video is embeddable."""
    if not YOUTUBE_ID.match(youtube_id):
        return None
    async with httpx.AsyncClient(timeout=6) as c:
        try:
            r = await c.get(
                OEMBED,
                params={"url": f"https://www.youtube.com/watch?v={youtube_id}", "format": "json"},
            )
        except httpx.HTTPError:
            return None
    if r.status_code != 200:
        return None
    data = r.json()
    return {"title": data.get("title", "")[:300], "channel": data.get("author_name", "")[:200]}
