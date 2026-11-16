"""Order API (FastAPI).

Endpoints
  POST /v1/orders                                   submit an order (idempotent)
  GET  /v1/accounts/{account_id}/orders/{order_id}  fetch one order
  GET  /v1/accounts/{account_id}/orders             recent orders for an account
  GET  /healthz   liveness: the process is up
  GET  /readyz    readiness: ledger and queue are reachable
  GET  /version   build and revision identity; smoke tests assert on it

Every response carries X-TradeOps-Revision so canary analysis can attribute a
response to the revision that served it, even through a weighted traffic split.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import re
import time
import uuid
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from typing import Annotated, Any

from fastapi import FastAPI, HTTPException, Path, Query, Request, Response
from fastapi.responses import JSONResponse
from opentelemetry import trace

from tradeops import __version__
from tradeops.bus import MemoryBus, PublishError, ServiceBusPublisher, SettlementPublisher
from tradeops.config import Settings, get_settings
from tradeops.domain import Order, OrderRequest
from tradeops.faults import FaultInjector, InjectedFaultError
from tradeops.service import IdempotencyConflictError, OrderService
from tradeops.store import MemoryOrderStore, OrderStore, TableOrderStore
from tradeops.telemetry import configure_azure_monitor, configure_logging
from tradeops.worker import run_memory_worker

log = logging.getLogger("tradeops.api")

_REQUEST_ID = re.compile(r"^[A-Za-z0-9._-]{8,64}$")
AccountId = Annotated[str, Path(pattern=r"^[A-Z0-9-]{3,32}$")]
OrderId = Annotated[str, Path(pattern=r"^[0-9a-f-]{36}$")]


def _error(status: int, code: str, message: str, request: Request, **extra: Any) -> JSONResponse:
    body = {"error": code, "message": message, "request_id": request.state.request_id, **extra}
    return JSONResponse(status_code=status, content=body)


def create_app(
    settings: Settings | None = None,
    *,
    store: OrderStore | None = None,
    publisher: SettlementPublisher | None = None,
    faults: FaultInjector | None = None,
) -> FastAPI:
    settings = settings or get_settings()
    configure_logging(settings, service="tradeops-api")
    configure_azure_monitor(settings, service="tradeops-api")  # before FastAPI() exists

    # Each dependency uses Azure when its endpoint is configured and an in-memory fake
    # otherwise, so `docker compose` can run a real Table ledger with an in-process queue.
    if store is None:
        uses_tables = settings.storage_table_endpoint or settings.storage_connection_string
        store = TableOrderStore.from_settings(settings) if uses_tables else MemoryOrderStore()
    if publisher is None:
        publisher = (
            ServiceBusPublisher.from_settings(settings)
            if settings.servicebus_namespace
            else MemoryBus()
        )
    faults = faults or FaultInjector(settings)
    service = OrderService(store, publisher, settings)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        worker: asyncio.Task[None] | None = None
        if isinstance(publisher, MemoryBus):
            worker = asyncio.create_task(run_memory_worker(service, publisher, settings))
        if faults.enabled:
            log.warning(
                "FAULT INJECTION ENABLED",
                extra={
                    "fault_rate": settings.fault_rate,
                    "fault_latency_ms": settings.fault_latency_ms,
                },
            )
        log.info(
            "api started", extra={"backend": settings.backend.value, "version": settings.version}
        )
        yield
        if worker is not None:
            worker.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await worker
        await publisher.close()
        await store.close()

    app = FastAPI(
        title="Azure TradeOps Order API",
        version=__version__,
        lifespan=lifespan,
        docs_url="/docs" if settings.environment in ("local", "dev") else None,
        redoc_url=None,
    )
    app.state.service = service
    app.state.publisher = publisher

    @app.middleware("http")
    async def context_middleware(
        request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        incoming = request.headers.get("x-request-id", "")
        request.state.request_id = incoming if _REQUEST_ID.match(incoming) else uuid.uuid4().hex
        span = trace.get_current_span()
        span.set_attribute("tradeops.revision", settings.revision)
        span.set_attribute("tradeops.request_id", request.state.request_id)
        started = time.perf_counter()
        try:
            if request.url.path.startswith("/v1/"):
                await faults.maybe_fail()
            response = await call_next(request)
        except Exception as exc:
            # Handled here rather than by an app-level handler so that 500s still carry
            # the revision headers that canary analysis attributes failures with.
            span.record_exception(exc)
            span.set_status(trace.StatusCode.ERROR)
            if isinstance(exc, InjectedFaultError):
                log.error("request failed", extra={"path": request.url.path, "error": str(exc)})
            else:
                log.exception("unhandled error", extra={"path": request.url.path})
            response = _error(500, "internal_error", "internal error", request)
        elapsed_ms = (time.perf_counter() - started) * 1000
        response.headers["X-Request-ID"] = request.state.request_id
        response.headers["X-TradeOps-Revision"] = settings.revision
        response.headers["X-TradeOps-Version"] = settings.version
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        if request.url.path.startswith("/v1/"):
            log.info(
                "request",
                extra={
                    "method": request.method,
                    "path": request.url.path,
                    "status_code": response.status_code,
                    "duration_ms": round(elapsed_ms, 2),
                    "request_id": request.state.request_id,
                },
            )
        return response

    @app.exception_handler(IdempotencyConflictError)
    async def _conflict(request: Request, exc: IdempotencyConflictError) -> JSONResponse:
        return _error(409, "idempotency_conflict", str(exc), request, order_id=exc.order.order_id)

    @app.exception_handler(PublishError)
    async def _unavailable(request: Request, exc: PublishError) -> JSONResponse:
        log.error("settlement queue unavailable", extra={"error": str(exc)})
        response = _error(
            503,
            "queue_unavailable",
            "order recorded but not yet queued; retry with the same client_order_id",
            request,
        )
        response.headers["Retry-After"] = "2"
        return response

    @app.get("/healthz", tags=["ops"])
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/readyz", tags=["ops"])
    async def readyz(response: Response) -> dict[str, Any]:
        checks: dict[str, str] = {}
        for name, dependency in (("ledger", store), ("queue", publisher)):
            try:
                await asyncio.wait_for(dependency.ping(), timeout=settings.readiness_timeout_s)
                checks[name] = "ok"
            except Exception as exc:
                log.warning(
                    "readiness check failed", extra={"dependency": name, "error": repr(exc)}
                )
                checks[name] = "unavailable"
        ready = all(v == "ok" for v in checks.values())
        response.status_code = 200 if ready else 503
        return {"status": "ready" if ready else "not_ready", "checks": checks}

    @app.get("/version", tags=["ops"])
    async def version() -> dict[str, Any]:
        return {
            "service": "tradeops-api",
            "version": settings.version,
            "git_sha": settings.git_sha,
            "revision": settings.revision,
            "environment": settings.environment,
            "fault_injection": faults.enabled,
        }

    @app.post("/v1/orders", status_code=201, tags=["orders"])
    async def submit_order(body: OrderRequest, response: Response) -> Order:
        order, created = await service.submit(body)
        if not created:
            response.status_code = 200
        response.headers["Location"] = f"/v1/accounts/{order.account_id}/orders/{order.order_id}"
        return order

    @app.get("/v1/accounts/{account_id}/orders/{order_id}", tags=["orders"])
    async def get_order(account_id: AccountId, order_id: OrderId) -> Order:
        order = await service.get(account_id, order_id)
        if order is None:
            raise HTTPException(status_code=404, detail="order not found")
        return order

    @app.get("/v1/accounts/{account_id}/orders", tags=["orders"])
    async def list_orders(
        account_id: AccountId, limit: Annotated[int, Query(ge=1, le=100)] = 20
    ) -> list[Order]:
        return await service.list_for_account(account_id, limit)

    return app
