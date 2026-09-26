"""Per-user account data: app settings (validated JSON on the user row) and the
saved-videos library."""

from typing import Annotated, Literal

from fastapi import APIRouter, HTTPException, Path, Request, Response
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator
from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert

from app.config import get_settings
from app.deps import DB, CurrentUser, limiter
from app.models import SavedVideo, Video
from app.videos.router import VideoOut

router = APIRouter(prefix="/api/me", tags=["account"])

PLAYBACK_RATES = (0.5, 0.75, 1.0, 1.25, 1.5, 2.0)


class Preferences(BaseModel):
    model_config = ConfigDict(extra="forbid")

    model: str | None = None
    player_mode: Literal["mini", "theater"] = "mini"
    autoplay_next: bool = False
    playback_rate: float = 1.0
    start_muted: bool = False
    voice_enabled: bool = True
    voice_language: str = Field(default="en-US", pattern=r"^[a-z]{2,3}(-[A-Z]{2})?$")
    appearance: Literal["light", "dark", "system"] = "light"

    @field_validator("model")
    @classmethod
    def _model(cls, v: str | None) -> str | None:
        if v is not None and v not in get_settings().allowed_models:
            raise ValueError("Model not allowed")
        return v

    @field_validator("playback_rate")
    @classmethod
    def _rate(cls, v: float) -> float:
        if v not in PLAYBACK_RATES:
            raise ValueError(f"Playback rate must be one of {PLAYBACK_RATES}")
        return v


class PreferencesPatch(BaseModel):
    """Any subset of [Preferences]; validated again as a whole before saving."""

    model_config = ConfigDict(extra="forbid")

    model: str | None = None
    player_mode: Literal["mini", "theater"] | None = None
    autoplay_next: bool | None = None
    playback_rate: float | None = None
    start_muted: bool | None = None
    voice_enabled: bool | None = None
    voice_language: str | None = Field(default=None, max_length=12)
    appearance: Literal["light", "dark", "system"] | None = None


def load(stored: dict | None) -> Preferences:
    """Stored values that no longer validate (e.g. a removed model) fall back to defaults."""
    good: dict = {}
    for key, value in (stored or {}).items():
        if key not in Preferences.model_fields:
            continue
        try:
            Preferences(**{key: value})
            good[key] = value
        except ValidationError:
            pass
    return Preferences(**good)


@router.get("/preferences", response_model=Preferences)
async def get_preferences(user: CurrentUser):
    return load(user.preferences)


@router.patch("/preferences", response_model=Preferences)
@limiter.limit("60/minute")
async def patch_preferences(request: Request, body: PreferencesPatch, db: DB, user: CurrentUser):
    merged = load(user.preferences).model_dump() | body.model_dump(exclude_unset=True)
    try:
        prefs = Preferences(**merged)
    except ValidationError as e:
        raise HTTPException(422, e.errors()[0]["msg"].replace("Value error, ", "")) from None
    user.preferences = prefs.model_dump()
    await db.commit()
    return prefs


# ------------------------------------------------------------------ library (OTTAI-16)

YoutubeId = Annotated[str, Path(pattern=r"^[A-Za-z0-9_-]{11}$")]
MAX_SAVED = 500


@router.get("/saved", response_model=list[VideoOut])
async def saved_videos(db: DB, user: CurrentUser):
    rows = await db.scalars(
        select(Video)
        .join(SavedVideo, SavedVideo.youtube_id == Video.youtube_id)
        .where(SavedVideo.user_id == user.id)
        .order_by(SavedVideo.created_at.desc())
        .limit(MAX_SAVED)
    )
    return [VideoOut.of(v) for v in rows]


@router.put("/saved/{youtube_id}", status_code=204)
@limiter.limit("60/minute")
async def save_video(request: Request, youtube_id: YoutubeId, db: DB, user: CurrentUser):
    """Idempotent: saving twice keeps one entry."""
    if await db.scalar(select(Video.id).where(Video.youtube_id == youtube_id)) is None:
        raise HTTPException(404, "Unknown video")
    await db.execute(
        insert(SavedVideo)
        .values(user_id=user.id, youtube_id=youtube_id)
        .on_conflict_do_nothing(constraint="uq_saved_user_video")
    )
    await db.commit()
    return Response(status_code=204)


@router.delete("/saved/{youtube_id}", status_code=204)
@limiter.limit("60/minute")
async def unsave_video(request: Request, youtube_id: YoutubeId, db: DB, user: CurrentUser):
    await db.execute(
        delete(SavedVideo).where(SavedVideo.user_id == user.id, SavedVideo.youtube_id == youtube_id)
    )
    await db.commit()
    return Response(status_code=204)
