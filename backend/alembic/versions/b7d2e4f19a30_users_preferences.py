"""users.preferences

Revision ID: b7d2e4f19a30
Revises: 729f233b4a55
Create Date: 2026-09-25 12:00:00
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = 'b7d2e4f19a30'
down_revision = '729f233b4a55'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        'users',
        sa.Column(
            'preferences',
            postgresql.JSONB(astext_type=sa.Text()),
            server_default=sa.text("'{}'::jsonb"),
            nullable=False,
        ),
    )


def downgrade() -> None:
    op.drop_column('users', 'preferences')
