"""saved_videos

Revision ID: c3a9f1d2e8b4
Revises: b7d2e4f19a30
Create Date: 2026-09-26 10:00:00
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = 'c3a9f1d2e8b4'
down_revision = 'b7d2e4f19a30'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        'saved_videos',
        sa.Column('id', postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column('user_id', postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column('youtube_id', sa.String(length=11), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.ForeignKeyConstraint(['user_id'], ['users.id'], ondelete='CASCADE'),
        sa.ForeignKeyConstraint(['youtube_id'], ['videos.youtube_id'], ondelete='CASCADE'),
        sa.UniqueConstraint('user_id', 'youtube_id', name='uq_saved_user_video'),
    )
    op.create_index(op.f('ix_saved_videos_user_id'), 'saved_videos', ['user_id'], unique=False)


def downgrade() -> None:
    op.drop_index(op.f('ix_saved_videos_user_id'), table_name='saved_videos')
    op.drop_table('saved_videos')
