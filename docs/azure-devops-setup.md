# Setting up Azure and Azure DevOps

About 30 minutes, once per subscription. Everything after this is driven by the pipeline.

## Prerequisites

- An Azure subscription where you are **Owner** (bootstrap creates role assignments).
- An Azure DevOps organization and project; the repo can live in Azure Repos or GitHub.
- Locally: Azure CLI ≥ 2.60 with Bicep (`az bicep install`) and PowerShell 7.

## 1. Register resource providers

```bash
for ns in Microsoft.App Microsoft.ContainerRegistry Microsoft.KeyVault Microsoft.ServiceBus \
          Microsoft.Storage Microsoft.OperationalInsights Microsoft.Insights Microsoft.Network \
          Microsoft.ManagedIdentity; do az provider register --namespace $ns; done
```

## 2. Create the service connections (workload identity federation)

For each of `sc-tradeops-dev`, `sc-tradeops-staging` and `sc-tradeops-prod`:

*Project settings → Service connections → New → Azure Resource Manager →
Workload identity federation (manual).* Copy the **Issuer** and **Subject identifier**
shown, then paste them into `infra/bootstrap/bootstrap.bicepparam`. Leave the dialog open;
you finish it in step 4.

## 3. Bootstrap the subscription

```bash
az deployment sub create -l eastus2 -n tradeops-bootstrap \
  -f infra/bootstrap/main.bicep -p infra/bootstrap/bootstrap.bicepparam
```

This creates `rg-tradeops-{dev,staging,prod}`, plus `rg-tradeops-cicd` holding one
managed identity per environment, federated with its service connection. Each identity
gets:

| Scope | Roles |
|---|---|
| its own resource group | Contributor; Role Based Access Control Administrator **constrained by an ABAC condition** to the seven data-plane roles in `infra/modules/rbac.bicep` |
| dev resource group (dev identity) | AcrPush |
| the previous stage's resource group | Reader and AcrPull, enough to resolve and import the release digest, nothing more |

The pipeline can never grant Owner, Contributor or User Access Administrator, and the prod
identity cannot touch dev or staging resources.

## 4. Finish the service connections

Back in each dialog, enter the subscription, the identity's **client id** (from the
bootstrap outputs), and scope it to the environment's resource group. Tick
"Grant access permission to all pipelines" only if you are not using pipeline permissions.

## 5. Assign the guardrails (Azure Policy, Deny)

```bash
az deployment sub create -l eastus2 -n tradeops-guardrails -f infra/governance/policies.bicep \
  -p resourceGroupNames='["rg-tradeops-dev","rg-tradeops-staging","rg-tradeops-prod"]'
```

Try it: `az storage account create -g rg-tradeops-dev -n sttest$RANDOM --allow-shared-key-access true`
is now denied with the TradeOps non-compliance message.

## 6. Create the environments and their checks

*Pipelines → Environments*: create `tradeops-dev`, `tradeops-staging` and
`tradeops-prod`. On **tradeops-prod**, add these checks:

- **Approvals**: the release approvers (not the person who queued the run).
- **Business hours**: e.g. Mon–Fri 09:00–16:00 America/New_York.
- **Branch control**: `refs/heads/main` only; require branch protection.
- **Exclusive lock**: one production deployment at a time.

Add **Exclusive lock** to staging as well.

## 7. Create the pipelines and branch policy

- New pipeline → existing YAML → `pipelines/azure-pipelines.yml` (name it `tradeops`).
- Optional: `pipelines/databricks-pipeline.yml` (see below).
- *Repos → Branches → main → Branch policies*: require a reviewer, add **Build
  validation** using the `tradeops` pipeline (the Build stage only runs on PRs), and block
  direct pushes.

## 8. First run

Queue `tradeops` on `main`. The first run creates each platform, then deploys release #1
straight to 100% after its smoke test, because there is no stable revision to canary
against yet. Every run after that canaries.

## Optional: Databricks

Set `param deployDatabricks = true` in the environment's `.bicepparam`, deploy, then add
that environment's pipeline identity to the workspace as a service principal with
workspace-admin (or a scoped group). Create a Unity Catalog catalog named as in
`databricks/databricks.yml` (`tradeops_<env>`), then create the
`pipelines/databricks-pipeline.yml` pipeline. The Databricks CLI authenticates through the
same federated Azure CLI session (`DATABRICKS_AUTH_TYPE=azure-cli`), so no Databricks token
is created.

## Tear down

```bash
az group delete -n rg-tradeops-dev --yes --no-wait
```

Dev's Key Vault has purge protection off, so it can be purged and its name reused.
Staging and prod keep purge protection.
