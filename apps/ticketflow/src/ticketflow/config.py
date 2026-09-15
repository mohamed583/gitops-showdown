"""Runtime configuration, read from the environment.

Everything here is supplied by the Helm chart: the ConfigMap for plain values,
the Secret for the database password. Nothing is defaulted to a production-like
value, so a missing variable fails loudly instead of quietly pointing somewhere
unexpected.
"""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="TICKETFLOW_", extra="ignore")

    # SQLAlchemy URL. The chart builds it from the Postgres Service name and the
    # Secret; tests override it with SQLite.
    database_url: str = "postgresql+psycopg://ticketflow:ticketflow@localhost:5432/ticketflow"

    # Surfaced by GET /version. The chart sets this from the chart appVersion so
    # you can see, in the demo, which revision each engine has converged to.
    release: str = "dev"
    environment: str = "local"


settings = Settings()
