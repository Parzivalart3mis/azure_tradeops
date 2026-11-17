function Get-PlatformOutput {
    <#
    .SYNOPSIS
        Reads the outputs of the platform deployment (infra/main.bicep) as a hashtable.
        These are the platform's contract with the release tooling.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [string] $DeploymentName = 'tradeops-platform'
    )
    $outputs = Invoke-AzCli -Arguments @(
        'deployment', 'group', 'show', '--resource-group', $ResourceGroup,
        '--name', $DeploymentName, '--query', 'properties.outputs'
    )
    if ($null -eq $outputs) {
        throw "Deployment '$DeploymentName' in '$ResourceGroup' has no outputs. Deploy the platform first."
    }
    $result = @{}
    foreach ($property in $outputs.PSObject.Properties) {
        $result[$property.Name] = $property.Value.value
    }
    return $result
}

function Test-TradeOpsEnvironment {
    <#
    .SYNOPSIS
        Pre-flight validation before anything is deployed: correct subscription, resource
        group present, resource providers registered, Bicep available and, optionally, a
        healthy platform deployment. Throws if any check fails, listing every failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [string] $ExpectedSubscriptionId,
        [switch] $RequirePlatform,
        [string[]] $RequiredProviders = @(
            'Microsoft.App', 'Microsoft.ContainerRegistry', 'Microsoft.KeyVault', 'Microsoft.ServiceBus',
            'Microsoft.Storage', 'Microsoft.OperationalInsights', 'Microsoft.Insights',
            'Microsoft.Network', 'Microsoft.ManagedIdentity'
        )
    )

    $results = [System.Collections.Generic.List[object]]::new()
    function Add-Result([string] $Check, [string] $Status, [string] $Detail) {
        $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
    }

    try {
        $account = Invoke-AzCli -Arguments @('account', 'show')
        Add-Result 'Azure CLI session' 'Pass' "$($account.user.type) in tenant $($account.tenantId)"
        if ($ExpectedSubscriptionId -and $account.id -ne $ExpectedSubscriptionId) {
            Add-Result 'Subscription' 'Fail' "signed in to $($account.id), expected $ExpectedSubscriptionId"
        }
        else {
            Add-Result 'Subscription' 'Pass' "$($account.name) ($($account.id))"
        }
    }
    catch {
        Add-Result 'Azure CLI session' 'Fail' $_.Exception.Message
    }

    try {
        $group = Invoke-AzCli -Arguments @('group', 'show', '--name', $ResourceGroup)
        Add-Result 'Resource group' 'Pass' "$($group.name) in $($group.location)"
    }
    catch {
        Add-Result 'Resource group' 'Fail' "$ResourceGroup not found or not accessible"
    }

    try {
        $registered = @(Invoke-AzCli -Arguments @(
                'provider', 'list', '--query', "[?registrationState=='Registered'].namespace"
            ))
        $missing = @($RequiredProviders | Where-Object { $_ -notin $registered })
        if ($missing.Count -gt 0) {
            Add-Result 'Resource providers' 'Fail' "not registered: $($missing -join ', ')"
        }
        else {
            Add-Result 'Resource providers' 'Pass' "$($RequiredProviders.Count) registered"
        }
    }
    catch {
        Add-Result 'Resource providers' 'Fail' $_.Exception.Message
    }

    try {
        $bicep = Invoke-AzCli -Arguments @('bicep', 'version') -Raw
        Add-Result 'Bicep CLI' 'Pass' ($bicep -split "`n" | Select-Object -First 1)
    }
    catch {
        Add-Result 'Bicep CLI' 'Fail' 'az bicep is not installed (az bicep install)'
    }

    if ($RequirePlatform) {
        try {
            $state = Invoke-AzCli -Arguments @(
                'deployment', 'group', 'show', '--resource-group', $ResourceGroup,
                '--name', 'tradeops-platform', '--query', 'properties.provisioningState'
            )
            $status = if ($state -eq 'Succeeded') { 'Pass' } else { 'Fail' }
            Add-Result 'Platform deployment' $status "provisioningState=$state"
        }
        catch {
            Add-Result 'Platform deployment' 'Fail' 'tradeops-platform deployment not found'
        }
    }

    try {
        $assignment = @(Invoke-AzCli -Arguments @(
                'policy', 'assignment', 'list', '--resource-group', $ResourceGroup,
                '--query', "[?name=='tradeops-guardrails'].name"
            ))
        if ($assignment.Count -gt 0) {
            Add-Result 'Policy guardrails' 'Pass' 'tradeops-guardrails assigned'
        }
        else {
            Add-Result 'Policy guardrails' 'Warn' 'tradeops-guardrails not assigned (see infra/governance)'
        }
    }
    catch {
        Add-Result 'Policy guardrails' 'Warn' "could not read policy assignments: $($_.Exception.Message)"
    }

    $results | Format-Table -AutoSize | Out-String | Write-Host
    $failures = @($results | Where-Object Status -EQ 'Fail')
    if ($failures.Count -gt 0) {
        throw "Environment validation failed: $(($failures | ForEach-Object { "$($_.Check): $($_.Detail)" }) -join '; ')"
    }
    return $results
}

# Changes to these properties need an explicit -AllowProtectedChange: they loosen or
# re-shape the security or data posture and deserve a human look at the what-if output.
$script:ProtectedProperties = @(
    'location'
    'sku.name'
    'properties.publicNetworkAccess'
    'properties.networkAcls.defaultAction'
    'properties.allowSharedKeyAccess'
    'properties.allowBlobPublicAccess'
    'properties.minimumTlsVersion'
    'properties.disableLocalAuth'
    'properties.DisableLocalAuth'
    'properties.enableRbacAuthorization'
    'properties.enablePurgeProtection'
    'properties.adminUserEnabled'
    'properties.securityRules'
)

function Invoke-PlatformDeployment {
    <#
    .SYNOPSIS
        what-if, gate, then deploy the platform template.
    .DESCRIPTION
        Runs `az deployment group what-if`, summarises every change, writes a Markdown
        summary (shown on the Azure Pipelines run), and refuses to continue when the change
        set contains deletions or touches a protected security property, unless explicitly
        allowed. With -WhatIfOnly it stops after the review (the pre-approval plan stage).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $TemplateFile,
        [Parameter(Mandatory)] [string] $ParameterFile,
        [string] $DeploymentName = 'tradeops-platform',
        [switch] $WhatIfOnly,
        [switch] $AllowDelete,
        [switch] $AllowProtectedChange,
        [string] $SummaryPath
    )

    Write-TradeOpsLog "what-if: $TemplateFile with $ParameterFile -> $ResourceGroup" -Level Section
    $whatIf = Invoke-AzCli -Arguments @(
        'deployment', 'group', 'what-if', '--resource-group', $ResourceGroup, '--name', $DeploymentName,
        '--template-file', $TemplateFile, '--parameters', $ParameterFile,
        '--result-format', 'FullResourcePayloads', '--no-pretty-print'
    )

    $changes = @($whatIf.changes)
    $counts = [ordered]@{}
    foreach ($type in 'Create', 'Modify', 'Delete', 'Deploy', 'NoChange', 'Ignore', 'Unsupported') {
        $counts[$type] = @($changes | Where-Object changeType -EQ $type).Count
    }

    $protectedHits = [System.Collections.Generic.List[string]]::new()
    foreach ($change in $changes | Where-Object changeType -EQ 'Modify') {
        foreach ($delta in @($change.delta)) {
            # NoEffect deltas are what-if noise (e.g. read-only or defaulted properties).
            if ($null -eq $delta -or $delta.propertyChangeType -eq 'NoEffect') { continue }
            foreach ($protected in $script:ProtectedProperties) {
                if ($delta.path -eq $protected -or $delta.path.StartsWith("$protected.") -or $delta.path.StartsWith("$protected[")) {
                    $protectedHits.Add("$($change.resourceId.Split('/')[-1]): $($delta.path)")
                }
            }
        }
    }
    $deletes = @($changes | Where-Object changeType -EQ 'Delete' | ForEach-Object { $_.resourceId })

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("### Infrastructure what-if: $ResourceGroup")
    $lines.Add('')
    $lines.Add('| Change | Count |')
    $lines.Add('|---|---:|')
    foreach ($entry in $counts.GetEnumerator()) { $lines.Add("| $($entry.Key) | $($entry.Value) |") }
    foreach ($change in $changes | Where-Object changeType -In 'Create', 'Modify', 'Delete') {
        $lines.Add("- **$($change.changeType)** ``$($change.resourceId.Split('/providers/')[-1])``")
    }
    if ($protectedHits.Count -gt 0) {
        $lines.Add('')
        $lines.Add('**Protected properties changed:**')
        foreach ($hit in $protectedHits) { $lines.Add("- $hit") }
    }
    $markdown = $lines -join "`n"
    Write-Host $markdown
    if ($SummaryPath) {
        Set-Content -Path $SummaryPath -Value $markdown -Encoding utf8
        if ($env:TF_BUILD) { Write-Host "##vso[task.uploadsummary]$((Resolve-Path $SummaryPath).Path)" }
    }

    $result = [pscustomobject]@{
        Counts            = $counts
        Deletes           = $deletes
        ProtectedChanges  = @($protectedHits)
        Deployed          = $false
        Outputs           = $null
    }

    if ($deletes.Count -gt 0 -and -not $AllowDelete) {
        throw "what-if would delete $($deletes.Count) resource(s): $($deletes -join ', '). Re-run with -AllowDelete after review."
    }
    if ($protectedHits.Count -gt 0 -and -not $AllowProtectedChange) {
        throw "what-if changes protected properties: $($protectedHits -join '; '). Re-run with -AllowProtectedChange after security review."
    }
    if ($WhatIfOnly) { return $result }

    if ($PSCmdlet.ShouldProcess($ResourceGroup, "deploy $DeploymentName")) {
        Write-TradeOpsLog "deploying $DeploymentName" -Level Section
        $deployment = Invoke-AzCli -Arguments @(
            'deployment', 'group', 'create', '--resource-group', $ResourceGroup, '--name', $DeploymentName,
            '--template-file', $TemplateFile, '--parameters', $ParameterFile, '--mode', 'Incremental'
        )
        $result.Deployed = $true
        $result.Outputs = $deployment.properties.outputs
        Write-TradeOpsLog "platform deployment $($deployment.properties.provisioningState)"
    }
    return $result
}
