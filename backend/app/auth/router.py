import uuid
from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Cookie, Header, HTTPException, Request, Response, status
from pydantic import BaseModel, EmailStr, Field
from sqlalchemy import delete, func, select, update
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
DEMO_TTL = timedelta(hours=24)
DEMO_HOURLY_CAP = 300  # global ceiling on demo sessions created per hour


class Credentials(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=128)


class RefreshBody(BaseModel):
    refresh_token: str | None = Field(default=None, max_length=200)


class UserOut(BaseModel):
    id: uuid.UUID
    email: str
    is_admin: bool
    is_demo: bool = False

    @classmethod
    def of(cls, u: User) -> "UserOut":
        return cls(id=u.id, email=u.email, is_admin=u.is_admin, is_demo=u.is_demo)


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
    expires = datetime.now(UTC) + timedelta(days=s.refresh_token_days)
    if user.is_demo:  # a demo session never outlives the demo account
        expires = min(expires, (user.created_at or datetime.now(UTC)) + DEMO_TTL)
    db.add(
        RefreshToken(
            user_id=user.id,
            token_hash=digest,
            family_id=family or uuid.uuid4(),
            expires_at=expires,
        )
    )
    await db.commit()
    out = TokenOut(
        access_token=create_access_token(user.id, user.is_admin and not user.is_demo),
        user=UserOut.of(user),
    )
    if client == "native":
        out.refresh_token = raw
    else:
        response.set_cookie(
            COOKIE,
            raw,
            max_age=int((expires - datetime.now(UTC)).total_seconds()),
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


@router.post("/demo", response_model=TokenOut, status_code=201)
@limiter.limit("5/minute;30/day")
async def demo(request: Request, db: DB, response: Response, x_client: ClientHeader = None):
    """Throwaway account so visitors can try everything without signing up.

    Demo users are never admins, cannot log in with a password, and are deleted
    (with their chats and history) 24 hours after creation.
    """
    now = datetime.now(UTC)
    await db.execute(delete(User).where(User.is_demo.is_(True), User.created_at < now - DEMO_TTL))
    recent = await db.scalar(
        select(func.count()).select_from(User).where(
            User.is_demo.is_(True), User.created_at > now - timedelta(hours=1)
        )
    )
    if (recent or 0) >= DEMO_HOURLY_CAP:
        await db.commit()
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Demo is busy, try again later")
    user = User(
        email=f"demo-{uuid.uuid4().hex[:12]}@demo.invalid",
        # random, never revealed: demo accounts can only be used through their session
        password_hash=hash_password(new_refresh_token()[0]),
        is_demo=True,
        created_at=now,
    )
    db.add(user)
    await db.flush()
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
    return UserOut.of(user)


class PasswordChange(BaseModel):
    current_password: str = Field(min_length=1, max_length=128)
    new_password: str = Field(min_length=1, max_length=128)


class PasswordConfirm(BaseModel):
    password: str = Field(min_length=1, max_length=128)


def _no_demo(user: User) -> None:
    if user.is_demo:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Not available for demo sessions")


async def _confirm_password(db: DB, user: User, password: str, wrong: str) -> None:
    """Password re-entry for sensitive actions, with the same lockout as login, so a
    stolen access token can't be used to guess the password.

    A wrong password is 403, not 401: the app treats 401 as "session expired".
    """
    s = get_settings()
    now = datetime.now(UTC)
    if user.locked_until and user.locked_until > now:
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Too many attempts, try later")
    if not verify_password(password, user.password_hash):
        user.failed_logins += 1
        if user.failed_logins >= s.max_login_failures:
            user.locked_until = now + timedelta(minutes=s.lockout_minutes)
            user.failed_logins = 0
        await db.commit()
        raise HTTPException(status.HTTP_403_FORBIDDEN, wrong)
    user.failed_logins = 0
    user.locked_until = None


@router.post("/change-password", response_model=TokenOut)
@limiter.limit("5/minute")
async def change_password(
    request: Request,
    body: PasswordChange,
    db: DB,
    user: CurrentUser,
    response: Response,
    x_client: ClientHeader = None,
):
    """Signs out every other session; this one gets a fresh token pair."""
    _no_demo(user)
    await _confirm_password(db, user, body.current_password, "Current password is incorrect")
    if problem := password_problem(body.new_password):
        raise HTTPException(422, problem)
    user.password_hash = hash_password(body.new_password)
    await db.execute(
        update(RefreshToken).where(RefreshToken.user_id == user.id).values(revoked=True)
    )
    return await _issue(db, user, response, x_client)


@router.delete("/account", status_code=204)
@limiter.limit("5/minute")
async def delete_account(
    request: Request, body: PasswordConfirm, db: DB, user: CurrentUser, response: Response
):
    """Deletes the user; conversations, messages, history and sessions cascade."""
    _no_demo(user)
    await _confirm_password(db, user, body.password, "Password is incorrect")
    await db.execute(delete(User).where(User.id == user.id))
    await db.commit()
    response.delete_cookie(COOKIE, path=COOKIE_PATH)
