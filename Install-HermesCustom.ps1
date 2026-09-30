[CmdletBinding()]
param(
    [string]$Repository = "Fermoders/hermes-agent",
    [string]$Ref = "main",
    [string]$HermesHome = $(if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $env:LOCALAPPDATA "hermes" }),
    [switch]$SkipSetup,
    [switch]$NoDesktop,
    [switch]$NoLaunch,
    [switch]$SkipBrowser,
    [switch]$SkipComputerUse,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Invoke-Native([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory = "") {
    $previous = Get-Location
    try {
        if ($WorkingDirectory) { Set-Location $WorkingDirectory }
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$FilePath failed with exit code $LASTEXITCODE"
        }
    } finally {
        Set-Location $previous
    }
}

function Save-ManagedCheckoutChanges([string]$RepositoryPath) {
    $status = @(& git -c windows.appendAtomically=false -C $RepositoryPath status --porcelain 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect the existing Hermes checkout."
    }
    if ([string]::IsNullOrWhiteSpace(($status -join "`n"))) {
        return ""
    }

    $stashName = "hermes-custom-installer-backup-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    Write-Warning "Local changes were found in the managed Hermes checkout."
    Write-Warning "They will be saved before switching to the custom fork."
    $stashOutput = @(& git -c windows.appendAtomically=false -C $RepositoryPath stash push --include-untracked -m $stashName)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not save the existing Hermes checkout changes in Git stash."
    }

    $stashRef = (& git -c windows.appendAtomically=false -C $RepositoryPath stash list --format="%gd%x09%s" | Where-Object {
        $_ -like "*$stashName*"
    } | Select-Object -First 1) -replace "`t.*$", ""
    if (-not $stashRef) {
        throw "Git reported a successful stash, but the recovery stash could not be located."
    }

    $remaining = @(& git -c windows.appendAtomically=false -C $RepositoryPath status --porcelain)
    if ($LASTEXITCODE -ne 0 -or -not [string]::IsNullOrWhiteSpace(($remaining -join "`n"))) {
        throw "The recovery stash was created, but the managed checkout is not clean; refusing to switch sources."
    }

    Write-Warning "Saved existing changes in $stashRef ($stashName)."
    Write-Warning "The custom fork already contains the maintained fixes; the backup is kept for manual recovery."
    return ,$stashRef
}

if (-not $env:LOCALAPPDATA) {
    throw "LOCALAPPDATA is not available; this installer requires native Windows PowerShell."
}

$HermesHome = [System.IO.Path]::GetFullPath($HermesHome)
$InstallDir = Join-Path $HermesHome "hermes-agent"
$RepositoryUrl = if ($Repository -match '^(https?|git@)') {
    $Repository
} else {
    "https://github.com/$Repository.git"
}

Write-Host "Hermes Custom Installer" -ForegroundColor Magenta
Write-Host "Repository: $RepositoryUrl"
Write-Host "Ref:        $Ref"
Write-Host "Install:    $InstallDir"

# Preserve legacy hand edits before upstream retargets the checkout. Upstream owns
# clone/update and creates durable recovery refs for displaced local commits.
$savedCheckoutStash = ""
if (Test-Path (Join-Path $InstallDir ".git")) {
    if ($Force) {
        Invoke-Native "git" @("-C", $InstallDir, "reset", "--hard")
        Invoke-Native "git" @("-C", $InstallDir, "clean", "-fd")
    } else {
        $savedCheckoutStash = Save-ManagedCheckoutChanges $InstallDir
    }
}

Write-Step "Installing the custom source with the official Hermes installer"
$officialInstallerResponse = Invoke-WebRequest -UseBasicParsing "https://hermes-agent.nousresearch.com/install.ps1"
$officialInstaller = $officialInstallerResponse.Content
if (-not $officialInstaller -and $officialInstallerResponse.RawContentStream) {
    $reader = New-Object System.IO.StreamReader($officialInstallerResponse.RawContentStream)
    $officialInstaller = $reader.ReadToEnd()
}
if (-not $officialInstaller) {
    throw "The official Hermes installer downloaded successfully but contained no script text."
}
$officialScript = [scriptblock]::Create([string]$officialInstaller)
$officialArgs = @{
    HermesHome = $HermesHome
    InstallDir = $InstallDir
    Branch = $Ref
    NonInteractive = $true
    SkipBrowser = [bool]$SkipBrowser
    SkipComputerUse = [bool]$SkipComputerUse
}
if (-not $NoDesktop) { $officialArgs.IncludeDesktop = $true }
$previousRepoUrl = $env:HERMES_REPO_URL
$previousHermesHome = $env:HERMES_HOME
try {
    $env:HERMES_REPO_URL = $RepositoryUrl
    $env:HERMES_HOME = $HermesHome
    # Dynamically invoked upstream reports caught failures via LASTEXITCODE.
    $global:LASTEXITCODE = 0
    & $officialScript @officialArgs
    if ($LASTEXITCODE -ne 0) {
        throw "The official Hermes installer failed with exit code $LASTEXITCODE."
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "The official installer completed, but git is still unavailable."
    }
    $origin = & git -C $InstallDir remote get-url origin
    if ($LASTEXITCODE -ne 0 -or $origin -ne $RepositoryUrl) {
        throw "Installed source origin does not match $RepositoryUrl."
    }
    $branch = & git -C $InstallDir rev-parse --abbrev-ref HEAD
    if ($LASTEXITCODE -ne 0 -or $branch -ne $Ref) {
        throw "Installed source branch does not match $Ref."
    }
    foreach ($file in @('pm/lock.json', 'pm/cli.py', 'hermes_cli/source_completion.py', 'scripts/desktop-update/runtime.ps1')) {
        if (-not (Test-Path (Join-Path $InstallDir $file))) {
            throw "Installed fork lacks the current PM/source-completion contract: $file"
        }
    }
    if (-not $NoDesktop) {
        $artifacts = @('win-unpacked', 'win-ia32-unpacked', 'win-arm64-unpacked') | Where-Object {
            Test-Path (Join-Path $InstallDir "apps/desktop/release/$_/Hermes.exe")
        }
        if (-not $artifacts) { throw "The requested Desktop build produced no Hermes.exe." }
    }

    if (-not $SkipSetup) {
        Write-Step "Opening Hermes setup"
        Invoke-Native "hermes" @("setup")
    }
    Write-Step "Verifying the installation"
    Invoke-Native "hermes" @("--version")
    Invoke-Native "hermes" @("doctor") # hermes doctor
    if (-not $NoDesktop -and -not $NoLaunch) {
        Write-Step "Launching Hermes Desktop"
        Start-Process "hermes" -ArgumentList "desktop"
    }
} finally {
    $env:HERMES_REPO_URL = $previousRepoUrl
    $env:HERMES_HOME = $previousHermesHome
}

Write-Host "`nHermes Custom is installed." -ForegroundColor Green
Write-Host "Source: $RepositoryUrl@$Ref"
Write-Host "Update: rerun this same command."
if ($savedCheckoutStash) {
    Write-Host "Previous local changes are preserved in: $savedCheckoutStash" -ForegroundColor Yellow
    Write-Host "Inspect them with: git -C `"$InstallDir`" stash show --stat $savedCheckoutStash"
}
