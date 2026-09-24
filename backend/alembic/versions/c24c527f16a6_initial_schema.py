"""initial schema

Revision ID: c24c527f16a6
Revises: 
Create Date: 2026-09-24 20:55:13.060559
"""
from alembic import op
import sqlalchemy as sa
import pgvector.sqlalchemy
from sqlalchemy.dialects import postgresql

revision = 'c24c527f16a6'
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    for ext in ('vector', 'pg_trgm', 'citext'):
        op.execute(f'CREATE EXTENSION IF NOT EXISTS {ext}')
    op.create_table('users',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('email', postgresql.CITEXT(), nullable=False),
    sa.Column('password_hash', sa.String(length=255), nullable=False),
    sa.Column('is_admin', sa.Boolean(), nullable=False),
    sa.Column('failed_logins', sa.Integer(), nullable=False),
    sa.Column('locked_until', sa.DateTime(timezone=True), nullable=True),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('email')
    )
    op.create_table('videos',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('youtube_id', sa.String(length=11), nullable=False),
    sa.Column('title', sa.String(length=300), nullable=False),
    sa.Column('description', sa.Text(), nullable=False),
    sa.Column('channel', sa.String(length=200), nullable=False),
    sa.Column('duration_s', sa.Integer(), nullable=False),
    sa.Column('topic', sa.String(length=100), nullable=False),
    sa.Column('tags', sa.ARRAY(sa.String(length=60)), nullable=False),
    sa.Column('tags_text', sa.Text(), nullable=False),
    sa.Column('source', sa.String(length=10), nullable=False),
    sa.Column('embeddable', sa.Boolean(), nullable=False),
    sa.Column('embedding', pgvector.sqlalchemy.vector.VECTOR(dim=768), nullable=True),
    sa.Column('tsv', postgresql.TSVECTOR(), sa.Computed("setweight(to_tsvector('english', coalesce(title,'')), 'A') || setweight(to_tsvector('english', coalesce(topic,'') || ' ' || coalesce(tags_text,'')), 'B') || setweight(to_tsvector('english', coalesce(description,'')), 'C')", persisted=True), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.CheckConstraint("source in ('curated','youtube')", name='ck_videos_source'),
    sa.CheckConstraint("youtube_id ~ '^[A-Za-z0-9_-]{11}$'", name='ck_videos_youtube_id'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('youtube_id')
    )
    op.create_index('ix_videos_embedding', 'videos', ['embedding'], unique=False, postgresql_using='hnsw', postgresql_ops={'embedding': 'vector_cosine_ops'})
    op.create_index('ix_videos_title_trgm', 'videos', ['title'], unique=False, postgresql_using='gin', postgresql_ops={'title': 'gin_trgm_ops'})
    op.create_index(op.f('ix_videos_topic'), 'videos', ['topic'], unique=False)
    op.create_index('ix_videos_tsv', 'videos', ['tsv'], unique=False, postgresql_using='gin')
    op.create_table('youtube_query_cache',
    sa.Column('query', sa.String(length=200), nullable=False),
    sa.Column('youtube_ids', sa.ARRAY(sa.String(length=11)), nullable=False),
    sa.Column('fetched_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('query')
    )
    op.create_table('conversations',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('user_id', sa.UUID(), nullable=False),
    sa.Column('title', sa.String(length=120), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_conversations_user_id'), 'conversations', ['user_id'], unique=False)
    op.create_table('refresh_tokens',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('user_id', sa.UUID(), nullable=False),
    sa.Column('token_hash', sa.String(length=64), nullable=False),
    sa.Column('family_id', sa.UUID(), nullable=False),
    sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False),
    sa.Column('revoked', sa.Boolean(), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('token_hash')
    )
    op.create_index(op.f('ix_refresh_tokens_family_id'), 'refresh_tokens', ['family_id'], unique=False)
    op.create_index(op.f('ix_refresh_tokens_user_id'), 'refresh_tokens', ['user_id'], unique=False)
    op.create_table('watch_history',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('user_id', sa.UUID(), nullable=False),
    sa.Column('youtube_id', sa.String(length=11), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_watch_history_user_id'), 'watch_history', ['user_id'], unique=False)
    op.create_table('messages',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('conversation_id', sa.UUID(), nullable=False),
    sa.Column('role', sa.String(length=10), nullable=False),
    sa.Column('content', sa.Text(), nullable=False),
    sa.Column('video_ids', sa.ARRAY(sa.String(length=11)), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['conversation_id'], ['conversations.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_messages_conversation_id'), 'messages', ['conversation_id'], unique=False)
    # ### end Alembic commands ###


def downgrade() -> None:
    # ### commands auto generated by Alembic - please adjust! ###
    op.drop_index(op.f('ix_messages_conversation_id'), table_name='messages')
    op.drop_table('messages')
    op.drop_index(op.f('ix_watch_history_user_id'), table_name='watch_history')
    op.drop_table('watch_history')
    op.drop_index(op.f('ix_refresh_tokens_user_id'), table_name='refresh_tokens')
    op.drop_index(op.f('ix_refresh_tokens_family_id'), table_name='refresh_tokens')
    op.drop_table('refresh_tokens')
    op.drop_index(op.f('ix_conversations_user_id'), table_name='conversations')
    op.drop_table('conversations')
    op.drop_table('youtube_query_cache')
    op.drop_index('ix_videos_tsv', table_name='videos', postgresql_using='gin')
    op.drop_index(op.f('ix_videos_topic'), table_name='videos')
    op.drop_index('ix_videos_title_trgm', table_name='videos', postgresql_using='gin', postgresql_ops={'title': 'gin_trgm_ops'})
    op.drop_index('ix_videos_embedding', table_name='videos', postgresql_using='hnsw', postgresql_ops={'embedding': 'vector_cosine_ops'})
    op.drop_table('videos')
    op.drop_table('users')
    # ### end Alembic commands ###
