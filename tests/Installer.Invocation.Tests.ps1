$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot '..\Install-HermesCustom.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('hermes-wrapper-test-' + [guid]::NewGuid().ToString('N'))
$oldRepo = $env:HERMES_REPO_URL
$oldHome = $env:HERMES_HOME
$global:WrapperCalls = 0
$global:WrapperCommands = @()
$global:WrapperFailure = $false
$global:WrapperNativeFailure = ''
$global:WrapperHome = $root
$global:WrapperInstaller = @'
[CmdletBinding()]
param([string]$Branch, [string]$HermesHome, [string]$InstallDir, [switch]$NonInteractive, [switch]$IncludeDesktop, [switch]$SkipBrowser, [switch]$SkipComputerUse)
$global:WrapperCalls++
if ($env:HERMES_REPO_URL -ne 'https://github.com/example/custom.git') { throw 'wrong repository environment' }
if ($Branch -ne 'custom' -or -not $NonInteractive -or -not $SkipBrowser -or -not $SkipComputerUse) { throw 'wrong official parameters' }
if ([bool]$IncludeDesktop -ne [bool]$global:WrapperDesktop) { throw 'wrong Desktop request' }
if ($IncludeDesktop -and -not $global:WrapperMissingDesktop) {
    $desktop = Join-Path $InstallDir 'apps/desktop/release/win-unpacked'
    New-Item -ItemType Directory -Force -Path $desktop | Out-Null
    Set-Content (Join-Path $desktop 'Hermes.exe') 'fixture'
}
if ($global:WrapperFailure) { $global:LASTEXITCODE = 1; return }
git -C $InstallDir fetch origin "+refs/heads/${Branch}:refs/remotes/origin/${Branch}"
if ($LASTEXITCODE) { throw 'fixture fetch failed' }
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir '.git') | Out-Null
foreach ($file in @('pm/lock.json', 'pm/cli.py', 'hermes_cli/source_completion.py', 'scripts/desktop-update/runtime.ps1')) {
    $path = Join-Path $InstallDir $file
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    Set-Content -LiteralPath $path -Value '{}'
}
$global:LASTEXITCODE = 0
'@
function Invoke-WebRequest { [pscustomobject]@{ Content = $global:WrapperInstaller } }
function git {
    $global:LASTEXITCODE = 0
    if ($args -contains 'get-url') { return 'https://github.com/example/custom.git' }
    if ($args -contains '--abbrev-ref') { return 'custom' }
}
function hermes {
    $global:WrapperCommands += ($args -join ' ')
    $global:LASTEXITCODE = $(if (($args -join ' ') -eq $global:WrapperNativeFailure) { 7 } else { 0 })
}
function Start-Process { throw 'NoLaunch must not launch anything' }
try {
    $env:HERMES_REPO_URL = 'caller-repo'
    $env:HERMES_HOME = 'caller-home'
    & $installer -Repository example/custom -Ref custom -HermesHome $root -SkipSetup -NoDesktop -NoLaunch -SkipBrowser -SkipComputerUse
    if ($global:WrapperCalls -ne 1) { throw "Expected one official pass; got $global:WrapperCalls" }
    if (($global:WrapperCommands -join ',') -ne '--version,doctor') { throw 'missing verification commands' }
    if ($env:HERMES_REPO_URL -ne 'caller-repo' -or $env:HERMES_HOME -ne 'caller-home') { throw 'caller environment not restored' }
    $global:WrapperFailure = $true
    $global:WrapperCommands = @()
    $caught = $false
    try { & $installer -Repository example/custom -Ref custom -HermesHome $root -NoDesktop -NoLaunch -SkipBrowser -SkipComputerUse } catch {
        if ($_ -notmatch 'official.*exit code 1') { throw }
        $caught = $true
    }
    if (-not $caught -or $global:WrapperCommands.Count) { throw 'official failure must stop setup and verification' }
    if ($env:HERMES_REPO_URL -ne 'caller-repo' -or $env:HERMES_HOME -ne 'caller-home') { throw 'failure did not restore caller environment' }
    $global:WrapperFailure = $false
    foreach ($command in @('setup', '--version', 'doctor')) {
        $global:WrapperNativeFailure = $command
        $caught = $false
        try { & $installer -Repository example/custom -Ref custom -HermesHome $root -NoDesktop -NoLaunch -SkipBrowser -SkipComputerUse } catch {
            if ($_ -notmatch 'hermes failed with exit code 7') { throw }
            $caught = $true
        }
        if (-not $caught) { throw "Failure of $command was ignored" }
    }
    $global:WrapperNativeFailure = ''
    $global:WrapperDesktop = $true
    & $installer -Repository example/custom -Ref custom -HermesHome $root -SkipSetup -NoLaunch -SkipBrowser -SkipComputerUse
    Remove-Item -Recurse -Force (Join-Path $root 'hermes-agent/apps')
    $global:WrapperMissingDesktop = $true
    $caught = $false
    try { & $installer -Repository example/custom -Ref custom -HermesHome $root -SkipSetup -NoLaunch -SkipBrowser -SkipComputerUse } catch {
        if ($_ -notmatch 'Desktop build produced no Hermes.exe') { throw }
        $caught = $true
    }
    if (-not $caught) { throw 'missing Desktop artifact was ignored' }
    Write-Output 'wrapper invocation and failure propagation checks passed'
} finally {
    $env:HERMES_REPO_URL = $oldRepo
    $env:HERMES_HOME = $oldHome
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    Remove-Item Function:Invoke-WebRequest, Function:git, Function:hermes, Function:Start-Process
}
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $installer), [ref]$null, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$officialPath = Join-Path $PSScriptRoot '..\.work\official-install.ps1'
if (Test-Path $officialPath) {
    $officialAst = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $officialPath), [ref]$null, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $names = @($officialAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    foreach ($name in @('Branch', 'HermesHome', 'InstallDir', 'NonInteractive', 'IncludeDesktop', 'SkipBrowser', 'SkipComputerUse')) {
        if ($names -notcontains $name) { throw "Official installer no longer supports $name" }
    }
    if ((Get-Content $officialPath -Raw) -notmatch 'HERMES_REPO_URL') { throw 'official repository override missing' }
    Write-Output 'downloaded official installer parameter contract passed'
}
Write-Output 'PowerShell parser passed'
