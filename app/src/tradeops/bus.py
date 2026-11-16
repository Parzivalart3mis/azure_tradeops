"""Settlement queue: an in-process asyncio queue locally, Azure Service Bus in Azure.

The message id is the order id. The Service Bus queue has duplicate detection turned on
(infra/modules/servicebus.bicep), so a retried publish of the same order is dropped by
the broker instead of being settled twice.
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass
from typing import Any, Protocol

from azure.core.credentials_async import AsyncTokenCredential

from tradeops.config import Settings
from tradeops.domain import Order, utcnow

MESSAGE_TYPE = "SettlementRequested"
SCHEMA_VERSION = 1


class PublishError(Exception):
    """The settlement request could not be queued; the client should retry."""


class MalformedMessageError(Exception):
    """A message that will never succeed, however often it is retried."""


@dataclass(frozen=True, slots=True)
class SettlementRequest:
    account_id: str
    order_id: str

    def to_json(self) -> str:
        return json.dumps(
            {
                "type": MESSAGE_TYPE,
                "schema_version": SCHEMA_VERSION,
                "account_id": self.account_id,
                "order_id": self.order_id,
                "requested_at": utcnow().isoformat(),
            }
        )

    @classmethod
    def from_json(cls, body: str | bytes) -> SettlementRequest:
        try:
            payload: Any = json.loads(body)
        except (ValueError, UnicodeDecodeError) as exc:
            raise MalformedMessageError(f"body is not JSON: {exc}") from exc
        if not isinstance(payload, dict) or payload.get("type") != MESSAGE_TYPE:
            raise MalformedMessageError("not a SettlementRequested message")
        if payload.get("schema_version") != SCHEMA_VERSION:
            raise MalformedMessageError(
                f"unsupported schema_version {payload.get('schema_version')}"
            )
        account_id, order_id = payload.get("account_id"), payload.get("order_id")
        if not isinstance(account_id, str) or not isinstance(order_id, str):
            raise MalformedMessageError("account_id and order_id are required strings")
        return cls(account_id=account_id, order_id=order_id)


class SettlementPublisher(Protocol):
    async def publish(self, order: Order) -> None: ...
    async def ping(self) -> None: ...
    async def close(self) -> None: ...


class MemoryBus:
    """In-process queue; the API runs a background settlement loop against it."""

    def __init__(self) -> None:
        self.queue: asyncio.Queue[str] = asyncio.Queue()
        self.fail_next_publishes = 0  # test hook: simulate broker outages

    async def publish(self, order: Order) -> None:
        if self.fail_next_publishes > 0:
            self.fail_next_publishes -= 1
            raise PublishError("simulated broker outage")
        await self.queue.put(SettlementRequest(order.account_id, order.order_id).to_json())

    async def ping(self) -> None:
        return None

    async def close(self) -> None:
        return None


class ServiceBusPublisher:
    def __init__(self, namespace: str, queue: str, credential: AsyncTokenCredential) -> None:
        from azure.servicebus.aio import ServiceBusClient

        self._credential = credential
        self._client = ServiceBusClient(fully_qualified_namespace=namespace, credential=credential)
        self._sender = self._client.get_queue_sender(queue_name=queue)
        self._open = False
        self._lock = asyncio.Lock()

    @classmethod
    def from_settings(cls, settings: Settings) -> ServiceBusPublisher:
        from azure.identity.aio import DefaultAzureCredential

        if settings.servicebus_namespace is None:  # guarded by Settings validation
            raise ValueError("servicebus_namespace is required")
        return cls(
            settings.servicebus_namespace, settings.settlement_queue, DefaultAzureCredential()
        )

    async def _ensure_open(self) -> None:
        # Opening the AMQP link authenticates and checks the Send claim, so it doubles
        # as a readiness check without needing Listen rights on the queue.
        async with self._lock:
            if not self._open:
                await self._sender.__aenter__()
                self._open = True

    async def publish(self, order: Order) -> None:
        from azure.servicebus import ServiceBusMessage
        from azure.servicebus.exceptions import ServiceBusError

        request = SettlementRequest(order.account_id, order.order_id)
        message = ServiceBusMessage(
            request.to_json(),
            message_id=order.order_id,
            content_type="application/json",
            subject=MESSAGE_TYPE,
            application_properties={"account_id": order.account_id, "synthetic": order.synthetic},
        )
        try:
            await self._ensure_open()
            await self._sender.send_messages(message)
        except ServiceBusError as exc:
            raise PublishError(str(exc)) from exc

    async def ping(self) -> None:
        await self._ensure_open()

    async def close(self) -> None:
        await self._sender.close()
        await self._client.close()
        await self._credential.close()
