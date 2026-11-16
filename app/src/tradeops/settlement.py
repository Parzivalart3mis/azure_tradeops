"""Settlement maths: commission and net cash movement."""

from __future__ import annotations

from decimal import Decimal

from tradeops.domain import Side, to_cents

COMMISSION_BPS = Decimal("5")  # 5 basis points of notional
MIN_COMMISSION = Decimal("1.00")
_BPS = Decimal("10000")


def commission(notional: Decimal) -> Decimal:
    return max(to_cents(notional * COMMISSION_BPS / _BPS), MIN_COMMISSION)


def net_amount(side: Side, notional: Decimal, fee: Decimal) -> Decimal:
    """Cash movement for the account: negative when cash leaves the account."""
    if side is Side.BUY:
        return to_cents(-(notional + fee))
    return to_cents(notional - fee)
