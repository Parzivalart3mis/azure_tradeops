# Security controls

## Where each control is enforced

| Control | PR time (PSRule) | Deploy time (Azure Policy, Deny) | Runtime / design |
|---|---|---|---|
| Storage: no shared keys, no public blobs, HTTPS + TLS 1.2 | `TradeOps.Storage.NoSharedKey`, `Azure.Storage.*` | `tradeops-storage-*` | Apps use Entra ID + Table Data Contributor on one account |
| Key Vault: RBAC model, firewall, purge protection (staging/prod) | `TradeOps.KeyVault.RbacOnly`, `Azure.KeyVault.*` | `tradeops-keyvault-rbac` | Secrets reach apps only as Container Apps Key Vault references |
| Service Bus: SAS keys disabled, duplicate detection | `TradeOps.ServiceBus.*`, `Azure.ServiceBus.DisableLocalAuth` | `tradeops-servicebus-no-local-auth` | Sender and Receiver roles scoped to the queue, not the namespace |
| Container registry: no admin user; private in prod | `Azure.ACR.*`, `TradeOps.Prod.PrivateNetworking` | `tradeops-acr-no-admin-user` | Release tags are locked (write- and delete-disabled) after push |
| Telemetry ingestion requires Entra ID | `TradeOps.Monitor.NoLocalAuth` | n/a | Monitoring Metrics Publisher on the App Insights component only |
| HTTPS-only ingress | `Azure.ContainerApp.Insecure` | `tradeops-containerapps-https-only` | n/a |
| No internet-exposed management ports | `TradeOps.NSG.NoInternetManagementPorts` | n/a | Explicit inbound deny for 22/3389/5985/5986 and outbound lateral-movement deny |
| Prod PaaS is private | `TradeOps.Prod.PrivateNetworking` | n/a | Private endpoints and private DNS; public network access disabled |
| Governance tags | `TradeOps.Tags.Required` + the Bicep type system | `tradeops-required-tags` | n/a |
| Approved regions | `Azure.Resource.AllowedRegions` | `tradeops-allowed-locations` | n/a |
| Risky infra changes reviewed | n/a | n/a | `what-if` gate blocks deletes and protected-property changes unless explicitly allowed |
| Application code | bandit (medium+), pip-audit (strict), gitleaks (full history) | n/a | Trivy fails fixable HIGH/CRITICAL; CycloneDX SBOM per build; non-root, read-only image |

### Proving the gate works

`scripts/Test-SecurityGates.ps1` runs in CI on every PR. It copies the real infrastructure
code, applies 13 unsafe changes one at a time and asserts that each one is rejected by the
expected rule. The untouched baseline must pass. On its first run it found a real gap:
opening SSH from the `Internet` service tag passed every built-in rule. The
`TradeOps.NSG.NoInternetManagementPorts` rule was added because of that.

## Identity and access

| Identity | Scope | Roles |
|---|---|---|
| `id-tradeops-api-<env>` (user-assigned) | registry / vault / queue / storage / App Insights | AcrPull, Key Vault Secrets User, Service Bus Data **Sender**, Storage Table Data Contributor, Monitoring Metrics Publisher |
| `id-tradeops-worker-<env>` | same resources | AcrPull, Key Vault Secrets User, Service Bus Data **Receiver** + Data Owner (queue only; KEDA reads queue length), Storage Table Data Contributor, Monitoring Metrics Publisher |
| `id-tradeops-pipeline-<env>` (federated with Azure DevOps) | its resource group | Contributor; RBAC Administrator restricted by ABAC to the 7 roles above; dev: AcrPush |
| same | previous stage's resource group | Reader + AcrPull (promotion by digest) |

No client secret exists for any identity. Azure DevOps exchanges its OIDC token for an
Entra token via the federated credential on each pipeline identity.

## Accepted exceptions

Each exception is recorded in `ps-rule.yaml` or `.ps-rule/TradeOps.Suppressions.Rule.yaml`
with its reason. Deleting the line turns the rule back on.

| Rule | Where | Why | Production follow-up |
|---|---|---|---|
| `Azure.ACR.GeoReplica`, `Azure.Log.Replication` | all | Single region by design; recovery is rebuild + import | Paired-region DR if the RTO requires it |
| `Azure.ContainerApp.PublicAccess`, `RestrictIngress` | all | Smoke tests and canary probes run from Microsoft-hosted agents | Internal environment behind Application Gateway WAF; Managed DevOps Pool in the VNet |
| `Azure.VNET.PrivateSubnet` | all | The Container Apps subnet keeps default outbound | NAT gateway or Azure Firewall with egress allow-list |
| `Azure.KeyVault.PurgeProtect`, `Azure.Storage.UseReplication` | dev | Disposable environment, synthetic data | n/a |
| `Azure.ACR.ExportPolicy` | dev, staging | Only configurable on Premium; prod is Premium with export disabled | n/a |
| `Azure.ContainerApp.MinReplicas` | dev, staging | Cost; prod runs ≥ 2 replicas across zones | n/a |

## Known gaps (out of scope for this build)

- The order API has no end-user authentication. Next step: Container Apps
  authentication (Entra ID) or JWT validation in the app, with per-account authorisation.
- Images are not yet signed. Next step: Notation signing in CI plus a verification policy.
- Canary analysis uses client-side synthetic traffic; a server-side Log Analytics check per
  revision would add real-user signal at higher traffic.
