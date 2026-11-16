"""Structured logging, OpenTelemetry and Azure Monitor wiring.

Logs go to stdout as one JSON object per line (Container Apps ships them to Log
Analytics as ContainerAppConsoleLogs). When APPLICATIONINSIGHTS_CONNECTION_STRING is set,
traces, metrics and logs also go to Application Insights. Each record carries the
Container Apps revision, which is what canary analysis splits on.
"""

from __future__ import annotations

import json
import logging
import sys
from datetime import UTC, datetime
from typing import Any

from opentelemetry import metrics, trace

from tradeops.config import Settings

LOGGER_NAMESPACE = "tradeops"

_RESERVED = set(logging.makeLogRecord({}).__dict__) | {"message", "asctime"}


class JsonFormatter(logging.Formatter):
    def __init__(self, *, service: str, environment: str, revision: str) -> None:
        super().__init__()
        self._static = {"service": service, "environment": environment, "revision": revision}

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "ts": datetime.fromtimestamp(record.created, UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            **self._static,
        }
        span = trace.get_current_span().get_span_context()
        if span.is_valid:
            payload["trace_id"] = format(span.trace_id, "032x")
            payload["span_id"] = format(span.span_id, "016x")
        for key, value in record.__dict__.items():
            if key not in _RESERVED and not key.startswith("_"):
                payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def configure_logging(settings: Settings, service: str) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(
        JsonFormatter(service=service, environment=settings.environment, revision=settings.revision)
    )
    root = logging.getLogger()
    root.handlers = [h for h in root.handlers if not isinstance(h, logging.StreamHandler)]
    root.addHandler(handler)
    root.setLevel(settings.log_level.upper())
    # The Azure SDK logs every HTTP request at INFO; keep the signal-to-noise sane.
    logging.getLogger("azure").setLevel(logging.WARNING)
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)


def configure_azure_monitor(settings: Settings, service: str) -> bool:
    """Send traces, metrics and logs to Application Insights. Must run before the
    FastAPI app is created so the distro's FastAPI instrumentation picks it up."""
    if settings.applicationinsights_connection_string is None:
        return False
    from azure.monitor.opentelemetry import configure_azure_monitor as _configure
    from opentelemetry.sdk.resources import Resource

    _configure(
        connection_string=settings.applicationinsights_connection_string.get_secret_value(),
        resource=Resource.create(
            {
                "service.name": service,
                "service.namespace": "tradeops",
                # Becomes AppVersion in Log Analytics; one value per ACA revision.
                "service.version": settings.revision,
                "deployment.environment": settings.environment,
            }
        ),
        logger_name=LOGGER_NAMESPACE,
    )
    return True


class Metrics:
    """Business metrics. Without a configured provider these are no-ops."""

    def __init__(self) -> None:
        meter = metrics.get_meter("tradeops")
        self.orders_received = meter.create_counter(
            "tradeops.orders.received", description="Orders submitted to the API"
        )
        self.orders_rejected = meter.create_counter(
            "tradeops.orders.rejected", description="Orders rejected by pre-trade risk"
        )
        self.transactions_settled = meter.create_counter(
            "tradeops.transactions.settled", description="Orders settled"
        )
        self.transactions_failed = meter.create_counter(
            "tradeops.transactions.failed", description="Settlements that exhausted retries"
        )
        self.settlement_latency = meter.create_histogram(
            "tradeops.settlement.latency", unit="ms", description="Order accept to settled"
        )
