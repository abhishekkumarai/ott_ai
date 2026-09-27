"""multi-source media support (video_ids length, saved_videos length, drop fk constraint)

Revision ID: f9a1b2c3d4e5
Revises: e8f2a4c6b310
Create Date: 2026-09-27 12:30:00
"""
from alembic import op
import sqlalchemy as sa


revision = 'f9a1b2c3d4e5'
down_revision = 'e8f2a4c6b310'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.alter_column('messages', 'video_ids', type_=sa.ARRAY(sa.String(length=60)))
    op.alter_column('messages', 'source', type_=sa.String(length=20))
    op.drop_constraint('saved_videos_youtube_id_fkey', 'saved_videos', type_='foreignkey')
    op.alter_column('saved_videos', 'youtube_id', type_=sa.String(length=60))


def downgrade() -> None:
    op.alter_column('saved_videos', 'youtube_id', type_=sa.String(length=11))
    op.create_foreign_key(
        'saved_videos_youtube_id_fkey', 'saved_videos', 'videos',
        ['youtube_id'], ['youtube_id'], ondelete='CASCADE'
    )
    op.alter_column('messages', 'source', type_=sa.String(length=10))
    op.alter_column('messages', 'video_ids', type_=sa.ARRAY(sa.String(length=11)))
