"""Static reference data: accounts and instruments.

A real system would read these from a reference-data service. Static data keeps the
simulation deterministic, which matters for repeatable smoke tests and canary analysis.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from enum import StrEnum


class AccountStatus(StrEnum):
    ACTIVE = "ACTIVE"
    SUSPENDED = "SUSPENDED"


@dataclass(frozen=True, slots=True)
class Account:
    account_id: str
    status: AccountStatus
    max_order_notional: Decimal
    synthetic: bool = False  # synthetic accounts carry smoke-test and canary traffic


@dataclass(frozen=True, slots=True)
class Instrument:
    symbol: str
    reference_price: Decimal
    restricted: bool = False  # on the compliance restricted list


ACCOUNTS: dict[str, Account] = {
    a.account_id: a
    for a in (
        Account("ACC-1001", AccountStatus.ACTIVE, Decimal("1000000.00")),
        Account("ACC-1002", AccountStatus.ACTIVE, Decimal("250000.00")),
        Account("ACC-1003", AccountStatus.ACTIVE, Decimal("10000000.00")),
        Account("ACC-2001", AccountStatus.SUSPENDED, Decimal("1000000.00")),
        Account("SMOKE-0001", AccountStatus.ACTIVE, Decimal("100000.00"), synthetic=True),
        Account("CANARY-0001", AccountStatus.ACTIVE, Decimal("100000.00"), synthetic=True),
    )
}

INSTRUMENTS: dict[str, Instrument] = {
    i.symbol: i
    for i in (
        Instrument("AAPL", Decimal("230.00")),
        Instrument("MSFT", Decimal("420.00")),
        Instrument("NVDA", Decimal("140.00")),
        Instrument("JPM", Decimal("240.00")),
        Instrument("GS", Decimal("580.00")),
        Instrument("SPY", Decimal("590.00")),
        Instrument("TLT", Decimal("92.00")),
        Instrument("ACME", Decimal("12.50"), restricted=True),
    )
}
