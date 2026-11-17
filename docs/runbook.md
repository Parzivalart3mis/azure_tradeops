# Production support runbook

All commands run from the repo root with an Azure CLI session that has access to the
environment (`az login`, or Cloud Shell with the repo cloned). Every script is safe to run
more than once.

## What is running right now?

```powershell
./scripts/Get-ReleaseStatus.ps1 -Environment prod
```

The output shows each API and worker revision with its traffic weight, label
(`stable` / `canary` / `previous`), health, running state and image digest. A healthy
steady state is one `stable` revision at 100%, one `previous` at 0%, and nothing else
active.

## Roll back

| Situation | Command | Effect |
|---|---|---|
| A canary is in flight and looks wrong | `./scripts/Invoke-Rollback.ps1 -Environment prod -Reason "INC-123"` | 100% to `stable`, canary deactivated, verified from outside |
| A release was promoted and is now misbehaving | `./scripts/Invoke-Rollback.ps1 -Environment prod -ToPrevious -Reason "INC-123"` | 100% to the warm `previous` revision; no image pull, no cold start |
| You want to see what would happen first | add `-WhatIf` | Prints the plan and changes nothing |

Each rollback writes `rollback-report-<env>.json` with the traffic-restored and verified
times. Attach it to the incident.

The worker is single-revision. To roll it back, re-run the previous successful pipeline
run's Prod stage, or redeploy the previous image with `Publish-WorkerRelease`.

## Smoke-test an environment

```powershell
./scripts/Invoke-SmokeTest.ps1 -Environment prod              # includes settlement end to end
./scripts/Invoke-SmokeTest.ps1 -Environment prod -SkipSettlement
```

Smoke traffic uses the synthetic `SMOKE-0001` account, so it never mixes with client data.

## Alert playbooks

Dashboard: Azure portal → Monitor → Workbooks → **TradeOps operations (prod)**.

### API error rate > 2% (Sev1 in prod)
1. In the workbook's "error rate by revision" chart, check whether one revision is
   responsible. If it is the newest one, roll back (`-ToPrevious`).
2. Check the "recent application errors" table. Every row carries `trace_id`, so paste it
   into Application Insights → Transaction search to see the end-to-end trace.
3. Check readiness: `curl https://<fqdn>/readyz` names the failing dependency (ledger or
   queue).

### Order submission p95 > 750 ms (Sev2)
1. Look at "Dependency calls": is Table Storage or Service Bus slow?
2. Check scale: was the API at `maxReplicas`? KQL:
   `ContainerAppSystemLogs | where Reason has "Scal" | order by TimeGenerated desc`.

### Settlements failed after retries / dead-letter queue > 0 (Sev1)
Orders are `FAILED` and their messages are in the dead-letter queue. No client cash moved.
1. Read the dead-letter reason without consuming the messages: Azure portal → Service Bus
   → `settlement-requests` → Service Bus Explorer → Dead-letter → Peek.
2. `MalformedMessage` / `UnknownOrder` point to a producer bug: roll back the API.
   `RetriesExhausted` points to a dependency outage: fix the dependency, then resubmit.
3. Resubmit once the cause is fixed. Duplicate detection makes resubmission safe within
   one hour, and settlement is idempotent beyond that.

### Container restarts / probe failures (Sev2)
`ContainerAppSystemLogs | where Reason in ("BackOff","ProbeFailed") | project TimeGenerated, RevisionName, Reason, Log`
Usually a bad configuration or an identity missing a role. `Test-Environment.ps1 -RequirePlatform`
checks the platform side.

## Useful KQL

```kusto
// Errors by revision, last hour (canary vs stable)
AppRequests
| where TimeGenerated > ago(1h) and AppRoleName == "tradeops-api" and Name !has "healthz"
| extend revision = coalesce(tostring(Properties["tradeops.revision"]), AppVersion)
| summarize requests = count(), errors = countif(toint(ResultCode) >= 500), p95 = percentile(DurationMs, 95) by revision

// Follow one order through API -> queue -> worker
ContainerAppConsoleLogs
| extend e = parse_json(Log)
| where tostring(e.order_id) == "<order-id>"
| project TimeGenerated, ContainerAppName, message = tostring(e.message), e
```
