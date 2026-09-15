"""Alembic environment.

The database URL comes from the application settings, never from alembic.ini,
so the migration Job and the API agree on where the database is by construction.
"""

from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool

from ticketflow.config import settings
from ticketflow.models import Base

config = context.config

# Without this the logging section of alembic.ini is never applied and the
# migration runs completely silently -- which is useless in a Job whose whole
# purpose is to be watched while it runs.
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

config.set_main_option("sqlalchemy.url", settings.database_url)

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    context.configure(
        url=config.get_main_option("sqlalchemy.url"),
        target_metadata=target_metadata,
        literal_binds=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
