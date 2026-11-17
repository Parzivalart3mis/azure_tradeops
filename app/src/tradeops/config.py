"""Runtime configuration, read from environment variables.

Everything an operator can change between environments lives here. In Azure the values
come from the Container App template (see infra/apps/*.bicep); locally they default to
an in-memory backend so the service runs with no cloud dependencies.
"""

from __future__ import annotations

from decimal import Decimal
from enum import StrEnum
from functools import lru_cache

from pydantic import AliasChoices, Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Backend(StrEnum):
    # memory: each dependency is in-memory unless its endpoint is configured.
    # azure:  both Azure endpoints are required; startup fails fast if one is missing.
    MEMORY = "memory"
    AZURE = "azure"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="TRADEOPS_", extra="ignore", populate_by_name=True)

    environment: str = "local"
    backend: Backend = Backend.MEMORY
    log_level: str = "INFO"

    # Release identity. CONTAINER_APP_REVISION is injected by Azure Container Apps.
    version: str = "0.0.0-dev"
    git_sha: str = "unknown"
    revision: str = Field(
        default="local",
        validation_alias=AliasChoices("TRADEOPS_REVISION", "CONTAINER_APP_REVISION", "revision"),
    )

    # Azure Table Storage (order ledger). In Azure the endpoint plus managed identity is
    # used; a connection string is only for Azurite during local development.
    storage_table_endpoint: str | None = None
    storage_connection_string: SecretStr | None = None
    orders_table: str = "orders"

    # Azure Service Bus (settlement queue), authenticated with managed identity.
    servicebus_namespace: str | None = None
    settlement_queue: str = "settlement-requests"
    max_delivery_count: int = Field(default=5, ge=1, le=100)

    # Pre-trade risk.
    max_order_notional: Decimal = Decimal("5000000.00")
    price_collar_pct: Decimal = Decimal("0.10")

    # Fault injection, used to demonstrate canary analysis and automatic rollback.
    # It only affects /v1/* business endpoints, so health probes keep passing; that is
    # the kind of bad release a liveness check alone would never catch.
    fault_rate: float = Field(default=0.0, ge=0.0, le=1.0)
    fault_latency_ms: int = Field(default=0, ge=0, le=30_000)

    readiness_timeout_s: float = Field(default=2.0, gt=0)

    # Application Insights has local auth disabled in Azure (infra/modules/monitoring.bicep),
    # so ingestion authenticates with the app's managed identity.
    appinsights_entra_auth: bool = False
    applicationinsights_connection_string: SecretStr | None = Field(
        default=None,
        validation_alias=AliasChoices(
            "APPLICATIONINSIGHTS_CONNECTION_STRING", "applicationinsights_connection_string"
        ),
    )

    @model_validator(mode="after")
    def _azure_backend_needs_endpoints(self) -> Settings:
        if self.backend is Backend.AZURE:
            if not (self.storage_table_endpoint or self.storage_connection_string):
                raise ValueError(
                    "backend=azure requires TRADEOPS_STORAGE_TABLE_ENDPOINT "
                    "(or TRADEOPS_STORAGE_CONNECTION_STRING for Azurite)"
                )
            if not self.servicebus_namespace:
                raise ValueError("backend=azure requires TRADEOPS_SERVICEBUS_NAMESPACE")
        return self


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
