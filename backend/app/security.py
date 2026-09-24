import hashlib
import secrets
import uuid
from datetime import UTC, datetime, timedelta

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerifyMismatchError

from app.config import get_settings

_ph = PasswordHasher()  # argon2id with library defaults
_DUMMY_HASH = _ph.hash(secrets.token_urlsafe(16))
ALGO = "HS256"

COMMON_PASSWORDS = {
    "password", "password1", "password123", "1234567890", "12345678910", "qwertyuiop",
    "iloveyou12", "letmein123", "welcome123", "admin12345", "passw0rd12", "abc1234567",
}


def hash_password(pw: str) -> str:
    return _ph.hash(pw)


def verify_password(pw: str, pw_hash: str | None) -> bool:
    """Constant-ish time: always runs one argon2 verification."""
    try:
        return _ph.verify(pw_hash or _DUMMY_HASH, pw) and pw_hash is not None
    except (VerifyMismatchError, InvalidHashError):
        return False


def password_problem(pw: str) -> str | None:
    if len(pw) < 10:
        return "Password must be at least 10 characters"
    if len(pw) > 128:
        return "Password must be at most 128 characters"
    if pw.lower() in COMMON_PASSWORDS:
        return "Password is too common"
    return None


def create_access_token(user_id: uuid.UUID, is_admin: bool) -> str:
    s = get_settings()
    now = datetime.now(UTC)
    payload = {
        "sub": str(user_id),
        "adm": is_admin,
        "iat": now,
        "exp": now + timedelta(minutes=s.access_token_minutes),
        "typ": "access",
    }
    return jwt.encode(payload, s.jwt_secret, algorithm=ALGO)


def decode_access_token(token: str) -> dict:
    payload = jwt.decode(
        token, get_settings().jwt_secret, algorithms=[ALGO], options={"require": ["exp", "sub"]}
    )
    if payload.get("typ") != "access":
        raise jwt.InvalidTokenError("wrong token type")
    return payload


def new_refresh_token() -> tuple[str, str]:
    raw = secrets.token_urlsafe(48)
    return raw, hash_token(raw)


def hash_token(raw: str) -> str:
    return hashlib.sha256(raw.encode()).hexdigest()
