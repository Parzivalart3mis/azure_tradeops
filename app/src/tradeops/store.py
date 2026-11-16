"""Order ledger: in-memory for local use and tests, Azure Table Storage in Azure.

Table layout: PartitionKey = account_id, RowKey = order_id. Order ids are derived from
(account_id, client_order_id), so a duplicate submission collides on insert instead of
creating a second order.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
from datetime import datetime
from decimal import Decimal
from typing import Any, Protocol

from azure.core.credentials_async import AsyncTokenCredential
from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError
from azure.data.tables import UpdateMode
from azure.data.tables.aio import TableClient, TableServiceClient

from tradeops.config import Settings
from tradeops.domain import Order


class OrderExistsError(Exception):
    def __init__(self, existing: Order) -> None:
        super().__init__(f"order {existing.order_id} already exists")
        self.existing = existing


class OrderStore(Protocol):
    async def insert(self, order: Order) -> None: ...
    async def get(self, account_id: str, order_id: str) -> Order | None: ...
    async def replace(self, order: Order) -> None: ...
    async def list_for_account(self, account_id: str, limit: int) -> list[Order]: ...
    async def ping(self) -> None: ...
    async def close(self) -> None: ...


class MemoryOrderStore:
    def __init__(self) -> None:
        self._orders: dict[tuple[str, str], Order] = {}
        self._lock = asyncio.Lock()

    async def insert(self, order: Order) -> None:
        async with self._lock:
            key = (order.account_id, order.order_id)
            if key in self._orders:
                raise OrderExistsError(self._orders[key])
            self._orders[key] = order

    async def get(self, account_id: str, order_id: str) -> Order | None:
        return self._orders.get((account_id, order_id))

    async def replace(self, order: Order) -> None:
        async with self._lock:
            self._orders[(order.account_id, order.order_id)] = order

    async def list_for_account(self, account_id: str, limit: int) -> list[Order]:
        orders = [o for (acct, _), o in self._orders.items() if acct == account_id]
        return sorted(orders, key=lambda o: o.created_at, reverse=True)[:limit]

    async def ping(self) -> None:
        return None

    async def close(self) -> None:
        return None


_DECIMAL_FIELDS = ("limit_price", "execution_price", "notional", "commission", "net_amount")
_DATETIME_FIELDS = ("created_at", "updated_at", "settled_at")


def order_to_entity(order: Order) -> dict[str, Any]:
    entity: dict[str, Any] = order.model_dump(mode="python", exclude={"account_id", "order_id"})
    entity["PartitionKey"] = order.account_id
    entity["RowKey"] = order.order_id
    for name in _DECIMAL_FIELDS:
        value = entity[name]
        entity[name] = str(value) if value is not None else None
    for name in _DATETIME_FIELDS:
        value = entity[name]
        entity[name] = value.isoformat() if value is not None else None
    entity["side"] = order.side.value
    entity["order_type"] = order.order_type.value
    entity["status"] = order.status.value
    entity["reject_reasons"] = json.dumps(order.reject_reasons)
    # Table Storage rejects null properties on insert; omit them instead.
    return {k: v for k, v in entity.items() if v is not None}


def entity_to_order(entity: dict[str, Any]) -> Order:
    data = {k: v for k, v in entity.items() if k not in ("PartitionKey", "RowKey")}
    data["account_id"] = entity["PartitionKey"]
    data["order_id"] = entity["RowKey"]
    for name in _DECIMAL_FIELDS:
        if data.get(name) is not None:
            data[name] = Decimal(data[name])
    for name in _DATETIME_FIELDS:
        if data.get(name) is not None:
            data[name] = datetime.fromisoformat(data[name])
    data["reject_reasons"] = json.loads(data.get("reject_reasons", "[]"))
    return Order.model_validate(data)


class TableOrderStore:
    def __init__(
        self,
        client: TableClient,
        *,
        create_table: bool = False,
        credential: AsyncTokenCredential | None = None,
    ) -> None:
        self._client = client
        self._create_table = create_table
        self._credential = credential
        self._ready = False

    @classmethod
    def from_settings(cls, settings: Settings) -> TableOrderStore:
        if settings.storage_connection_string is not None:
            # Local development against Azurite only. Azure deployments disable shared keys.
            service = TableServiceClient.from_connection_string(
                settings.storage_connection_string.get_secret_value()
            )
            return cls(service.get_table_client(settings.orders_table), create_table=True)

        from azure.identity.aio import DefaultAzureCredential

        if settings.storage_table_endpoint is None:  # guarded by Settings validation
            raise ValueError("storage_table_endpoint is required")
        credential = DefaultAzureCredential()
        client = TableClient(
            endpoint=settings.storage_table_endpoint,
            table_name=settings.orders_table,
            credential=credential,
        )
        return cls(client, credential=credential)

    async def _ensure_table(self) -> None:
        if self._create_table and not self._ready:
            with contextlib.suppress(ResourceExistsError):
                await self._client.create_table()
        self._ready = True

    async def insert(self, order: Order) -> None:
        await self._ensure_table()
        try:
            await self._client.create_entity(order_to_entity(order))
        except ResourceExistsError:
            existing = await self.get(order.account_id, order.order_id)
            if existing is None:  # deleted between the two calls; surface the conflict
                raise
            raise OrderExistsError(existing) from None

    async def get(self, account_id: str, order_id: str) -> Order | None:
        await self._ensure_table()
        try:
            entity = await self._client.get_entity(partition_key=account_id, row_key=order_id)
        except ResourceNotFoundError:
            return None
        return entity_to_order(dict(entity))

    async def replace(self, order: Order) -> None:
        await self._ensure_table()
        await self._client.upsert_entity(order_to_entity(order), mode=UpdateMode.REPLACE)

    async def list_for_account(self, account_id: str, limit: int) -> list[Order]:
        await self._ensure_table()
        orders: list[Order] = []
        entities = self._client.query_entities(
            "PartitionKey eq @pk", parameters={"pk": account_id}, results_per_page=200
        )
        async for entity in entities:
            orders.append(entity_to_order(dict(entity)))
            if len(orders) >= 1000:
                break
        return sorted(orders, key=lambda o: o.created_at, reverse=True)[:limit]

    async def ping(self) -> None:
        await self._ensure_table()
        entities = self._client.query_entities(
            "PartitionKey eq @pk", parameters={"pk": "__readiness__"}, results_per_page=1
        )
        async for _ in entities:
            break

    async def close(self) -> None:
        await self._client.close()
        if self._credential is not None:
            await self._credential.close()
