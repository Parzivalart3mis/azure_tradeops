"""Generates tradeops-workbook.json (the Azure Monitor workbook deployed by
infra/modules/workbook.bicep). Edit the queries here, then run: python build_workbook.py"""

import json
from pathlib import Path

WS = "__WORKSPACE_ID__"  # replaced with the workspace resource id at deploy time
REVISION = 'extend revision = coalesce(tostring(Properties["tradeops.revision"]), AppVersion)'


def query(name, title, kql, viz, width="50", **extra):
    content = {
        "version": "KqlItem/1.0",
        "query": kql.strip(),
        "size": 0,
        "title": title,
        "timeContextFromParameter": "TimeRange",
        "queryType": 0,
        "resourceType": "microsoft.operationalinsights/workspaces",
        "crossComponentResources": [WS],
        "visualization": viz,
        **extra,
    }
    return {"type": 3, "content": content, "customWidth": width, "name": name}


items = [
    {
        "type": 1,
        "name": "header",
        "content": {
            "json": "## TradeOps operations\n"
            "Order API and settlement worker health, split by Container Apps revision so a "
            "canary can be compared against the stable release side by side."
        },
    },
    {
        "type": 9,
        "name": "parameters",
        "content": {
            "version": "KqlParameterItem/1.0",
            "style": "pills",
            "queryType": 0,
            "resourceType": "microsoft.operationalinsights/workspaces",
            "parameters": [
                {
                    "id": "8f3c1c2e-3b1a-4c55-9a51-1f0b8f0f6d01",
                    "version": "KqlParameterItem/1.0",
                    "name": "TimeRange",
                    "label": "Time range",
                    "type": 4,
                    "isRequired": True,
                    "value": {"durationMs": 3600000},
                    "typeSettings": {
                        "selectableValues": [
                            {"durationMs": 900000},
                            {"durationMs": 3600000},
                            {"durationMs": 14400000},
                            {"durationMs": 86400000},
                            {"durationMs": 604800000},
                        ]
                    },
                }
            ],
        },
    },
    query(
        "error-rate-by-revision",
        "API error rate by revision (%)",
        f"""
AppRequests
| where AppRoleName == "tradeops-api" and Name !has "healthz" and Name !has "readyz"
| {REVISION}
| summarize error_rate = round(100.0 * countif(toint(ResultCode) >= 500) / count(), 2) by revision, bin(TimeGenerated, 1m)
| render timechart
""",
        "timechart",
    ),
    query(
        "traffic-split",
        "Requests served per revision (live traffic split)",
        f"""
AppRequests
| where AppRoleName == "tradeops-api" and Name !has "healthz" and Name !has "readyz"
| {REVISION}
| summarize requests = count() by revision
""",
        "piechart",
    ),
    query(
        "latency",
        "Order submission latency (ms)",
        """
AppRequests
| where AppRoleName == "tradeops-api" and Name startswith "POST /v1/orders"
| summarize p50 = percentile(DurationMs, 50), p95 = percentile(DurationMs, 95), p99 = percentile(DurationMs, 99) by bin(TimeGenerated, 1m)
| render timechart
""",
        "timechart",
    ),
    query(
        "order-outcomes",
        "Order outcomes",
        """
AppMetrics
| where Name in ("tradeops.orders.received", "tradeops.orders.rejected", "tradeops.transactions.settled", "tradeops.transactions.failed")
| summarize count = sum(Sum) by Name, bin(TimeGenerated, 5m)
| render columnchart
""",
        "barchart",
    ),
    query(
        "rejections",
        "Pre-trade risk rejections by reason",
        """
AppMetrics
| where Name == "tradeops.orders.rejected"
| extend reason = tostring(Properties["reason"])
| summarize rejected = sum(Sum) by reason
| order by rejected desc
""",
        "table",
    ),
    query(
        "settlement-latency",
        "Settlement latency, accept to settled (ms)",
        """
AppMetrics
| where Name == "tradeops.settlement.latency"
| summarize avg_ms = sum(Sum) / sum(ItemCount), max_ms = max(Max) by bin(TimeGenerated, 5m)
| render timechart
""",
        "timechart",
    ),
    query(
        "dead-letters",
        "Settlement dead-letter queue depth",
        """
AzureMetrics
| where ResourceProvider == "MICROSOFT.SERVICEBUS" and MetricName in ("DeadletteredMessages", "ActiveMessages")
| summarize value = max(Maximum) by MetricName, bin(TimeGenerated, 5m)
| render timechart
""",
        "timechart",
    ),
    query(
        "dependencies",
        "Dependency calls (Table Storage, Service Bus)",
        """
AppDependencies
| where AppRoleName startswith "tradeops"
| summarize calls = count(), failed = countif(Success == false), p95_ms = percentile(DurationMs, 95) by Target, DependencyType
| order by calls desc
""",
        "table",
    ),
    query(
        "platform-events",
        "Container Apps platform events (restarts, probes, scaling)",
        """
ContainerAppSystemLogs
| where ContainerAppName startswith "ca-tradeops"
| project TimeGenerated, ContainerAppName, RevisionName, Reason, Log
| order by TimeGenerated desc
| take 100
""",
        "table",
        width="100",
    ),
    query(
        "recent-errors",
        "Recent application errors (structured logs)",
        """
ContainerAppConsoleLogs
| where ContainerAppName startswith "ca-tradeops"
| extend entry = parse_json(Log)
| where tostring(entry.level) in ("ERROR", "CRITICAL")
| project TimeGenerated, RevisionName, message = tostring(entry.message), order_id = tostring(entry.order_id), error = tostring(entry.error), trace_id = tostring(entry.trace_id)
| order by TimeGenerated desc
| take 100
""",
        "table",
        width="100",
    ),
]

workbook = {
    "version": "Notebook/1.0",
    "items": items,
    "fallbackResourceIds": [WS],
    "$schema": "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json",
}

Path(__file__).with_name("tradeops-workbook.json").write_text(json.dumps(workbook, indent=2) + "\n")
