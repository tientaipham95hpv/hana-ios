"""hybrid voice response and semantic routing modes

Revision ID: 0002_hybrid_voice_modes
Revises: 0001_phase6
"""

import sqlalchemy as sa

from alembic import op

revision = "0002_hybrid_voice_modes"
down_revision = "0001_phase6"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # The Phase 6 baseline uses current ORM metadata for clean installations.
    # A pre-6.2 database still needs both additive columns.
    existing = {
        column["name"] for column in sa.inspect(op.get_bind()).get_columns("turns", schema="hana")
    }
    if "response_mode" not in existing:
        op.add_column(
            "turns",
            sa.Column("response_mode", sa.String(length=16), nullable=False, server_default="AUTO"),
            schema="hana",
        )
    if "semantic_mode" not in existing:
        op.add_column(
            "turns",
            sa.Column(
                "semantic_mode", sa.String(length=24), nullable=False, server_default="daily"
            ),
            schema="hana",
        )


def downgrade() -> None:
    op.drop_column("turns", "semantic_mode", schema="hana")
    op.drop_column("turns", "response_mode", schema="hana")
