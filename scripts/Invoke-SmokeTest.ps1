<#
.SYNOPSIS
    Smoke-tests an environment's public API URL (or any revision URL).
.EXAMPLE
    ./scripts/Invoke-SmokeTest.ps1 -Environment prod
.EXAMPLE
    ./scripts/Invoke-SmokeTest.ps1 -BaseUrl http://localhost:8080 -SkipSettlement
#>
[CmdletBinding(DefaultParameterSetName = 'Environment')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Environment')] [ValidateSet('dev', 'staging', 'prod')] [string] $Environment,
    [Parameter(ParameterSetName = 'Environment')] [string] $ResourceGroup = "rg-tradeops-$Environment",
    [Parameter(Mandatory, ParameterSetName = 'Url')] [string] $BaseUrl,
    [string] $ExpectedVersion,
    [switch] $SkipSettlement,
    [string] $ReportPath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TradeOps/TradeOps.psd1') -Force
if ($ReportPath -and (Split-Path $ReportPath)) { New-Item -ItemType Directory -Force -Path (Split-Path $ReportPath) | Out-Null }
if ($PSCmdlet.ParameterSetName -eq 'Environment') {
    $platform = Get-PlatformOutput -ResourceGroup $ResourceGroup
    $BaseUrl = (Get-ContainerAppTraffic -ResourceGroup $ResourceGroup -AppName $platform.apiAppName).Fqdn
}
$result = Invoke-SmokeTest -BaseUrl $BaseUrl -ExpectedVersion $ExpectedVersion -SkipSettlement:$SkipSettlement -NoThrow
if ($ReportPath) { $result | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportPath -Encoding utf8 }
if (-not $result.Passed) { throw "Smoke test failed against $BaseUrl" }
