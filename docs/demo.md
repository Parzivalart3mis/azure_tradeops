# Demonstrations and evidence capture

The three outcomes this project exists to show, how to trigger each one, and exactly what
to record. Fill in the evidence table in the README from real runs; leave a cell empty
rather than estimate it.

## 1. Commit to production

1. Merge a PR to `main` (any visible change: bump `appVersion` in
   `pipelines/variables/common.yml`).
2. Let Dev and Staging run; approve Prod after reading the **Prod plan** stage's what-if
   summary (Extensions tab of the run).

**Capture:**
- Pipeline run graph (all stages green) with total duration and per-stage durations.
- Tests tab: Python, Pester and PSRule result counts.
- `reports-prod-1` artifact: `release-report-prod.json` (phases with timings, canary
  metrics at 10% and 50%).
- The workbook's "requests served per revision" pie during the 50% step.

## 2. A failing release is detected and rolled back

1. Queue `tradeops` manually and tick **Demo: ship a deliberately failing release to
   staging**. Fault rate 0.3 makes 30% of order requests fail with 500; health probes stay
   green.
2. Watch the Staging stage:
   - the revision deploys at 0% and the smoke test probably passes (it only makes five
     business calls), which is fine;
   - traffic moves to 10%, and canary analysis sends 60 orders and measures roughly 30%
     errors against a 1% SLO;
   - automatic rollback: 100% back to `stable`, canary deactivated, verified from outside;
   - the stage fails and Prod never starts.

**Capture:**
- `release-report-staging.json`: `Outcome: RolledBack`, `MaxTrafficExposed: 10`,
  `DetectionSec`, `RecoverySec`, and the canary vs. baseline error rates.
- The workbook's "error rate by revision" chart showing the spike confined to the canary.
- `Get-ReleaseStatus.ps1 -Environment staging` afterwards: stable at 100%, canary inactive.

Locally, with no Azure needed, the same analysis code against a 30%-fault instance
measured 28% errors (`201x72 500x28`) and failed the verdict, while the healthy instance
measured 0% and passed. See the README's verified-results table.

## 3. An unsafe change is rejected

Two layers; show both.

**At PR time (PSRule):**
```bash
git switch -c demo/unsafe-storage
sed -i 's/allowSharedKeyAccess: false/allowSharedKeyAccess: true/' infra/modules/storage.bicep
git commit -am "demo: enable storage shared keys" && git push -u origin demo/unsafe-storage
```
Open a PR. Build validation fails in *Infrastructure → PSRule for Azure* with
`TradeOps.Storage.NoSharedKey` and `Azure.Storage.LocalAuth`, so the PR cannot merge.
`./scripts/Test-SecurityGates.ps1` shows all 13 such cases locally in about 45 seconds.

**At deploy time (Azure Policy), even outside the pipeline:**
```bash
az storage account create -g rg-tradeops-dev -n sttradeopsdemo$RANDOM -l eastus2 \
  --allow-shared-key-access true \
  --tags costCenter=x owner=y dataClassification=internal
```
The response is `RequestDisallowedByPolicy` with the TradeOps non-compliance message.

**Capture:** the failed PR check, the PSRule test results tab, and the policy denial.

## Timing fields worth reporting

| Metric | Source |
|---|---|
| Commit → prod (wall clock, excluding approval wait) | run duration minus the approval wait |
| Build stage duration | run graph |
| Time to detect a bad canary | `DetectionSec` in the release report |
| Time to recover (rollback verified from outside) | `RecoverySec` / rollback report `VerifiedSec` |
| Customer traffic exposed to the bad release | `MaxTrafficExposed` |
