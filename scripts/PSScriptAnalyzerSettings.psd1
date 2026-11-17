@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Pipeline-facing scripts deliberately write progress to the host so it shows in
        # Azure Pipelines logs without polluting the objects functions return.
        'PSAvoidUsingWriteHost'
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('7.2') }
    }
}
