import os

from alembic import context
from sqlalchemy import engine_from_config, pool

config = context.config


def url() -> str:
    """Built from the environment dx injects, never from alembic.ini.

    Each worktree and agent instance gets its own database; a URL baked into a
    committed file would migrate whichever one it happened to name.
    """
    # +psycopg, not bare postgresql://: SQLAlchemy would otherwise default to the
    # psycopg2 driver, which is not installed, and report ModuleNotFoundError for
    # a package nothing asked for.
    scheme = "postgresql+psycopg" if "postgres" in os.environ.get("DB_HOST", "") else "mysql+pymysql"
    return "%s://%s:%s@%s:%s/%s" % (
        scheme, os.environ.get("DB_USERNAME", ""), os.environ.get("DB_PASSWORD", ""),
        os.environ.get("DB_HOST", ""), os.environ.get("DB_PORT", ""),
        os.environ.get("DB_DATABASE", ""),
    )


config.set_main_option("sqlalchemy.url", url())


def run_migrations_online() -> None:
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.", poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        context.configure(connection=connection)
        with context.begin_transaction():
            context.run_migrations()


run_migrations_online()
