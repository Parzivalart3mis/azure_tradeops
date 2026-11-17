"""Generates synthetic settled trades as JSON lines (the bundle job's first task).

The data deliberately includes a small share of bad rows (non-positive quantities,
mismatched notionals, unknown sides) and redelivered duplicates, so the pipeline's
validation, quarantine and de-duplication paths run on every refresh.

    python generate_trades.py --output /Volumes/tradeops_dev/settlement/landing/trades --count 5000
"""

from __future__ import annotations

import argparse
import random
import uuid
from datetime import UTC, datetime, timedelta
from decimal import ROUND_HALF_EVEN, Decimal
from typing import Any

CENTS = Decimal("0.01")
INSTRUMENTS = {
    "AAPL": Decimal("230.00"),
    "MSFT": Decimal("420.00"),
    "NVDA": Decimal("140.00"),
    "JPM": Decimal("240.00"),
    "GS": Decimal("580.00"),
    "SPY": Decimal("590.00"),
    "TLT": Decimal("92.00"),
}
ACCOUNTS = ["ACC-1001", "ACC-1002", "ACC-1003", "ACC-1004", "ACC-1005"]
BAD_ROW_RATE = 0.01
DUPLICATE_RATE = 0.005


def _cents(value: Decimal) -> Decimal:
    return value.quantize(CENTS, rounding=ROUND_HALF_EVEN)


def make_trade(rng: random.Random, settled_at: datetime) -> dict[str, Any]:
    symbol = rng.choice(list(INSTRUMENTS))
    # Prices drift within the API's +/-10% collar.
    price = (INSTRUMENTS[symbol] * Decimal(str(round(rng.uniform(0.95, 1.05), 4)))).quantize(
        Decimal("0.0001")
    )
    quantity = rng.choice([1, 5, 10, 25, 50, 100, 250, 500])
    side = rng.choice(["BUY", "SELL"])
    notional = _cents(price * quantity)
    commission = max(_cents(notional * Decimal("5") / Decimal("10000")), Decimal("1.00"))
    net = _cents(-(notional + commission)) if side == "BUY" else _cents(notional - commission)
    return {
        "order_id": str(uuid.UUID(int=rng.getrandbits(128))),
        "account_id": rng.choice(ACCOUNTS),
        "symbol": symbol,
        "side": side,
        "quantity": quantity,
        "execution_price": str(price),
        "notional": str(notional),
        "commission": str(commission),
        "net_amount": str(net),
        "status": "SETTLED",
        "synthetic": "true",
        "settled_at": settled_at.isoformat(),
    }


def corrupt(rng: random.Random, trade: dict[str, Any]) -> dict[str, Any]:
    bad = dict(trade)
    kind = rng.choice(["quantity", "notional", "side"])
    if kind == "quantity":
        bad["quantity"] = 0
    elif kind == "notional":
        bad["notional"] = str(Decimal(bad["notional"]) + Decimal("10.00"))
    else:
        bad["side"] = "HOLD"
    return bad


def generate(count: int, seed: int, as_of: datetime) -> list[dict[str, Any]]:
    rng = random.Random(seed)
    trades: list[dict[str, Any]] = []
    for i in range(count):
        settled_at = as_of - timedelta(seconds=rng.randint(0, 8 * 3600))
        trade = make_trade(rng, settled_at)
        if rng.random() < BAD_ROW_RATE:
            trade = corrupt(rng, trade)
        trades.append(trade)
        if i and rng.random() < DUPLICATE_RATE:
            trades.append(dict(rng.choice(trades)))  # at-least-once redelivery
    return trades


def main() -> None:  # pragma: no cover - runs on Databricks
    from pyspark.sql import SparkSession

    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--count", type=int, default=5000)
    parser.add_argument("--seed", type=int, default=None)
    args = parser.parse_args()

    seed = args.seed if args.seed is not None else int(datetime.now(UTC).timestamp())
    rows = generate(args.count, seed, datetime.now(UTC))
    spark = SparkSession.builder.getOrCreate()
    # Everything is written as JSON strings; the pipeline applies the typed schema.
    spark.createDataFrame(rows).coalesce(1).write.mode("append").json(args.output)
    print(f"wrote {len(rows)} synthetic trades (seed={seed}) to {args.output}")


if __name__ == "__main__":  # pragma: no cover
    main()
