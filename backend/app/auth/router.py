import uuid
from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Cookie, Header, HTTPException, Request, Response, status
from pydantic import BaseModel, EmailStr, Field
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError

from app.config import get_settings
from app.deps import DB, CurrentUser, limiter
from app.models import RefreshToken, User
from app.security import (
    create_access_token,
    hash_password,
    hash_token,
    new_refresh_token,
    password_problem,
    verify_password,
)

router = APIRouter(prefix="/api/auth", tags=["auth"])
COOKIE = "ott_refresh"
COOKIE_PATH = "/api/auth"


class Credentials(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=128)


class RefreshBody(BaseModel):
    refresh_token: str | None = Field(default=None, max_length=200)


class UserOut(BaseModel):
    id: uuid.UUID
    email: str
    is_admin: bool


class TokenOut(BaseModel):
    access_token: str
    token_type: str = "bearer"
    refresh_token: str | None = None
    user: UserOut


ClientHeader = Annotated[str | None, Header(alias="X-Client")]


async def _issue(
    db: DB, user: User, response: Response, client: str | None, family: uuid.UUID | None = None
) -> TokenOut:
    s = get_settings()
    raw, digest = new_refresh_token()
    db.add(
        RefreshToken(
            user_id=user.id,
            token_hash=digest,
            family_id=family or uuid.uuid4(),
            expires_at=datetime.now(UTC) + timedelta(days=s.refresh_token_days),
        )
    )
    await db.commit()
    out = TokenOut(
        access_token=create_access_token(user.id, user.is_admin),
        user=UserOut(id=user.id, email=user.email, is_admin=user.is_admin),
    )
    if client == "native":
        out.refresh_token = raw
    else:
        response.set_cookie(
            COOKIE,
            raw,
            max_age=s.refresh_token_days * 86400,
            path=COOKIE_PATH,
            httponly=True,
            secure=True,
            samesite="strict",
        )
    return out


@router.post("/register", response_model=TokenOut, status_code=201)
@limiter.limit("5/minute")
async def register(
    request: Request, body: Credentials, db: DB, response: Response, x_client: ClientHeader = None
):
    if problem := password_problem(body.password):
        raise HTTPException(422, problem)
    user = User(email=body.email.lower(), password_hash=hash_password(body.password))
    db.add(user)
    try:
        await db.flush()
    except IntegrityError:
        await db.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "Email already registered") from None
    return await _issue(db, user, response, x_client)


@router.post("/login", response_model=TokenOut)
@limiter.limit("10/minute")
async def login(
    request: Request, body: Credentials, db: DB, response: Response, x_client: ClientHeader = None
):
    s = get_settings()
    user = await db.scalar(select(User).where(User.email == body.email.lower()))
    now = datetime.now(UTC)
    bad = HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid email or password")
    ok = verify_password(body.password, user.password_hash if user else None)
    if user is None:
        raise bad
    if user.locked_until and user.locked_until > now:
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Too many attempts, try later")
    if not ok:
        user.failed_logins += 1
        if user.failed_logins >= s.max_login_failures:
            user.locked_until = now + timedelta(minutes=s.lockout_minutes)
            user.failed_logins = 0
        await db.commit()
        raise bad
    user.failed_logins = 0
    user.locked_until = None
    return await _issue(db, user, response, x_client)


@router.post("/refresh", response_model=TokenOut)
@limiter.limit("30/minute")
async def refresh(
    request: Request,
    db: DB,
    response: Response,
    body: RefreshBody | None = None,
    ott_refresh: Annotated[str | None, Cookie()] = None,
    x_client: ClientHeader = None,
):
    raw = (body.refresh_token if body else None) or ott_refresh
    denied = HTTPException(status.HTTP_401_UNAUTHORIZED, "Session expired")
    if not raw:
        raise denied
    token = await db.scalar(select(RefreshToken).where(RefreshToken.token_hash == hash_token(raw)))
    if token is None:
        raise denied
    if token.revoked:
        # Reuse of a rotated token: assume theft, revoke the whole family.
        await db.execute(
            update(RefreshToken)
            .where(RefreshToken.family_id == token.family_id)
            .values(revoked=True)
        )
        await db.commit()
        response.delete_cookie(COOKIE, path=COOKIE_PATH)
        raise denied
    if token.expires_at <= datetime.now(UTC):
        raise denied
    token.revoked = True
    user = await db.get(User, token.user_id)
    if user is None:
        raise denied
    return await _issue(db, user, response, x_client, family=token.family_id)


@router.post("/logout", status_code=204)
async def logout(
    db: DB,
    response: Response,
    body: RefreshBody | None = None,
    ott_refresh: Annotated[str | None, Cookie()] = None,
):
    raw = (body.refresh_token if body else None) or ott_refresh
    if raw:
        token = await db.scalar(
            select(RefreshToken).where(RefreshToken.token_hash == hash_token(raw))
        )
        if token:
            await db.execute(
                update(RefreshToken)
                .where(RefreshToken.family_id == token.family_id)
                .values(revoked=True)
            )
            await db.commit()
    response.delete_cookie(COOKIE, path=COOKIE_PATH)


@router.get("/me", response_model=UserOut)
async def me(user: CurrentUser):
    return UserOut(id=user.id, email=user.email, is_admin=user.is_admin)
