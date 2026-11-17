<#
.SYNOPSIS
    Pushes the image built and scanned in CI (a `docker save` archive) to the dev registry
    under an immutable tag, and prints its digest. Later stages promote by that digest.
.EXAMPLE
    ./scripts/Push-Image.ps1 -ImageArchive image/tradeops.tar.gz -Tag 1.0.0-20261116.3
#>
[CmdletBinding()]
param(
    [ValidateSet('dev')] [string] $Environment = 'dev',
    [string] $ResourceGroup = "rg-tradeops-$Environment",
    [Parameter(Mandatory)] [string] $ImageArchive,
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$')] [string] $Tag,
    [string] $Repository = 'tradeops'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TradeOps/TradeOps.psd1') -Force
$platform = Get-PlatformOutput -ResourceGroup $ResourceGroup
$target = "$($platform.registryLoginServer)/${Repository}:$Tag"

$loaded = docker load --input $ImageArchive
if ($LASTEXITCODE -ne 0) { throw "docker load failed: $loaded" }
$source = ($loaded | Select-String 'Loaded image: (.+)$').Matches[0].Groups[1].Value
docker tag $source $target
az acr login --name $platform.registryName --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'az acr login failed' }
docker push $target
if ($LASTEXITCODE -ne 0) { throw "docker push $target failed" }

# Lock the tag: a release tag must never be overwritten or deleted.
az acr repository update --name $platform.registryName --image "${Repository}:$Tag" `
    --write-enabled false --delete-enabled false --only-show-errors --output none
$digest = az acr repository show --name $platform.registryName --image "${Repository}:$Tag" --query digest --output tsv
Write-Host "pushed $target ($digest), tag locked"
if ($env:TF_BUILD) { Write-Host "##vso[task.setvariable variable=imageDigest;isOutput=true]$digest" }
