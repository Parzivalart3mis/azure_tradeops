"""Order lifecycle: submit -> (risk) -> ACCEPTED/REJECTED -> SETTLED/FAILED.

Submission is idempotent on (account_id, client_order_id):
  * same key, same economics   -> the original order is returned (HTTP 200 replay)
  * same key, different content -> IdempotencyConflictError (HTTP 409)
  * order stored but never queued (broker outage) -> the replay queues it again; the
    broker's duplicate detection makes the second publish safe.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from datetime import datetime

from tradeops import risk, settlement
from tradeops.bus import SettlementPublisher
from tradeops.config import Settings
from tradeops.domain import Order, OrderRequest, OrderStatus, make_order_id, utcnow
from tradeops.store import OrderExistsError, OrderStore
from tradeops.telemetry import Metrics

log = logging.getLogger("tradeops.service")


class IdempotencyConflictError(Exception):
    def __init__(self, order: Order) -> None:
        super().__init__(
            f"client_order_id {order.client_order_id!r} was already used for a different order"
        )
        self.order = order


class UnknownOrderError(Exception):
    """Settlement was requested for an order the ledger has never seen."""


class OrderService:
    def __init__(
        self,
        store: OrderStore,
        publisher: SettlementPublisher,
        settings: Settings,
        metrics: Metrics | None = None,
        clock: Callable[[], datetime] = utcnow,
    ) -> None:
        self._store = store
        self._publisher = publisher
        self._settings = settings
        self._metrics = metrics or Metrics()
        self._clock = clock

    async def submit(self, request: OrderRequest) -> tuple[Order, bool]:
        """Returns (order, created). created=False means this was an idempotent replay."""
        order_id = make_order_id(request.account_id, request.client_order_id)
        fingerprint = request.fingerprint()

        existing = await self._store.get(request.account_id, order_id)
        if existing is not None:
            return await self._replay(existing, fingerprint), False

        decision = risk.evaluate(request, self._settings)
        now = self._clock()
        order = Order(
            order_id=order_id,
            account_id=request.account_id,
            client_order_id=request.client_order_id,
            symbol=request.symbol,
            side=request.side,
            order_type=request.order_type,
            quantity=request.quantity,
            limit_price=request.limit_price,
            execution_price=decision.execution_price,
            notional=decision.notional,
            status=OrderStatus.ACCEPTED if decision.accepted else OrderStatus.REJECTED,
            reject_reasons=list(decision.reasons),
            fingerprint=fingerprint,
            synthetic=decision.synthetic,
            accepted_by_revision=self._settings.revision,
            created_at=now,
            updated_at=now,
        )
        try:
            await self._store.insert(order)
        except OrderExistsError as exc:  # lost a race with a concurrent duplicate
            return await self._replay(exc.existing, fingerprint), False

        attrs = {"synthetic": order.synthetic, "side": order.side.value}
        self._metrics.orders_received.add(1, attrs)
        if decision.accepted:
            order = await self._enqueue(order)
        else:
            self._metrics.orders_rejected.add(1, {**attrs, "reason": decision.reasons[0]})

        log.info(
            "order submitted",
            extra={
                "order_id": order.order_id,
                "account_id": order.account_id,
                "status": order.status.value,
                "reject_reasons": order.reject_reasons,
                "notional": str(order.notional),
                "synthetic": order.synthetic,
            },
        )
        return order, True

    async def _replay(self, existing: Order, fingerprint: str) -> Order:
        if existing.fingerprint != fingerprint:
            raise IdempotencyConflictError(existing)
        if existing.status is OrderStatus.ACCEPTED and not existing.enqueued:
            log.warning(
                "re-queuing order that was never enqueued", extra={"order_id": existing.order_id}
            )
            return await self._enqueue(existing)
        return existing

    async def _enqueue(self, order: Order) -> Order:
        await self._publisher.publish(order)  # PublishError propagates -> HTTP 503
        queued = order.model_copy(update={"enqueued": True, "updated_at": self._clock()})
        await self._store.replace(queued)
        return queued

    async def get(self, account_id: str, order_id: str) -> Order | None:
        return await self._store.get(account_id, order_id)

    async def list_for_account(self, account_id: str, limit: int) -> list[Order]:
        return await self._store.list_for_account(account_id, limit)

    async def settle(self, account_id: str, order_id: str) -> Order:
        order = await self._store.get(account_id, order_id)
        if order is None:
            raise UnknownOrderError(f"{account_id}/{order_id}")
        if order.status.is_terminal:
            return order  # at-least-once delivery: a redelivered message is a no-op

        fee = settlement.commission(order.notional)
        now = self._clock()
        settled = order.model_copy(
            update={
                "status": OrderStatus.SETTLED,
                "commission": fee,
                "net_amount": settlement.net_amount(order.side, order.notional, fee),
                "settled_at": now,
                "updated_at": now,
            }
        )
        await self._store.replace(settled)
        latency_ms = (now - order.created_at).total_seconds() * 1000
        self._metrics.transactions_settled.add(1, {"synthetic": order.synthetic})
        self._metrics.settlement_latency.record(latency_ms, {"synthetic": order.synthetic})
        log.info(
            "order settled",
            extra={
                "order_id": order_id,
                "account_id": account_id,
                "commission": str(fee),
                "net_amount": str(settled.net_amount),
                "settlement_latency_ms": round(latency_ms, 1),
            },
        )
        return settled

    async def mark_failed(self, account_id: str, order_id: str, reason: str) -> Order | None:
        order = await self._store.get(account_id, order_id)
        self._metrics.transactions_failed.add(1, {"reason": reason[:64]})
        if order is None or order.status.is_terminal:
            log.error("settlement failed", extra={"order_id": order_id, "reason": reason})
            return order
        failed = order.model_copy(
            update={
                "status": OrderStatus.FAILED,
                "failure_reason": reason,
                "updated_at": self._clock(),
            }
        )
        await self._store.replace(failed)
        log.error(
            "settlement failed; order dead-lettered",
            extra={"order_id": order_id, "account_id": account_id, "reason": reason},
        )
        return failed
