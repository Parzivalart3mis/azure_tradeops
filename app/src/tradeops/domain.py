"""Order domain model.

Money is always `Decimal`, quantised to cents with banker's rounding, and is serialised
as a string in JSON and in Table Storage. Floats never touch a monetary value.
"""

from __future__ import annotations

import hashlib
import uuid
from datetime import UTC, datetime
from decimal import ROUND_HALF_EVEN, Decimal
from enum import StrEnum

from pydantic import BaseModel, ConfigDict, Field, model_validator

CENTS = Decimal("0.01")

# Namespace for deterministic order ids: the same (account, client_order_id) pair always
# maps to the same order id, which is what makes order submission idempotent.
ORDER_NAMESPACE = uuid.UUID("6f1d3c55-8a52-4b3e-9a4f-2f1f6f0c7a10")


def to_cents(value: Decimal) -> Decimal:
    return value.quantize(CENTS, rounding=ROUND_HALF_EVEN)


def utcnow() -> datetime:
    return datetime.now(UTC)


def make_order_id(account_id: str, client_order_id: str) -> str:
    return str(uuid.uuid5(ORDER_NAMESPACE, f"{account_id}/{client_order_id}"))


class Side(StrEnum):
    BUY = "BUY"
    SELL = "SELL"


class OrderType(StrEnum):
    MARKET = "MARKET"
    LIMIT = "LIMIT"


class OrderStatus(StrEnum):
    ACCEPTED = "ACCEPTED"  # passed pre-trade risk, waiting for settlement
    REJECTED = "REJECTED"  # failed pre-trade risk; kept for the audit trail
    SETTLED = "SETTLED"
    FAILED = "FAILED"  # settlement exhausted its retries and was dead-lettered

    @property
    def is_terminal(self) -> bool:
        return self is not OrderStatus.ACCEPTED


class OrderRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    client_order_id: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9._-]+$")
    account_id: str = Field(pattern=r"^[A-Z0-9-]{3,32}$")
    symbol: str = Field(pattern=r"^[A-Z]{1,6}$")
    side: Side
    order_type: OrderType = OrderType.LIMIT
    quantity: int = Field(gt=0, le=1_000_000)
    limit_price: Decimal | None = Field(default=None, gt=0, max_digits=12, decimal_places=4)

    @model_validator(mode="after")
    def _price_matches_order_type(self) -> OrderRequest:
        if self.order_type is OrderType.LIMIT and self.limit_price is None:
            raise ValueError("limit_price is required for LIMIT orders")
        if self.order_type is OrderType.MARKET and self.limit_price is not None:
            raise ValueError("limit_price must be omitted for MARKET orders")
        return self

    def fingerprint(self) -> str:
        """Stable hash of the economic content, used to detect idempotency-key reuse."""
        canonical = self.model_dump_json(exclude={"client_order_id"})
        return hashlib.sha256(canonical.encode()).hexdigest()


class Order(BaseModel):
    model_config = ConfigDict(frozen=True)

    order_id: str
    account_id: str
    client_order_id: str
    symbol: str
    side: Side
    order_type: OrderType
    quantity: int
    limit_price: Decimal | None
    execution_price: Decimal
    notional: Decimal
    status: OrderStatus
    reject_reasons: list[str] = Field(default_factory=list)
    fingerprint: str
    enqueued: bool = False
    commission: Decimal | None = None
    net_amount: Decimal | None = None
    failure_reason: str | None = None
    synthetic: bool = False
    accepted_by_revision: str
    created_at: datetime
    updated_at: datetime
    settled_at: datetime | None = None
