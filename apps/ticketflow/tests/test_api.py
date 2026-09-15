"""API behaviour."""


def test_healthz_does_not_touch_the_database(client):
    # Liveness must stay green even with no schema at all -- see main.healthz.
    assert client.get("/healthz").status_code == 200
    assert client.get("/healthz").json() == {"status": "ok"}


def test_readyz_is_green_once_the_schema_exists(client):
    response = client.get("/readyz")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_version_reports_the_release(client):
    body = client.get("/version").json()
    assert body["version"] == "0.1.0"
    assert set(body) == {"version", "release", "environment"}


def test_create_then_read_a_ticket(client):
    created = client.post(
        "/tickets",
        json={
            "title": "disk full on node-3",
            "description": "kubelet evicting",
            "priority": "high",
        },
    )
    assert created.status_code == 201
    ticket = created.json()
    assert ticket["id"] > 0
    assert ticket["status"] == "open"
    assert ticket["priority"] == "high"

    fetched = client.get(f"/tickets/{ticket['id']}")
    assert fetched.status_code == 200
    assert fetched.json()["title"] == "disk full on node-3"


def test_defaults_are_applied(client):
    ticket = client.post("/tickets", json={"title": "minimal"}).json()
    assert ticket["priority"] == "normal"
    assert ticket["description"] == ""


def test_listing_is_ordered_by_id(client):
    for title in ("first", "second", "third"):
        client.post("/tickets", json={"title": title})
    titles = [t["title"] for t in client.get("/tickets").json()]
    assert titles == ["first", "second", "third"]


def test_unknown_ticket_is_404(client):
    assert client.get("/tickets/4242").status_code == 404


def test_invalid_priority_is_rejected(client):
    response = client.post("/tickets", json={"title": "x", "priority": "catastrophic"})
    assert response.status_code == 422


def test_empty_title_is_rejected(client):
    assert client.post("/tickets", json={"title": ""}).status_code == 422
