@{
    RootModule        = 'TradeOps.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '5b0c8f0e-6a3d-4f7b-9d2e-1c4a7e9b3f21'
    Author            = 'Azure TradeOps'
    Description       = 'Release, verification and rollback tooling for the Azure TradeOps platform.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Get-PlatformOutput'
        'Test-TradeOpsEnvironment'
        'Invoke-PlatformDeployment'
        'Get-ContainerAppTraffic'
        'Get-StableRevision'
        'Set-TrafficConfiguration'
        'Wait-RevisionReady'
        'Invoke-SmokeTest'
        'Measure-CanaryHealth'
        'Import-ReleaseImage'
        'Publish-ApiRevision'
        'Invoke-CanaryRelease'
        'Invoke-Promotion'
        'Invoke-Rollback'
        'Publish-WorkerRelease'
        'Get-TradeOpsStatus'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
