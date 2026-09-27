import uuid
from typing import Annotated

from fastapi import APIRouter, HTTPException, Path, Query, Request
from pydantic import BaseModel, Field
from sqlalchemy import func, select

from app import ollama
from app.config import get_settings
from app.deps import DB, CurrentUser, limiter
from app.models import Conversation, Message, Video, WatchHistory
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
    provider: str = "youtube"  # "youtube" | "vidy"
    media_type: str = "video"  # "video" | "movie" | "tv" | "anime"
    season: int | None = None
    episode: int | None = None

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
            provider="youtube",
            media_type="video",
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
    source = v.chapters_text or v.description
    return [ChapterOut(**c) for c in service.parse_chapters(source, v.duration_s)]


class TranscriptLine(BaseModel):
    start_s: int | None
    text: str


@router.get("/{youtube_id}/transcript", response_model=list[TranscriptLine])
@limiter.limit("60/minute")
async def transcript(request: Request, db: DB, user: CurrentUser, youtube_id: YoutubeId):
    """Admin-curated transcript; 404 when the video has none."""
    v = await db.scalar(select(Video).where(Video.youtube_id == youtube_id))
    if v is None or not (v.transcript or "").strip():
        raise HTTPException(404, "No transcript for this video")
    return [TranscriptLine(**ln) for ln in service.parse_transcript(v.transcript)]


class SummaryIn(BaseModel):
    start_s: float | None = Field(default=None, ge=0)
    end_s: float | None = Field(default=None, ge=0)
    label: str = Field(default="", max_length=160)
    model: str | None = Field(default=None, max_length=60)
    conversation_id: uuid.UUID | None = None


class SummaryOut(BaseModel):
    summary: str
    model: str
    prompt_tokens: int = 0
    output_tokens: int = 0


SUMMARY_SYSTEM = (
    "You summarise part of a video transcript for a learner. Write 2-5 short plain "
    "sentences covering the key points, in the transcript's language. Use only the "
    "transcript; if it is too short or unclear, say so briefly."
)
SUMMARY_SCHEMA = {
    "type": "object",
    "properties": {"summary": {"type": "string"}},
    "required": ["summary"],
}


@router.post("/{youtube_id}/summary", response_model=SummaryOut)
@limiter.limit("10/minute")
async def summary(
    request: Request, body: SummaryIn, db: DB, user: CurrentUser, youtube_id: YoutubeId
):
    """Summarise the transcript (or one part of it) with the local model. When a
    conversation is given, the request and answer are saved in it."""
    s = get_settings()
    model = body.model or s.default_model
    if model not in s.allowed_models:
        raise HTTPException(422, "Model not allowed")
    v = await db.scalar(select(Video).where(Video.youtube_id == youtube_id))
    if v is None or not (v.transcript or "").strip():
        raise HTTPException(404, "No transcript for this video")
    conv = None
    if body.conversation_id is not None:
        conv = await db.get(Conversation, body.conversation_id)
        if conv is None or conv.user_id != user.id:
            raise HTTPException(404, "Conversation not found")
    excerpt = service.transcript_excerpt(service.parse_transcript(v.transcript), body.start_s, body.end_s)
    if len(excerpt) < 40:
        raise HTTPException(422, "Not enough transcript for that part")
    res = await ollama.chat_json(
        model,
        [
            {"role": "system", "content": SUMMARY_SYSTEM},
            {"role": "user", "content": f"Video: {v.title}\nTranscript excerpt:\n{excerpt}"},
        ],
        SUMMARY_SCHEMA,
        num_predict=400,
        num_ctx=await ollama.context_length(model),
    )
    # LLM output is untrusted: plain text, length-limited.
    text = " ".join(str((res.data if res else {}).get("summary") or "").split())[:1500]
    if res is None or not text:
        raise HTTPException(503, "The AI model is offline; try again later")
    if conv is not None:
        label = body.label.strip() or v.title
        db.add(Message(conversation_id=conv.id, role="user", content=f"Summarize “{label}”"))
        db.add(
            Message(
                conversation_id=conv.id,
                role="assistant",
                content=text,
                source="summary",
                model=model,
                prompt_tokens=res.prompt_tokens,
                output_tokens=res.output_tokens,
            )
        )
        conv.updated_at = func.now()
        await db.commit()
    return SummaryOut(
        summary=text, model=model, prompt_tokens=res.prompt_tokens, output_tokens=res.output_tokens
    )


@router.post("/{youtube_id}/watched", status_code=204)
@limiter.limit("60/minute")
async def watched(request: Request, db: DB, user: CurrentUser, youtube_id: YoutubeId):
    if await db.scalar(select(Video.id).where(Video.youtube_id == youtube_id)) is None:
        raise HTTPException(404, "Unknown video")
    db.add(WatchHistory(user_id=user.id, youtube_id=youtube_id))
    await db.commit()
