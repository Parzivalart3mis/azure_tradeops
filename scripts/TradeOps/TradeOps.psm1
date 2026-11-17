#Requires -Version 7.2
Set-StrictMode -Version Latest

# Private helpers first (wrappers around az and HTTP that the tests mock), then the public
# functions. Every public function is safe to re-run: deployments are incremental, traffic
# changes are declarative, and a rollback with nothing to roll back is a no-op.
foreach ($folder in 'Private', 'Public') {
    $path = Join-Path $PSScriptRoot $folder
    foreach ($file in Get-ChildItem -Path $path -Filter '*.ps1' -File | Sort-Object Name) {
        . $file.FullName
    }
}
