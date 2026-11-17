# Cost

Approximate US East 2 list prices at the time of writing. Check the Azure Pricing
Calculator before deploying; prices change and these are not quotes.

| Environment | Main cost drivers | Rough monthly order of magnitude |
|---|---|---|
| dev | Container Apps consumption (largely inside the free grant), Standard ACR, Standard Service Bus, Log Analytics capped at 1 GB/day | tens of dollars |
| staging | as dev, with the API and worker kept at one replica each | tens of dollars |
| prod | **Premium Service Bus (1 messaging unit) and Premium ACR** (both needed for private endpoints), private endpoints, GZRS storage, 2+ replicas per app | several hundred to ~$1,000 |

## Keeping a portfolio deployment cheap

- Deploy **dev and staging only**. Every outcome in `docs/demo.md` can be shown in staging;
  the prod stage can be demonstrated with `prod.bicepparam` pointed at a second
  Standard-SKU environment, with `enablePrivateNetworking = false`.
- Log Analytics has a daily cap (`logDailyQuotaGb`) in every environment.
- The dev worker scales to zero (`workerScale.minReplicas = 0`); KEDA wakes it on queue depth.
- Leave Databricks off (`deployDatabricks = false`) unless you are demonstrating Phase 4.
- Tear down when you're done: `az group delete -n rg-tradeops-<env> --yes --no-wait`.
