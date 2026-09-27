"""Build seed/catalog.json from real YouTube search results (run once; ~2.5k quota units).

Only public, embeddable, syndicated, non-live videos of 4-20 minutes are kept, and each
one is double-checked through the keyless oEmbed endpoint. The resulting JSON is
committed so re-seeding never needs the API.

    python -m seed.build_catalog                      # every topic
    python -m seed.build_catalog LLMs "data structures"  # only these; others kept

A topic's queries cost ~100 quota units each.
"""

import asyncio
import json
import re
import sys
from pathlib import Path

import httpx

from app.config import get_settings
from app.videos import youtube

OUT = Path(__file__).with_name("catalog.json")
PER_QUERY = 2

# PER_QUERY per topic overrides the default (the Recommended rail draws only from
# these three, so they get more videos).
RICH = {"LLMs": 3, "machine learning": 3, "data structures": 3}

TOPICS: dict[str, list[str]] = {
    "LLMs": [
        "large language models explained",
        "transformers attention mechanism explained",
        "how chatgpt works",
        "retrieval augmented generation explained",
        "fine tuning llm explained",
        "tokenization and embeddings llm",
    ],
    "machine learning": [
        "machine learning explained for beginners",
        "neural networks explained",
        "gradient descent explained",
        "backpropagation explained",
        "decision trees and random forests explained",
        "overfitting bias variance explained",
    ],
    "data structures": [
        "data structures explained",
        "linked list data structure",
        "binary search tree explained",
        "hash table explained",
        "graph data structure bfs dfs",
        "heap priority queue explained",
    ],
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


_OTHER_LANGUAGE = re.compile(
    r"\b(hindi|tamil|telugu|urdu|bangla|bengali|marathi|malayalam)\b", re.I
)
# Devanagari through Sinhala: the Indic scripts relevanceLanguage=en lets through.
_INDIC_SCRIPT = re.compile("[ऀ-෿]")


def english(d: dict) -> bool:
    """The app is English-only: skip videos titled in another script or labelled as
    another language (relevanceLanguage=en is only a hint to YouTube)."""
    text = f"{d['title']} {d.get('channel', '')}"
    return not _OTHER_LANGUAGE.search(text) and not _INDIC_SCRIPT.search(text)


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


async def main(only: list[str]) -> None:
    key = get_settings().youtube_api_key
    if not key:
        raise SystemExit("OTT_YOUTUBE_API_KEY missing")
    unknown = [t for t in only if t not in TOPICS]
    if unknown:
        raise SystemExit(f"unknown topics {unknown}; choose from {list(TOPICS)}")
    topics = only or list(TOPICS)
    # Rebuilding some topics keeps every other topic's videos as they are.
    catalog: list[dict] = []
    if only and OUT.exists():
        catalog = [v for v in json.loads(OUT.read_text(encoding="utf-8")) if v["topic"] not in only]
    seen: set[str] = {v["youtube_id"] for v in catalog}
    async with httpx.AsyncClient(timeout=10) as c:
        for topic in topics:
            per_query = RICH.get(topic, PER_QUERY)
            for q in TOPICS[topic]:
                ids = [i for i in await search_ids(c, key, q) if i not in seen]
                kept = 0
                for d in await youtube.details(ids):
                    if kept == per_query or d["live"] or not 120 <= d["duration_s"] <= 1500:
                        continue
                    if not english(d):
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
    asyncio.run(main(sys.argv[1:]))
