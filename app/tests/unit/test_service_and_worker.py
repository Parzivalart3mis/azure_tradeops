from __future__ import annotations

import asyncio
import json
from decimal import Decimal

import pytest

from tests.conftest import order_payload
from tradeops.bus import MalformedMessageError, MemoryBus, PublishError, SettlementRequest
from tradeops.config import Settings
from tradeops.domain import OrderRequest, OrderStatus
from tradeops.service import IdempotencyConflictError, OrderService, UnknownOrderError
from tradeops.store import MemoryOrderStore
from tradeops.worker import Outcome, process, run_memory_worker


def req(**overrides: object) -> OrderRequest:
    return OrderRequest.model_validate(order_payload(**overrides))


class TestSubmit:
    async def test_accepted_order_is_stored_and_queued(
        self, service: OrderService, bus: MemoryBus
    ) -> None:
        order, created = await service.submit(req())
        assert created
        assert order.status is OrderStatus.ACCEPTED
        assert order.enqueued
        assert order.accepted_by_revision == "ca-tradeops-api-test--r1"
        message = SettlementRequest.from_json(bus.queue.get_nowait())
        assert message.order_id == order.order_id

    async def test_rejected_order_is_stored_but_not_queued(
        self, service: OrderService, bus: MemoryBus
    ) -> None:
        order, _ = await service.submit(req(account_id="ACC-2001"))
        assert order.status is OrderStatus.REJECTED
        assert not order.enqueued
        assert bus.queue.empty()

    async def test_replay_returns_original(self, service: OrderService, bus: MemoryBus) -> None:
        first, _ = await service.submit(req())
        again, created = await service.submit(req())
        assert not created
        assert again == first
        assert bus.queue.qsize() == 1

    async def test_reusing_client_id_for_different_order_conflicts(
        self, service: OrderService
    ) -> None:
        await service.submit(req())
        with pytest.raises(IdempotencyConflictError):
            await service.submit(req(quantity=5))

    async def test_publish_failure_then_replay_requeues(
        self, service: OrderService, bus: MemoryBus, store: MemoryOrderStore
    ) -> None:
        bus.fail_next_publishes = 1
        with pytest.raises(PublishError):
            await service.submit(req())
        stranded = await store.list_for_account("ACC-1001", 10)
        assert stranded[0].status is OrderStatus.ACCEPTED
        assert not stranded[0].enqueued

        order, created = await service.submit(req())
        assert not created
        assert order.enqueued
        assert bus.queue.qsize() == 1

    async def test_concurrent_duplicates_create_one_order(
        self, service: OrderService, store: MemoryOrderStore
    ) -> None:
        results = await asyncio.gather(*(service.submit(req()) for _ in range(5)))
        assert sum(created for _, created in results) == 1
        assert len(await store.list_for_account("ACC-1001", 10)) == 1


class TestSettle:
    async def test_settle_computes_commission_and_net(self, service: OrderService) -> None:
        order, _ = await service.submit(req())
        settled = await service.settle(order.account_id, order.order_id)
        assert settled.status is OrderStatus.SETTLED
        assert settled.commission == Decimal("11.58")
        assert settled.net_amount == Decimal("-23161.58")
        assert settled.settled_at is not None

    async def test_settle_is_idempotent(self, service: OrderService) -> None:
        order, _ = await service.submit(req())
        first = await service.settle(order.account_id, order.order_id)
        second = await service.settle(order.account_id, order.order_id)
        assert first == second

    async def test_settle_unknown_order(self, service: OrderService) -> None:
        with pytest.raises(UnknownOrderError):
            await service.settle("ACC-1001", "00000000-0000-0000-0000-000000000000")

    async def test_mark_failed(self, service: OrderService) -> None:
        order, _ = await service.submit(req())
        failed = await service.mark_failed(order.account_id, order.order_id, "boom")
        assert failed is not None
        assert failed.status is OrderStatus.FAILED
        assert failed.failure_reason == "boom"
        # A terminal order is not overwritten.
        again = await service.mark_failed(order.account_id, order.order_id, "other")
        assert again is not None
        assert again.failure_reason == "boom"


class TestMessages:
    def test_round_trip(self) -> None:
        message = SettlementRequest("ACC-1001", "abc")
        assert SettlementRequest.from_json(message.to_json()) == message

    @pytest.mark.parametrize(
        "body",
        [
            "not json",
            json.dumps([1, 2]),
            json.dumps({"type": "Other"}),
            json.dumps({"type": "SettlementRequested", "schema_version": 99}),
            json.dumps({"type": "SettlementRequested", "schema_version": 1, "order_id": 1}),
        ],
    )
    def test_malformed(self, body: str) -> None:
        with pytest.raises(MalformedMessageError):
            SettlementRequest.from_json(body)


class FlakyService(OrderService):
    def __init__(self, inner: OrderService, failures: int) -> None:
        self.__dict__.update(inner.__dict__)
        self.failures = failures

    async def settle(self, account_id: str, order_id: str):  # type: ignore[no-untyped-def]
        if self.failures > 0:
            self.failures -= 1
            raise TimeoutError("ledger timeout")
        return await super().settle(account_id, order_id)


class TestWorker:
    async def test_complete(self, service: OrderService) -> None:
        order, _ = await service.submit(req())
        body = SettlementRequest(order.account_id, order.order_id).to_json()
        result = await process(service, body, delivery_count=1, max_delivery_count=5)
        assert result.outcome is Outcome.COMPLETE

    async def test_malformed_is_dead_lettered_immediately(self, service: OrderService) -> None:
        result = await process(service, b"{", delivery_count=1, max_delivery_count=5)
        assert result.outcome is Outcome.DEAD_LETTER
        assert result.reason is not None
        assert result.reason.startswith("MalformedMessage")

    async def test_unknown_order_is_dead_lettered(self, service: OrderService) -> None:
        body = SettlementRequest("ACC-1001", "missing").to_json()
        result = await process(service, body, delivery_count=1, max_delivery_count=5)
        assert result.outcome is Outcome.DEAD_LETTER

    async def test_transient_failure_abandons_then_dead_letters_on_last_attempt(
        self, service: OrderService, store: MemoryOrderStore
    ) -> None:
        order, _ = await service.submit(req())
        flaky = FlakyService(service, failures=10)
        body = SettlementRequest(order.account_id, order.order_id).to_json()

        early = await process(flaky, body, delivery_count=2, max_delivery_count=5)
        assert early.outcome is Outcome.ABANDON

        last = await process(flaky, body, delivery_count=5, max_delivery_count=5)
        assert last.outcome is Outcome.DEAD_LETTER
        stored = await store.get(order.account_id, order.order_id)
        assert stored is not None
        assert stored.status is OrderStatus.FAILED

    async def test_memory_worker_retries_until_settled(
        self, service: OrderService, bus: MemoryBus, settings: Settings, store: MemoryOrderStore
    ) -> None:
        order, _ = await service.submit(req())
        flaky = FlakyService(service, failures=2)
        task = asyncio.create_task(run_memory_worker(flaky, bus, settings))
        await asyncio.wait_for(bus.queue.join(), timeout=5)
        task.cancel()
        stored = await store.get(order.account_id, order.order_id)
        assert stored is not None
        assert stored.status is OrderStatus.SETTLED
