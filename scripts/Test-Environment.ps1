<#
.SYNOPSIS
    Pre-flight validation for a TradeOps environment (run before any deployment step).
.EXAMPLE
    ./scripts/Test-Environment.ps1 -ResourceGroup rg-tradeops-dev -RequirePlatform
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $ExpectedSubscriptionId = $env:TRADEOPS_SUBSCRIPTION_ID,
    [switch] $RequirePlatform
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TradeOps/TradeOps.psd1') -Force
Test-TradeOpsEnvironment -ResourceGroup $ResourceGroup -ExpectedSubscriptionId $ExpectedSubscriptionId -RequirePlatform:$RequirePlatform | Out-Null
