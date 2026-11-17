<#
.SYNOPSIS
    Progressive release of one build to one environment: promote the image by digest, canary
    the API with automatic rollback, then roll the settlement worker.
.DESCRIPTION
    The image is identified by its release tag in the previous stage's registry (dev for
    staging, staging for prod; the environment's own registry for dev). The tag is resolved
    to a digest once, and everything after that uses the digest.
.EXAMPLE
    ./scripts/Deploy-Release.ps1 -Environment staging -PromoteFrom dev -Version 1.0.0-20261116.3 -RevisionSuffix r4521-1
.EXAMPLE
    # The failing-release demo: the canary fails 30% of orders and is rolled back automatically.
    ./scripts/Deploy-Release.ps1 -Environment staging ... -FaultRate 0.3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('dev', 'staging', 'prod')] [string] $Environment,
    [string] $ResourceGroup = "rg-tradeops-$Environment",
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $RevisionSuffix,
    # Stage whose registry holds the image. Empty: the image is already in this environment's.
    [ValidateSet('', 'dev', 'staging')] [string] $PromoteFrom = '',
    [string] $Repository = 'tradeops',
    [string] $GitSha = 'unknown',
    [string] $AppsTemplateDirectory,
    # Dev skips the canary: straight to 100% after the smoke test.
    [int[]] $Steps = @(10, 50),
    [string] $FaultRate = '0',
    [int] $AnalysisRequests = 60,
    [double] $MaxErrorRatePct = 1.0,
    [double] $MaxP95Ms = 1000,
    [string] $ReportPath = "release-report-$Environment.json"
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TradeOps/TradeOps.psd1') -Force
if ($ReportPath -and (Split-Path $ReportPath)) { New-Item -ItemType Directory -Force -Path (Split-Path $ReportPath) | Out-Null }
$root = Split-Path $PSScriptRoot -Parent
if (-not $AppsTemplateDirectory) { $AppsTemplateDirectory = Join-Path $root 'infra/apps' }
$apiTemplate = Get-ChildItem -Path $AppsTemplateDirectory -Filter 'api.*' | Where-Object Extension -In '.json', '.bicep' | Sort-Object Extension -Descending | Select-Object -First 1
$workerTemplate = Get-ChildItem -Path $AppsTemplateDirectory -Filter 'worker.*' | Where-Object Extension -In '.json', '.bicep' | Sort-Object Extension -Descending | Select-Object -First 1

$platform = Get-PlatformOutput -ResourceGroup $ResourceGroup
$source = if ($PromoteFrom) { Get-PlatformOutput -ResourceGroup "rg-tradeops-$PromoteFrom" } else { $platform }
$tag = ($Version -replace '[^A-Za-z0-9_.-]', '-')
$digest = az acr repository show --name $source.registryName --image "${Repository}:$tag" --query digest --output tsv
if ($LASTEXITCODE -ne 0 -or -not $digest) { throw "Release tag ${Repository}:$tag not found in $($source.registryLoginServer)." }
Write-Host "release $Version = $Repository@$digest (from $($source.registryLoginServer))"
$image = Import-ReleaseImage -SourceLoginServer $source.registryLoginServer -TargetRegistryName $platform.registryName `
    -TargetLoginServer $platform.registryLoginServer -Digest $digest -Tag $tag -Repository $Repository

$release = Invoke-CanaryRelease -ResourceGroup $ResourceGroup -TemplateFile $apiTemplate.FullName -Image $image `
    -Version $Version -RevisionSuffix $RevisionSuffix -GitSha $GitSha -Steps $Steps -FaultRate $FaultRate `
    -AnalysisRequests $AnalysisRequests -MaxErrorRatePct $MaxErrorRatePct -MaxP95Ms $MaxP95Ms -ReportPath $ReportPath

Publish-WorkerRelease -ResourceGroup $ResourceGroup -TemplateFile $workerTemplate.FullName -Image $image `
    -RevisionSuffix $RevisionSuffix -Version $Version -GitSha $GitSha

Write-Host "Release $Version $($release.Outcome) in $Environment in $($release.TotalSec)s (report: $ReportPath)"
if ($env:TF_BUILD) {
    Write-Host "##vso[task.setvariable variable=releasedImage;isOutput=true]$image"
}
