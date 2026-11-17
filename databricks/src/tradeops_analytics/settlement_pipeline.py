# Lakeflow Declarative Pipeline (DLT) for TradeOps settlement analytics.
#
#   landing (JSON in a UC volume)
#     -> bronze_trades                 streaming ingest with Auto Loader
#     -> silver_trades                 validated and de-duplicated
#        quarantine_trades             rejected rows with their reason, kept for audit
#     -> gold_daily_positions          net position and cash per account/symbol/day
#     -> gold_concentration_breaches   single-symbol concentration above the limit
#     -> gold_settlement_summary       daily control totals for ledger reconciliation
#
# The logic lives in transforms.py (unit-tested locally); this file only wires it up.
# `spark` is provided by the pipeline runtime.
# ruff: noqa: F821

import dlt
from pyspark.sql import functions as F

try:
    from tradeops_analytics import transforms as t
except ImportError:  # deployed as a pipeline source file: transforms.py sits alongside
    import transforms as t

LANDING_PATH = spark.conf.get("tradeops.landing_path")
CONCENTRATION_LIMIT = float(spark.conf.get("tradeops.concentration_limit", "0.25"))


@dlt.table(comment="Synthetic trades as landed, with ingestion lineage.")
def bronze_trades():
    return (
        spark.readStream.format("cloudFiles")
        .option("cloudFiles.format", "json")
        .schema(t.TRADE_SCHEMA)
        .load(LANDING_PATH)
        .withColumn("_ingested_at", F.current_timestamp())
        .withColumn("_source_file", F.col("_metadata.file_path"))
    )


@dlt.view(comment="Bronze trades annotated with a rejection reason (null when valid).")
def validated_trades():
    return t.validate_trades(dlt.read("bronze_trades"))


@dlt.table(comment="Valid, de-duplicated settled trades.")
@dlt.expect_or_fail("no_rejected_rows", "rejection_reason IS NULL")
def silver_trades():
    valid = dlt.read("validated_trades").where("rejection_reason IS NULL")
    return t.deduplicate(valid)


@dlt.table(comment="Rejected trades and why; never silently dropped.")
def quarantine_trades():
    return dlt.read("validated_trades").where("rejection_reason IS NOT NULL")


@dlt.table(comment="Net position and cash per account, symbol and trade date.")
@dlt.expect("positions_have_trades", "trade_count > 0")
def gold_daily_positions():
    return t.daily_positions(dlt.read("silver_trades"))


@dlt.table(
    comment=f"Account-days where one symbol exceeds {CONCENTRATION_LIMIT:.0%} of gross notional."
)
def gold_concentration_breaches():
    return t.concentration_breaches(dlt.read("gold_daily_positions"), CONCENTRATION_LIMIT)


@dlt.table(comment="Daily settlement control totals.")
def gold_settlement_summary():
    return t.settlement_summary(dlt.read("silver_trades"))
