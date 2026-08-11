$ErrorActionPreference = "Stop"

$installerPath = Join-Path $PSScriptRoot "..\Install-HermesCustom.ps1"
$source = Get-Content -LiteralPath $installerPath -Raw
$invokeStart = $source.IndexOf("function Invoke-Native")
$start = $source.IndexOf("function Save-ManagedCheckoutChanges")
$end = $source.IndexOf("`nif (-not `$env:LOCALAPPDATA)", $start)
if ($invokeStart -lt 0 -or $start -lt $invokeStart -or $end -le $start) {
    throw "Could not extract checkout preservation helpers from the installer."
}
Invoke-Expression $source.Substring($invokeStart, $end - $invokeStart)

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-installer-test-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    & git -C $root init --quiet
    & git -C $root config user.name "Hermes Installer Test"
    & git -C $root config user.email "installer-test@example.invalid"
    Set-Content -LiteralPath (Join-Path $root "tracked.txt") -Value "before" -NoNewline
    & git -C $root add tracked.txt
    & git -C $root commit --quiet -m initial

    Set-Content -LiteralPath (Join-Path $root "tracked.txt") -Value "after" -NoNewline
    Set-Content -LiteralPath (Join-Path $root "untracked.txt") -Value "new" -NoNewline

    $stashRef = Save-ManagedCheckoutChanges $root
    if (-not $stashRef) { throw "Expected a recovery stash for the dirty repository." }
    $status = @(& git -C $root status --porcelain)
    if (-not [string]::IsNullOrWhiteSpace(($status -join "`n"))) {
        throw "Managed checkout was not clean after saving local changes: $($status -join ', ')"
    }
    $stashEntry = @(& git -C $root stash list --format="%gd%x09%s") | Where-Object { $_ -like "$stashRef`t*" } | Select-Object -First 1
    if ($stashEntry -notlike "*hermes-custom-installer-backup-*") {
        throw "Recovery stash does not carry the expected installer marker."
    }
    $stashFiles = @(& git -C $root stash show --include-untracked --name-only $stashRef)
    if ($stashFiles -notcontains "tracked.txt" -or $stashFiles -notcontains "untracked.txt") {
        throw "Recovery stash did not preserve tracked and untracked changes."
    }

    Write-Output "managed checkout functional preservation passed"
} finally {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
