# Local equivalents of every CI gate. Needs: uv, PowerShell 7 (pwsh), Bicep CLI, Docker,
# Java 21 for the Spark tests. `make ci` runs what the Build stage runs.
SHELL := /bin/bash
PWSH ?= pwsh
BICEP ?= bicep
ENTRYPOINTS := infra/main.bicep infra/apps/api.bicep infra/apps/worker.bicep infra/governance/policies.bicep infra/bootstrap/main.bicep

.PHONY: help setup run test test-all lint security bicep psrule gates pester databricks image compose ci

help: ## List targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

setup: ## Install Python dependencies (app + databricks)
	cd app && uv sync
	cd databricks && uv sync

run: ## Run the API locally with in-memory ledger and queue (http://localhost:8080/docs)
	cd app && uv run uvicorn tradeops.main:app --reload --port 8080

test: ## Unit tests
	cd app && uv run pytest

test-all: ## Unit + Azurite integration tests with the CI coverage gate (needs Azurite on :10002)
	cd app && TRADEOPS_TEST_AZURITE=1 uv run pytest -m "" --cov --cov-fail-under=90

lint: ## ruff, format check, mypy --strict
	cd app && uv run ruff check . && uv run ruff format --check . && uv run mypy

security: ## bandit + pip-audit
	cd app && uv run bandit -r src -c pyproject.toml --severity-level medium --confidence-level medium
	cd app && uv export --frozen --no-dev --no-emit-project --format requirements-txt > /tmp/tradeops-req.txt && uv run pip-audit --strict -r /tmp/tradeops-req.txt --progress-spinner off

bicep: ## Lint every Bicep entrypoint and compile the environment parameter files
	@for f in $(ENTRYPOINTS); do echo "lint $$f"; $(BICEP) lint $$f || exit 1; done
	@for e in dev staging prod; do $(BICEP) build-params infra/env/$$e.bicepparam --stdout > /dev/null && echo "params $$e ok"; done

psrule: ## PSRule for Azure over all environments and app templates
	$(PWSH) -NoLogo -c "Assert-PSRule -Format File -InputPath infra/ -Module PSRule.Rules.Azure"

gates: ## Security gate self-test: unsafe infra changes must be rejected
	$(PWSH) -NoLogo -File scripts/Test-SecurityGates.ps1

pester: ## PSScriptAnalyzer + Pester for the release tooling
	$(PWSH) -NoLogo -c '$$f = Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings scripts/PSScriptAnalyzerSettings.psd1; if ($$f) { $$f | Format-Table; exit 1 }'
	$(PWSH) -NoLogo -c '$$c = New-PesterConfiguration; $$c.Run.Path = "scripts/tests"; $$c.Run.Exit = $$true; Invoke-Pester -Configuration $$c'

databricks: ## Spark unit tests for the analytics bundle
	cd databricks && uv run ruff check . && uv run pytest

image: ## Build the container image
	docker build app -t tradeops:local --build-arg VERSION=0.0.0-local

compose: ## API + Azurite in Docker
	docker compose up --build

ci: lint security test bicep psrule gates pester databricks ## Everything the Build stage runs (except image scan)
