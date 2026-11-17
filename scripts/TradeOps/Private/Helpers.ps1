function Invoke-AzCli {
    <#
    .SYNOPSIS
        Runs an Azure CLI command and returns its JSON output as objects. Throws on failure
        with az's own error text, so callers never have to check $LASTEXITCODE.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        # Return raw text instead of parsing JSON (for commands with no JSON output).
        [switch] $Raw
    )

    $stderrFile = New-TemporaryFile
    try {
        $output = & az @Arguments --only-show-errors --output json 2> $stderrFile.FullName
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $stderr = (Get-Content -Raw -Path $stderrFile.FullName) ?? ''
            throw "az $($Arguments[0..([Math]::Min(2, $Arguments.Count - 1))] -join ' ') failed (exit $exitCode): $($stderr.Trim())"
        }
        $text = ($output -join "`n").Trim()
        if ($Raw) { return $text }
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return $text | ConvertFrom-Json -Depth 64
    }
    finally {
        Remove-Item -Path $stderrFile.FullName -ErrorAction SilentlyContinue
    }
}

function Invoke-TradeOpsHttp {
    <#
    .SYNOPSIS
        One HTTP call returning status, headers, parsed body and latency. Never throws on an
        HTTP error status (callers judge the status); a transport failure (DNS, TLS, timeout)
        is reported as StatusCode 0 so it counts as a failed request in canary analysis.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('GET', 'POST')] [string] $Method,
        [Parameter(Mandatory)] [string] $Uri,
        [object] $Body,
        [hashtable] $Headers = @{},
        [int] $TimeoutSec = 15
    )

    $params = @{
        Method             = $Method
        Uri                = $Uri
        Headers            = $Headers
        TimeoutSec         = $TimeoutSec
        SkipHttpErrorCheck = $true
        UseBasicParsing    = $true
    }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $params.ContentType = 'application/json'
    }

    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-WebRequest @params
        $watch.Stop()
        $parsed = $null
        if ($response.Content) {
            try { $parsed = $response.Content | ConvertFrom-Json -Depth 32 } catch { $parsed = $null }
        }
        $responseHeaders = @{}
        foreach ($key in $response.Headers.Keys) {
            $responseHeaders[$key] = @($response.Headers[$key])[0]
        }
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Headers    = $responseHeaders
            Body       = $parsed
            ElapsedMs  = [Math]::Round($watch.Elapsed.TotalMilliseconds, 1)
            Error      = $null
        }
    }
    catch {
        $watch.Stop()
        return [pscustomobject]@{
            StatusCode = 0
            Headers    = @{}
            Body       = $null
            ElapsedMs  = [Math]::Round($watch.Elapsed.TotalMilliseconds, 1)
            Error      = $_.Exception.Message
        }
    }
}

function Write-TradeOpsLog {
    <# Timestamped log line. Under Azure Pipelines, warnings and errors become annotations. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('Info', 'Section', 'Warning', 'Error')] [string] $Level = 'Info'
    )
    $stamp = [DateTime]::UtcNow.ToString('HH:mm:ss')
    $inPipeline = [bool]$env:TF_BUILD
    switch ($Level) {
        'Section' { if ($inPipeline) { Write-Host "##[section]$Message" } else { Write-Host "`n== $Message ==" } }
        'Warning' { if ($inPipeline) { Write-Host "##vso[task.logissue type=warning]$Message" } else { Write-Warning $Message } }
        'Error' { if ($inPipeline) { Write-Host "##vso[task.logissue type=error]$Message" } else { Write-Host "ERROR: $Message" } }
        default { Write-Host "[$stamp] $Message" }
    }
}

function Get-Percentile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [double[]] $Values,
        [Parameter(Mandatory)] [ValidateRange(0, 100)] [double] $Percentile
    )
    if ($Values.Count -eq 0) { return 0 }
    $sorted = $Values | Sort-Object
    # Nearest-rank method: simple, and exact for the sample sizes used here.
    $rank = [Math]::Max(1, [Math]::Ceiling(($Percentile / 100) * $sorted.Count))
    return [double]$sorted[$rank - 1]
}

function Get-RevisionFqdn {
    <# A revision's own hostname, reachable whatever its traffic weight. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AppName,
        [Parameter(Mandatory)] [string] $RevisionName
    )
    $revision = Invoke-AzCli -Arguments @(
        'containerapp', 'revision', 'show', '--resource-group', $ResourceGroup,
        '--name', $AppName, '--revision', $RevisionName
    )
    return $revision.properties.fqdn
}

function Get-Field {
    <#
    .SYNOPSIS
        Reads a property from a parsed response body, or $null when the body or property is
        missing. Error bodies don't share the success schema, and StrictMode would otherwise
        turn a failed check into a crash instead of a reported failure.
    #>
    param([object] $Object, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $Object -or $Object -is [string]) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}
