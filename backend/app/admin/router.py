from typing import Annotated

from fastapi import APIRouter, HTTPException, Path, Query
from pydantic import BaseModel, Field
from sqlalchemy import delete, func, or_, select

from app.deps import DB, AdminUser
from app.models import Video
from app.videos import service, youtube

router = APIRouter(prefix="/api/admin", tags=["admin"])
YoutubeId = Annotated[str, Path(pattern=r"^[A-Za-z0-9_-]{11}$")]


class AdminVideo(BaseModel):
    youtube_id: str
    title: str
    channel: str
    topic: str
    tags: list[str]
    duration_s: int
    source: str
    has_embedding: bool


class VideoIn(BaseModel):
    youtube_id: str = Field(pattern=r"^[A-Za-z0-9_-]{11}$")
    topic: str = Field(min_length=1, max_length=100)
    tags: list[Annotated[str, Field(max_length=60)]] = Field(default=[], max_length=15)
    title: str | None = Field(default=None, max_length=300)
    description: str | None = Field(default=None, max_length=2000)


class VideoPatch(BaseModel):
    topic: str | None = Field(default=None, min_length=1, max_length=100)
    tags: list[Annotated[str, Field(max_length=60)]] | None = Field(default=None, max_length=15)
    title: str | None = Field(default=None, min_length=1, max_length=300)


class Page(BaseModel):
    total: int
    items: list[AdminVideo]


def _out(v: Video) -> AdminVideo:
    return AdminVideo(
        youtube_id=v.youtube_id,
        title=v.title,
        channel=v.channel,
        topic=v.topic,
        tags=v.tags,
        duration_s=v.duration_s,
        source=v.source,
        has_embedding=v.embedding is not None,
    )


@router.get("/videos", response_model=Page)
async def list_videos(
    db: DB,
    admin: AdminUser,
    q: Annotated[str, Query(max_length=100)] = "",
    source: Annotated[str, Query(pattern="^(curated|youtube|)$")] = "",
    offset: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
):
    stmt = select(Video)
    if q:
        escaped = q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        like = f"%{escaped}%"
        stmt = stmt.where(or_(Video.title.ilike(like), Video.topic.ilike(like), Video.youtube_id == q))
    if source:
        stmt = stmt.where(Video.source == source)
    total = await db.scalar(select(func.count()).select_from(stmt.subquery()))
    rows = await db.scalars(stmt.order_by(Video.created_at.desc()).offset(offset).limit(limit))
    return Page(total=total or 0, items=[_out(v) for v in rows])


@router.post("/videos", response_model=AdminVideo, status_code=201)
async def add_video(body: VideoIn, db: DB, admin: AdminUser):
    meta = (await youtube.details([body.youtube_id]) or [None])[0]
    if meta is None:
        o = await youtube.oembed(body.youtube_id)
        if o is None:
            raise HTTPException(422, "Video not found or not embeddable")
        meta = {"youtube_id": body.youtube_id, **o, "description": "", "tags": [], "duration_s": 0}
    item = {
        **meta,
        "title": body.title or meta["title"],
        "description": body.description if body.description is not None else meta.get("description", ""),
        "tags": body.tags or meta.get("tags", []),
        "topic": body.topic,
    }
    (video,) = await service.upsert_videos(db, [item], source="curated", topic=body.topic)
    return _out(video)


@router.patch("/videos/{youtube_id}", response_model=AdminVideo)
async def edit_video(youtube_id: YoutubeId, body: VideoPatch, db: DB, admin: AdminUser):
    v = await db.scalar(select(Video).where(Video.youtube_id == youtube_id))
    if v is None:
        raise HTTPException(404, "Not found")
    item = {
        "youtube_id": v.youtube_id,
        "title": body.title or v.title,
        "description": v.description,
        "channel": v.channel,
        "duration_s": v.duration_s,
        "tags": body.tags if body.tags is not None else v.tags,
        "topic": body.topic or v.topic,
    }
    (video,) = await service.upsert_videos(db, [item], source="curated")
    await db.refresh(video)
    return _out(video)


@router.delete("/videos/{youtube_id}", status_code=204)
async def delete_video(youtube_id: YoutubeId, db: DB, admin: AdminUser):
    res = await db.execute(delete(Video).where(Video.youtube_id == youtube_id))
    if res.rowcount == 0:
        raise HTTPException(404, "Not found")
    await db.commit()

