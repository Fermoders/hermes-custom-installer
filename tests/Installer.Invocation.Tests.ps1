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
function Write-DoctorFixture($Arguments, [int]$Code) {
    if ($Arguments[0] -ne 'doctor') { return }
    if ($Arguments.Count -ne 3 -or $Arguments[1] -ne '--result-json') { throw 'unexpected doctor arguments' }
    @{ schema_version = 1; command = 'doctor'; completed = $true; exit_code = $Code;
       issues = @($(if ($Code -eq 1) { 'fixture unresolved diagnostic issue' }));
       manual_issues = @(); fixed = 0 } | ConvertTo-Json -Compress | Set-Content -LiteralPath $Arguments[2] -Encoding UTF8
}
function hermes {
    $command = if ($args[0] -eq 'doctor') { 'doctor' } else { $args -join ' ' }
    $global:WrapperCommands += $command
    $global:LASTEXITCODE = $(if ($command -eq $global:WrapperNativeFailure) { 7 } else { 0 })
    Write-DoctorFixture $args $global:LASTEXITCODE
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
    function hermes {
        $global:WrapperCommands += $(if ($args[0] -eq 'doctor') { 'doctor' } else { $args -join ' ' })
        $global:LASTEXITCODE = $(if ($args[0] -eq 'doctor') { 1 } else { 0 })
        Write-DoctorFixture $args $global:LASTEXITCODE
        if ($args[0] -eq 'doctor') { Write-Output 'fixture unresolved diagnostic issue' }
    }
    $global:WrapperCommands = @()
    $report = @(& $installer -Repository example/custom -Ref custom -HermesHome $root -SkipSetup -NoDesktop -NoLaunch -SkipBrowser -SkipComputerUse 3>&1)
    if (($global:WrapperCommands -join ',') -ne '--version,doctor') { throw 'diagnostic verification commands changed' }
    if (($report -join "`n") -notmatch 'fixture unresolved diagnostic issue') { throw 'doctor report was hidden' }
    if (-not @($report | Where-Object { $_ -is [Management.Automation.WarningRecord] -and $_ -match 'installed.*diagnostic' }).Count) { throw 'diagnostic issues need an installation-success warning' }
    if ($LASTEXITCODE -ne 0) { throw 'handled doctor findings left a failed installer exit status' }
    if ($env:HERMES_REPO_URL -ne 'caller-repo' -or $env:HERMES_HOME -ne 'caller-home') { throw 'diagnostic issues did not restore caller environment' }
    function hermes {
        $global:WrapperCommands += ($args -join ' ')
        $global:LASTEXITCODE = 0
    }
    $global:WrapperDesktop = $true
    $global:WrapperLaunches = 0
    function Start-Process {
        if ($args[0] -ne 'hermes' -or $args[-1] -ne 'desktop') { throw 'unexpected launch request' }
        $global:WrapperLaunches++
    }
    function hermes {
        $global:WrapperCommands += $(if ($args[0] -eq 'doctor') { 'doctor' } else { $args -join ' ' })
        $global:LASTEXITCODE = $(if ($args[0] -eq 'doctor') { 1 } else { 0 })
        Write-DoctorFixture $args $global:LASTEXITCODE
    }
    & $installer -Repository example/custom -Ref custom -HermesHome $root -SkipSetup -SkipBrowser -SkipComputerUse
    if ($global:WrapperLaunches -ne 1) { throw 'doctor findings prevented Desktop launch' }
    function hermes {
        if ($args[0] -eq 'doctor') { & python -c "raise RuntimeError('fixture doctor crash')" }
        else { $global:LASTEXITCODE = 0 }
    }
    $caught = $false
    try { & $installer -Repository example/custom -Ref custom -HermesHome $root -SkipSetup -SkipBrowser -SkipComputerUse } catch {
        if ($_ -notmatch 'did not produce a completed diagnostic result.*exit code 1') { throw }
        $caught = $true
    }
    if (-not $caught -or $global:WrapperLaunches -ne 1) { throw 'Python crash allowed Desktop launch' }
    function hermes {
        $global:LASTEXITCODE = $(if ($args[0] -eq 'doctor') { 1 } else { 0 })
        Write-DoctorFixture $args $global:LASTEXITCODE
    }
    function Start-Process { throw 'fixture Desktop launch failed' }
    $caught = $false
    try { & $installer -Repository example/custom -Ref custom -HermesHome $root -SkipSetup -SkipBrowser -SkipComputerUse } catch {
        if ($_ -notmatch 'fixture Desktop launch failed') { throw }
        $caught = $true
    }
    if (-not $caught) { throw 'Desktop launch failure was ignored' }
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

# Exercise the real native boundary without running Hermes or the installer.
$definition = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-HermesDoctor' }, $true)
if (-not $definition) { throw 'Missing doctor helper' }
Invoke-Expression $definition.Extent.Text
$oldNativePreference = $PSNativeCommandUseErrorActionPreference
try {
    $PSNativeCommandUseErrorActionPreference = $true
    function hermes {
        Write-DoctorFixture $args $global:DoctorExit
        & cmd.exe /d /c "echo fixture-doctor-report & exit /b $global:DoctorExit"
    }
    foreach ($code in @(0, 1, 2, 7, 23)) {
        $global:DoctorExit = $code
        $caught = $false
        try { $report = @(Invoke-HermesDoctor 3>&1) } catch {
            if ($_ -notmatch "hermes failed with exit code $code") { throw }
            $caught = $true
        }
        if ($caught -ne ($code -gt 1)) { throw "Wrong diagnostic policy for exit $code" }
        if ($code -le 1) {
            if ($LASTEXITCODE -ne 0 -or ($report -join "`n") -notmatch 'fixture-doctor-report') { throw 'status or report lost' }
            if (@($report | Where-Object { $_ -is [Management.Automation.WarningRecord] }).Count -ne [int]($code -eq 1)) { throw 'wrong warning count' }
        }
        if ($PSNativeCommandUseErrorActionPreference -ne $true -or $ErrorActionPreference -ne 'Stop') { throw 'caller preferences changed' }
    }
    function hermes { & python -c "raise RuntimeError('fixture doctor crash')" }
    $caught = $false
    try { Invoke-HermesDoctor } catch { $caught = $true }
    if (-not $caught) { throw 'Python RuntimeError exit1 accepted as completed diagnostics' }
    function hermes { 'no exit status' }
    function Probe {
        $LASTEXITCODE = 0
        $caught = $false
        try { Invoke-HermesDoctor | Out-Null } catch {
            if ($_ -notmatch 'did not report an exit code') { throw }
            $caught = $true
        }
        if (-not $caught) { throw 'caller-local stale0 accepted as doctor success' }
    }
    Probe
    foreach ($invalid in @('missing', 'partial', 'not-completed', 'wrong-status', 'string-status')) {
        $global:DoctorInvalid = $invalid
        function hermes {
            if ($global:DoctorInvalid -eq 'partial') { Set-Content -LiteralPath $args[2] '{' }
            elseif ($global:DoctorInvalid -ne 'missing') {
                $data = @{ schema_version = 1; command = 'doctor'; completed = $true; exit_code = 1;
                    issues = @('fixture finding'); manual_issues = @(); fixed = 0 }
                if ($global:DoctorInvalid -eq 'not-completed') { $data.completed = $false }
                if ($global:DoctorInvalid -eq 'wrong-status') { $data.exit_code = 0 }
                if ($global:DoctorInvalid -eq 'string-status') { $data.exit_code = '1' }
                $data | ConvertTo-Json -Compress | Set-Content -LiteralPath $args[2] -Encoding UTF8
            }
            & cmd.exe /d /c 'exit /b 1'
        }
        function ProbeInvalid {
            $LASTEXITCODE = 0
            $caught = $false
            try { Invoke-HermesDoctor | Out-Null } catch { $caught = $true }
            if (-not $caught) { throw "Invalid completed result accepted: $global:DoctorInvalid" }
        }
        ProbeInvalid
    }
    foreach ($stale in @(0, 1)) {
        function hermes { & nonexistent-hermes-doctor-test-command }
        $global:LASTEXITCODE = $stale
        $caught = $false
        try { Invoke-HermesDoctor } catch [Management.Automation.CommandNotFoundException] { $caught = $true }
        if (-not $caught) { throw 'doctor launch failure ignored' }
        function hermes { Write-Output 'fixture without status' }
        $global:LASTEXITCODE = $stale
        $caught = $false
        try { Invoke-HermesDoctor | Out-Null } catch {
            if ($_ -notmatch 'did not report an exit code') { throw }
            $caught = $true
        }
        if (-not $caught) { throw 'stale diagnostic status accepted' }
    }
    function hermes { throw 'fixture doctor invocation failed' }
    $caught = $false
    try { Invoke-HermesDoctor } catch {
        if ($_ -notmatch 'fixture doctor invocation failed') { throw }
        $caught = $true
    }
    if (-not $caught) { throw 'doctor invocation exception ignored' }
    $nativeDefinition = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Native' }, $true)
    Invoke-Expression $nativeDefinition.Extent.Text
    function hermes { $global:LASTEXITCODE = 1 }
    foreach ($command in @('setup', '--version')) {
        $caught = $false
        try { Invoke-Native 'hermes' @($command) } catch {
            if ($_ -notmatch 'hermes failed with exit code 1') { throw }
            $caught = $true
        }
        if (-not $caught) { throw "diagnostic policy leaked into $command" }
    }
    Write-Output 'native doctor exit policy, launch failures, stale status and caller preferences passed'
} finally {
    $PSNativeCommandUseErrorActionPreference = $oldNativePreference
    Remove-Item Function:hermes
}
$global:LASTEXITCODE = 0 # Expected failure probes above must not fail the CI shell.
