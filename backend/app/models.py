import uuid
from datetime import datetime

from pgvector.sqlalchemy import Vector
from sqlalchemy import (
    ARRAY,
    Boolean,
    CheckConstraint,
    Computed,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import CITEXT, JSONB, TSVECTOR, UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

EMBED_DIM = 768
YOUTUBE_ID_RE = r"^[A-Za-z0-9_-]{11}$"


class Base(DeclarativeBase):
    pass


def _uuid() -> Mapped[uuid.UUID]:
    return mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)


def _created() -> Mapped[datetime]:
    return mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)


class User(Base):
    __tablename__ = "users"
    id: Mapped[uuid.UUID] = _uuid()
    email: Mapped[str] = mapped_column(CITEXT, unique=True, nullable=False)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    is_admin: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    is_demo: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default="false", nullable=False, index=True
    )
    # Validated app settings (see app.account.router.Preferences); unknown keys never stored.
    preferences: Mapped[dict] = mapped_column(
        JSONB, default=dict, server_default=text("'{}'::jsonb"), nullable=False
    )
    failed_logins: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    locked_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = _created()


class RefreshToken(Base):
    __tablename__ = "refresh_tokens"
    id: Mapped[uuid.UUID] = _uuid()
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True, nullable=False
    )
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    family_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), index=True, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    revoked: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    created_at: Mapped[datetime] = _created()


class Video(Base):
    __tablename__ = "videos"
    __table_args__ = (
        CheckConstraint(f"youtube_id ~ '{YOUTUBE_ID_RE}'", name="ck_videos_youtube_id"),
        CheckConstraint("source in ('curated','youtube')", name="ck_videos_source"),
        Index("ix_videos_tsv", "tsv", postgresql_using="gin"),
        Index(
            "ix_videos_embedding",
            "embedding",
            postgresql_using="hnsw",
            postgresql_ops={"embedding": "vector_cosine_ops"},
        ),
        Index(
            "ix_videos_title_trgm",
            "title",
            postgresql_using="gin",
            postgresql_ops={"title": "gin_trgm_ops"},
        ),
    )
    id: Mapped[uuid.UUID] = _uuid()
    youtube_id: Mapped[str] = mapped_column(String(11), unique=True, nullable=False)
    title: Mapped[str] = mapped_column(String(300), nullable=False)
    description: Mapped[str] = mapped_column(Text, default="", nullable=False)
    channel: Mapped[str] = mapped_column(String(200), default="", nullable=False)
    duration_s: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    topic: Mapped[str] = mapped_column(String(100), default="", nullable=False, index=True)
    tags: Mapped[list[str]] = mapped_column(ARRAY(String(60)), default=list, nullable=False)
    tags_text: Mapped[str] = mapped_column(Text, default="", nullable=False)
    source: Mapped[str] = mapped_column(String(10), default="curated", nullable=False)
    embeddable: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    embedding: Mapped[list[float] | None] = mapped_column(Vector(EMBED_DIM))
    tsv: Mapped[str] = mapped_column(
        TSVECTOR,
        Computed(
            "setweight(to_tsvector('english', coalesce(title,'')), 'A') || "
            "setweight(to_tsvector('english', coalesce(topic,'') || ' ' || coalesce(tags_text,'')), 'B') || "
            "setweight(to_tsvector('english', coalesce(description,'')), 'C')",
            persisted=True,
        ),
    )
    created_at: Mapped[datetime] = _created()


class YoutubeQueryCache(Base):
    __tablename__ = "youtube_query_cache"
    query: Mapped[str] = mapped_column(String(200), primary_key=True)
    youtube_ids: Mapped[list[str]] = mapped_column(ARRAY(String(11)), nullable=False)
    fetched_at: Mapped[datetime] = _created()


class Conversation(Base):
    __tablename__ = "conversations"
    id: Mapped[uuid.UUID] = _uuid()
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True, nullable=False
    )
    title: Mapped[str] = mapped_column(String(120), default="New chat", nullable=False)
    created_at: Mapped[datetime] = _created()
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )


class Message(Base):
    __tablename__ = "messages"
    id: Mapped[uuid.UUID] = _uuid()
    conversation_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("conversations.id", ondelete="CASCADE"), index=True, nullable=False
    )
    role: Mapped[str] = mapped_column(String(10), nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    video_ids: Mapped[list[str]] = mapped_column(ARRAY(String(11)), default=list, nullable=False)
    created_at: Mapped[datetime] = _created()


class WatchHistory(Base):
    __tablename__ = "watch_history"
    id: Mapped[uuid.UUID] = _uuid()
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True, nullable=False
    )
    youtube_id: Mapped[str] = mapped_column(String(11), nullable=False)
    created_at: Mapped[datetime] = _created()


class SavedVideo(Base):
    """A user's library ("Save to practice routine")."""

    __tablename__ = "saved_videos"
    __table_args__ = (UniqueConstraint("user_id", "youtube_id", name="uq_saved_user_video"),)
    id: Mapped[uuid.UUID] = _uuid()
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True, nullable=False
    )
    youtube_id: Mapped[str] = mapped_column(
        ForeignKey("videos.youtube_id", ondelete="CASCADE"), nullable=False
    )
    created_at: Mapped[datetime] = _created()
