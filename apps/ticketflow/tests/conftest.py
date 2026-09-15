"""Test fixtures.

Tests run against SQLite in memory, not Postgres: they exercise the API and the
ORM mapping, which is what unit tests can honestly cover here. Whether the real
migration applies cleanly to Postgres is a question for the cluster, and it is
answered there -- see the migration Job and the e2e workflow.
"""

import os

os.environ["TICKETFLOW_DATABASE_URL"] = "sqlite+pysqlite:///:memory:"

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from sqlalchemy import create_engine  # noqa: E402
from sqlalchemy.orm import sessionmaker  # noqa: E402
from sqlalchemy.pool import StaticPool  # noqa: E402

from ticketflow.db import get_session  # noqa: E402
from ticketflow.main import app  # noqa: E402
from ticketflow.models import Base  # noqa: E402


@pytest.fixture
def client():
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    TestingSession = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)

    def override_get_session():
        session = TestingSession()
        try:
            yield session
        finally:
            session.close()

    app.dependency_overrides[get_session] = override_get_session
    with TestClient(app) as test_client:
        yield test_client
    app.dependency_overrides.clear()
    Base.metadata.drop_all(engine)
