"""Pre-trade risk checks.

Every check runs and every failure is reported, rather than stopping at the first one,
so a rejected order's audit record shows the full set of reasons.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

from tradeops.config import Settings
from tradeops.domain import OrderRequest, OrderType, to_cents
from tradeops.reference import ACCOUNTS, INSTRUMENTS, AccountStatus


class RejectReason:
    UNKNOWN_ACCOUNT = "UNKNOWN_ACCOUNT"
    ACCOUNT_SUSPENDED = "ACCOUNT_SUSPENDED"
    UNKNOWN_INSTRUMENT = "UNKNOWN_INSTRUMENT"
    RESTRICTED_INSTRUMENT = "RESTRICTED_INSTRUMENT"
    PRICE_OUTSIDE_COLLAR = "PRICE_OUTSIDE_COLLAR"
    NOTIONAL_LIMIT_EXCEEDED = "NOTIONAL_LIMIT_EXCEEDED"


@dataclass(frozen=True, slots=True)
class RiskDecision:
    reasons: tuple[str, ...]
    execution_price: Decimal
    notional: Decimal
    synthetic: bool

    @property
    def accepted(self) -> bool:
        return not self.reasons


def evaluate(request: OrderRequest, settings: Settings) -> RiskDecision:
    reasons: list[str] = []

    account = ACCOUNTS.get(request.account_id)
    if account is None:
        reasons.append(RejectReason.UNKNOWN_ACCOUNT)
    elif account.status is not AccountStatus.ACTIVE:
        reasons.append(RejectReason.ACCOUNT_SUSPENDED)

    instrument = INSTRUMENTS.get(request.symbol)
    if instrument is None:
        reasons.append(RejectReason.UNKNOWN_INSTRUMENT)
    elif instrument.restricted:
        reasons.append(RejectReason.RESTRICTED_INSTRUMENT)

    # OrderRequest validation guarantees LIMIT orders carry a price and MARKET orders don't.
    if request.order_type is OrderType.LIMIT and request.limit_price is not None:
        price = request.limit_price
        if instrument is not None:
            deviation = abs(price - instrument.reference_price) / instrument.reference_price
            if deviation > settings.price_collar_pct:
                reasons.append(RejectReason.PRICE_OUTSIDE_COLLAR)
    else:
        price = instrument.reference_price if instrument is not None else Decimal(0)

    notional = to_cents(price * request.quantity)
    limit = settings.max_order_notional
    if account is not None:
        limit = min(limit, account.max_order_notional)
    if notional > limit:
        reasons.append(RejectReason.NOTIONAL_LIMIT_EXCEEDED)

    return RiskDecision(
        reasons=tuple(reasons),
        execution_price=price,
        notional=notional,
        synthetic=account.synthetic if account is not None else False,
    )
