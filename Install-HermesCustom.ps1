[CmdletBinding()]
param(
    [string]$Repository = "Fermoders/hermes-agent",
    [string]$Ref = "main",
    [string]$HermesHome = $(if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $env:LOCALAPPDATA "hermes" }),
    [switch]$SkipSetup,
    [switch]$NoDesktop,
    [switch]$NoLaunch,
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

Write-Step "Installing the official Hermes prerequisites and CLI"
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
    Branch = "main"
    SkipSetup = $true
}
if (-not $NoDesktop) { $officialArgs.IncludeDesktop = $true }
& $officialScript @officialArgs

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "The official installer completed, but git is still unavailable."
}

Write-Step "Switching the managed checkout to the custom Hermes fork"
$savedCheckoutStash = ""
if (-not (Test-Path (Join-Path $InstallDir ".git"))) {
    if ((Test-Path $InstallDir) -and $Force) {
        Remove-Item -Recurse -Force $InstallDir
    } elseif (Test-Path $InstallDir) {
        throw "The official install directory is not a Git checkout. Re-run with -Force to replace it."
    }
    Invoke-Native "git" @("clone", "--branch", $Ref, $RepositoryUrl, $InstallDir)
} else {
    if ($Force) {
        Invoke-Native "git" @("-C", $InstallDir, "reset", "--hard")
        Invoke-Native "git" @("-C", $InstallDir, "clean", "-fd")
    } else {
        $savedCheckoutStash = Save-ManagedCheckoutChanges $InstallDir
    }
    Invoke-Native "git" @("-C", $InstallDir, "remote", "set-url", "origin", $RepositoryUrl)
    Invoke-Native "git" @("-C", $InstallDir, "fetch", "--prune", "origin", $Ref)
    Invoke-Native "git" @("-C", $InstallDir, "checkout", "-B", $Ref, "FETCH_HEAD")
    Invoke-Native "git" @("-C", $InstallDir, "reset", "--hard", "FETCH_HEAD")
    Invoke-Native "git" @("-C", $InstallDir, "branch", "--set-upstream-to", "origin/$Ref", $Ref)
}
Invoke-Native "git" @("-C", $InstallDir, "config", "core.autocrlf", "false")

Write-Step "Re-running the official installer against the custom source tree"
$customArgs = @{
    HermesHome = $HermesHome
    InstallDir = $InstallDir
    Branch = $Ref
    SkipSetup = $true
}
if (-not $NoDesktop) { $customArgs.IncludeDesktop = $true }
& $officialScript @customArgs

if (-not $SkipSetup) {
    Write-Step "Opening Hermes setup"
    & hermes setup
}

Write-Step "Verifying the installation"
& hermes --version
& hermes doctor

if (-not $NoDesktop -and -not $NoLaunch) {
    Write-Step "Launching Hermes Desktop"
    Start-Process "hermes" -ArgumentList "desktop"
}

Write-Host "`nHermes Custom is installed." -ForegroundColor Green
Write-Host "Source: $RepositoryUrl@$Ref"
Write-Host "Update: rerun this same command."
if ($savedCheckoutStash) {
    Write-Host "Previous local changes are preserved in: $savedCheckoutStash" -ForegroundColor Yellow
    Write-Host "Inspect them with: git -C `"$InstallDir`" stash show --stat $savedCheckoutStash"
}
