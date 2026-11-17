"""Local Spark tests for the settlement transforms (needs Java 17 or 21)."""

from __future__ import annotations

import os
import shutil
from collections.abc import Iterator
from datetime import UTC, datetime
from decimal import Decimal

import pytest

pyspark = pytest.importorskip("pyspark")
if not (os.getenv("JAVA_HOME") or shutil.which("java")):
    pytest.skip("Java is required for local Spark", allow_module_level=True)

from pyspark.sql import SparkSession  # noqa: E402

from tradeops_analytics import transforms as t  # noqa: E402
from tradeops_analytics.generate_trades import generate  # noqa: E402

AS_OF = datetime(2026, 11, 16, 21, 0, tzinfo=UTC)


@pytest.fixture(scope="session")
def spark() -> Iterator[SparkSession]:
    session = (
        SparkSession.builder.master("local[2]")
        .appName("tradeops-analytics-tests")
        .config("spark.sql.shuffle.partitions", "2")
        .config("spark.sql.session.timeZone", "UTC")
        .config("spark.ui.enabled", "false")
        .getOrCreate()
    )
    yield session
    session.stop()


def trade(**overrides: object) -> dict[str, object]:
    row: dict[str, object] = {
        "order_id": "o-1",
        "account_id": "ACC-1001",
        "symbol": "AAPL",
        "side": "BUY",
        "quantity": 10,
        "execution_price": Decimal("230.0000"),
        "notional": Decimal("2300.00"),
        "commission": Decimal("1.15"),
        "net_amount": Decimal("-2301.15"),
        "status": "SETTLED",
        "synthetic": "true",
        "settled_at": datetime(2026, 11, 16, 15, 0),
    }
    row.update(overrides)
    return row


def frame(spark: SparkSession, rows: list[dict[str, object]]):  # type: ignore[no-untyped-def]
    ordered = [tuple(r[f.name] for f in t.TRADE_SCHEMA.fields) for r in rows]
    return spark.createDataFrame(ordered, schema=t.TRADE_SCHEMA)


def test_validation_assigns_one_reason_per_bad_row(spark: SparkSession) -> None:
    rows = [
        trade(order_id="ok"),
        trade(order_id="", quantity=0),  # missing id wins over quantity
        trade(order_id="q", quantity=0, notional=Decimal("0.00")),
        trade(order_id="s", side="HOLD"),
        trade(order_id="n", notional=Decimal("2310.00")),
        trade(order_id="p", execution_price=Decimal("0.0000"), notional=Decimal("0.00")),
    ]
    result = {
        r.order_id: r.rejection_reason for r in t.validate_trades(frame(spark, rows)).collect()
    }
    assert result == {
        "ok": None,
        "": "MISSING_ORDER_ID",
        "q": "NON_POSITIVE_QUANTITY",
        "s": "INVALID_SIDE",
        "n": "NOTIONAL_MISMATCH",
        "p": "NON_POSITIVE_PRICE",
    }


def test_deduplicate_keeps_latest_delivery(spark: SparkSession) -> None:
    rows = [
        trade(order_id="dup", settled_at=datetime(2026, 11, 16, 15, 0), quantity=10),
        trade(order_id="dup", settled_at=datetime(2026, 11, 16, 16, 0), quantity=10),
        trade(order_id="other"),
    ]
    result = t.deduplicate(frame(spark, rows)).collect()
    assert len(result) == 2
    assert next(r for r in result if r.order_id == "dup").settled_at.hour == 16


def test_daily_positions_net_buys_against_sells(spark: SparkSession) -> None:
    rows = [
        trade(
            order_id="b",
            side="BUY",
            quantity=10,
            notional=Decimal("2300.00"),
            net_amount=Decimal("-2301.15"),
        ),
        trade(
            order_id="s",
            side="SELL",
            quantity=4,
            notional=Decimal("920.00"),
            net_amount=Decimal("919.00"),
            commission=Decimal("1.00"),
        ),
    ]
    (position,) = t.daily_positions(frame(spark, rows)).collect()
    assert position.net_quantity == 6
    assert position.gross_notional == Decimal("3220.00")
    assert position.net_cash == Decimal("-1382.15")
    assert position.trade_count == 2


def test_concentration_breach_detection(spark: SparkSession) -> None:
    rows = [
        trade(
            order_id="a",
            symbol="AAPL",
            notional=Decimal("8000.00"),
            quantity=1,
            execution_price=Decimal("8000.0000"),
        ),
        trade(
            order_id="m",
            symbol="MSFT",
            notional=Decimal("1000.00"),
            quantity=1,
            execution_price=Decimal("1000.0000"),
        ),
        trade(
            order_id="n",
            symbol="NVDA",
            notional=Decimal("1000.00"),
            quantity=1,
            execution_price=Decimal("1000.0000"),
        ),
    ]
    positions = t.daily_positions(frame(spark, rows))
    breaches = t.concentration_breaches(positions, limit=0.25).collect()
    assert [(b.symbol, b.concentration) for b in breaches] == [("AAPL", Decimal("0.8000"))]


def test_generated_data_round_trips_through_the_pipeline_logic(spark: SparkSession) -> None:
    rows = generate(count=2000, seed=7, as_of=AS_OF)
    raw = spark.createDataFrame(rows)
    typed = raw.select(*[raw[f.name].cast(f.dataType).alias(f.name) for f in t.TRADE_SCHEMA.fields])
    validated = t.validate_trades(typed)
    valid = validated.where("rejection_reason IS NULL")
    rejected = validated.where("rejection_reason IS NOT NULL")

    assert 0 < rejected.count() < 0.03 * len(rows)  # ~1% corrupted on purpose
    silver = t.deduplicate(valid)
    assert silver.count() < valid.count()  # redelivered duplicates removed
    assert silver.select("order_id").distinct().count() == silver.count()

    summary = t.settlement_summary(silver).collect()
    positions = t.daily_positions(silver)
    total_from_positions = sum(r.gross_notional for r in positions.collect())
    assert sum(r.gross_notional for r in summary) == total_from_positions  # control totals agree


def test_generator_is_deterministic() -> None:
    assert generate(50, 1, AS_OF) == generate(50, 1, AS_OF)
    assert generate(50, 1, AS_OF) != generate(50, 2, AS_OF)
