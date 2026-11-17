<#
.SYNOPSIS
    what-if, review gate, and deployment of the platform (infra/main.bicep) to one environment.
.EXAMPLE
    # Plan only (used by the pre-approval stage so reviewers see the change set)
    ./scripts/Deploy-Platform.ps1 -Environment prod -WhatIfOnly
.EXAMPLE
    ./scripts/Deploy-Platform.ps1 -Environment dev
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('dev', 'staging', 'prod')] [string] $Environment,
    [string] $ResourceGroup = "rg-tradeops-$Environment",
    # Compiled template and parameters from the build artifact; falls back to the sources.
    [string] $TemplateFile,
    [string] $ParameterFile,
    [switch] $WhatIfOnly,
    [switch] $AllowDelete,
    [switch] $AllowProtectedChange,
    [string] $SummaryPath = "whatif-$Environment.md"
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TradeOps/TradeOps.psd1') -Force
if ($SummaryPath -and (Split-Path $SummaryPath)) { New-Item -ItemType Directory -Force -Path (Split-Path $SummaryPath) | Out-Null }
$root = Split-Path $PSScriptRoot -Parent
if (-not $TemplateFile) { $TemplateFile = Join-Path $root 'infra/main.bicep' }
if (-not $ParameterFile) { $ParameterFile = Join-Path $root "infra/env/$Environment.bicepparam" }

Invoke-PlatformDeployment -ResourceGroup $ResourceGroup -TemplateFile $TemplateFile -ParameterFile $ParameterFile `
    -WhatIfOnly:$WhatIfOnly -AllowDelete:$AllowDelete -AllowProtectedChange:$AllowProtectedChange `
    -SummaryPath $SummaryPath | Out-Null
