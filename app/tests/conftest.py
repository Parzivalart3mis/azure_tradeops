from __future__ import annotations

from collections.abc import Iterator
from decimal import Decimal
from typing import Any

import pytest
from fastapi.testclient import TestClient

from tradeops.api import create_app
from tradeops.bus import MemoryBus
from tradeops.config import Settings
from tradeops.service import OrderService
from tradeops.store import MemoryOrderStore


@pytest.fixture
def settings() -> Settings:
    return Settings(
        environment="test", revision="ca-tradeops-api-test--r1", version="1.2.3", git_sha="abc123"
    )


@pytest.fixture
def store() -> MemoryOrderStore:
    return MemoryOrderStore()


@pytest.fixture
def bus() -> MemoryBus:
    return MemoryBus()


@pytest.fixture
def service(store: MemoryOrderStore, bus: MemoryBus, settings: Settings) -> OrderService:
    return OrderService(store, bus, settings)


@pytest.fixture
def client(settings: Settings, store: MemoryOrderStore, bus: MemoryBus) -> Iterator[TestClient]:
    app = create_app(settings, store=store, publisher=bus)
    with TestClient(app) as test_client:
        yield test_client


def order_payload(**overrides: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "client_order_id": "c-0001",
        "account_id": "ACC-1001",
        "symbol": "AAPL",
        "side": "BUY",
        "order_type": "LIMIT",
        "quantity": 100,
        "limit_price": "231.50",
    }
    payload.update(overrides)
    return {k: v for k, v in payload.items() if v is not None}


def money(value: str) -> Decimal:
    return Decimal(value)
