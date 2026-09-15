"""Probe ticketflow through its Kubernetes Service, from inside the cluster.

Run by `make smoke` via `kubectl exec`. Hitting the Service name rather than
localhost proves Service routing and DNS, not just that the process listens.
No host port is involved, so the check cannot race a stale port-forward.
"""

import json
import sys
import urllib.error
import urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8000"
failures = []


def call(method: str, path: str, body: dict | None = None) -> tuple[int, str]:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        f"{BASE}{path}",
        data=data,
        method=method,
        headers={"Content-Type": "application/json"} if data else {},
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode()


def check(label: str, expected: int, method: str, path: str, body: dict | None = None) -> None:
    status, payload = call(method, path, body)
    ok = status == expected
    if not ok:
        failures.append(f"{label}: expected {expected}, got {status}")
    print(f"    {'PASS' if ok else 'FAIL'}  {label:<24} {status}  {payload[:96]}")


check("liveness", 200, "GET", "/healthz")
check("readiness", 200, "GET", "/readyz")
check("version", 200, "GET", "/version")
# A 201 here is the real proof the migration ran: without the tickets table
# this is a 500, not a 201.
check("create ticket", 201, "POST", "/tickets", {"title": "smoke test", "priority": "low"})
check("list tickets", 200, "GET", "/tickets")
check("unknown ticket 404", 404, "GET", "/tickets/999999")
check("invalid payload 422", 422, "POST", "/tickets", {"title": ""})

if failures:
    print("\n  smoke probe FAILED:")
    for failure in failures:
        print(f"    - {failure}")
    sys.exit(1)
print("\n    all probes passed")
