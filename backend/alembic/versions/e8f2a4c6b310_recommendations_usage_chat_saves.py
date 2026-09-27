"""messages.recommendations/source/model/tokens; saved_videos per conversation

Revision ID: e8f2a4c6b310
Revises: d5b1c7e3a902
Create Date: 2026-09-27 12:00:00
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = 'e8f2a4c6b310'
down_revision = 'd5b1c7e3a902'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column('messages', sa.Column('recommendations', postgresql.JSONB(), nullable=True))
    op.add_column('messages', sa.Column('source', sa.String(length=10), nullable=True))
    op.add_column('messages', sa.Column('model', sa.String(length=60), nullable=True))
    op.add_column('messages', sa.Column('prompt_tokens', sa.Integer(), server_default='0', nullable=False))
    op.add_column('messages', sa.Column('output_tokens', sa.Integer(), server_default='0', nullable=False))

    # Saves now belong to a chat; the old global library is dropped, not moved.
    op.execute('DELETE FROM saved_videos')
    op.drop_constraint('uq_saved_user_video', 'saved_videos', type_='unique')
    op.add_column(
        'saved_videos',
        sa.Column('conversation_id', postgresql.UUID(as_uuid=True), nullable=False),
    )
    op.create_foreign_key(
        'fk_saved_videos_conversation_id', 'saved_videos', 'conversations',
        ['conversation_id'], ['id'], ondelete='CASCADE',
    )
    op.create_index(op.f('ix_saved_videos_conversation_id'), 'saved_videos', ['conversation_id'])
    op.create_unique_constraint(
        'uq_saved_conversation_video', 'saved_videos', ['conversation_id', 'youtube_id']
    )


def downgrade() -> None:
    # Per-chat saves can't be folded back into one library without guessing: drop them.
    op.execute('DELETE FROM saved_videos')
    op.drop_constraint('uq_saved_conversation_video', 'saved_videos', type_='unique')
    op.drop_index(op.f('ix_saved_videos_conversation_id'), table_name='saved_videos')
    op.drop_constraint('fk_saved_videos_conversation_id', 'saved_videos', type_='foreignkey')
    op.drop_column('saved_videos', 'conversation_id')
    op.create_unique_constraint('uq_saved_user_video', 'saved_videos', ['user_id', 'youtube_id'])

    op.drop_column('messages', 'output_tokens')
    op.drop_column('messages', 'prompt_tokens')
    op.drop_column('messages', 'model')
    op.drop_column('messages', 'source')
    op.drop_column('messages', 'recommendations')
