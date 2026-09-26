from typing import Annotated

from fastapi import APIRouter, HTTPException, Path, Query, Request
from pydantic import BaseModel
from sqlalchemy import select

from app.deps import DB, CurrentUser, limiter
from app.models import Video, WatchHistory
from app.videos import service

router = APIRouter(prefix="/api/videos", tags=["videos"])
YoutubeId = Annotated[str, Path(pattern=r"^[A-Za-z0-9_-]{11}$")]


class VideoOut(BaseModel):
    youtube_id: str
    title: str
    channel: str
    duration_s: int
    topic: str
    thumbnail: str
    match: int | None = None  # 1-99: cosine similarity as a percentage

    @classmethod
    def of(cls, v: Video, match: int | None = None) -> "VideoOut":
        return cls(
            youtube_id=v.youtube_id,
            title=v.title,
            channel=v.channel,
            duration_s=v.duration_s,
            topic=v.topic,
            thumbnail=f"https://i.ytimg.com/vi/{v.youtube_id}/mqdefault.jpg",
            match=match,
        )


class ChapterOut(BaseModel):
    start_s: int
    title: str


@router.get("/search", response_model=list[VideoOut])
@limiter.limit("30/minute")
async def search(
    request: Request, db: DB, user: CurrentUser, q: Annotated[str, Query(min_length=1, max_length=200)]
):
    videos, _ = await service.find_videos(db, q)
    return [VideoOut.of(v) for v in videos]


@router.get("/{youtube_id}/recommendations", response_model=list[VideoOut])
@limiter.limit("60/minute")
async def recommendations(request: Request, db: DB, user: CurrentUser, youtube_id: YoutubeId):
    return [VideoOut.of(v, m) for v, m in await service.recommendations(db, youtube_id, user.id)]


@router.get("/{youtube_id}/chapters", response_model=list[ChapterOut])
@limiter.limit("60/minute")
async def chapters(request: Request, db: DB, user: CurrentUser, youtube_id: YoutubeId):
    """Chapters parsed from the video description; empty when it has none."""
    v = await db.scalar(select(Video).where(Video.youtube_id == youtube_id))
    if v is None:
        raise HTTPException(404, "Unknown video")
    return [ChapterOut(**c) for c in service.parse_chapters(v.description, v.duration_s)]


@router.post("/{youtube_id}/watched", status_code=204)
@limiter.limit("60/minute")
async def watched(request: Request, db: DB, user: CurrentUser, youtube_id: YoutubeId):
    if await db.scalar(select(Video.id).where(Video.youtube_id == youtube_id)) is None:
        raise HTTPException(404, "Unknown video")
    db.add(WatchHistory(user_id=user.id, youtube_id=youtube_id))
    await db.commit()
