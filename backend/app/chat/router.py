import asyncio
import uuid
from datetime import datetime
from typing import Annotated, Literal

from fastapi import APIRouter, HTTPException, Path, Query, Request, Response
from pydantic import BaseModel, Field
from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert

from app import ollama
from app.chat.intent import parse_command
from app.chat.llm import HISTORY_WINDOW, SYSTEM, estimate_tokens, next_context, understand
from app.config import get_settings
from app.deps import DB, CurrentUser, limiter
from app.models import Conversation, Message, SavedVideo, Video
from app.videos import service
from app.videos.router import VideoOut

router = APIRouter(prefix="/api", tags=["chat"])


class ChatIn(BaseModel):
    message: str = Field(min_length=1, max_length=500)
    conversation_id: uuid.UUID | None = None
    model: str | None = Field(default=None, max_length=60)
    player_open: bool = False
    source: str = "youtube"


class ActionOut(BaseModel):
    type: Literal["seek", "pause", "play", "stop", "next", "loop", "unloop", "mute", "unmute", "save"]
    seconds: float = 0
    start: float | None = None
    end: float | None = None


class UsageOut(BaseModel):
    """Token use of one chat (OTTAI-27)."""

    prompt_tokens: int = 0  # whole chat, as reported by Ollama
    output_tokens: int = 0
    context_tokens: int = 0  # estimated prompt size the next request starts from
    context_limit: int = 0  # num_ctx sent with requests for this model
    history_window: int = HISTORY_WINDOW
    trimmed: bool = False  # older messages had to be dropped to fit


class ChatOut(BaseModel):
    conversation_id: uuid.UUID
    reply: str
    videos: list[VideoOut] = []
    recommendations: list[VideoOut] = []
    action: ActionOut | None = None
    source: Literal["command", "catalog", "youtube", "vidy", "none", "chat"]
    highlights: list[str] = []
    model: str | None = None  # None: no LLM wrote this reply
    prompt_tokens: int = 0
    output_tokens: int = 0
    usage: UsageOut


class ConversationOut(BaseModel):
    id: uuid.UUID
    title: str
    updated_at: datetime
    prompt_tokens: int = 0
    output_tokens: int = 0


class MessageOut(BaseModel):
    role: str
    content: str
    videos: list[VideoOut]
    # None: made before recommendations were stored (the app looks them up).
    recommendations: list[VideoOut] | None = None
    source: str | None = None
    model: str | None = None
    prompt_tokens: int = 0
    output_tokens: int = 0
    created_at: datetime


class ModelInfo(BaseModel):
    name: str
    context: int


class ModelsOut(BaseModel):
    models: list[ModelInfo]
    default: str
    history_window: int = HISTORY_WINDOW
    # Context meter of a chat with nothing sent yet (the system prompt alone).
    base_context: int = 0


def _command_reply(action: str, seconds: float) -> str:
    if action == "seek":
        n = int(abs(seconds)) if float(seconds).is_integer() else abs(seconds)
        return f"{'Forward' if seconds > 0 else 'Back'} {n} seconds."
    return {"pause": "Paused.", "play": "Playing.", "stop": "Stopped. Back to chat.",
            "next": "Playing the next video.", "loop": "Looping this part.",
            "unloop": "Stopped looping.", "mute": "Muted.", "unmute": "Sound on.",
            "save": "Saved to this chat."}[action]


def _clock(seconds: float) -> str:
    s = int(seconds)
    h, m, r = s // 3600, s % 3600 // 60, s % 60
    return f"{h}:{m:02d}:{r:02d}" if h else f"{m}:{r:02d}"


async def _conversation(db: DB, user_id: uuid.UUID, cid: uuid.UUID | None, title: str) -> Conversation:
    if cid is not None:
        conv = await db.get(Conversation, cid)
        if conv is None or conv.user_id != user_id:
            raise HTTPException(404, "Conversation not found")
        return conv
    conv = Conversation(user_id=user_id, title=title[:120] or "New chat")
    db.add(conv)
    await db.flush()
    return conv


def _model(name: str | None) -> str:
    s = get_settings()
    model = name or s.default_model
    if model not in s.allowed_models:
        raise HTTPException(422, "Model not allowed")
    return model


async def _history(db: DB, conv_id: uuid.UUID) -> list[dict]:
    """The last HISTORY_WINDOW messages, oldest first, as LLM chat messages.
    Only text: recommendations and saves never go into the prompt."""
    rows = (
        await db.scalars(
            select(Message)
            .where(Message.conversation_id == conv_id)
            .order_by(Message.created_at.desc())
            .limit(HISTORY_WINDOW)
        )
    ).all()
    return [{"role": m.role, "content": m.content} for m in reversed(rows)]


async def _usage(db: DB, conv_id: uuid.UUID, model: str, trimmed: bool = False) -> UsageOut:
    prompt, output = (
        await db.execute(
            select(
                func.coalesce(func.sum(Message.prompt_tokens), 0),
                func.coalesce(func.sum(Message.output_tokens), 0),
            ).where(Message.conversation_id == conv_id)
        )
    ).one()
    ctx = await ollama.context_length(model)
    tokens, next_trimmed = next_context(await _history(db, conv_id), ctx)
    return UsageOut(
        prompt_tokens=prompt,
        output_tokens=output,
        context_tokens=tokens,
        context_limit=ctx,
        trimmed=trimmed or next_trimmed,
    )


async def _allowed_models() -> list[str]:
    s = get_settings()
    installed = await ollama.installed_models()
    return [m for m in s.allowed_models if m in installed] if installed else []


@router.get("/models", response_model=ModelsOut)
async def models(user: CurrentUser):
    s = get_settings()
    names = await _allowed_models()
    contexts = await asyncio.gather(*(ollama.context_length(n) for n in names))
    return ModelsOut(
        models=[ModelInfo(name=n, context=c) for n, c in zip(names, contexts, strict=True)],
        default=s.default_model,
        base_context=estimate_tokens([{"role": "system", "content": SYSTEM}]),
    )


@router.post("/chat", response_model=ChatOut)
@limiter.limit("40/minute")
async def chat(request: Request, body: ChatIn, db: DB, user: CurrentUser):
    model = _model(body.model)
    text = body.message.strip()
    if not text:
        raise HTTPException(422, "Empty message")

    conv = await _conversation(db, user.id, body.conversation_id, text)
    conv.updated_at = func.now()

    cmd = parse_command(text)
    if cmd is not None:
        db.add(Message(conversation_id=conv.id, role="user", content=text))
        if not body.player_open:
            reply = "Nothing is playing right now. Ask me for a video on any topic."
            action = None
        else:
            reply = _command_reply(cmd.action, cmd.seconds)
            if cmd.action == "loop" and cmd.start is not None and cmd.end is not None:
                reply = f"Looping {_clock(cmd.start)} to {_clock(cmd.end)}."
            action = ActionOut(type=cmd.action, seconds=cmd.seconds, start=cmd.start, end=cmd.end)
        db.add(Message(conversation_id=conv.id, role="assistant", content=reply, source="command"))
        await db.commit()
        return ChatOut(
            conversation_id=conv.id,
            reply=reply,
            action=action,
            source="command",
            usage=await _usage(db, conv.id, model),
        )

    history = await _history(db, conv.id)
    db.add(Message(conversation_id=conv.id, role="user", content=text))
    ctx = await ollama.context_length(model)
    u = await understand(text, model, history, ctx)

    videos: list[Video] = []
    scores: dict[str, int] = {}
    source = "chat"
    reply = u.reply
    if u.topic:
        videos, source, scores = await service.find_videos_scored(db, u.topic)
        if not videos:
            reply = f"I couldn't find a video for “{u.topic}”. Try describing it differently."
    rail = await service.rail(db, videos, scores, user.id)
    db.add(
        Message(
            conversation_id=conv.id,
            role="assistant",
            content=reply,
            video_ids=[v.youtube_id for v in videos],
            recommendations=[{"youtube_id": v.youtube_id, "match": m} for v, m in rail],
            source=source,
            model=model if u.used_llm else None,
            prompt_tokens=u.prompt_tokens,
            output_tokens=u.output_tokens,
        )
    )
    await db.commit()
    return ChatOut(
        conversation_id=conv.id,
        reply=reply,
        videos=[VideoOut.of(v, scores.get(v.youtube_id)) for v in videos],
        recommendations=[VideoOut.of(v, m) for v, m in rail],
        source=source,
        highlights=u.highlights if videos else [],
        model=model if u.used_llm else None,
        prompt_tokens=u.prompt_tokens,
        output_tokens=u.output_tokens,
        usage=await _usage(db, conv.id, model, u.trimmed),
    )


@router.get("/conversations", response_model=list[ConversationOut])
async def conversations(db: DB, user: CurrentUser):
    totals = (
        select(
            Message.conversation_id.label("cid"),
            func.sum(Message.prompt_tokens).label("p"),
            func.sum(Message.output_tokens).label("o"),
        )
        .group_by(Message.conversation_id)
        .subquery()
    )
    rows = await db.execute(
        select(Conversation, totals.c.p, totals.c.o)
        .outerjoin(totals, totals.c.cid == Conversation.id)
        .where(Conversation.user_id == user.id)
        .order_by(Conversation.updated_at.desc())
        .limit(50)
    )
    return [
        ConversationOut(
            id=c.id, title=c.title, updated_at=c.updated_at, prompt_tokens=p or 0, output_tokens=o or 0
        )
        for c, p, o in rows.all()
    ]


ConvId = Annotated[uuid.UUID, Path()]


@router.get("/conversations/{conversation_id}/messages", response_model=list[MessageOut])
async def messages(conversation_id: ConvId, db: DB, user: CurrentUser):
    conv = await _conversation(db, user.id, conversation_id, "")
    msgs = (
        await db.scalars(
            select(Message).where(Message.conversation_id == conv.id).order_by(Message.created_at).limit(500)
        )
    ).all()
    ids = {i for m in msgs for i in m.video_ids} | {
        r["youtube_id"] for m in msgs for r in (m.recommendations or [])
    }
    vids = {v.youtube_id: v for v in await db.scalars(select(Video).where(Video.youtube_id.in_(ids)))} if ids else {}
    return [
        MessageOut(
            role=m.role,
            content=m.content,
            videos=[VideoOut.of(vids[i]) for i in m.video_ids if i in vids],
            recommendations=None
            if m.recommendations is None
            else [
                VideoOut.of(vids[r["youtube_id"]], r.get("match"))
                for r in m.recommendations
                if r.get("youtube_id") in vids
            ],
            source=m.source,
            model=m.model,
            prompt_tokens=m.prompt_tokens,
            output_tokens=m.output_tokens,
            created_at=m.created_at,
        )
        for m in msgs
    ]


@router.get("/conversations/{conversation_id}/usage", response_model=UsageOut)
async def usage(
    conversation_id: ConvId,
    db: DB,
    user: CurrentUser,
    model: Annotated[str | None, Query(max_length=60)] = None,
):
    """Totals and the context meter for a reopened chat, for [model] (default model
    when omitted)."""
    conv = await _conversation(db, user.id, conversation_id, "")
    return await _usage(db, conv.id, _model(model))


@router.delete("/conversations", status_code=204)
async def delete_all_conversations(db: DB, user: CurrentUser):
    """Clear the user's whole chat history (their saves go with it)."""
    await db.execute(delete(Conversation).where(Conversation.user_id == user.id))
    await db.commit()


@router.delete("/conversations/{conversation_id}", status_code=204)
async def delete_conversation(conversation_id: ConvId, db: DB, user: CurrentUser):
    conv = await _conversation(db, user.id, conversation_id, "")
    await db.execute(delete(Conversation).where(Conversation.id == conv.id))
    await db.commit()


# ------------------------------------------------------------------ saves (OTTAI-25)

YoutubeId = Annotated[str, Path(pattern=r"^[A-Za-z0-9_-]{11}$")]
MAX_SAVED = 500


@router.get("/conversations/{conversation_id}/saved", response_model=list[VideoOut])
async def saved_videos(conversation_id: ConvId, db: DB, user: CurrentUser):
    """This chat's saves, newest first."""
    conv = await _conversation(db, user.id, conversation_id, "")
    rows = await db.scalars(
        select(Video)
        .join(SavedVideo, SavedVideo.youtube_id == Video.youtube_id)
        .where(SavedVideo.conversation_id == conv.id)
        .order_by(SavedVideo.created_at.desc())
        .limit(MAX_SAVED)
    )
    return [VideoOut.of(v) for v in rows]


@router.put("/conversations/{conversation_id}/saved/{youtube_id}", status_code=204)
@limiter.limit("60/minute")
async def save_video(
    request: Request, conversation_id: ConvId, youtube_id: YoutubeId, db: DB, user: CurrentUser
):
    """Idempotent: saving twice in one chat keeps one entry."""
    conv = await _conversation(db, user.id, conversation_id, "")
    if await db.scalar(select(Video.id).where(Video.youtube_id == youtube_id)) is None:
        raise HTTPException(404, "Unknown video")
    await db.execute(
        insert(SavedVideo)
        .values(user_id=user.id, conversation_id=conv.id, youtube_id=youtube_id)
        .on_conflict_do_nothing(constraint="uq_saved_conversation_video")
    )
    await db.commit()
    return Response(status_code=204)


@router.delete("/conversations/{conversation_id}/saved/{youtube_id}", status_code=204)
@limiter.limit("60/minute")
async def unsave_video(
    request: Request, conversation_id: ConvId, youtube_id: YoutubeId, db: DB, user: CurrentUser
):
    conv = await _conversation(db, user.id, conversation_id, "")
    await db.execute(
        delete(SavedVideo).where(
            SavedVideo.conversation_id == conv.id,
            SavedVideo.user_id == user.id,
            SavedVideo.youtube_id == youtube_id,
        )
    )
    await db.commit()
    return Response(status_code=204)
