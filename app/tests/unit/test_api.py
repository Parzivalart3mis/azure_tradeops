from __future__ import annotations

import json
import logging
import random
import time
from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient

from tests.conftest import order_payload
from tradeops.api import create_app
from tradeops.bus import MemoryBus
from tradeops.config import Backend, Settings
from tradeops.faults import FaultInjector
from tradeops.store import MemoryOrderStore
from tradeops.telemetry import JsonFormatter


def wait_for_status(
    client: TestClient, location: str, status: str, timeout: float = 5
) -> dict[str, object]:
    deadline = time.monotonic() + timeout
    while True:
        body = client.get(location).json()
        if body["status"] == status or time.monotonic() > deadline:
            return body  # type: ignore[no-any-return]
        time.sleep(0.02)


class TestOps:
    def test_healthz(self, client: TestClient) -> None:
        assert client.get("/healthz").json() == {"status": "ok"}

    def test_readyz(self, client: TestClient) -> None:
        response = client.get("/readyz")
        assert response.status_code == 200
        assert response.json()["checks"] == {"ledger": "ok", "queue": "ok"}

    def test_readyz_reports_failed_dependency(self, settings: Settings, bus: MemoryBus) -> None:
        class DownStore(MemoryOrderStore):
            async def ping(self) -> None:
                raise ConnectionError("table endpoint unreachable")

        with TestClient(create_app(settings, store=DownStore(), publisher=bus)) as client:
            response = client.get("/readyz")
        assert response.status_code == 503
        assert response.json()["checks"]["ledger"] == "unavailable"

    def test_version_and_revision_headers(self, client: TestClient) -> None:
        response = client.get("/version")
        assert response.json()["version"] == "1.2.3"
        assert response.json()["fault_injection"] is False
        assert response.headers["X-TradeOps-Revision"] == "ca-tradeops-api-test--r1"
        assert response.headers["X-Content-Type-Options"] == "nosniff"

    def test_request_id_is_echoed_when_valid(self, client: TestClient) -> None:
        good = client.get("/healthz", headers={"X-Request-ID": "smoke-12345678"})
        assert good.headers["X-Request-ID"] == "smoke-12345678"
        bad = client.get("/healthz", headers={"X-Request-ID": "<script>"})
        assert bad.headers["X-Request-ID"] != "<script>"


class TestOrders:
    def test_submit_settle_and_fetch(self, client: TestClient) -> None:
        response = client.post("/v1/orders", json=order_payload())
        assert response.status_code == 201
        body = response.json()
        assert body["status"] == "ACCEPTED"
        assert body["notional"] == "23150.00"  # money is a string on the wire

        settled = wait_for_status(client, response.headers["Location"], "SETTLED")
        assert settled["status"] == "SETTLED"
        assert settled["commission"] == "11.58"

        listing = client.get("/v1/accounts/ACC-1001/orders").json()
        assert [o["order_id"] for o in listing] == [body["order_id"]]

    def test_replay_returns_200_with_same_order(self, client: TestClient) -> None:
        first = client.post("/v1/orders", json=order_payload())
        second = client.post("/v1/orders", json=order_payload())
        assert second.status_code == 200
        assert second.json()["order_id"] == first.json()["order_id"]

    def test_idempotency_conflict(self, client: TestClient) -> None:
        client.post("/v1/orders", json=order_payload())
        response = client.post("/v1/orders", json=order_payload(quantity=7))
        assert response.status_code == 409
        assert response.json()["error"] == "idempotency_conflict"

    def test_risk_rejection_is_recorded_not_errored(self, client: TestClient) -> None:
        response = client.post("/v1/orders", json=order_payload(symbol="ACME", limit_price="12.50"))
        assert response.status_code == 201
        assert response.json()["status"] == "REJECTED"
        assert response.json()["reject_reasons"] == ["RESTRICTED_INSTRUMENT"]

    def test_schema_violation_is_422(self, client: TestClient) -> None:
        assert client.post("/v1/orders", json=order_payload(quantity=0)).status_code == 422

    def test_unknown_order_is_404(self, client: TestClient) -> None:
        response = client.get("/v1/accounts/ACC-1001/orders/00000000-0000-0000-0000-000000000000")
        assert response.status_code == 404

    def test_bad_path_parameters_are_422(self, client: TestClient) -> None:
        assert client.get("/v1/accounts/acc!/orders").status_code == 422

    def test_queue_outage_returns_503_then_retry_succeeds(
        self, client: TestClient, bus: MemoryBus
    ) -> None:
        bus.fail_next_publishes = 1
        outage = client.post("/v1/orders", json=order_payload())
        assert outage.status_code == 503
        assert outage.headers["Retry-After"] == "2"
        retry = client.post("/v1/orders", json=order_payload())
        assert retry.status_code == 200
        assert retry.json()["enqueued"] is True


class TestFaultInjection:
    @pytest.fixture
    def faulty(self, settings: Settings) -> Iterator[TestClient]:
        faulty_settings = settings.model_copy(update={"fault_rate": 1.0})
        app = create_app(
            faulty_settings,
            store=MemoryOrderStore(),
            publisher=MemoryBus(),
            faults=FaultInjector(faulty_settings, rng=random.Random(7)),
        )
        with TestClient(app) as client:
            yield client

    def test_business_endpoints_fail_but_probes_pass(self, faulty: TestClient) -> None:
        assert faulty.get("/healthz").status_code == 200
        assert faulty.get("/readyz").status_code == 200
        assert faulty.get("/version").json()["fault_injection"] is True
        response = faulty.post("/v1/orders", json=order_payload())
        assert response.status_code == 500
        # Failures still name the revision that produced them.
        assert response.headers["X-TradeOps-Revision"] == "ca-tradeops-api-test--r1"

    def test_partial_fault_rate(self, settings: Settings) -> None:
        partial = settings.model_copy(update={"fault_rate": 0.5})
        injector = FaultInjector(partial, rng=random.Random(42))
        app = create_app(partial, store=MemoryOrderStore(), publisher=MemoryBus(), faults=injector)
        with TestClient(app) as client:
            codes = [
                client.post("/v1/orders", json=order_payload(client_order_id=f"c-{i}")).status_code
                for i in range(200)
            ]
        failure_rate = codes.count(500) / len(codes)
        assert 0.35 < failure_rate < 0.65


class TestSettingsAndLogging:
    def test_azure_backend_requires_endpoints(self) -> None:
        with pytest.raises(ValueError, match="TRADEOPS_STORAGE_TABLE_ENDPOINT"):
            Settings(backend=Backend.AZURE)
        with pytest.raises(ValueError, match="SERVICEBUS_NAMESPACE"):
            Settings(
                backend=Backend.AZURE, storage_table_endpoint="https://x.table.core.windows.net"
            )

    def test_revision_from_container_apps_env(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("CONTAINER_APP_REVISION", "ca-tradeops-api-dev--r42")
        assert Settings().revision == "ca-tradeops-api-dev--r42"

    def test_json_formatter(self) -> None:
        formatter = JsonFormatter(service="svc", environment="test", revision="r1")
        record = logging.makeLogRecord(
            {
                "name": "tradeops.x",
                "levelname": "INFO",
                "msg": "hello %s",
                "args": ("world",),
                "order_id": "o1",
            }
        )
        line = json.loads(formatter.format(record))
        assert line["message"] == "hello world"
        assert line["order_id"] == "o1"
        assert line["revision"] == "r1"
