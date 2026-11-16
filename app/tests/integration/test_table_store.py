"""Exercises TableOrderStore against Azurite, the Azure Storage emulator.

Run with:  npx azurite-table --inMemoryPersistence &   then   pytest -m integration
"""

from __future__ import annotations

import os
import uuid
from collections.abc import AsyncIterator
from decimal import Decimal

import pytest
from pydantic import SecretStr

from tradeops.config import Settings
from tradeops.domain import Order, OrderStatus, OrderType, Side, utcnow
from tradeops.store import OrderExistsError, TableOrderStore

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        not os.getenv("TRADEOPS_TEST_AZURITE"), reason="TRADEOPS_TEST_AZURITE not set"
    ),
]

# Azurite's published well-known development key; not a secret.
AZURITE = (
    "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;"
    "AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/"  # gitleaks:allow
    "K1SZFPTOtr/KBHBeksoGMGw==;"
    "TableEndpoint=http://127.0.0.1:10002/devstoreaccount1;"
)


@pytest.fixture
async def table_store() -> AsyncIterator[TableOrderStore]:
    settings = Settings(
        storage_connection_string=SecretStr(AZURITE), orders_table=f"orders{uuid.uuid4().hex[:8]}"
    )
    store = TableOrderStore.from_settings(settings)
    yield store
    await store.close()


def make_order(order_id: str, **overrides: object) -> Order:
    now = utcnow()
    data: dict[str, object] = {
        "order_id": order_id,
        "account_id": "ACC-1001",
        "client_order_id": "c-1",
        "symbol": "AAPL",
        "side": Side.BUY,
        "order_type": OrderType.LIMIT,
        "quantity": 10,
        "limit_price": Decimal("230.1234"),
        "execution_price": Decimal("230.1234"),
        "notional": Decimal("2301.23"),
        "status": OrderStatus.ACCEPTED,
        "reject_reasons": [],
        "fingerprint": "f",
        "accepted_by_revision": "r1",
        "created_at": now,
        "updated_at": now,
    }
    data.update(overrides)
    return Order.model_validate(data)


async def test_round_trip_preserves_decimals_and_datetimes(table_store: TableOrderStore) -> None:
    order = make_order(str(uuid.uuid4()), reject_reasons=["A", "B"])
    await table_store.insert(order)
    loaded = await table_store.get(order.account_id, order.order_id)
    assert loaded == order
    assert loaded is not None
    assert isinstance(loaded.notional, Decimal)


async def test_duplicate_insert_raises_with_existing(table_store: TableOrderStore) -> None:
    order = make_order(str(uuid.uuid4()))
    await table_store.insert(order)
    with pytest.raises(OrderExistsError) as exc:
        await table_store.insert(order.model_copy(update={"quantity": 99}))
    assert exc.value.existing.quantity == 10


async def test_replace_list_and_ping(table_store: TableOrderStore) -> None:
    order = make_order(str(uuid.uuid4()))
    await table_store.insert(order)
    settled = order.model_copy(
        update={"status": OrderStatus.SETTLED, "commission": Decimal("1.00")}
    )
    await table_store.replace(settled)
    assert (await table_store.list_for_account("ACC-1001", 10))[0].status is OrderStatus.SETTLED
    assert await table_store.get("ACC-1001", "missing") is None
    await table_store.ping()
