"""Management commands.

python -m app.cli create-admin <email>     (password read from prompt / OTT_ADMIN_PASSWORD)
python -m app.cli seed                     (load seed/catalog.json into the catalog)
python -m app.cli reembed                  (recompute missing embeddings)
"""

import asyncio
import getpass
import json
import os
import sys
from pathlib import Path

from sqlalchemy import select

from app import ollama
from app.db import SessionLocal, engine
from app.models import User, Video
from app.security import hash_password, password_problem
from app.videos.service import doc_text, upsert_videos

SEED = Path(__file__).resolve().parents[1] / "seed" / "catalog.json"


async def create_admin(email: str) -> None:
    pw = os.environ.get("OTT_ADMIN_PASSWORD") or getpass.getpass("Admin password: ")
    if problem := password_problem(pw):
        sys.exit(problem)
    async with SessionLocal() as db:
        user = await db.scalar(select(User).where(User.email == email.lower()))
        if user is None:
            db.add(User(email=email.lower(), password_hash=hash_password(pw), is_admin=True))
        else:
            user.is_admin = True
            user.password_hash = hash_password(pw)
        await db.commit()
    print(f"admin ready: {email}")


async def seed() -> None:
    items = json.loads(SEED.read_text(encoding="utf-8"))
    async with SessionLocal() as db:
        for i in range(0, len(items), 16):
            await upsert_videos(db, items[i : i + 16], source="curated")
    print(f"seeded {len(items)} videos")


async def reembed() -> None:
    async with SessionLocal() as db:
        videos = list(await db.scalars(select(Video).where(Video.embedding.is_(None))))
        for i in range(0, len(videos), 16):
            batch = videos[i : i + 16]
            vecs = await ollama.embed([doc_text(v) for v in batch])
            if vecs is None:
                sys.exit("Ollama unavailable")
            for v, vec in zip(batch, vecs, strict=True):
                v.embedding = vec
            await db.commit()
    print(f"embedded {len(videos)} videos")


async def main(argv: list[str]) -> None:
    try:
        match argv:
            case ["create-admin", email]:
                await create_admin(email)
            case ["seed"]:
                await seed()
            case ["reembed"]:
                await reembed()
            case _:
                sys.exit(__doc__)
    finally:
        await ollama.close()
        await engine.dispose()


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:]))
