"""Settlement analytics transforms (pure PySpark, no Databricks-only APIs).

Kept separate from the pipeline definitions so they can be unit-tested on a laptop with
local Spark and reused by both the declarative pipeline and ad-hoc notebooks.

Money columns are DECIMAL(18,2), never floating point.
"""

from __future__ import annotations

from pyspark.sql import DataFrame, Window
from pyspark.sql import functions as F
from pyspark.sql.types import (
    DecimalType,
    IntegerType,
    StringType,
    StructField,
    StructType,
    TimestampType,
)

MONEY = DecimalType(18, 2)
PRICE = DecimalType(18, 4)

TRADE_SCHEMA = StructType(
    [
        StructField("order_id", StringType()),
        StructField("account_id", StringType()),
        StructField("symbol", StringType()),
        StructField("side", StringType()),
        StructField("quantity", IntegerType()),
        StructField("execution_price", PRICE),
        StructField("notional", MONEY),
        StructField("commission", MONEY),
        StructField("net_amount", MONEY),
        StructField("status", StringType()),
        StructField("synthetic", StringType()),
        StructField("settled_at", TimestampType()),
    ]
)

VALID_SIDES = ("BUY", "SELL")


def validate_trades(trades: DataFrame) -> DataFrame:
    """Adds `rejection_reason` (null when the row is valid). Checks run in priority order,
    so each invalid row carries exactly one, most fundamental, reason."""
    reason = (
        F.when(F.col("order_id").isNull() | (F.trim("order_id") == ""), F.lit("MISSING_ORDER_ID"))
        .when(F.col("account_id").isNull(), F.lit("MISSING_ACCOUNT"))
        .when(~F.col("side").isin(*VALID_SIDES), F.lit("INVALID_SIDE"))
        .when(F.col("quantity").isNull() | (F.col("quantity") <= 0), F.lit("NON_POSITIVE_QUANTITY"))
        .when(
            F.col("execution_price").isNull() | (F.col("execution_price") <= 0),
            F.lit("NON_POSITIVE_PRICE"),
        )
        .when(F.col("settled_at").isNull(), F.lit("MISSING_SETTLEMENT_TIME"))
        # The notional must agree with price x quantity to the cent.
        .when(
            F.abs(
                F.col("notional")
                - F.round(F.col("execution_price") * F.col("quantity"), 2).cast(MONEY)
            )
            > F.lit(0.01),
            F.lit("NOTIONAL_MISMATCH"),
        )
    )
    return trades.withColumn("rejection_reason", reason)


def deduplicate(trades: DataFrame) -> DataFrame:
    """At-least-once delivery means the same order can land twice; keep the latest copy."""
    latest = Window.partitionBy("order_id").orderBy(F.col("settled_at").desc())
    return (
        trades.withColumn("_rank", F.row_number().over(latest))
        .where(F.col("_rank") == 1)
        .drop("_rank")
    )


def daily_positions(trades: DataFrame) -> DataFrame:
    """Net position and cash per account, symbol and trade date."""
    signed_quantity = F.when(F.col("side") == "BUY", F.col("quantity")).otherwise(
        -F.col("quantity")
    )
    return (
        trades.withColumn("trade_date", F.to_date("settled_at"))
        .groupBy("account_id", "symbol", "trade_date")
        .agg(
            F.sum(signed_quantity).alias("net_quantity"),
            F.sum("notional").cast(MONEY).alias("gross_notional"),
            F.sum("net_amount").cast(MONEY).alias("net_cash"),
            F.sum("commission").cast(MONEY).alias("commission"),
            F.count(F.lit(1)).alias("trade_count"),
        )
    )


def concentration_breaches(positions: DataFrame, limit: float) -> DataFrame:
    """Account-days where a single symbol exceeds `limit` (e.g. 0.25) of the account's gross
    notional for the day, a standard concentration-risk control."""
    account_day = Window.partitionBy("account_id", "trade_date")
    return (
        positions.withColumn("account_gross", F.sum("gross_notional").over(account_day))
        .withColumn(
            "concentration",
            F.round(F.col("gross_notional") / F.col("account_gross"), 4).cast(DecimalType(6, 4)),
        )
        .where(F.col("concentration") > F.lit(limit))
        .where(F.col("account_gross") > 0)
        .select(
            "account_id",
            "trade_date",
            "symbol",
            "gross_notional",
            "account_gross",
            "concentration",
        )
    )


def settlement_summary(trades: DataFrame) -> DataFrame:
    """One row per trade date: volumes, commission and cash moved, the daily control total
    that is reconciled against the ledger."""
    return (
        trades.withColumn("trade_date", F.to_date("settled_at"))
        .groupBy("trade_date")
        .agg(
            F.count(F.lit(1)).alias("trades"),
            F.countDistinct("account_id").alias("accounts"),
            F.sum("notional").cast(MONEY).alias("gross_notional"),
            F.sum("commission").cast(MONEY).alias("commission"),
            F.sum("net_amount").cast(MONEY).alias("net_cash"),
        )
    )
