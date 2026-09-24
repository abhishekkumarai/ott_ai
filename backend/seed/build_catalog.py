"""Build seed/catalog.json from real YouTube search results (run once; ~2.5k quota units).

Only public, embeddable, syndicated, non-live videos of 4-20 minutes are kept, and each
one is double-checked through the keyless oEmbed endpoint. The resulting JSON is
committed so re-seeding never needs the API.

    python -m seed.build_catalog
"""

import asyncio
import json
from pathlib import Path

import httpx

from app.config import get_settings
from app.videos import youtube

OUT = Path(__file__).with_name("catalog.json")
PER_QUERY = 2

TOPICS: dict[str, list[str]] = {
    "programming": [
        "python tutorial for beginners",
        "javascript explained",
        "docker explained in minutes",
        "git and github basics",
        "how the internet works",
        "sql database basics",
    ],
    "science": [
        "black holes explained",
        "quantum physics explained simply",
        "how dna works",
        "calculus intuition",
        "climate change science explained",
        "how vaccines work",
    ],
    "lifestyle": [
        "sourdough bread recipe",
        "easy pasta recipe",
        "indian curry recipe",
        "home workout no equipment",
        "meal prep for the week",
        "travel guide japan",
    ],
    "music": [
        "music theory basics",
        "learn guitar chords beginner",
        "jazz piano explained",
        "history of hip hop",
        "how to make a beat",
        "classical music explained",
    ],
}


async def search_ids(c: httpx.AsyncClient, key: str, q: str) -> list[str]:
    r = await c.get(
        f"{youtube.API}/search",
        params={
            "part": "id",
            "q": q,
            "type": "video",
            "videoEmbeddable": "true",
            "videoSyndicated": "true",
            "videoDuration": "medium",
            "relevanceLanguage": "en",
            "safeSearch": "strict",
            "maxResults": 6,
            "key": key,
        },
    )
    r.raise_for_status()
    return [i["id"]["videoId"] for i in r.json().get("items", [])]


async def main() -> None:
    key = get_settings().youtube_api_key
    if not key:
        raise SystemExit("OTT_YOUTUBE_API_KEY missing")
    catalog: list[dict] = []
    seen: set[str] = set()
    async with httpx.AsyncClient(timeout=10) as c:
        for topic, queries in TOPICS.items():
            for q in queries:
                ids = [i for i in await search_ids(c, key, q) if i not in seen]
                kept = 0
                for d in await youtube.details(ids):
                    if kept == PER_QUERY or d["live"] or not 120 <= d["duration_s"] <= 1500:
                        continue
                    if await youtube.oembed(d["youtube_id"]) is None:
                        continue
                    d.pop("live")
                    catalog.append({**d, "topic": topic, "tags": d["tags"] + q.split()[:3]})
                    seen.add(d["youtube_id"])
                    kept += 1
                print(f"{topic:12} {q:40} +{kept}")
    OUT.write_text(json.dumps(catalog, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"wrote {len(catalog)} videos to {OUT}")


if __name__ == "__main__":
    asyncio.run(main())
