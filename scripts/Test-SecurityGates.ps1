<#
.SYNOPSIS
    Proves the infrastructure security gate rejects unsafe changes (a mutation test).
.DESCRIPTION
    A gate that has never been seen failing proves nothing. This script copies the real
    infrastructure code to a scratch directory, applies one unsafe change at a time (shared
    keys on, HTTP ingress, SAS auth, public prod endpoints, ...), runs the same PSRule gate
    the pipeline runs, and asserts that each change is rejected by the expected rule. The
    untouched baseline must pass. Any unsafe change that gets through fails this script.
.EXAMPLE
    ./scripts/Test-SecurityGates.ps1 -SummaryPath security-gates.md
#>
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
    [string] $SummaryPath,
    [string] $Only
)
$ErrorActionPreference = 'Stop'
Import-Module PSRule.Rules.Azure -ErrorAction Stop

$mutations = @(
    @{ Name = 'Storage: shared key access enabled'; File = 'infra/modules/storage.bicep'; Find = 'allowSharedKeyAccess: false'; Replace = 'allowSharedKeyAccess: true'; Input = 'infra/env/dev.bicepparam'; Expect = 'TradeOps.Storage.NoSharedKey' }
    @{ Name = 'Storage: anonymous blob access'; File = 'infra/modules/storage.bicep'; Find = 'allowBlobPublicAccess: false'; Replace = 'allowBlobPublicAccess: true'; Input = 'infra/env/dev.bicepparam'; Expect = 'Azure.Storage.BlobPublicAccess' }
    @{ Name = 'Storage: TLS 1.0 allowed'; File = 'infra/modules/storage.bicep'; Find = "minimumTlsVersion: 'TLS1_2'"; Replace = "minimumTlsVersion: 'TLS1_0'"; Input = 'infra/env/dev.bicepparam'; Expect = 'Azure.Storage.MinTLS' }
    @{ Name = 'Key Vault: access policies instead of RBAC'; File = 'infra/modules/keyvault.bicep'; Find = 'enableRbacAuthorization: true'; Replace = 'enableRbacAuthorization: false'; Input = 'infra/env/dev.bicepparam'; Expect = 'TradeOps.KeyVault.RbacOnly' }
    @{ Name = 'Key Vault: firewall open to all networks'; File = 'infra/modules/keyvault.bicep'; Find = "defaultAction: 'Deny'"; Replace = "defaultAction: 'Allow'"; Input = 'infra/env/staging.bicepparam'; Expect = 'Azure.KeyVault.Firewall' }
    @{ Name = 'Service Bus: SAS keys enabled'; File = 'infra/modules/servicebus.bicep'; Find = 'disableLocalAuth: true'; Replace = 'disableLocalAuth: false'; Input = 'infra/env/dev.bicepparam'; Expect = 'TradeOps.ServiceBus.NoLocalAuth' }
    @{ Name = 'Service Bus: duplicate detection off'; File = 'infra/modules/servicebus.bicep'; Find = 'requiresDuplicateDetection: true'; Replace = 'requiresDuplicateDetection: false'; Input = 'infra/env/dev.bicepparam'; Expect = 'TradeOps.ServiceBus.DuplicateDetection' }
    @{ Name = 'Container registry: admin user enabled'; File = 'infra/modules/registry.bicep'; Find = 'adminUserEnabled: false'; Replace = 'adminUserEnabled: true'; Input = 'infra/env/dev.bicepparam'; Expect = 'Azure.ACR.AdminUser' }
    @{ Name = 'App Insights: local auth (ingestion keys) on'; File = 'infra/modules/monitoring.bicep'; Find = 'DisableLocalAuth: true'; Replace = 'DisableLocalAuth: false'; Input = 'infra/env/dev.bicepparam'; Expect = 'Azure.AppInsights.LocalAuth' }
    @{ Name = 'Container App: plain HTTP ingress'; File = 'infra/apps/api.bicep'; Find = 'allowInsecure: false'; Replace = 'allowInsecure: true'; Input = 'infra/apps/api.ci.bicepparam'; Expect = 'Azure.ContainerApp.Insecure' }
    @{ Name = 'Prod: PaaS endpoints made public'; File = 'infra/env/prod.bicepparam'; Find = 'param enablePrivateNetworking = true'; Replace = 'param enablePrivateNetworking = false'; Input = 'infra/env/prod.bicepparam'; Expect = 'TradeOps.Prod.PrivateNetworking' }
    @{ Name = 'NSG: SSH open to the internet'; File = 'infra/modules/network.bicep'; Find = "destinationPortRanges: ['443', '31443']"; Replace = "destinationPortRanges: ['443', '31443', '22']"; Input = 'infra/env/dev.bicepparam'; Expect = 'TradeOps.NSG.NoInternetManagementPorts' }
    @{ Name = 'Tags: costCenter removed'; File = 'infra/env/dev.bicepparam'; Find = "  costCenter: 'CC-4410-PLATFORM'`n"; Replace = ''; Input = 'infra/env/dev.bicepparam'; Expect = 'TradeOps.Bicep.Compile' }
)
if ($Only) { $mutations = @($mutations | Where-Object Name -Like "*$Only*") }

function Copy-Workspace([string] $Root) {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) "tradeops-gates-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Path $scratch | Out-Null
    foreach ($item in 'infra', 'monitoring', '.ps-rule', 'ps-rule.yaml') {
        Copy-Item -Path (Join-Path $Root $item) -Destination $scratch -Recurse
    }
    return $scratch
}

function Invoke-Gate([string] $Workspace, [string] $InputPath) {
    Push-Location $Workspace
    try {
        $results = Invoke-PSRule -Format File -InputPath $InputPath -Module PSRule.Rules.Azure -Outcome Fail, Error -WarningAction SilentlyContinue -ErrorAction Stop
        return @($results | ForEach-Object RuleName | Sort-Object -Unique)
    }
    catch {
        # A template that no longer compiles (e.g. a required tag removed) is rejected too.
        if ($_.Exception.Message -match 'compilation|BCP\d+') { return @('TradeOps.Bicep.Compile') }
        throw
    }
    finally {
        Pop-Location
    }
}

$rows = [System.Collections.Generic.List[object]]::new()

Write-Host '== baseline (no mutation) must pass =='
$baseline = Copy-Workspace -Root $RepositoryRoot
try {
    $baselineFailures = Invoke-Gate -Workspace $baseline -InputPath 'infra/'
    $rows.Add([pscustomobject]@{ Change = 'Baseline (repository as committed)'; Expected = 'pass'; Result = ($baselineFailures.Count -eq 0 ? 'pass' : "FAIL: $($baselineFailures -join ', ')"); Caught = ($baselineFailures.Count -eq 0) })
}
finally { Remove-Item -Recurse -Force $baseline }

foreach ($mutation in $mutations) {
    Write-Host "== $($mutation.Name) =="
    $workspace = Copy-Workspace -Root $RepositoryRoot
    try {
        $path = Join-Path $workspace $mutation.File
        $content = Get-Content -Raw -Path $path
        if (-not $content.Contains($mutation.Find)) {
            throw "Mutation '$($mutation.Name)' did not apply: '$($mutation.Find)' not found in $($mutation.File). Update the test."
        }
        Set-Content -Path $path -Value $content.Replace($mutation.Find, $mutation.Replace) -NoNewline
        $failures = Invoke-Gate -Workspace $workspace -InputPath $mutation.Input
        $expected = $mutation.Expect -split '\|'
        $hit = @($failures | Where-Object { $_ -in $expected })
        $rows.Add([pscustomobject]@{
                Change   = $mutation.Name
                Expected = $expected -join ' or '
                Result   = $failures.Count ? ($failures -join ', ') : 'passed the gate'
                Caught   = $hit.Count -gt 0
            })
    }
    finally { Remove-Item -Recurse -Force $workspace }
}

$rows | Format-Table Caught, Change, Expected, Result -AutoSize -Wrap | Out-String -Width 220 | Write-Host

if ($SummaryPath) {
    $md = @('### Security gate self-test', '', '| Unsafe change | Rejected by | Caught |', '|---|---|:-:|')
    foreach ($row in $rows) { $md += "| $($row.Change) | $($row.Result) | $($row.Caught ? 'yes' : '**NO**') |" }
    Set-Content -Path $SummaryPath -Value ($md -join "`n") -Encoding utf8
    if ($env:TF_BUILD) { Write-Host "##vso[task.uploadsummary]$((Resolve-Path $SummaryPath).Path)" }
}

$escaped = @($rows | Where-Object { -not $_.Caught })
if ($escaped.Count -gt 0) {
    throw "Security gate self-test failed: $($escaped.Count) case(s) not handled as expected: $(($escaped | ForEach-Object Change) -join '; ')"
}
Write-Host "All $($mutations.Count) unsafe changes were rejected; baseline passes."
