"""One migration, so dx db:migrate has something to do."""

import sqlalchemy as sa
from alembic import op

revision = "0001"
down_revision = None


def upgrade() -> None:
    op.create_table(
        "demo_notes",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("body", sa.String(255), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("demo_notes")
