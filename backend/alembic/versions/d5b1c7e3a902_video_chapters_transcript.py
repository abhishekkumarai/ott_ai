"""videos.chapters_text, videos.transcript (curated by admins)

Revision ID: d5b1c7e3a902
Revises: c3a9f1d2e8b4
Create Date: 2026-09-27 10:00:00
"""
from alembic import op
import sqlalchemy as sa


revision = 'd5b1c7e3a902'
down_revision = 'c3a9f1d2e8b4'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column('videos', sa.Column('chapters_text', sa.Text(), nullable=True))
    op.add_column('videos', sa.Column('transcript', sa.Text(), nullable=True))


def downgrade() -> None:
    op.drop_column('videos', 'transcript')
    op.drop_column('videos', 'chapters_text')
