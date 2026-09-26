import uuid
from datetime import datetime
from typing import Annotated, Literal

from fastapi import APIRouter, HTTPException, Path, Request
from pydantic import BaseModel, Field
from sqlalchemy import delete, func, select

from app import ollama
from app.chat.intent import parse_command
from app.chat.llm import understand
from app.config import get_settings
from app.deps import DB, CurrentUser, limiter
from app.models import Conversation, Message, Video
from app.videos import service
from app.videos.router import VideoOut

router = APIRouter(prefix="/api", tags=["chat"])


class ChatIn(BaseModel):
    message: str = Field(min_length=1, max_length=500)
    conversation_id: uuid.UUID | None = None
    model: str | None = Field(default=None, max_length=60)
    player_open: bool = False


class ActionOut(BaseModel):
    type: Literal["seek", "pause", "play", "stop", "next", "loop", "unloop", "mute", "unmute", "save"]
    seconds: float = 0
    start: float | None = None
    end: float | None = None


class ChatOut(BaseModel):
    conversation_id: uuid.UUID
    reply: str
    videos: list[VideoOut] = []
    action: ActionOut | None = None
    source: Literal["command", "catalog", "youtube", "none", "chat"]
    highlights: list[str] = []


class ConversationOut(BaseModel):
    id: uuid.UUID
    title: str
    updated_at: datetime


class MessageOut(BaseModel):
    role: str
    content: str
    videos: list[VideoOut]
    created_at: datetime


class ModelsOut(BaseModel):
    models: list[str]
    default: str


def _command_reply(action: str, seconds: float) -> str:
    if action == "seek":
        n = int(abs(seconds)) if float(seconds).is_integer() else abs(seconds)
        return f"{'Forward' if seconds > 0 else 'Back'} {n} seconds."
    return {"pause": "Paused.", "play": "Playing.", "stop": "Stopped. Back to chat.",
            "next": "Playing the next video.", "loop": "Looping this part.",
            "unloop": "Stopped looping.", "mute": "Muted.", "unmute": "Sound on.",
            "save": "Saved to your library."}[action]


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


async def _allowed_models() -> list[str]:
    s = get_settings()
    installed = await ollama.installed_models()
    return [m for m in s.allowed_models if m in installed] if installed else []


@router.get("/models", response_model=ModelsOut)
async def models(user: CurrentUser):
    s = get_settings()
    return ModelsOut(models=await _allowed_models(), default=s.default_model)


@router.post("/chat", response_model=ChatOut)
@limiter.limit("40/minute")
async def chat(request: Request, body: ChatIn, db: DB, user: CurrentUser):
    s = get_settings()
    model = body.model or s.default_model
    if model not in s.allowed_models:
        raise HTTPException(422, "Model not allowed")
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
        db.add(Message(conversation_id=conv.id, role="assistant", content=reply))
        await db.commit()
        return ChatOut(conversation_id=conv.id, reply=reply, action=action, source="command")

    history_rows = (
        await db.scalars(
            select(Message)
            .where(Message.conversation_id == conv.id)
            .order_by(Message.created_at.desc())
            .limit(6)
        )
    ).all()
    history = [{"role": m.role, "content": m.content} for m in reversed(history_rows)]
    db.add(Message(conversation_id=conv.id, role="user", content=text))
    u = await understand(text, model, history)

    videos: list[Video] = []
    scores: dict[str, int] = {}
    source = "chat"
    reply = u.reply
    if u.topic:
        videos, source, scores = await service.find_videos_scored(db, u.topic)
        if not videos:
            reply = f"I couldn't find a video for “{u.topic}”. Try describing it differently."
    db.add(
        Message(
            conversation_id=conv.id,
            role="assistant",
            content=reply,
            video_ids=[v.youtube_id for v in videos],
        )
    )
    await db.commit()
    return ChatOut(
        conversation_id=conv.id,
        reply=reply,
        videos=[VideoOut.of(v, scores.get(v.youtube_id)) for v in videos],
        source=source,
        highlights=u.highlights if videos else [],
    )


@router.get("/conversations", response_model=list[ConversationOut])
async def conversations(db: DB, user: CurrentUser):
    rows = await db.scalars(
        select(Conversation)
        .where(Conversation.user_id == user.id)
        .order_by(Conversation.updated_at.desc())
        .limit(50)
    )
    return [ConversationOut(id=c.id, title=c.title, updated_at=c.updated_at) for c in rows]


ConvId = Annotated[uuid.UUID, Path()]


@router.get("/conversations/{conversation_id}/messages", response_model=list[MessageOut])
async def messages(conversation_id: ConvId, db: DB, user: CurrentUser):
    conv = await _conversation(db, user.id, conversation_id, "")
    msgs = (
        await db.scalars(
            select(Message).where(Message.conversation_id == conv.id).order_by(Message.created_at).limit(500)
        )
    ).all()
    ids = {i for m in msgs for i in m.video_ids}
    vids = {v.youtube_id: v for v in await db.scalars(select(Video).where(Video.youtube_id.in_(ids)))} if ids else {}
    return [
        MessageOut(
            role=m.role,
            content=m.content,
            videos=[VideoOut.of(vids[i]) for i in m.video_ids if i in vids],
            created_at=m.created_at,
        )
        for m in msgs
    ]


@router.delete("/conversations", status_code=204)
async def delete_all_conversations(db: DB, user: CurrentUser):
    """Clear the user's whole chat history."""
    await db.execute(delete(Conversation).where(Conversation.user_id == user.id))
    await db.commit()


@router.delete("/conversations/{conversation_id}", status_code=204)
async def delete_conversation(conversation_id: ConvId, db: DB, user: CurrentUser):
    conv = await _conversation(db, user.id, conversation_id, "")
    await db.execute(delete(Conversation).where(Conversation.id == conv.id))
    await db.commit()
