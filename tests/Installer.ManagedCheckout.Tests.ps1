$ErrorActionPreference = "Stop"

$installerPath = Join-Path $PSScriptRoot "..\Install-HermesCustom.ps1"
$installer = Get-Content -LiteralPath $installerPath -Raw

if ($installer -notmatch 'function\s+Save-ManagedCheckoutChanges') {
    throw "Installer must save managed checkout changes before switching forks."
}
if ($installer -notmatch 'hermes-custom-installer-backup-') {
    throw "Installer must create a named recovery stash for local changes."
}
if ($installer -notmatch 'stash\s+push\s+--include-untracked') {
    throw "Installer must preserve untracked files as well as tracked modifications."
}
if ($installer -match 'The Hermes checkout contains local changes\. Commit/stash them or re-run with -Force\.') {
    throw "Installer still aborts on the exact dirty-checkout error reported by the user."
}

Write-Output "managed checkout preservation checks passed"
