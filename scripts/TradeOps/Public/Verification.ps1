# Reference prices mirror app/src/tradeops/reference.py so synthetic orders stay inside the
# +/-10% price collar and are accepted by pre-trade risk.
$script:SyntheticInstruments = @(
    @{ Symbol = 'AAPL'; Price = '230.00' }
    @{ Symbol = 'MSFT'; Price = '420.00' }
    @{ Symbol = 'NVDA'; Price = '140.00' }
    @{ Symbol = 'JPM'; Price = '240.00' }
)

function New-SyntheticOrder {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object; changes no state.')]
    param([string] $Account, [string] $ClientOrderId, [int] $Index = 0, [string] $Symbol, [string] $Price, [int] $Quantity = 1)
    $instrument = $script:SyntheticInstruments[$Index % $script:SyntheticInstruments.Count]
    return [ordered]@{
        client_order_id = $ClientOrderId
        account_id      = $Account
        symbol          = $Symbol ? $Symbol : $instrument.Symbol
        side            = if ($Index % 2) { 'SELL' } else { 'BUY' }
        order_type      = 'LIMIT'
        quantity        = $Quantity
        limit_price     = $Price ? $Price : $instrument.Price
    }
}

function Invoke-SmokeTest {
    <#
    .SYNOPSIS
        Functional smoke test of one API endpoint (a revision's own URL or the app URL).
    .DESCRIPTION
        Probes, release identity, then a real business flow on the synthetic SMOKE-0001
        account: accept, idempotent replay, risk rejection, schema rejection, and settlement
        end to end through Service Bus, the worker and Table Storage.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [string] $ExpectedVersion,
        [string] $ExpectedRevision,
        [string] $RunId = ([guid]::NewGuid().ToString('N').Substring(0, 12)),
        [int] $SettlementTimeoutSec = 90,
        [switch] $SkipSettlement,
        [switch] $NoThrow
    )

    $base = $BaseUrl.TrimEnd('/')
    if ($base -notmatch '^https?://') { $base = "https://$base" }
    $headers = @{ 'X-Request-ID' = "smoke-$RunId" }
    $checks = [System.Collections.Generic.List[object]]::new()
    $started = [Diagnostics.Stopwatch]::StartNew()

    function Add-Check([string] $Name, [bool] $Passed, [string] $Detail, [double] $ElapsedMs = 0) {
        $checks.Add([pscustomobject]@{ Check = $Name; Passed = $Passed; Detail = $Detail; ElapsedMs = $ElapsedMs })
    }

    # A freshly started revision can take a moment to accept connections.
    $health = $null
    foreach ($attempt in 1..5) {
        $health = Invoke-TradeOpsHttp -Method GET -Uri "$base/healthz" -Headers $headers
        if ($health.StatusCode -eq 200) { break }
        Start-Sleep -Seconds 3
    }
    Add-Check 'liveness /healthz' ($health.StatusCode -eq 200) "HTTP $($health.StatusCode)" $health.ElapsedMs

    $ready = Invoke-TradeOpsHttp -Method GET -Uri "$base/readyz" -Headers $headers
    $readyChecks = Get-Field $ready.Body 'checks'
    $readyDetail = if ($readyChecks) { ($readyChecks.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' ' } else { '' }
    Add-Check 'readiness /readyz (ledger, queue)' ($ready.StatusCode -eq 200) "HTTP $($ready.StatusCode) $readyDetail" $ready.ElapsedMs

    $version = Invoke-TradeOpsHttp -Method GET -Uri "$base/version" -Headers $headers
    $versionOk = $version.StatusCode -eq 200 -and
        (-not $ExpectedVersion -or (Get-Field $version.Body 'version') -eq $ExpectedVersion) -and
        (-not $ExpectedRevision -or (Get-Field $version.Body 'revision') -eq $ExpectedRevision)
    Add-Check 'release identity /version' $versionOk "version=$((Get-Field $version.Body 'version')) revision=$((Get-Field $version.Body 'revision'))" $version.ElapsedMs

    $order = New-SyntheticOrder -Account 'SMOKE-0001' -ClientOrderId "smoke-$RunId"
    $submit = Invoke-TradeOpsHttp -Method POST -Uri "$base/v1/orders" -Body $order -Headers $headers
    $accepted = $submit.StatusCode -in 200, 201 -and (Get-Field $submit.Body 'status') -in 'ACCEPTED', 'SETTLED'
    Add-Check 'order accepted' $accepted "HTTP $($submit.StatusCode) status=$((Get-Field $submit.Body 'status'))" $submit.ElapsedMs

    $replay = Invoke-TradeOpsHttp -Method POST -Uri "$base/v1/orders" -Body $order -Headers $headers
    $replayOk = $replay.StatusCode -eq 200 -and $accepted -and (Get-Field $replay.Body 'order_id') -eq (Get-Field $submit.Body 'order_id')
    Add-Check 'idempotent replay' $replayOk "HTTP $($replay.StatusCode)" $replay.ElapsedMs

    $restricted = New-SyntheticOrder -Account 'SMOKE-0001' -ClientOrderId "smoke-$RunId-r" -Symbol 'ACME' -Price '12.50'
    $reject = Invoke-TradeOpsHttp -Method POST -Uri "$base/v1/orders" -Body $restricted -Headers $headers
    $rejectOk = $reject.StatusCode -in 200, 201 -and (Get-Field $reject.Body 'status') -eq 'REJECTED' -and
        ('RESTRICTED_INSTRUMENT' -in @((Get-Field $reject.Body 'reject_reasons')))
    Add-Check 'pre-trade risk rejects restricted symbol' $rejectOk "HTTP $($reject.StatusCode) status=$((Get-Field $reject.Body 'status'))" $reject.ElapsedMs

    $invalid = New-SyntheticOrder -Account 'SMOKE-0001' -ClientOrderId "smoke-$RunId-x" -Quantity 0
    $schema = Invoke-TradeOpsHttp -Method POST -Uri "$base/v1/orders" -Body $invalid -Headers $headers
    Add-Check 'schema validation (qty 0 -> 422)' ($schema.StatusCode -eq 422) "HTTP $($schema.StatusCode)" $schema.ElapsedMs

    if (-not $SkipSettlement -and $accepted) {
        $location = "$base/v1/accounts/SMOKE-0001/orders/$((Get-Field $submit.Body 'order_id'))"
        $deadline = [DateTime]::UtcNow.AddSeconds($SettlementTimeoutSec)
        $settleWatch = [Diagnostics.Stopwatch]::StartNew()
        $status = (Get-Field $submit.Body 'status')
        while ($status -ne 'SETTLED' -and $status -ne 'FAILED' -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds 2
            $status = (Invoke-TradeOpsHttp -Method GET -Uri $location -Headers $headers).Body.status
        }
        Add-Check 'settled end to end (Service Bus -> worker -> ledger)' ($status -eq 'SETTLED') "status=$status after $([int]$settleWatch.Elapsed.TotalSeconds)s" $settleWatch.Elapsed.TotalMilliseconds
    }

    $started.Stop()
    $passed = -not ($checks | Where-Object { -not $_.Passed })
    $checks | Format-Table Check, Passed, Detail -AutoSize | Out-String -Width 200 | Write-Host
    $result = [pscustomobject]@{
        BaseUrl     = $base
        Passed      = [bool]$passed
        Checks      = @($checks)
        DurationSec = [Math]::Round($started.Elapsed.TotalSeconds, 1)
    }
    if (-not $passed -and -not $NoThrow) {
        $failed = ($checks | Where-Object { -not $_.Passed } | ForEach-Object Check) -join ', '
        throw "Smoke test failed against ${base}: $failed"
    }
    return $result
}

function Measure-CanaryHealth {
    <#
    .SYNOPSIS
        Canary analysis: drives synthetic order traffic at a revision and judges its error
        rate and latency against fixed SLO thresholds and, when given, the stable baseline.
    .DESCRIPTION
        Traffic goes to the revision's own URL, so the verdict reflects only the canary
        regardless of the current traffic weight. Each response's X-TradeOps-Revision header
        confirms which revision served it. Orders use the synthetic CANARY-0001 account,
        which business dashboards exclude.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CanaryUrl,
        [string] $ExpectedRevision,
        [string] $BaselineUrl,
        [ValidateRange(10, 2000)] [int] $Requests = 60,
        [double] $MaxErrorRatePct = 1.0,
        [double] $MaxP95Ms = 1000,
        # Fail when canary p95 is this many times the baseline's (ignored below 200 ms).
        [double] $LatencyRegressionFactor = 2.0,
        [string] $RunId = ([guid]::NewGuid().ToString('N').Substring(0, 12))
    )

    function Invoke-Sample([string] $Url, [int] $Count, [string] $Prefix, [string] $Run) {
        $base = $Url.TrimEnd('/')
        if ($base -notmatch '^https?://') { $base = "https://$base" }
        $samples = foreach ($i in 0..($Count - 1)) {
            $order = New-SyntheticOrder -Account 'CANARY-0001' -ClientOrderId "$Prefix-$Run-$i" -Index $i
            $response = Invoke-TradeOpsHttp -Method POST -Uri "$base/v1/orders" -Body $order -Headers @{ 'X-Request-ID' = "$Prefix-$Run-$i" }
            [pscustomobject]@{
                StatusCode = $response.StatusCode
                ElapsedMs  = $response.ElapsedMs
                Revision   = $response.Headers['X-TradeOps-Revision']
                Ok         = $response.StatusCode -in 200, 201 -and (Get-Field $response.Body 'status') -in 'ACCEPTED', 'SETTLED'
            }
        }
        $samples = @($samples)
        $failures = @($samples | Where-Object { -not $_.Ok }).Count
        $latencies = [double[]]@($samples | ForEach-Object ElapsedMs)
        return [pscustomobject]@{
            Requests     = $samples.Count
            Failures     = $failures
            ErrorRatePct = [Math]::Round(100.0 * $failures / [Math]::Max(1, $samples.Count), 2)
            P50Ms        = Get-Percentile -Values $latencies -Percentile 50
            P95Ms        = Get-Percentile -Values $latencies -Percentile 95
            P99Ms        = Get-Percentile -Values $latencies -Percentile 99
            StatusCodes  = ($samples | Group-Object StatusCode | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ' '
            Revisions    = @($samples | ForEach-Object Revision | Where-Object { $_ } | Sort-Object -Unique)
        }
    }

    Write-TradeOpsLog "canary analysis: $Requests synthetic orders -> $CanaryUrl"
    $canary = Invoke-Sample -Url $CanaryUrl -Count $Requests -Prefix 'canary' -Run $RunId
    $baseline = $null
    if ($BaselineUrl) {
        $baseline = Invoke-Sample -Url $BaselineUrl -Count ([Math]::Max(10, [int]($Requests / 2))) -Prefix 'baseline' -Run $RunId
    }

    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($canary.ErrorRatePct -gt $MaxErrorRatePct) {
        $reasons.Add("error rate $($canary.ErrorRatePct)% > $MaxErrorRatePct% ($($canary.StatusCodes))")
    }
    if ($canary.P95Ms -gt $MaxP95Ms) {
        $reasons.Add("p95 latency $($canary.P95Ms) ms > $MaxP95Ms ms")
    }
    if ($baseline -and $canary.P95Ms -gt 200 -and $baseline.P95Ms -gt 0 -and
        $canary.P95Ms -gt $baseline.P95Ms * $LatencyRegressionFactor) {
        $reasons.Add("p95 latency $($canary.P95Ms) ms is more than ${LatencyRegressionFactor}x baseline $($baseline.P95Ms) ms")
    }
    if ($ExpectedRevision -and $canary.Revisions.Count -gt 0 -and ($canary.Revisions | Where-Object { $_ -ne $ExpectedRevision })) {
        $reasons.Add("responses came from unexpected revisions: $($canary.Revisions -join ', ')")
    }

    $verdict = if ($reasons.Count -eq 0) { 'Pass' } else { 'Fail' }
    $summary = "canary verdict=$verdict errors=$($canary.ErrorRatePct)% p50=$($canary.P50Ms)ms p95=$($canary.P95Ms)ms p99=$($canary.P99Ms)ms"
    if ($baseline) { $summary += " | baseline errors=$($baseline.ErrorRatePct)% p95=$($baseline.P95Ms)ms" }
    Write-TradeOpsLog $summary -Level ($verdict -eq 'Pass' ? 'Info' : 'Warning')

    return [pscustomobject]@{
        Verdict    = $verdict
        Reasons    = @($reasons)
        Canary     = $canary
        Baseline   = $baseline
        Thresholds = [pscustomobject]@{ MaxErrorRatePct = $MaxErrorRatePct; MaxP95Ms = $MaxP95Ms; LatencyRegressionFactor = $LatencyRegressionFactor }
    }
}
