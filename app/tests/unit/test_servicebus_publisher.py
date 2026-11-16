"""ServiceBusPublisher against a fake Service Bus client (no network)."""

from __future__ import annotations

import json
from typing import Any, ClassVar

import pytest
from azure.servicebus.exceptions import ServiceBusConnectionError

from tests.conftest import order_payload
from tradeops import bus as bus_module
from tradeops.bus import PublishError, ServiceBusPublisher
from tradeops.config import Backend, Settings
from tradeops.domain import OrderRequest
from tradeops.service import OrderService
from tradeops.store import MemoryOrderStore


class FakeSender:
    def __init__(self) -> None:
        self.opened = 0
        self.sent: list[Any] = []
        self.closed = False
        self.fail_with: Exception | None = None

    async def __aenter__(self) -> FakeSender:
        self.opened += 1
        return self

    async def send_messages(self, message: Any) -> None:
        if self.fail_with:
            raise self.fail_with
        self.sent.append(message)

    async def close(self) -> None:
        self.closed = True


class FakeClient:
    instances: ClassVar[list[FakeClient]] = []

    def __init__(self, fully_qualified_namespace: str, credential: Any) -> None:
        self.namespace = fully_qualified_namespace
        self.sender = FakeSender()
        self.closed = False
        FakeClient.instances.append(self)

    def get_queue_sender(self, queue_name: str) -> FakeSender:
        self.queue_name = queue_name
        return self.sender

    async def close(self) -> None:
        self.closed = True


class FakeCredential:
    closed = False

    async def close(self) -> None:
        self.closed = True


@pytest.fixture
def fake_sb(monkeypatch: pytest.MonkeyPatch) -> type[FakeClient]:
    import azure.servicebus.aio

    FakeClient.instances.clear()
    monkeypatch.setattr(azure.servicebus.aio, "ServiceBusClient", FakeClient)
    return FakeClient


async def test_publish_sets_message_id_for_duplicate_detection(fake_sb: type[FakeClient]) -> None:
    credential = FakeCredential()
    publisher = ServiceBusPublisher("sb.servicebus.windows.net", "settlement-requests", credential)  # type: ignore[arg-type]
    service = OrderService(MemoryOrderStore(), publisher, Settings())
    order, _ = await service.submit(OrderRequest.model_validate(order_payload()))

    client = fake_sb.instances[0]
    assert client.queue_name == "settlement-requests"
    (message,) = client.sender.sent
    assert message.message_id == order.order_id
    assert message.subject == bus_module.MESSAGE_TYPE
    assert json.loads(str(message))["order_id"] == order.order_id

    await publisher.ping()
    assert client.sender.opened == 1  # link opened once and reused

    await publisher.close()
    assert client.sender.closed
    assert client.closed
    assert credential.closed


async def test_broker_errors_become_publish_errors(fake_sb: type[FakeClient]) -> None:
    publisher = ServiceBusPublisher("sb.servicebus.windows.net", "q", FakeCredential())  # type: ignore[arg-type]
    fake_sb.instances[0].sender.fail_with = ServiceBusConnectionError(message="link detached")
    service = OrderService(MemoryOrderStore(), publisher, Settings())
    with pytest.raises(PublishError):
        await service.submit(OrderRequest.model_validate(order_payload()))


def test_from_settings_uses_namespace(fake_sb: type[FakeClient]) -> None:
    settings = Settings(
        backend=Backend.AZURE,
        storage_table_endpoint="https://st.table.core.windows.net",
        servicebus_namespace="sb-tradeops.servicebus.windows.net",
    )
    ServiceBusPublisher.from_settings(settings)
    assert fake_sb.instances[0].namespace == "sb-tradeops.servicebus.windows.net"
