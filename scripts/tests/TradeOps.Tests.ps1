#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Unit tests for the release tooling. Azure CLI and HTTP are mocked at the two private
# seams (Invoke-AzCli, Invoke-TradeOpsHttp), so these run anywhere in a few seconds.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../TradeOps/TradeOps.psd1') -Force

    function New-App {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test fixture builder.')]
        param([object[]] $Traffic, [string] $Latest = 'ca-api--r2')
        [pscustomobject]@{
            id         = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/containerApps/ca-api'
            name       = 'ca-api'
            properties = [pscustomobject]@{
                latestRevisionName = $Latest
                configuration      = [pscustomobject]@{
                    ingress = [pscustomobject]@{ fqdn = 'ca-api.example.io'; traffic = $Traffic }
                }
            }
        }
    }
    function New-Entry {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test fixture builder.')]
        param([string] $Revision, [int] $Weight, [string] $Label)
        $entry = [ordered]@{ revisionName = $Revision; weight = $Weight }
        if ($Label) { $entry.label = $Label }
        [pscustomobject]$entry
    }
    function New-Response {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test fixture builder.')]
        param([int] $Status, [object] $Body, [string] $Revision = 'ca-api--r2', [double] $Ms = 40)
        [pscustomobject]@{
            StatusCode = $Status; Body = $Body; ElapsedMs = $Ms; Error = $null
            Headers    = @{ 'X-TradeOps-Revision' = $Revision }
        }
    }
}

Describe 'Get-StableRevision' {
    It 'returns the revision labelled stable, not the heaviest one' {
        Mock -ModuleName TradeOps Invoke-AzCli {
            @(New-App -Traffic @((New-Entry 'ca-api--r1' 10 'stable'), (New-Entry 'ca-api--r2' 90 'canary')))
        }
        Get-StableRevision -ResourceGroup rg -AppName ca-api | Should -Be 'ca-api--r1'
    }

    It 'falls back to the heaviest revision when nothing is labelled' {
        Mock -ModuleName TradeOps Invoke-AzCli {
            @(New-App -Traffic @((New-Entry 'ca-api--r1' 30 $null), (New-Entry 'ca-api--r2' 70 $null)))
        }
        Get-StableRevision -ResourceGroup rg -AppName ca-api | Should -Be 'ca-api--r2'
    }

    It 'resolves a latestRevision entry to the latest revision name' {
        Mock -ModuleName TradeOps Invoke-AzCli {
            @(New-App -Latest 'ca-api--r7' -Traffic @([pscustomobject]@{ latestRevision = $true; weight = 100 }))
        }
        Get-StableRevision -ResourceGroup rg -AppName ca-api | Should -Be 'ca-api--r7'
    }

    It 'returns null on the first release (app does not exist)' {
        Mock -ModuleName TradeOps Invoke-AzCli { @() }
        Get-StableRevision -ResourceGroup rg -AppName ca-api | Should -BeNullOrEmpty
    }
}

Describe 'Set-TrafficConfiguration' {
    BeforeEach {
        $script:patchBody = $null
        $script:traffic = @((New-Entry 'ca-api--r1' 100 'stable'))
        Mock -ModuleName TradeOps Start-Sleep {}
        Mock -ModuleName TradeOps Invoke-AzCli {
            switch ($Arguments[0]) {
                'containerapp' {
                    if ($Arguments[1] -eq 'list') { return @(New-App -Traffic $script:traffic) }
                    return 'Succeeded'
                }
                'rest' {
                    $file = ($Arguments | Where-Object { $_ -like '@*' }).TrimStart('@')
                    $script:patchBody = Get-Content -Raw $file | ConvertFrom-Json
                    $script:traffic = @($script:patchBody.properties.configuration.ingress.traffic | ForEach-Object {
                            New-Entry $_.revisionName $_.weight $_.label
                        })
                    return $null
                }
            }
        }
    }

    It 'sends one merge-patch containing the whole traffic table' {
        Set-TrafficConfiguration -ResourceGroup rg -AppName ca-api -Entries @(
            @{ RevisionName = 'ca-api--r1'; Weight = 90; Label = 'stable' }
            @{ RevisionName = 'ca-api--r2'; Weight = 10; Label = 'canary' }
        ) | Out-Null
        $sent = $script:patchBody.properties.configuration.ingress.traffic
        $sent.Count | Should -Be 2
        ($sent | Where-Object label -EQ 'canary').weight | Should -Be 10
        Should -Invoke -ModuleName TradeOps Invoke-AzCli -ParameterFilter {
            $Arguments[0] -eq 'rest' -and ($Arguments -join ' ') -match 'api-version=2025-07-01' -and $Arguments -contains 'patch'
        } -Times 1 -Exactly
    }

    It 'rejects weights that do not sum to 100' {
        { Set-TrafficConfiguration -ResourceGroup rg -AppName ca-api -Entries @(
                @{ RevisionName = 'a'; Weight = 90 }, @{ RevisionName = 'b'; Weight = 20 }
            ) } | Should -Throw '*sum to 100*'
    }

    It 'fails verification when the platform did not apply the weights' {
        Mock -ModuleName TradeOps Invoke-AzCli {
            if ($Arguments[0] -eq 'containerapp' -and $Arguments[1] -eq 'list') {
                return @(New-App -Traffic @((New-Entry 'ca-api--r1' 100 'stable')))
            }
            if ($Arguments[0] -eq 'containerapp') { return 'Succeeded' }
            return $null
        }
        { Set-TrafficConfiguration -ResourceGroup rg -AppName ca-api -Entries @(
                @{ RevisionName = 'ca-api--r1'; Weight = 50; Label = 'stable' }
                @{ RevisionName = 'ca-api--r2'; Weight = 50; Label = 'canary' }
            ) } | Should -Throw '*verification failed*'
    }
}

Describe 'Wait-RevisionReady' {
    BeforeEach { Mock -ModuleName TradeOps Start-Sleep {} }

    It 'returns once the revision is provisioned, running and healthy' {
        $script:calls = 0
        Mock -ModuleName TradeOps Invoke-AzCli {
            $script:calls++
            $state = if ($script:calls -lt 3) { 'Provisioning' } else { 'Provisioned' }
            [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = $state; runningState = 'Running'; healthState = 'Healthy' } }
        }
        Wait-RevisionReady -ResourceGroup rg -AppName ca-api -RevisionName ca-api--r2 -RequireHealthy | Out-Null
        $script:calls | Should -Be 3
    }

    It 'fails fast when the revision fails to start' {
        Mock -ModuleName TradeOps Invoke-AzCli {
            [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Failed'; runningState = 'Failed'; healthState = 'Unhealthy' } }
        }
        { Wait-RevisionReady -ResourceGroup rg -AppName ca-api -RevisionName ca-api--r2 } | Should -Throw '*failed to start*'
    }

    It 'requires Healthy only when asked (the worker has no probes)' {
        Mock -ModuleName TradeOps Invoke-AzCli {
            [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Provisioned'; runningState = 'Running'; healthState = 'None' } }
        }
        { Wait-RevisionReady -ResourceGroup rg -AppName w -RevisionName w--r2 } | Should -Not -Throw
        { Wait-RevisionReady -ResourceGroup rg -AppName w -RevisionName w--r2 -RequireHealthy -TimeoutSec 0 } | Should -Throw '*Timed out*'
    }
}

Describe 'Invoke-PlatformDeployment' {
    BeforeEach {
        $script:deployed = $false
        $script:whatIf = [pscustomobject]@{ changes = @(
                [pscustomobject]@{ changeType = 'Create'; resourceId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/st1'; delta = $null }
                [pscustomobject]@{ changeType = 'NoChange'; resourceId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv1'; delta = $null }
            )
        }
        Mock -ModuleName TradeOps Invoke-AzCli {
            if ($Arguments -contains 'what-if') { return $script:whatIf }
            if ($Arguments -contains 'create') {
                $script:deployed = $true
                return [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded'; outputs = @{} } }
            }
        }
    }

    It 'summarises the change set and deploys' {
        $result = Invoke-PlatformDeployment -ResourceGroup rg -TemplateFile t -ParameterFile p
        $result.Counts.Create | Should -Be 1
        $result.Counts.NoChange | Should -Be 1
        $script:deployed | Should -BeTrue
    }

    It 'stops after review with -WhatIfOnly' {
        Invoke-PlatformDeployment -ResourceGroup rg -TemplateFile t -ParameterFile p -WhatIfOnly | Out-Null
        $script:deployed | Should -BeFalse
    }

    It 'blocks deletions unless -AllowDelete' {
        $script:whatIf.changes += [pscustomobject]@{ changeType = 'Delete'; resourceId = '/x/providers/Microsoft.Network/virtualNetworks/vnet'; delta = $null }
        { Invoke-PlatformDeployment -ResourceGroup rg -TemplateFile t -ParameterFile p } | Should -Throw '*would delete*'
        $script:deployed | Should -BeFalse
        Invoke-PlatformDeployment -ResourceGroup rg -TemplateFile t -ParameterFile p -AllowDelete | Out-Null
        $script:deployed | Should -BeTrue
    }

    It 'blocks changes to protected security properties unless explicitly allowed' {
        $script:whatIf.changes += [pscustomobject]@{
            changeType = 'Modify'; resourceId = '/x/providers/Microsoft.Storage/storageAccounts/st1'
            delta      = @([pscustomobject]@{ path = 'properties.allowSharedKeyAccess'; propertyChangeType = 'Modify' })
        }
        { Invoke-PlatformDeployment -ResourceGroup rg -TemplateFile t -ParameterFile p } | Should -Throw '*protected properties*allowSharedKeyAccess*'
        $script:deployed | Should -BeFalse
    }

    It 'ignores what-if noise (NoEffect deltas) on protected properties' {
        $script:whatIf.changes += [pscustomobject]@{
            changeType = 'Modify'; resourceId = '/x/providers/Microsoft.Network/networkSecurityGroups/nsg'
            delta      = @([pscustomobject]@{ path = 'properties.securityRules'; propertyChangeType = 'NoEffect' })
        }
        (Invoke-PlatformDeployment -ResourceGroup rg -TemplateFile t -ParameterFile p).Deployed | Should -BeTrue
    }

    It 'lets ordinary modifications through' {
        $script:whatIf.changes += [pscustomobject]@{
            changeType = 'Modify'; resourceId = '/x/providers/Microsoft.Insights/components/appi'
            delta      = @([pscustomobject]@{ path = 'properties.RetentionInDays'; propertyChangeType = 'Modify' })
        }
        (Invoke-PlatformDeployment -ResourceGroup rg -TemplateFile t -ParameterFile p).Deployed | Should -BeTrue
    }
}

Describe 'Test-TradeOpsEnvironment' {
    It 'reports every failed check at once' {
        Mock -ModuleName TradeOps Invoke-AzCli {
            switch ($Arguments[0]) {
                'account' { [pscustomobject]@{ id = 'sub-actual'; name = 'n'; tenantId = 't'; user = @{ type = 'servicePrincipal' } } }
                'group' { throw 'ResourceGroupNotFound' }
                'provider' { @('Microsoft.App', 'Microsoft.Storage') }
                'bicep' { 'Bicep CLI version 0.49.2' }
                'policy' { @() }
            }
        }
        { Test-TradeOpsEnvironment -ResourceGroup rg -ExpectedSubscriptionId 'sub-expected' } |
            Should -Throw -ExpectedMessage '*Subscription*Resource group*Resource providers*'
    }

    It 'passes a healthy environment and only warns about missing guardrails' {
        Mock -ModuleName TradeOps Invoke-AzCli {
            switch ($Arguments[0]) {
                'account' { [pscustomobject]@{ id = 'sub'; name = 'n'; tenantId = 't'; user = @{ type = 'servicePrincipal' } } }
                'group' { [pscustomobject]@{ name = 'rg'; location = 'eastus2' } }
                'provider' { @('Microsoft.App', 'Microsoft.ContainerRegistry', 'Microsoft.KeyVault', 'Microsoft.ServiceBus', 'Microsoft.Storage', 'Microsoft.OperationalInsights', 'Microsoft.Insights', 'Microsoft.Network', 'Microsoft.ManagedIdentity') }
                'bicep' { 'Bicep CLI version 0.49.2' }
                'policy' { @() }
            }
        }
        $results = Test-TradeOpsEnvironment -ResourceGroup rg -ExpectedSubscriptionId 'sub'
        ($results | Where-Object Status -EQ 'Fail') | Should -BeNullOrEmpty
        ($results | Where-Object Check -EQ 'Policy guardrails').Status | Should -Be 'Warn'
    }
}

Describe 'Measure-CanaryHealth' {
    It 'passes a healthy canary' {
        Mock -ModuleName TradeOps Invoke-TradeOpsHttp { New-Response 201 ([pscustomobject]@{ status = 'ACCEPTED' }) }
        $result = Measure-CanaryHealth -CanaryUrl https://canary -ExpectedRevision ca-api--r2 -Requests 20
        $result.Verdict | Should -Be 'Pass'
        $result.Canary.ErrorRatePct | Should -Be 0
    }

    It 'fails a canary whose error rate breaches the SLO' {
        $script:n = 0
        Mock -ModuleName TradeOps Invoke-TradeOpsHttp {
            $script:n++
            if ($script:n % 3 -eq 0) { New-Response 500 ([pscustomobject]@{ error = 'internal_error' }) }
            else { New-Response 201 ([pscustomobject]@{ status = 'ACCEPTED' }) }
        }
        $result = Measure-CanaryHealth -CanaryUrl https://canary -Requests 30 -MaxErrorRatePct 1
        $result.Verdict | Should -Be 'Fail'
        $result.Canary.ErrorRatePct | Should -Be 33.33
        $result.Reasons[0] | Should -BeLike 'error rate 33.33%*'
    }

    It 'counts transport failures (status 0) as errors' {
        Mock -ModuleName TradeOps Invoke-TradeOpsHttp { New-Response 0 $null $null }
        (Measure-CanaryHealth -CanaryUrl https://canary -Requests 10).Verdict | Should -Be 'Fail'
    }

    It 'fails on a latency regression against the stable baseline' {
        Mock -ModuleName TradeOps Invoke-TradeOpsHttp {
            $ms = if ($Uri -like 'https://canary*') { 600 } else { 100 }
            New-Response 201 ([pscustomobject]@{ status = 'ACCEPTED' }) 'r' $ms
        }
        $result = Measure-CanaryHealth -CanaryUrl https://canary -BaselineUrl https://stable -Requests 20 -MaxP95Ms 1000
        $result.Verdict | Should -Be 'Fail'
        $result.Reasons -join ' ' | Should -BeLike '*baseline*'
    }

    It 'fails when responses come from the wrong revision' {
        Mock -ModuleName TradeOps Invoke-TradeOpsHttp { New-Response 201 ([pscustomobject]@{ status = 'ACCEPTED' }) 'ca-api--r1' }
        (Measure-CanaryHealth -CanaryUrl https://canary -ExpectedRevision ca-api--r2 -Requests 10).Verdict | Should -Be 'Fail'
    }
}

Describe 'Invoke-SmokeTest' {
    BeforeEach {
        Mock -ModuleName TradeOps Start-Sleep {}
        $script:orderStatus = 'SETTLED'
        Mock -ModuleName TradeOps Invoke-TradeOpsHttp {
            $path = ([uri]$Uri).AbsolutePath
            switch -Wildcard ($path) {
                '/healthz' { New-Response 200 ([pscustomobject]@{ status = 'ok' }) }
                '/readyz' { New-Response 200 ([pscustomobject]@{ status = 'ready'; checks = [pscustomobject]@{ ledger = 'ok'; queue = 'ok' } }) }
                '/version' { New-Response 200 ([pscustomobject]@{ version = '1.4.0'; revision = 'ca-api--r2' }) }
                '/v1/orders' {
                    if ($Body.quantity -eq 0) { return New-Response 422 $null }
                    if ($Body.symbol -eq 'ACME') { return New-Response 201 ([pscustomobject]@{ status = 'REJECTED'; reject_reasons = @('RESTRICTED_INSTRUMENT') }) }
                    $code = if ($Body.client_order_id -eq $script:lastId) { 200 } else { 201 }
                    $script:lastId = $Body.client_order_id
                    New-Response $code ([pscustomobject]@{ status = 'ACCEPTED'; order_id = 'o-1' })
                }
                '/v1/accounts/*' { New-Response 200 ([pscustomobject]@{ status = $script:orderStatus }) }
            }
        }
    }

    It 'passes every check against a healthy release' {
        $result = Invoke-SmokeTest -BaseUrl ca-api--r2.example.io -ExpectedVersion 1.4.0 -ExpectedRevision ca-api--r2
        $result.Passed | Should -BeTrue
        $result.Checks.Count | Should -Be 8
        $result.BaseUrl | Should -Be 'https://ca-api--r2.example.io'
    }

    It 'fails when the wrong version answers' {
        { Invoke-SmokeTest -BaseUrl https://x -ExpectedVersion 9.9.9 } | Should -Throw '*release identity*'
    }

    It 'reports (not crashes on) error bodies that lack the success schema' {
        # Regression: found by running the smoke test against a fault-injected local app.
        Mock -ModuleName TradeOps Invoke-TradeOpsHttp {
            if (([uri]$Uri).AbsolutePath -like '/v1/*') { return New-Response 500 ([pscustomobject]@{ error = 'internal_error' }) }
            New-Response 200 ([pscustomobject]@{ status = 'ok'; checks = [pscustomobject]@{ ledger = 'ok' }; version = '1'; revision = 'r' })
        }
        $result = Invoke-SmokeTest -BaseUrl https://x -NoThrow
        $result.Passed | Should -BeFalse
        ($result.Checks | Where-Object Check -EQ 'order accepted').Detail | Should -Be 'HTTP 500 status='
    }

    It 'fails when settlement never completes' {
        $script:orderStatus = 'ACCEPTED'
        $result = Invoke-SmokeTest -BaseUrl https://x -SettlementTimeoutSec 0 -NoThrow
        $result.Passed | Should -BeFalse
        ($result.Checks | Where-Object { -not $_.Passed }).Check | Should -BeLike 'settled end to end*'
    }
}

Describe 'Invoke-Rollback' {
    BeforeEach {
        Mock -ModuleName TradeOps Start-Sleep {}
        Mock -ModuleName TradeOps Set-TrafficConfiguration {}
        Mock -ModuleName TradeOps Invoke-AzCli {}
        Mock -ModuleName TradeOps Invoke-TradeOpsHttp { New-Response 200 $null 'ca-api--r1' }
    }

    It 'returns all traffic to stable, deactivates the canary and verifies from outside' {
        Mock -ModuleName TradeOps Get-ContainerAppTraffic {
            [pscustomobject]@{ Id = 'id'; Fqdn = 'ca-api.example.io'; Traffic = @(
                    [pscustomobject]@{ RevisionName = 'ca-api--r1'; Weight = 90; Label = 'stable' }
                    [pscustomobject]@{ RevisionName = 'ca-api--r2'; Weight = 10; Label = 'canary' }
                )
            }
        }
        $result = Invoke-Rollback -ResourceGroup rg -AppName ca-api -Reason 'canary failed'
        $result.RolledBack | Should -BeTrue
        $result.Verified | Should -BeTrue
        $result.Target | Should -Be 'ca-api--r1'
        Should -Invoke -ModuleName TradeOps Set-TrafficConfiguration -Times 1 -Exactly -ParameterFilter {
            $Entries.Count -eq 1 -and $Entries[0].RevisionName -eq 'ca-api--r1' -and $Entries[0].Weight -eq 100
        }
        Should -Invoke -ModuleName TradeOps Invoke-AzCli -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join ' ') -like '*revision deactivate*ca-api--r2*'
        }
    }

    It 'is a no-op when there is no canary' {
        Mock -ModuleName TradeOps Get-ContainerAppTraffic {
            [pscustomobject]@{ Id = 'id'; Fqdn = 'f'; Traffic = @([pscustomobject]@{ RevisionName = 'ca-api--r1'; Weight = 100; Label = 'stable' }) }
        }
        $result = Invoke-Rollback -ResourceGroup rg -AppName ca-api
        $result.RolledBack | Should -BeFalse
        Should -Invoke -ModuleName TradeOps Set-TrafficConfiguration -Times 0
    }

    It 'reverts a promoted release to the warm previous revision' {
        Mock -ModuleName TradeOps Get-ContainerAppTraffic {
            [pscustomobject]@{ Id = 'id'; Fqdn = 'f'; Traffic = @(
                    [pscustomobject]@{ RevisionName = 'ca-api--r2'; Weight = 100; Label = 'stable' }
                    [pscustomobject]@{ RevisionName = 'ca-api--r1'; Weight = 0; Label = 'previous' }
                )
            }
        }
        $result = Invoke-Rollback -ResourceGroup rg -AppName ca-api -ToPrevious
        $result.Target | Should -Be 'ca-api--r1'
        $result.Removed | Should -Be 'ca-api--r2'
    }

    It 'reports an unverified rollback when traffic keeps hitting the bad revision' {
        Mock -ModuleName TradeOps Get-ContainerAppTraffic {
            [pscustomobject]@{ Id = 'id'; Fqdn = 'f'; Traffic = @(
                    [pscustomobject]@{ RevisionName = 'ca-api--r1'; Weight = 90; Label = 'stable' }
                    [pscustomobject]@{ RevisionName = 'ca-api--r2'; Weight = 10; Label = 'canary' }
                )
            }
        }
        Mock -ModuleName TradeOps Invoke-TradeOpsHttp { New-Response 200 $null 'ca-api--r2' }
        (Invoke-Rollback -ResourceGroup rg -AppName ca-api -VerifyTimeoutSec 0).Verified | Should -BeFalse
    }
}

Describe 'Invoke-CanaryRelease' {
    BeforeEach {
        $script:report = Join-Path $TestDrive 'release.json'
        Mock -ModuleName TradeOps Get-PlatformOutput { @{ apiAppName = 'ca-api'; environmentName = 'staging' } }
        Mock -ModuleName TradeOps Get-StableRevision { 'ca-api--r1' }
        Mock -ModuleName TradeOps Publish-ApiRevision { 'ca-api--r2' }
        Mock -ModuleName TradeOps Wait-RevisionReady {}
        Mock -ModuleName TradeOps Get-RevisionFqdn { "$RevisionName.example.io" }
        Mock -ModuleName TradeOps Invoke-SmokeTest { [pscustomobject]@{ Passed = $true; Checks = @() } }
        Mock -ModuleName TradeOps Set-TrafficConfiguration {}
        Mock -ModuleName TradeOps Invoke-Promotion {}
        Mock -ModuleName TradeOps Invoke-Rollback { [pscustomobject]@{ RolledBack = $true; Verified = $true; VerifiedSec = 12.5 } }
        $script:releaseArgs = @{
            ResourceGroup = 'rg'; TemplateFile = 'api.json'; Image = 'cr.io/tradeops@sha256:abc'
            Version = '1.4.0'; RevisionSuffix = 'r2'; ReportPath = $script:report
        }
    }

    It 'walks the canary steps and promotes a healthy release' {
        Mock -ModuleName TradeOps Measure-CanaryHealth { [pscustomobject]@{ Verdict = 'Pass'; Reasons = @(); Canary = @{}; Baseline = @{} } }
        $result = Invoke-CanaryRelease @script:releaseArgs
        $result.Outcome | Should -Be 'Promoted'
        Should -Invoke -ModuleName TradeOps Set-TrafficConfiguration -Times 2 -Exactly
        Should -Invoke -ModuleName TradeOps Invoke-Promotion -Times 1 -Exactly
        Should -Invoke -ModuleName TradeOps Invoke-Rollback -Times 0
        (Get-Content $script:report | ConvertFrom-Json).Outcome | Should -Be 'Promoted'
    }

    It 'rolls back automatically when canary analysis fails, and records the timings' {
        Mock -ModuleName TradeOps Measure-CanaryHealth { [pscustomobject]@{ Verdict = 'Fail'; Reasons = @('error rate 30% > 1%'); Canary = @{}; Baseline = @{} } }
        { Invoke-CanaryRelease @script:releaseArgs -FaultRate 0.3 } | Should -Throw '*RolledBack*error rate 30%*'
        Should -Invoke -ModuleName TradeOps Set-TrafficConfiguration -Times 1 -Exactly  # stopped at 10%
        Should -Invoke -ModuleName TradeOps Invoke-Promotion -Times 0
        Should -Invoke -ModuleName TradeOps Invoke-Rollback -Times 1 -Exactly
        $report = Get-Content $script:report | ConvertFrom-Json
        $report.Outcome | Should -Be 'RolledBack'
        $report.MaxTrafficExposed | Should -Be 10
        $report.RecoverySec | Should -Be 12.5
        $report.DetectionSec | Should -Not -BeNullOrEmpty
    }

    It 'rolls back before any customer traffic when the smoke test fails' {
        Mock -ModuleName TradeOps Invoke-SmokeTest { [pscustomobject]@{ Passed = $false; Checks = @([pscustomobject]@{ Check = 'order accepted'; Passed = $false }) } }
        { Invoke-CanaryRelease @script:releaseArgs } | Should -Throw '*smoke test failed*'
        Should -Invoke -ModuleName TradeOps Set-TrafficConfiguration -Times 0
        (Get-Content $script:report | ConvertFrom-Json).MaxTrafficExposed | Should -Be 0
    }

    It 'promotes the first release directly after its smoke test' {
        Mock -ModuleName TradeOps Get-StableRevision { $null }
        (Invoke-CanaryRelease @script:releaseArgs).Outcome | Should -Be 'Promoted'
        Should -Invoke -ModuleName TradeOps Set-TrafficConfiguration -Times 0
        Should -Invoke -ModuleName TradeOps Publish-ApiRevision -ParameterFilter { $StableRevisionName -eq '' } -Times 1
    }

    It 'refuses to redeploy the revision that is already stable' {
        Mock -ModuleName TradeOps Get-StableRevision { 'ca-api--r2' }
        { Invoke-CanaryRelease @script:releaseArgs } | Should -Throw '*already the stable revision*'
    }
}

Describe 'Import-ReleaseImage' {
    It 'imports by digest and verifies the digest in the target registry' {
        $digest = 'sha256:' + ('a' * 64)
        Mock -ModuleName TradeOps Invoke-AzCli {
            if ($Arguments[1] -eq 'repository') { return [pscustomobject]@{ digest = $digest } }
        }
        $image = Import-ReleaseImage -SourceLoginServer dev.azurecr.io -TargetRegistryName stg -TargetLoginServer stg.azurecr.io -Digest $digest -Tag 1.4.0
        $image | Should -Be "stg.azurecr.io/tradeops@$digest"
        Should -Invoke -ModuleName TradeOps Invoke-AzCli -ParameterFilter { ($Arguments -join ' ') -like "acr import*--source dev.azurecr.io/tradeops@$digest*" } -Times 1
    }

    It 'skips the import within one registry' {
        Mock -ModuleName TradeOps Invoke-AzCli {}
        Import-ReleaseImage -SourceLoginServer dev.azurecr.io -TargetRegistryName dev -TargetLoginServer dev.azurecr.io -Digest ('sha256:' + 'b' * 64) -Tag t |
            Should -BeLike 'dev.azurecr.io/tradeops@sha256:*'
        Should -Invoke -ModuleName TradeOps Invoke-AzCli -Times 0
    }

    It 'rejects anything that is not a sha256 digest' {
        { Import-ReleaseImage -SourceLoginServer a -TargetRegistryName b -TargetLoginServer c -Digest 'latest' -Tag t } | Should -Throw
    }
}
