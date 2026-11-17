function Import-ReleaseImage {
    <#
    .SYNOPSIS
        Promotes an image between environments' registries by digest with `az acr import`.
        The digest is immutable, so the target runs exactly the bytes that passed upstream.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $SourceLoginServer,
        [Parameter(Mandatory)] [string] $TargetRegistryName,
        [Parameter(Mandatory)] [string] $TargetLoginServer,
        [Parameter(Mandatory)] [ValidatePattern('^sha256:[a-f0-9]{64}$')] [string] $Digest,
        [Parameter(Mandatory)] [string] $Tag,
        [string] $Repository = 'tradeops'
    )
    $target = "$TargetLoginServer/$Repository@$Digest"
    if ($SourceLoginServer -eq $TargetLoginServer) { return $target }

    Write-TradeOpsLog "promoting $Repository@$Digest from $SourceLoginServer to $TargetLoginServer" -Level Section
    Invoke-AzCli -Arguments @(
        'acr', 'import', '--name', $TargetRegistryName,
        '--source', "$SourceLoginServer/$Repository@$Digest",
        '--image', "${Repository}:$Tag", '--force'
    ) | Out-Null
    $manifest = Invoke-AzCli -Arguments @(
        'acr', 'repository', 'show', '--name', $TargetRegistryName, '--image', "$Repository@$Digest"
    )
    if ($manifest.digest -ne $Digest) {
        throw "Imported digest mismatch: expected $Digest, registry reports $($manifest.digest)."
    }
    return $target
}

function ConvertTo-ArmParameterFile {
    param([Parameter(Mandatory)] [hashtable] $Values)
    $parameters = [ordered]@{}
    foreach ($key in ($Values.Keys | Sort-Object)) { $parameters[$key] = @{ value = $Values[$key] } }
    $file = New-TemporaryFile
    [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = $parameters
    } | ConvertTo-Json -Depth 20 | Set-Content -Path $file.FullName -Encoding utf8
    return $file
}

function Publish-ApiRevision {
    <#
    .SYNOPSIS
        Deploys infra/apps/api.bicep: a new revision at canaryWeight (0 by default), labelled
        'canary', while the stable revision keeps its traffic. Returns the new revision name.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [hashtable] $Platform,
        [Parameter(Mandatory)] [string] $TemplateFile,
        [Parameter(Mandatory)] [string] $Image,
        [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9][a-z0-9-]{0,28}[a-z0-9]$')] [string] $RevisionSuffix,
        [Parameter(Mandatory)] [string] $Version,
        [string] $GitSha = 'unknown',
        [string] $StableRevisionName = '',
        [ValidateRange(0, 100)] [int] $CanaryWeight = 0,
        [ValidatePattern('^(0(\.\d+)?|1(\.0+)?)$')] [string] $FaultRate = '0'
    )
    $values = @{
        name                       = $Platform.apiAppName
        tags                       = $Platform.tags
        environmentName            = $Platform.environmentName
        containerAppsEnvironmentId = $Platform.containerAppsEnvironmentId
        image                      = $Image
        registryLoginServer        = $Platform.registryLoginServer
        revisionSuffix             = $RevisionSuffix
        stableRevisionName         = $StableRevisionName
        canaryWeight               = $CanaryWeight
        identityId                 = $Platform.apiIdentityId
        identityClientId           = $Platform.apiIdentityClientId
        appInsightsSecretUri       = $Platform.appInsightsSecretUri
        storageTableEndpoint       = $Platform.storageTableEndpoint
        ordersTable                = $Platform.ordersTable
        serviceBusFqdn             = $Platform.serviceBusFqdn
        settlementQueue            = $Platform.settlementQueue
        maxDeliveryCount           = $Platform.maxDeliveryCount
        scale                      = $Platform.apiScale
        version                    = $Version
        gitSha                     = $GitSha
        faultRate                  = $FaultRate
    }
    $newRevision = "$($Platform.apiAppName)--$RevisionSuffix"
    if ($FaultRate -ne '0') {
        Write-TradeOpsLog "FAULT INJECTION: $newRevision will fail $FaultRate of order requests" -Level Warning
    }
    if (-not $PSCmdlet.ShouldProcess($newRevision, 'deploy API revision')) { return $newRevision }

    $parameterFile = ConvertTo-ArmParameterFile -Values $values
    try {
        Write-TradeOpsLog "deploying $newRevision ($Image)" -Level Section
        Invoke-AzCli -Arguments @(
            'deployment', 'group', 'create', '--resource-group', $ResourceGroup, '--name', "api-$RevisionSuffix",
            '--template-file', $TemplateFile, '--parameters', "@$($parameterFile.FullName)"
        ) | Out-Null
    }
    finally {
        Remove-Item -Path $parameterFile.FullName -ErrorAction SilentlyContinue
    }
    return $newRevision
}

function Invoke-Promotion {
    <#
    .SYNOPSIS
        Makes the canary the stable revision (100%), keeps the old stable revision warm at 0%
        under the 'previous' label for instant manual rollback, and deactivates anything older.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AppName,
        [Parameter(Mandatory)] [string] $NewRevision,
        [Parameter(Mandatory)] [string] $PreviousRevision
    )
    if (-not $PSCmdlet.ShouldProcess($AppName, "promote $NewRevision")) { return }
    Set-TrafficConfiguration -ResourceGroup $ResourceGroup -AppName $AppName -Entries @(
        @{ RevisionName = $NewRevision; Weight = 100; Label = 'stable' }
        @{ RevisionName = $PreviousRevision; Weight = 0; Label = 'previous' }
    ) | Out-Null

    $active = @(Invoke-AzCli -Arguments @(
            'containerapp', 'revision', 'list', '--resource-group', $ResourceGroup, '--name', $AppName,
            '--query', '[?properties.active].name'
        ))
    foreach ($revision in $active | Where-Object { $_ -and $_ -notin $NewRevision, $PreviousRevision }) {
        Write-TradeOpsLog "deactivating superseded revision $revision"
        Invoke-AzCli -Arguments @(
            'containerapp', 'revision', 'deactivate', '--resource-group', $ResourceGroup,
            '--name', $AppName, '--revision', $revision
        ) | Out-Null
    }
    Write-TradeOpsLog "promoted $NewRevision to stable; $PreviousRevision kept warm as 'previous'"
}

function Invoke-Rollback {
    <#
    .SYNOPSIS
        Returns all traffic to the stable revision and deactivates the canary. With
        -ToPrevious, reverts an already-promoted release to the 'previous' revision.
    .DESCRIPTION
        Idempotent: with no canary (or no previous) revision it reports that and does
        nothing, so the pipeline's on-failure hook can always call it. After the traffic
        change it probes the app URL until every response comes from the target revision,
        and reports the measured time to recovery.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AppName,
        [string] $Reason = 'unspecified',
        [switch] $ToPrevious,
        [int] $VerifyRequests = 20,
        [int] $VerifyTimeoutSec = 120,
        [string] $ReportPath
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $startedAt = [DateTime]::UtcNow
    $state = Get-ContainerAppTraffic -ResourceGroup $ResourceGroup -AppName $AppName
    $result = [ordered]@{
        App            = $AppName
        Reason         = $Reason
        Mode           = if ($ToPrevious) { 'to-previous' } else { 'abort-canary' }
        RolledBack     = $false
        Target         = $null
        Removed        = $null
        StartedAt      = $startedAt.ToString('o')
        TrafficRestoredSec = $null
        VerifiedSec    = $null
        Verified       = $false
        Detail         = $null
    }

    $stable = $state ? @($state.Traffic | Where-Object Label -EQ 'stable') : @()
    $canary = $state ? @($state.Traffic | Where-Object Label -EQ 'canary') : @()
    $previous = $state ? @($state.Traffic | Where-Object Label -EQ 'previous') : @()

    if ($ToPrevious) {
        if ($previous.Count -eq 0 -or $stable.Count -eq 0) {
            $result.Detail = 'no previous revision to roll back to'
        }
        else {
            $result.Target = $previous[0].RevisionName
            $result.Removed = $stable[0].RevisionName
        }
    }
    elseif ($canary.Count -eq 0) {
        $result.Detail = 'no canary revision in the traffic table; nothing to roll back'
    }
    elseif ($stable.Count -eq 0) {
        throw "Cannot roll back ${AppName}: no revision is labelled 'stable'."
    }
    else {
        $result.Target = $stable[0].RevisionName
        $result.Removed = $canary[0].RevisionName
    }

    if (-not $result.Target) {
        Write-TradeOpsLog "rollback: $($result.Detail)"
        return [pscustomobject]$result
    }
    if (-not $PSCmdlet.ShouldProcess($AppName, "roll back to $($result.Target)")) { return [pscustomobject]$result }

    Write-TradeOpsLog "ROLLBACK $AppName -> $($result.Target) (removing $($result.Removed)): $Reason" -Level Warning
    $entries = @(@{ RevisionName = $result.Target; Weight = 100; Label = 'stable' })
    if (-not $ToPrevious -and $previous.Count -gt 0 -and $previous[0].RevisionName -ne $result.Target) {
        $entries += @{ RevisionName = $previous[0].RevisionName; Weight = 0; Label = 'previous' }
    }
    Set-TrafficConfiguration -ResourceGroup $ResourceGroup -AppName $AppName -Entries $entries | Out-Null
    $result.TrafficRestoredSec = [Math]::Round($watch.Elapsed.TotalSeconds, 1)

    Invoke-AzCli -Arguments @(
        'containerapp', 'revision', 'deactivate', '--resource-group', $ResourceGroup,
        '--name', $AppName, '--revision', $result.Removed
    ) | Out-Null
    $result.RolledBack = $true

    # Verify from the outside: every response through the public URL must come from the target.
    $deadline = [DateTime]::UtcNow.AddSeconds($VerifyTimeoutSec)
    $url = "https://$($state.Fqdn)/version"
    do {
        $served = @(1..$VerifyRequests | ForEach-Object {
                (Invoke-TradeOpsHttp -Method GET -Uri $url -Headers @{ 'X-Request-ID' = "rollback-verify-$_-$([guid]::NewGuid().ToString('N').Substring(0, 8))" }).Headers['X-TradeOps-Revision']
            })
        $result.Verified = ($served.Count -eq $VerifyRequests) -and -not ($served | Where-Object { $_ -ne $result.Target })
        if (-not $result.Verified) { Start-Sleep -Seconds 3 }
    } while (-not $result.Verified -and [DateTime]::UtcNow -lt $deadline)
    $result.VerifiedSec = [Math]::Round($watch.Elapsed.TotalSeconds, 1)

    if ($result.Verified) {
        Write-TradeOpsLog "rollback verified: $VerifyRequests/$VerifyRequests responses from $($result.Target) after $($result.VerifiedSec)s"
    }
    else {
        Write-TradeOpsLog "rollback traffic set, but verification did not converge within ${VerifyTimeoutSec}s" -Level Error
    }
    $report = [pscustomobject]$result
    if ($ReportPath) { $report | ConvertTo-Json -Depth 10 | Set-Content -Path $ReportPath -Encoding utf8 }
    return $report
}

function Invoke-CanaryRelease {
    <#
    .SYNOPSIS
        End-to-end progressive release of the API with automatic rollback.
    .DESCRIPTION
        1. deploy the new revision at 0% (label 'canary')
        2. wait for it to be provisioned, running and healthy
        3. smoke-test it through its own URL, before any customer traffic
        4. for each step (default 10%, 50%): shift traffic, then run canary analysis
        5. promote to 100%, keeping the old stable revision warm as 'previous'
        On any failure after step 1 the release is rolled back automatically, the detection
        and recovery times are recorded, and the function throws so the pipeline fails.
        A release report (JSON) is written either way.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $TemplateFile,
        [Parameter(Mandatory)] [string] $Image,
        [Parameter(Mandatory)] [string] $Version,
        [Parameter(Mandatory)] [string] $RevisionSuffix,
        [string] $GitSha = 'unknown',
        [int[]] $Steps = @(10, 50),
        [string] $FaultRate = '0',
        [int] $AnalysisRequests = 60,
        [double] $MaxErrorRatePct = 1.0,
        [double] $MaxP95Ms = 1000,
        [switch] $SkipSettlementCheck,
        [string] $ReportPath = 'release-report.json'
    )

    $clock = [Diagnostics.Stopwatch]::StartNew()
    $phases = [System.Collections.Generic.List[object]]::new()
    function Add-Phase([string] $Name, [string] $Outcome, [double] $StartSec, [object] $Detail = $null) {
        $phases.Add([pscustomobject]@{
                Phase       = $Name
                Outcome     = $Outcome
                StartSec    = [Math]::Round($StartSec, 1)
                DurationSec = [Math]::Round($clock.Elapsed.TotalSeconds - $StartSec, 1)
                Detail      = $Detail
            })
    }

    $platform = Get-PlatformOutput -ResourceGroup $ResourceGroup
    $appName = $platform.apiAppName
    $stable = Get-StableRevision -ResourceGroup $ResourceGroup -AppName $appName
    $newRevision = "$appName--$RevisionSuffix"
    if ($stable -eq $newRevision) { throw "Revision $newRevision is already the stable revision." }

    $report = [ordered]@{
        Environment       = $platform.environmentName
        App               = $appName
        Version           = $Version
        Image             = $Image
        NewRevision       = $newRevision
        PreviousStable    = $stable
        FaultRate         = $FaultRate
        Steps             = $Steps
        Outcome           = 'InProgress'
        MaxTrafficExposed = 0
        StartedAt         = [DateTime]::UtcNow.ToString('o')
        Phases            = $phases
        Analysis          = [System.Collections.Generic.List[object]]::new()
        Rollback          = $null
        DetectionSec      = $null
        RecoverySec       = $null
        TotalSec          = $null
    }
    function Save-Report([string] $Path) {
        $report.TotalSec = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
        [pscustomobject]$report | ConvertTo-Json -Depth 12 | Set-Content -Path $Path -Encoding utf8
    }

    $t = $clock.Elapsed.TotalSeconds
    Publish-ApiRevision -ResourceGroup $ResourceGroup -Platform $platform -TemplateFile $TemplateFile `
        -Image $Image -RevisionSuffix $RevisionSuffix -Version $Version -GitSha $GitSha `
        -StableRevisionName ($stable ?? '') -FaultRate $FaultRate | Out-Null
    Add-Phase 'deploy-revision' 'Succeeded' $t

    $failure = $null
    try {
        $t = $clock.Elapsed.TotalSeconds
        Wait-RevisionReady -ResourceGroup $ResourceGroup -AppName $appName -RevisionName $newRevision -RequireHealthy | Out-Null
        Add-Phase 'revision-ready' 'Succeeded' $t

        $canaryFqdn = Get-RevisionFqdn -ResourceGroup $ResourceGroup -AppName $appName -RevisionName $newRevision
        $t = $clock.Elapsed.TotalSeconds
        $smoke = Invoke-SmokeTest -BaseUrl $canaryFqdn -ExpectedVersion $Version -ExpectedRevision $newRevision `
            -SkipSettlement:$SkipSettlementCheck -NoThrow
        Add-Phase 'smoke-test (0% traffic)' ($smoke.Passed ? 'Succeeded' : 'Failed') $t ($smoke.Checks | Where-Object { -not $_.Passed } | ForEach-Object Check)
        if (-not $smoke.Passed) { throw "smoke test failed on $newRevision before receiving traffic" }

        if (-not $stable) {
            # First release: the template already gave the new revision 100% and 'stable'.
            $report.MaxTrafficExposed = 100
            $report.Outcome = 'Promoted'
            Write-TradeOpsLog "first release: $newRevision is stable"
            Save-Report -Path $ReportPath
            return [pscustomobject]$report
        }

        $stableFqdn = Get-RevisionFqdn -ResourceGroup $ResourceGroup -AppName $appName -RevisionName $stable
        foreach ($weight in $Steps) {
            $t = $clock.Elapsed.TotalSeconds
            Set-TrafficConfiguration -ResourceGroup $ResourceGroup -AppName $appName -Entries @(
                @{ RevisionName = $stable; Weight = 100 - $weight; Label = 'stable' }
                @{ RevisionName = $newRevision; Weight = $weight; Label = 'canary' }
            ) | Out-Null
            $report.MaxTrafficExposed = $weight
            $analysis = Measure-CanaryHealth -CanaryUrl $canaryFqdn -ExpectedRevision $newRevision -BaselineUrl $stableFqdn `
                -Requests $AnalysisRequests -MaxErrorRatePct $MaxErrorRatePct -MaxP95Ms $MaxP95Ms
            $report.Analysis.Add([pscustomobject]@{ Weight = $weight; Verdict = $analysis.Verdict; Reasons = $analysis.Reasons; Canary = $analysis.Canary; Baseline = $analysis.Baseline })
            Add-Phase "canary $weight%" ($analysis.Verdict -eq 'Pass' ? 'Succeeded' : 'Failed') $t ($analysis.Reasons -join '; ')
            if ($analysis.Verdict -ne 'Pass') { throw "canary analysis failed at ${weight}%: $($analysis.Reasons -join '; ')" }
        }

        $t = $clock.Elapsed.TotalSeconds
        Invoke-Promotion -ResourceGroup $ResourceGroup -AppName $appName -NewRevision $newRevision -PreviousRevision $stable
        $report.MaxTrafficExposed = 100
        Add-Phase 'promote' 'Succeeded' $t
        $report.Outcome = 'Promoted'
    }
    catch {
        $failure = $_
    }

    if ($failure) {
        $report.DetectionSec = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
        Write-TradeOpsLog "release failed: $($failure.Exception.Message)" -Level Error
        $t = $clock.Elapsed.TotalSeconds
        if ($stable) {
            $rollback = Invoke-Rollback -ResourceGroup $ResourceGroup -AppName $appName -Reason $failure.Exception.Message
            $report.Rollback = $rollback
            $report.RecoverySec = $rollback.VerifiedSec
            $report.Outcome = $rollback.RolledBack ? 'RolledBack' : 'Failed'
            Add-Phase 'automatic-rollback' ($rollback.Verified ? 'Succeeded' : 'Unverified') $t
        }
        else {
            $report.Outcome = 'Failed'
            Add-Phase 'automatic-rollback' 'Skipped' $t 'first release: no stable revision to return to'
        }
        Save-Report -Path $ReportPath
        throw "Release $Version failed and was $($report.Outcome): $($failure.Exception.Message)"
    }

    Save-Report -Path $ReportPath
    return [pscustomobject]$report
}

function Publish-WorkerRelease {
    <#
    .SYNOPSIS
        Rolls the settlement worker to the new image after the API has been promoted. If the
        new worker revision does not come up, the previous image is redeployed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $TemplateFile,
        [Parameter(Mandatory)] [string] $Image,
        [Parameter(Mandatory)] [string] $RevisionSuffix,
        [Parameter(Mandatory)] [string] $Version,
        [string] $GitSha = 'unknown'
    )
    $platform = Get-PlatformOutput -ResourceGroup $ResourceGroup
    $appName = $platform.workerAppName
    $existing = @(Invoke-AzCli -Arguments @(
            'containerapp', 'list', '--resource-group', $ResourceGroup, '--query', "[?name=='$appName'].properties.template.containers[0].image"
        ))
    $previousImage = $existing | Select-Object -First 1

    function Publish-WorkerRevision([string] $WithImage, [string] $Suffix, [string] $Template, [string] $Sha) {
        $values = @{
            name                       = $appName
            tags                       = $platform.tags
            environmentName            = $platform.environmentName
            containerAppsEnvironmentId = $platform.containerAppsEnvironmentId
            image                      = $WithImage
            registryLoginServer        = $platform.registryLoginServer
            revisionSuffix             = $Suffix
            identityId                 = $platform.workerIdentityId
            identityClientId           = $platform.workerIdentityClientId
            appInsightsSecretUri       = $platform.appInsightsSecretUri
            storageTableEndpoint       = $platform.storageTableEndpoint
            ordersTable                = $platform.ordersTable
            serviceBusName             = $platform.serviceBusName
            serviceBusFqdn             = $platform.serviceBusFqdn
            settlementQueue            = $platform.settlementQueue
            maxDeliveryCount           = $platform.maxDeliveryCount
            scale                      = $platform.workerScale
            version                    = $Version
            gitSha                     = $Sha
        }
        $parameterFile = ConvertTo-ArmParameterFile -Values $values
        try {
            Invoke-AzCli -Arguments @(
                'deployment', 'group', 'create', '--resource-group', $ResourceGroup, '--name', "worker-$Suffix",
                '--template-file', $Template, '--parameters', "@$($parameterFile.FullName)"
            ) | Out-Null
        }
        finally {
            Remove-Item -Path $parameterFile.FullName -ErrorAction SilentlyContinue
        }
        Wait-RevisionReady -ResourceGroup $ResourceGroup -AppName $appName -RevisionName "$appName--$Suffix" | Out-Null
    }

    if (-not $PSCmdlet.ShouldProcess($appName, "deploy worker $Version")) { return }
    Write-TradeOpsLog "deploying worker $appName--$RevisionSuffix" -Level Section
    try {
        Publish-WorkerRevision -WithImage $Image -Suffix $RevisionSuffix -Template $TemplateFile -Sha $GitSha
    }
    catch {
        if (-not $previousImage) { throw }
        Write-TradeOpsLog "worker release failed ($($_.Exception.Message)); redeploying $previousImage" -Level Error
        Publish-WorkerRevision -WithImage $previousImage -Suffix "$RevisionSuffix-rb" -Template $TemplateFile -Sha $GitSha
        throw "Worker release $Version failed and was rolled back to $previousImage."
    }
    Write-TradeOpsLog "worker running $Version"
}

function Get-TradeOpsStatus {
    <#
    .SYNOPSIS
        Production-support view: traffic table and revision health for the API and worker.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ResourceGroup)
    $platform = Get-PlatformOutput -ResourceGroup $ResourceGroup
    $status = foreach ($appName in $platform.apiAppName, $platform.workerAppName) {
        $revisions = @(Invoke-AzCli -Arguments @(
                'containerapp', 'revision', 'list', '--resource-group', $ResourceGroup, '--name', $appName, '--all'
            ))
        $traffic = Get-ContainerAppTraffic -ResourceGroup $ResourceGroup -AppName $appName
        foreach ($revision in $revisions | Where-Object { $_ }) {
            $entry = $traffic ? @($traffic.Traffic | Where-Object RevisionName -EQ $revision.name) : @()
            [pscustomobject]@{
                App      = $appName
                Revision = $revision.name
                Active   = $revision.properties.active
                Weight   = ($entry | Measure-Object Weight -Sum).Sum
                Label    = ($entry | ForEach-Object Label) -join ','
                Health   = $revision.properties.healthState
                Running  = $revision.properties.runningState
                Image    = ($revision.properties.template.containers[0].image -split '[@:]')[-1] -replace '^(.{14}).+$', '$1'
                Created  = $revision.properties.createdTime
            }
        }
    }
    $status | Sort-Object App, Created -Descending | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    return $status
}
