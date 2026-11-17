<#
.SYNOPSIS
    Production-support view of revisions, traffic weights, labels and health.
.EXAMPLE
    ./scripts/Get-ReleaseStatus.ps1 -Environment prod
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('dev', 'staging', 'prod')] [string] $Environment,
    [string] $ResourceGroup = "rg-tradeops-$Environment"
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TradeOps/TradeOps.psd1') -Force
Get-TradeOpsStatus -ResourceGroup $ResourceGroup | Out-Null
