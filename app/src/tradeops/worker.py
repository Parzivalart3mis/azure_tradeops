"""Settlement worker: consumes SettlementRequested messages and settles orders.

Delivery is at-least-once. Outcomes per message:
  * settled (or already terminal)           -> complete
  * malformed body / unknown order          -> dead-letter now (retrying can't help)
  * transient error, attempts remaining     -> abandon (Service Bus redelivers)
  * transient error, last attempt           -> mark order FAILED, then dead-letter

In Azure this runs as its own Container App (`python -m tradeops.worker`) and KEDA
scales it on queue depth. Locally, the API runs `run_memory_worker` in-process.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import signal
from dataclasses import dataclass
from enum import StrEnum

from tradeops.bus import MalformedMessageError, MemoryBus, SettlementRequest
from tradeops.config import Settings, get_settings
from tradeops.service import OrderService, UnknownOrderError

log = logging.getLogger("tradeops.worker")


class Outcome(StrEnum):
    COMPLETE = "complete"
    ABANDON = "abandon"
    DEAD_LETTER = "dead_letter"


@dataclass(frozen=True, slots=True)
class Disposition:
    outcome: Outcome
    reason: str | None = None


async def process(
    service: OrderService, body: str | bytes, *, delivery_count: int, max_delivery_count: int
) -> Disposition:
    try:
        request = SettlementRequest.from_json(body)
    except MalformedMessageError as exc:
        log.error("malformed settlement message", extra={"reason": str(exc)})
        return Disposition(Outcome.DEAD_LETTER, f"MalformedMessage: {exc}")

    try:
        await service.settle(request.account_id, request.order_id)
    except UnknownOrderError as exc:
        await service.mark_failed(request.account_id, request.order_id, "UnknownOrder")
        return Disposition(Outcome.DEAD_LETTER, f"UnknownOrder: {exc}")
    except Exception as exc:
        reason = f"{type(exc).__name__}: {exc}"
        if delivery_count >= max_delivery_count:
            await service.mark_failed(request.account_id, request.order_id, reason)
            return Disposition(Outcome.DEAD_LETTER, f"RetriesExhausted: {reason}")
        log.warning(
            "settlement attempt failed; will retry",
            extra={
                "order_id": request.order_id,
                "delivery_count": delivery_count,
                "reason": reason,
            },
        )
        return Disposition(Outcome.ABANDON, reason)
    return Disposition(Outcome.COMPLETE)


async def run_memory_worker(service: OrderService, bus: MemoryBus, settings: Settings) -> None:
    """In-process settlement loop for the memory backend. Retries inline."""
    while True:
        body = await bus.queue.get()
        try:
            for attempt in range(1, settings.max_delivery_count + 1):
                disposition = await process(
                    service,
                    body,
                    delivery_count=attempt,
                    max_delivery_count=settings.max_delivery_count,
                )
                if disposition.outcome is not Outcome.ABANDON:
                    break
                await asyncio.sleep(0.05 * attempt)
        finally:
            bus.queue.task_done()


async def run_servicebus_worker(
    settings: Settings, stop: asyncio.Event
) -> None:  # pragma: no cover - needs Azure
    from azure.identity.aio import DefaultAzureCredential
    from azure.servicebus.aio import ServiceBusClient

    from tradeops.store import TableOrderStore

    if settings.servicebus_namespace is None:
        raise SystemExit("TRADEOPS_SERVICEBUS_NAMESPACE is required for the worker")

    store = TableOrderStore.from_settings(settings)

    class _NoPublish:
        async def publish(self, order: object) -> None:
            raise RuntimeError("the worker never publishes")

        async def ping(self) -> None: ...

        async def close(self) -> None: ...

    service = OrderService(store, _NoPublish(), settings)
    credential = DefaultAzureCredential()
    client = ServiceBusClient(
        fully_qualified_namespace=settings.servicebus_namespace, credential=credential
    )
    log.info("settlement worker started", extra={"queue": settings.settlement_queue})
    try:
        async with (
            client,
            client.get_queue_receiver(settings.settlement_queue, prefetch_count=20) as receiver,
        ):
            while not stop.is_set():
                messages = await receiver.receive_messages(max_message_count=20, max_wait_time=5)
                for message in messages:
                    disposition = await process(
                        service,
                        b"".join(message.body),
                        delivery_count=message.delivery_count or 1,
                        max_delivery_count=settings.max_delivery_count,
                    )
                    if disposition.outcome is Outcome.COMPLETE:
                        await receiver.complete_message(message)
                    elif disposition.outcome is Outcome.ABANDON:
                        await receiver.abandon_message(message)
                    else:
                        await receiver.dead_letter_message(
                            message,
                            reason=(disposition.reason or "unknown")[:120],
                            error_description=disposition.reason,
                        )
    finally:
        await store.close()
        await credential.close()
        log.info("settlement worker stopped")


def main() -> None:  # pragma: no cover - process entrypoint
    from tradeops.telemetry import configure_azure_monitor, configure_logging

    settings = get_settings()
    configure_logging(settings, service="tradeops-worker")
    configure_azure_monitor(settings, service="tradeops-worker")

    async def _run() -> None:
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            with contextlib.suppress(NotImplementedError):
                loop.add_signal_handler(sig, stop.set)
        await run_servicebus_worker(settings, stop)

    asyncio.run(_run())


if __name__ == "__main__":  # pragma: no cover
    main()
