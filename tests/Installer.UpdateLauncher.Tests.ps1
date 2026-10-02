$ErrorActionPreference = 'Stop'
$launcher = (Resolve-Path (Join-Path $PSScriptRoot '../Update-HermesCustom-Verified.ps1')).Path
$root = Join-Path $PSScriptRoot ('../.work/update-launcher-test-' + [guid]::NewGuid().ToString('N'))
$oldTemp = $env:TEMP
$callerNativePreference = $PSNativeCommandUseErrorActionPreference
$oldProtocol = [Net.ServicePointManager]::SecurityProtocol
$expectedUri = 'https://raw.githubusercontent.com/Fermoders/hermes-custom-installer/996bd8f86b1446f53279916fbab37bf0728a10a9/Install-HermesCustom.ps1'
$global:LauncherDownloadCalls = 0
$global:LauncherInstallCalls = 0
$global:LauncherMode = ''
$global:LauncherArguments = @()
$global:LauncherFixtureBytes = [Text.Encoding]::UTF8.GetBytes((Get-Content (Join-Path $PSScriptRoot '../Install-HermesCustom.ps1') -Raw).Replace("`r`n", "`n"))
New-Item -ItemType Directory -Path $root | Out-Null
function Invoke-WebRequest {
    param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile)
    $global:LauncherDownloadCalls++
    if (-not $UseBasicParsing -or $Uri -cne $expectedUri) { throw 'Wrong pinned installer download contract' }
    if ($global:LauncherMode -eq 'download-failure') { throw 'Fixture download failed' }
    if ($global:LauncherMode -eq 'hash-mismatch') {
        [IO.File]::WriteAllText($OutFile, '# not the verified installer')
    } else {
        [IO.File]::WriteAllBytes($OutFile, $global:LauncherFixtureBytes)
    }
}
function powershell.exe {
    $global:LauncherInstallCalls++
    $global:LauncherArguments = @($args)
    if ($global:LauncherMode -eq 'launch-failure') { throw 'Fixture process launch failed' }
    if ($global:LauncherMode -eq 'missing-status') { return }
    $global:LASTEXITCODE = if ($global:LauncherMode -eq 'installer-failure') { 7 } else { 0 }
}
try {
    $env:TEMP = (Resolve-Path $root).Path
    foreach ($mode in @('success', 'installer-failure', 'download-failure', 'hash-mismatch', 'launch-failure', 'missing-status')) {
        $global:LauncherMode = $mode
        $global:LauncherDownloadCalls = 0
        $global:LauncherInstallCalls = 0
        $global:LauncherArguments = @()
        $global:LASTEXITCODE = 0
        $caught = ''
        try { & $launcher } catch { $caught = "$_" }
        if ($global:LauncherDownloadCalls -ne 1) { throw 'Launcher must download exactly once' }
        if ($mode -eq 'success') {
            if ($caught -or $global:LASTEXITCODE -ne 0) { throw "Successful fixture failed: $caught" }
        } else {
            $expectedFailure = switch ($mode) {
                'installer-failure' { 'update failed \(exit 7\)' }
                'download-failure' { 'Fixture download failed' }
                'hash-mismatch' { 'SHA-256 mismatch' }
                'launch-failure' { 'Fixture process launch failed' }
                'missing-status' { 'update failed \(exit 1\)' }
            }
            if ($caught -notmatch $expectedFailure) { throw "Wrong failure for ${mode}: $caught" }
        }
        $expectedCalls = if ($mode -in @('download-failure', 'hash-mismatch')) { 0 } else { 1 }
        if ($global:LauncherInstallCalls -ne $expectedCalls) { throw "Wrong installer call count for $mode" }
        if ($expectedCalls) {
            $arguments = $global:LauncherArguments
            if ($arguments.Count -ne 6 -or $arguments[0] -cne '-NoProfile' -or $arguments[1] -cne '-ExecutionPolicy' -or
                $arguments[2] -cne 'Bypass' -or $arguments[3] -cne '-File' -or $arguments[5] -cne '-SkipSetup' -or
                [IO.Path]::GetFileName($arguments[4]) -cne 'Install-HermesCustom.ps1' -or
                [IO.Path]::GetFullPath($arguments[4]) -notlike "$env:TEMP\*") { throw 'Unsafe installer invocation arguments' }
        }
        if (@(Get-ChildItem -LiteralPath $root -Force).Count) { throw "Temporary files not removed after $mode" }
        Write-Output "update launcher behavior passed: $mode"
    }
} finally {
    $env:TEMP = $oldTemp
    [Net.ServicePointManager]::SecurityProtocol = $oldProtocol
    Remove-Item Function:Invoke-WebRequest, Function:powershell.exe
    Remove-Item -LiteralPath $root -Recurse -Force
}
if ($PSNativeCommandUseErrorActionPreference -ne $callerNativePreference) { throw 'Caller native preference changed' }
$global:LASTEXITCODE = 0
Write-Output 'verified update launcher integrity, failure propagation and cleanup passed'
