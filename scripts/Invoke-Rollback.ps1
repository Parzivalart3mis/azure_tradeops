<#
.SYNOPSIS
    Rolls the API back. Default: abort an in-flight canary (all traffic to 'stable').
    -ToPrevious: revert a promoted release to the warm 'previous' revision.
    -Auto: what the pipeline's on-failure hook uses. Aborts a canary if one is in flight;
    otherwise, if this run's release report says the release was promoted (so the failure
    came after promotion), reverts to 'previous'.
    Safe to run at any time; it does nothing when there is nothing to roll back.
.EXAMPLE
    ./scripts/Invoke-Rollback.ps1 -Environment prod -ToPrevious -Reason "INC-2041 settlement errors"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [ValidateSet('dev', 'staging', 'prod')] [string] $Environment,
    [string] $ResourceGroup = "rg-tradeops-$Environment",
    [string] $Reason = 'manual rollback',
    [switch] $ToPrevious,
    [switch] $Auto,
    [string] $ReleaseReportPath,
    [string] $ReportPath = "rollback-report-$Environment.json"
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TradeOps/TradeOps.psd1') -Force
if ($ReportPath -and (Split-Path $ReportPath)) { New-Item -ItemType Directory -Force -Path (Split-Path $ReportPath) | Out-Null }
$platform = Get-PlatformOutput -ResourceGroup $ResourceGroup
$result = Invoke-Rollback -ResourceGroup $ResourceGroup -AppName $platform.apiAppName -Reason $Reason `
    -ToPrevious:$ToPrevious -ReportPath $ReportPath -WhatIf:$WhatIfPreference
if ($Auto -and -not $result.RolledBack -and $ReleaseReportPath -and (Test-Path $ReleaseReportPath)) {
    $release = Get-Content -Raw $ReleaseReportPath | ConvertFrom-Json
    if ($release.Outcome -eq 'Promoted' -and $release.PreviousStable) {
        Write-Host "release $($release.Version) was promoted before the failure; reverting to previous"
        $result = Invoke-Rollback -ResourceGroup $ResourceGroup -AppName $platform.apiAppName -Reason $Reason `
            -ToPrevious -ReportPath $ReportPath -WhatIf:$WhatIfPreference
    }
}
$result | Format-List | Out-String | Write-Host
if ($result.RolledBack -and -not $result.Verified) { throw 'Rollback applied but not verified; investigate immediately.' }
