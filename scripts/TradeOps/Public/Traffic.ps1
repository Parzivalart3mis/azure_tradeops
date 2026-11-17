$script:ContainerAppsApiVersion = '2025-07-01'

function Get-ContainerAppTraffic {
    <#
    .SYNOPSIS
        The container app's ingress traffic table, or $null when the app does not exist yet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AppName
    )
    $apps = @(Invoke-AzCli -Arguments @(
            'containerapp', 'list', '--resource-group', $ResourceGroup, '--query', "[?name=='$AppName']"
        ))
    if ($apps.Count -eq 0 -or $null -eq $apps[0]) { return $null }
    $app = $apps[0]

    $entries = foreach ($entry in @($app.properties.configuration.ingress.traffic)) {
        if ($null -eq $entry) { continue }
        $revisionName = if ($entry.PSObject.Properties['revisionName'] -and $entry.revisionName) {
            $entry.revisionName
        }
        else {
            $app.properties.latestRevisionName  # a `latestRevision: true` entry
        }
        [pscustomobject]@{
            RevisionName = $revisionName
            Weight       = [int]$entry.weight
            Label        = if ($entry.PSObject.Properties['label']) { $entry.label } else { $null }
        }
    }

    return [pscustomobject]@{
        Id                 = $app.id
        Name               = $app.name
        Fqdn               = $app.properties.configuration.ingress.fqdn
        LatestRevisionName = $app.properties.latestRevisionName
        Traffic            = @($entries)
    }
}

function Get-StableRevision {
    <#
    .SYNOPSIS
        The revision serving production: the one labelled 'stable', else the heaviest-
        weighted one. $null on the first release.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AppName
    )
    $state = Get-ContainerAppTraffic -ResourceGroup $ResourceGroup -AppName $AppName
    if ($null -eq $state -or $state.Traffic.Count -eq 0) { return $null }
    $labelled = @($state.Traffic | Where-Object Label -EQ 'stable')
    if ($labelled.Count -gt 0) { return $labelled[0].RevisionName }
    return ($state.Traffic | Sort-Object Weight -Descending | Select-Object -First 1).RevisionName
}

function Set-TrafficConfiguration {
    <#
    .SYNOPSIS
        Atomically replaces the app's traffic table (weights and labels) with one ARM PATCH,
        waits for the update to finish and verifies the result.
    .DESCRIPTION
        Container Apps PATCH is a JSON merge patch: the traffic array is replaced as a whole
        and nothing else changes. Every canary step, promotion and rollback goes through
        this one function, so the traffic table is always fully declared, never edited.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AppName,
        # @{ RevisionName = '...'; Weight = 90; Label = 'stable' }, ...
        [Parameter(Mandatory)] [hashtable[]] $Entries,
        [int] $TimeoutSec = 300
    )

    $total = ($Entries | Measure-Object -Property Weight -Sum).Sum
    if ($total -ne 100) { throw "Traffic weights must sum to 100 (got $total)." }

    $state = Get-ContainerAppTraffic -ResourceGroup $ResourceGroup -AppName $AppName
    if ($null -eq $state) { throw "Container app $AppName not found in $ResourceGroup." }

    $traffic = @(foreach ($entry in $Entries) {
            $item = [ordered]@{ revisionName = $entry.RevisionName; weight = [int]$entry.Weight }
            if ($entry.Label) { $item.label = $entry.Label }
            $item
        })
    $body = @{ properties = @{ configuration = @{ ingress = @{ traffic = $traffic } } } }
    $description = ($Entries | ForEach-Object { "$($_.RevisionName)=$($_.Weight)%$(if ($_.Label) { " [$($_.Label)]" })" }) -join ', '

    if (-not $PSCmdlet.ShouldProcess($AppName, "set traffic: $description")) { return }

    $bodyFile = New-TemporaryFile
    try {
        $body | ConvertTo-Json -Depth 10 -Compress | Set-Content -Path $bodyFile.FullName -Encoding utf8
        Invoke-AzCli -Arguments @(
            'rest', '--method', 'patch', '--url', "$($state.Id)?api-version=$($script:ContainerAppsApiVersion)",
            '--headers', 'Content-Type=application/json', '--body', "@$($bodyFile.FullName)"
        ) | Out-Null
    }
    finally {
        Remove-Item -Path $bodyFile.FullName -ErrorAction SilentlyContinue
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    do {
        $provisioning = Invoke-AzCli -Arguments @(
            'containerapp', 'show', '--resource-group', $ResourceGroup, '--name', $AppName,
            '--query', 'properties.provisioningState'
        )
        if ($provisioning -eq 'Succeeded') { break }
        if ($provisioning -eq 'Failed') { throw "Traffic update on $AppName failed (provisioningState=Failed)." }
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($provisioning -ne 'Succeeded') { throw "Timed out waiting for traffic update on $AppName." }

    $after = Get-ContainerAppTraffic -ResourceGroup $ResourceGroup -AppName $AppName
    foreach ($entry in $Entries) {
        $actual = @($after.Traffic | Where-Object RevisionName -EQ $entry.RevisionName)
        $weight = ($actual | Measure-Object -Property Weight -Sum).Sum
        if ($weight -ne $entry.Weight) {
            throw "Traffic verification failed for $($entry.RevisionName): expected $($entry.Weight)%, found $weight%."
        }
    }
    Write-TradeOpsLog "traffic now: $description"
    return $after
}

function Wait-RevisionReady {
    <#
    .SYNOPSIS
        Waits until a revision is provisioned and running (and healthy when it has probes).
        Fails fast when the platform reports the revision as failed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AppName,
        [Parameter(Mandatory)] [string] $RevisionName,
        [int] $TimeoutSec = 600,
        [int] $PollSec = 10,
        # The API has readiness probes, so it must report Healthy. The worker has none.
        [switch] $RequireHealthy
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $last = $null
    do {
        $revision = Invoke-AzCli -Arguments @(
            'containerapp', 'revision', 'show', '--resource-group', $ResourceGroup,
            '--name', $AppName, '--revision', $RevisionName
        )
        $p = $revision.properties
        $last = "provisioning=$($p.provisioningState) running=$($p.runningState) health=$($p.healthState)"
        if ($p.provisioningState -eq 'Failed' -or $p.runningState -in 'Failed', 'Degraded') {
            throw "Revision $RevisionName failed to start ($last)."
        }
        $healthy = $p.healthState -eq 'Healthy' -or (-not $RequireHealthy -and $p.healthState -in 'None', $null)
        if ($p.provisioningState -eq 'Provisioned' -and $p.runningState -in 'Running', 'RunningAtMaxScale' -and $healthy) {
            Write-TradeOpsLog "revision $RevisionName ready ($last)"
            return $revision
        }
        Write-TradeOpsLog "waiting for $RevisionName ($last)"
        Start-Sleep -Seconds $PollSec
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out after ${TimeoutSec}s waiting for revision $RevisionName ($last)."
}
