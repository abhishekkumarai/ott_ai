"""Catalog search (hybrid full-text + pgvector), YouTube fallback, recommendations."""

import logging
import re
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from sqlalchemy import case, func, literal_column, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app import ollama
from app.config import get_settings
from app.models import Video, WatchHistory, YoutubeQueryCache
from app.timecode import stamp_seconds
from app.videos import youtube

log = logging.getLogger("ott_ai.search")

RRF_K = 60
# nomic-embed-text cosine similarity above which a catalog hit counts as relevant
SEMANTIC_MIN = 0.62
CACHE_TTL = timedelta(days=7)
MIN_DURATION_S = 60
SAME_TOPIC_BONUS = 0.06


@dataclass
class Hit:
    video: Video
    score: float
    similarity: float
    text_match: bool


def doc_text(v: Video | dict) -> str:
    g = v.get if isinstance(v, dict) else lambda k, d="": getattr(v, k, d)
    tags = " ".join(g("tags", []) or [])
    return f"search_document: {g('title', '')}. {g('topic', '')}. {tags}. {(g('description', '') or '')[:500]}"


def query_text(q: str) -> str:
    return f"search_query: {q}"


def normalize_query(q: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s-]", " ", q.lower())).strip()[:200]


async def search_catalog(db: AsyncSession, query: str, limit: int = 6) -> list[Hit]:
    query = query.strip()[:200]
    if not query:
        return []
    tsq = func.websearch_to_tsquery("english", query)
    fts_rows = (
        await db.execute(
            select(Video.id, func.ts_rank_cd(Video.tsv, tsq).label("r"))
            .where(Video.tsv.op("@@")(tsq), Video.embeddable.is_(True))
            .order_by(literal_column("r").desc())
            .limit(30)
        )
    ).all()

    vec_rows = []
    qvec = await ollama.embed_one(query_text(query))
    if qvec is not None:
        dist = Video.embedding.cosine_distance(qvec)
        vec_rows = (
            await db.execute(
                select(Video.id, dist.label("d"))
                .where(Video.embedding.is_not(None), Video.embeddable.is_(True))
                .order_by(dist)
                .limit(30)
            )
        ).all()

    scores: dict[uuid.UUID, float] = {}
    sims: dict[uuid.UUID, float] = {}
    text_ids = set()
    for rank, (vid, _) in enumerate(fts_rows):
        scores[vid] = scores.get(vid, 0) + 1 / (RRF_K + rank)
        text_ids.add(vid)
    for rank, (vid, d) in enumerate(vec_rows):
        scores[vid] = scores.get(vid, 0) + 1 / (RRF_K + rank)
        sims[vid] = 1 - float(d)

    # Only keep results with some real evidence of relevance
    relevant = [v for v in scores if v in text_ids or sims.get(v, 0) >= SEMANTIC_MIN]
    relevant.sort(key=lambda v: scores[v], reverse=True)
    relevant = relevant[:limit]
    if not relevant:
        return []
    videos = {v.id: v for v in (await db.scalars(select(Video).where(Video.id.in_(relevant))))}
    return [
        Hit(videos[v], scores[v], sims.get(v, 0.0), v in text_ids) for v in relevant if v in videos
    ]


async def upsert_videos(
    db: AsyncSession, items: list[dict], source: str, topic: str = ""
) -> list[Video]:
    items = [i for i in items if youtube.YOUTUBE_ID.match(i.get("youtube_id", ""))]
    if not items:
        return []
    vectors = await ollama.embed([doc_text({**i, "topic": i.get("topic") or topic}) for i in items])
    for idx, i in enumerate(items):
        tags = [t[:60] for t in i.get("tags", [])][:15]
        values = {
            "youtube_id": i["youtube_id"],
            "title": i["title"][:300],
            "description": i.get("description", "")[:2000],
            "channel": i.get("channel", "")[:200],
            "duration_s": int(i.get("duration_s", 0)),
            "topic": (i.get("topic") or topic)[:100],
            "tags": tags,
            "tags_text": " ".join(tags),
            "source": source,
            "embeddable": True,
            "embedding": vectors[idx] if vectors else None,
        }
        stmt = insert(Video).values(id=uuid.uuid4(), **values)
        update_cols = {k: stmt.excluded[k] for k in values if k != "youtube_id"}
        if source == "youtube":
            # never downgrade a curated entry to an API-cached one
            update_cols.pop("source")
            update_cols.pop("topic")
        await db.execute(stmt.on_conflict_do_update(index_elements=["youtube_id"], set_=update_cols))
    await db.commit()
    ids = [i["youtube_id"] for i in items]
    rows = {v.youtube_id: v for v in await db.scalars(select(Video).where(Video.youtube_id.in_(ids)))}
    return [rows[i] for i in ids if i in rows]


async def youtube_fallback(db: AsyncSession, query: str, limit: int = 6) -> list[Video]:
    key = normalize_query(query)
    if not key or not get_settings().youtube_api_key:
        return []
    cached = await db.get(YoutubeQueryCache, key)
    if cached and cached.fetched_at > datetime.now(UTC) - CACHE_TTL:
        rows = {
            v.youtube_id: v
            for v in await db.scalars(select(Video).where(Video.youtube_id.in_(cached.youtube_ids)))
        }
        return [rows[i] for i in cached.youtube_ids if i in rows][:limit]

    items = [
        i
        for i in await youtube.search(query, max_results=10)
        if not i["live"] and i["duration_s"] >= MIN_DURATION_S
    ]
    videos = await upsert_videos(db, items, source="youtube", topic=key[:100])
    stmt = insert(YoutubeQueryCache).values(
        query=key, youtube_ids=[v.youtube_id for v in videos], fetched_at=func.now()
    )
    await db.execute(
        stmt.on_conflict_do_update(
            index_elements=["query"],
            set_={"youtube_ids": stmt.excluded.youtube_ids, "fetched_at": func.now()},
        )
    )
    await db.commit()
    return videos[:limit]


def match_percent(similarity: float | None) -> int | None:
    """Cosine similarity shown as a whole percentage (None when there is no vector)."""
    if similarity is None or similarity <= 0:
        return None
    return max(1, min(99, round(similarity * 100)))


async def find_videos_scored(
    db: AsyncSession, query: str, limit: int = 6
) -> tuple[list[Video], str, dict[str, int]]:
    """Like [find_videos], plus a match % per catalog hit (YouTube fallback has none)."""
    hits = await search_catalog(db, query, limit)
    strong = [h for h in hits if h.text_match or h.similarity >= SEMANTIC_MIN]
    if strong:
        scores = {
            h.video.youtube_id: pct
            for h in strong
            if (pct := match_percent(h.similarity)) is not None
        }
        return [h.video for h in strong], "catalog", scores
    videos = await youtube_fallback(db, query, limit)
    return videos, "youtube" if videos else "none", {}


async def find_videos(db: AsyncSession, query: str, limit: int = 6) -> tuple[list[Video], str]:
    """Catalog first; YouTube API only when the catalog has nothing relevant."""
    videos, source, _ = await find_videos_scored(db, query, limit)
    return videos, source


async def recommendations(
    db: AsyncSession, youtube_id: str, user_id: uuid.UUID | None, limit: int = 8
) -> list[tuple[Video, int | None]]:
    """Related videos with a match % (cosine similarity to the current video)."""
    current = await db.scalar(select(Video).where(Video.youtube_id == youtube_id))
    if current is None:
        return []
    exclude = {youtube_id}
    if user_id is not None:
        recent = await db.scalars(
            select(WatchHistory.youtube_id)
            .where(WatchHistory.user_id == user_id)
            .order_by(WatchHistory.created_at.desc())
            .limit(20)
        )
        exclude |= set(recent)
    out: list[tuple[Video, int | None]] = []
    if current.embedding is not None:
        raw = Video.embedding.cosine_distance(current.embedding)
        # Ordered by similarity nudged towards the same topic (raw nomic scores are
        # tightly packed); the match % shown is the plain similarity.
        dist = raw - case((Video.topic == current.topic, SAME_TOPIC_BONUS), else_=0.0)
        rows = await db.execute(
            select(Video, raw.label("d"))
            .where(
                Video.embedding.is_not(None),
                Video.embeddable.is_(True),
                Video.youtube_id.not_in(exclude),
            )
            .order_by(dist)
            .limit(limit)
        )
        out = [(v, match_percent(1 - d)) for v, d in rows.all()]
    if len(out) < limit and current.topic:
        have = exclude | {v.youtube_id for v, _ in out}
        out += [
            (v, None)
            for v in await db.scalars(
                select(Video)
                .where(Video.topic == current.topic, Video.youtube_id.not_in(have))
                .order_by(func.random())
                .limit(limit - len(out))
            )
        ]
    return out


# "0:00 Intro", "(1:02:03) Part two", "12:30 - Wrap up"
_CHAPTER_LINE = re.compile(
    r"^\s*[\[(]?((?:\d{1,2}:)?\d{1,2}:\d{2})[\])]?\s*[-–—:|.)]*\s*(\S.{0,150})$"
)


def parse_chapters(description: str, duration_s: int = 0) -> list[dict]:
    """YouTube-style chapters from a video description.

    Follows YouTube's own rules so only real chapter lists are shown: the first stamp
    is 0:00, there are at least three, and they increase.
    """
    out: list[dict] = []
    for line in (description or "").splitlines():
        m = _CHAPTER_LINE.match(line)
        if not m:
            continue
        start = stamp_seconds(m.group(1))
        title = " ".join(m.group(2).split()).strip(" -–—|")[:120]
        if not title or (out and start <= out[-1]["start_s"]):
            continue
        if duration_s and start >= duration_s:
            break
        out.append({"start_s": start, "title": title})
    if len(out) < 3 or out[0]["start_s"] != 0:
        return []
    return out


# "1:15 some words", "[01:15] some words", "(1:02:03) words"
_TRANSCRIPT_LINE = re.compile(
    r"^\s*[\[(]?((?:\d{1,2}:)?\d{1,2}:\d{2})[\])]?\s*[-\u2013\u2014:|.)]*\s*(\S.*)$"
)
MAX_TRANSCRIPT_LINES = 5000


def parse_transcript(text: str) -> list[dict]:
    """Transcript lines. A leading timestamp makes a line seekable ("start_s");
    lines without one keep start_s None (plain pasted text)."""
    out: list[dict] = []
    for raw in (text or "").splitlines():
        line = " ".join(raw.split())
        if not line:
            continue
        m = _TRANSCRIPT_LINE.match(line)
        if m:
            out.append({"start_s": stamp_seconds(m.group(1)), "text": m.group(2)[:1000]})
        else:
            out.append({"start_s": None, "text": line[:1000]})
        if len(out) >= MAX_TRANSCRIPT_LINES:
            break
    return out


def transcript_excerpt(lines: list[dict], start: float | None, end: float | None, limit: int = 12000) -> str:
    """Text for [start, end). Timed lines are filtered by time; an untimed
    transcript can't be sliced, so the whole text is used."""
    timed = [ln for ln in lines if ln["start_s"] is not None]
    if timed and (start is not None or end is not None):
        lo = start or 0
        hi = end if end is not None else float("inf")
        picked = [ln["text"] for ln in timed if lo <= ln["start_s"] < hi]
    else:
        picked = [ln["text"] for ln in lines]
    return " ".join(picked)[:limit]
