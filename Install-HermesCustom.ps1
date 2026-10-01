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

function Invoke-HermesDoctor {
    # Exit 1 alone also means an uncaught Python exception. Require a fresh,
    # versioned completed report; never classify diagnostic text or tracebacks.
    $PSNativeCommandUseErrorActionPreference = $false
    $tempRoot = if ($env:TMPDIR) { $env:TMPDIR } else { [IO.Path]::GetTempPath() }
    $resultDirectory = Join-Path $tempRoot ('hermes-doctor-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $resultDirectory | Out-Null
    $resultPath = Join-Path $resultDirectory 'completed.json'
    try {
        # Explicit matching scope is essential: a caller-local LASTEXITCODE
        # must not shadow the native process status (or a missing status).
        $global:LASTEXITCODE = $null
        & hermes doctor --result-json $resultPath
        $exitCode = $global:LASTEXITCODE
        if ($null -eq $exitCode) { throw 'hermes doctor did not report an exit code.' }
        if ($exitCode -notin @(0, 1)) { throw "hermes failed with exit code $exitCode (hermes doctor)" }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw "hermes doctor did not produce a completed diagnostic result (exit code $exitCode)."
        }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if (($result.schema_version -isnot [int] -and $result.schema_version -isnot [long]) -or
            $result.schema_version -ne 1 -or $result.command -cne 'doctor' -or
            $result.completed -isnot [bool] -or -not $result.completed -or
            ($result.exit_code -isnot [int] -and $result.exit_code -isnot [long]) -or
            $result.exit_code -ne $exitCode -or
            $result.issues -isnot [array] -or $result.manual_issues -isnot [array] -or
            @(@($result.issues) + @($result.manual_issues) | Where-Object { $_ -isnot [string] }).Count -gt 0 -or
            ($result.fixed -isnot [int] -and $result.fixed -isnot [long]) -or $result.fixed -ne 0 -or
            [int][bool]($result.issues.Count + $result.manual_issues.Count) -ne $exitCode) {
            throw 'hermes doctor returned an invalid completed diagnostic result.'
        }
        if ($exitCode -eq 1) {
            Write-Warning 'Hermes Custom is installed, but hermes doctor reported unresolved diagnostic issues (exit code 1). Review the report above; no automatic repairs were run.'
        }
        $global:LASTEXITCODE = 0
    } finally {
        Remove-Item -LiteralPath $resultDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-GitFetchWithRetry([scriptblock]$Command, [int]$RetryDelayMilliseconds = 1000) {
    # An old Desktop's passive update check can advance origin/main while the
    # installer fetch is still expecting its prior SHA. Only retry that ref
    # compare-and-swap failure; auth/network errors still stop installation.
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    foreach ($attempt in 1..3) {
        # If Git cannot be started, no native exit code will be written.
        $global:LASTEXITCODE = 1
        $output = @(& $Command 2>&1)
        $exitCode = $LASTEXITCODE
        $output | ForEach-Object { Write-Output "$_" }
        $refRace = ($output -join "`n") -match '(?im)(fetching ref .* failed: incorrect old value provided|cannot lock ref .*: is at [0-9a-f]+ but expected [0-9a-f]+)'
        if ($exitCode -eq 0 -or -not $refRace -or $attempt -eq 3) {
            $global:LASTEXITCODE = $exitCode
            return
        }
        Write-Warning "A concurrent update check changed the Git tracking ref; retrying fetch (attempt $($attempt + 1) of 3)."
        if ($RetryDelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $RetryDelayMilliseconds }
    }
}

function ConvertTo-RetryingInstallerScript([string]$Source) {
    # Wrap only upstream's repository fetch. Never retry the entire installer:
    # dependency/setup/build stages must not run twice after partial success.
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "The official Hermes installer could not be parsed." }
    $fetches = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'git' -and
            @($node.CommandElements | Where-Object { $_.Extent.Text -eq 'fetch' }).Count -gt 0
    }, $true))
    if ($fetches.Count -ne 1 -or $fetches[0].Extent.Text -notmatch '^git\s+-C\s+\$InstallDir\s+fetch\s+origin\s+') {
        throw "The official Hermes installer repository fetch contract changed; refusing to alter an unknown command."
    }
    $fetch = $fetches[0].Extent
    $adapted = $Source.Substring(0, $fetch.StartOffset) +
        'Invoke-GitFetchWithRetry { ' + $fetch.Text + ' }' +
        $Source.Substring($fetch.EndOffset)
    return [scriptblock]::Create($adapted)
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
$officialScript = ConvertTo-RetryingInstallerScript ([string]$officialInstaller)
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
    Invoke-HermesDoctor
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
