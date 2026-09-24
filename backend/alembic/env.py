import asyncio

from alembic import context
from sqlalchemy.ext.asyncio import create_async_engine

from app.config import get_settings
from app.models import Base

target_metadata = Base.metadata


def do_run(connection) -> None:
    context.configure(connection=connection, target_metadata=target_metadata)
    with context.begin_transaction():
        context.run_migrations()


async def run() -> None:
    engine = create_async_engine(get_settings().db_url)
    async with engine.connect() as conn:
        await conn.run_sync(do_run)
        await conn.commit()
    await engine.dispose()


asyncio.run(run())
