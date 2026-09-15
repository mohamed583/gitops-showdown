"""ticketflow -- a minimal support-ticket API.

The application is deliberately small. It exists to be deployed, not to be
impressive: the object of study is the two GitOps engines that deliver it, and
the schema migration that sits between them.
"""

from fastapi import Depends, FastAPI, HTTPException, status
from sqlalchemy import select, text
from sqlalchemy.orm import Session

from ticketflow import __version__
from ticketflow.config import settings
from ticketflow.db import get_session
from ticketflow.models import Ticket
from ticketflow.schemas import TicketCreate, TicketRead

app = FastAPI(title="ticketflow", version=__version__)


@app.get("/healthz", tags=["ops"])
def healthz() -> dict[str, str]:
    """Liveness. Deliberately does NOT touch the database.

    A liveness probe that depends on Postgres restarts the API whenever the
    database blinks, which turns a database incident into an application
    incident. Readiness is where the dependency belongs.
    """
    return {"status": "ok"}


@app.get("/readyz", tags=["ops"])
def readyz(session: Session = Depends(get_session)) -> dict[str, str]:
    """Readiness. Fails while the database is unreachable.

    Connectivity only -- deliberately NOT "has the schema been migrated".
    The migration runs as a post-install Helm hook, and Helm waits for the
    Deployment to be ready before it runs post-install hooks. A readiness probe
    that required the migrated schema would therefore deadlock the first
    install: the pod waits for the migration, the migration waits for the pod.
    """
    try:
        session.execute(text("SELECT 1"))
    except Exception as exc:  # noqa: BLE001 -- surfaced verbatim to the probe
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"database not ready: {exc.__class__.__name__}",
        ) from exc
    return {"status": "ready"}


@app.get("/version", tags=["ops"])
def version() -> dict[str, str]:
    """Which revision this pod is running.

    The chart feeds `release` from its appVersion, so during the demo you can
    watch the two engines converge on the same value at different moments.
    """
    return {
        "version": __version__,
        "release": settings.release,
        "environment": settings.environment,
    }


@app.post("/tickets", response_model=TicketRead, status_code=201, tags=["tickets"])
def create_ticket(payload: TicketCreate, session: Session = Depends(get_session)) -> Ticket:
    ticket = Ticket(**payload.model_dump())
    session.add(ticket)
    session.commit()
    session.refresh(ticket)
    return ticket


@app.get("/tickets", response_model=list[TicketRead], tags=["tickets"])
def list_tickets(session: Session = Depends(get_session)) -> list[Ticket]:
    return list(session.scalars(select(Ticket).order_by(Ticket.id)))


@app.get("/tickets/{ticket_id}", response_model=TicketRead, tags=["tickets"])
def get_ticket(ticket_id: int, session: Session = Depends(get_session)) -> Ticket:
    ticket = session.get(Ticket, ticket_id)
    if ticket is None:
        raise HTTPException(status_code=404, detail="ticket not found")
    return ticket
