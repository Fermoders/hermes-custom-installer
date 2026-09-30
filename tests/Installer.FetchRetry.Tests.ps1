$ErrorActionPreference = 'Stop'
$installerPath = Join-Path $PSScriptRoot '..\Install-HermesCustom.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $installerPath), [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Invoke-GitFetchWithRetry', 'ConvertTo-RetryingInstallerScript')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Installer is missing the fetch-race helper: $name" }
    Invoke-Expression $definition.Extent.Text
}

$global:FetchRetryCalls = 0
$global:FetchRetryRaceAttempts = 1
$global:FetchRetryFailure = ''
$global:FetchRetryInvocationFailure = $false
function git {
    $global:FetchRetryCalls++
    if ($global:FetchRetryInvocationFailure) {
        nonexistent-hermes-git-command fetch origin main
    } elseif ($global:FetchRetryFailure) {
        Write-Output $global:FetchRetryFailure
        $global:LASTEXITCODE = 1
    } elseif ($global:FetchRetryCalls -le $global:FetchRetryRaceAttempts) {
        Write-Output 'error: fetching ref refs/remotes/origin/main failed: incorrect old value provided'
        $global:LASTEXITCODE = 1
    } else {
        Write-Output 'fetch succeeded'
        $global:LASTEXITCODE = 0
    }
}
try {
    $fixture = @'
param([string]$InstallDir, [string]$Branch)
$global:FetchRetryStages++
git -C $InstallDir fetch origin "+refs/heads/${Branch}:refs/remotes/origin/${Branch}"
if ($LASTEXITCODE) { throw 'fetch failed' }
$global:FetchRetryTail++
'@
    $global:FetchRetryStages = 0
    $global:FetchRetryTail = 0
    $official = ConvertTo-RetryingInstallerScript $fixture
    $output = @(& $official -InstallDir 'fixture' -Branch 'main')
    if ($global:FetchRetryCalls -ne 2 -or $LASTEXITCODE -ne 0) { throw 'ref race was not retried successfully' }
    if ($global:FetchRetryStages -ne 1 -or $global:FetchRetryTail -ne 1) { throw 'retry reran stages instead of only fetch' }
    if (($output -join "`n") -notmatch 'fetch succeeded') { throw 'native fetch output was lost' }

    $global:FetchRetryCalls = 0
    $global:FetchRetryRaceAttempts = 2
    Invoke-GitFetchWithRetry { git fetch origin main } -RetryDelayMilliseconds 0 | Out-Null
    if ($global:FetchRetryCalls -ne 3 -or $LASTEXITCODE -ne 0) { throw 'ref race did not recover on the last permitted attempt' }
    $global:FetchRetryRaceAttempts = 1

    $global:FetchRetryCalls = 1
    $global:FetchRetryStages = 0
    $global:FetchRetryTail = 0
    & $official -InstallDir 'fixture' -Branch 'main' | Out-Null
    if ($global:FetchRetryCalls -ne 2 -or $global:FetchRetryStages -ne 1 -or $global:FetchRetryTail -ne 1) { throw 'successful fetch was unnecessarily retried' }

    $global:FetchRetryCalls = 0
    $global:FetchRetryTail = 0
    $global:FetchRetryFailure = 'fatal: unable to access remote'
    $caught = $false
    try { & $official -InstallDir 'fixture' -Branch 'main' | Out-Null } catch {
        if ($_ -notmatch 'fetch failed') { throw }
        $caught = $true
    }
    if (-not $caught -or $global:FetchRetryCalls -ne 1 -or $global:FetchRetryTail -ne 0) { throw 'adapted installer continued after a failed fetch' }
    $global:FetchRetryFailure = ''

    try {
        Invoke-GitFetchWithRetry { nonexistent-hermes-git-command fetch origin main } -RetryDelayMilliseconds 0 | Out-Null
    } catch [Management.Automation.CommandNotFoundException] {
        # A terminating launch failure may propagate, but must never leave 0.
    }
    if ($LASTEXITCODE -eq 0) { throw 'a missing fetch command must not be reported as successful' }

    $global:FetchRetryCalls = 0
    $global:FetchRetryTail = 0
    $global:FetchRetryInvocationFailure = $true
    $caught = $false
    try { & $official -InstallDir 'fixture' -Branch 'main' | Out-Null } catch {
        if ($_ -notmatch 'fetch failed' -and $_.Exception -isnot [Management.Automation.CommandNotFoundException]) { throw }
        $caught = $true
    } finally {
        $global:FetchRetryInvocationFailure = $false
    }
    if (-not $caught -or $LASTEXITCODE -eq 0 -or $global:FetchRetryCalls -ne 1 -or $global:FetchRetryTail -ne 0) { throw 'invocation failure retried or allowed the adapted installer tail' }

    foreach ($failure in @(
        'fatal: could not read Username for https://example.invalid',
        'fatal: unable to access https://example.invalid: Could not resolve host',
        "fatal: Unable to create 'index.lock': File exists"
    )) {
        $global:FetchRetryCalls = 0
        $global:FetchRetryFailure = $failure
        Invoke-GitFetchWithRetry { git fetch origin main } -RetryDelayMilliseconds 0 | Out-Null
        if ($global:FetchRetryCalls -ne 1 -or $LASTEXITCODE -ne 1) { throw 'non-ref-race error must fail without retries' }
    }
    foreach ($race in @(
        'error: fetching ref refs/remotes/origin/main failed: incorrect old value provided',
        "error: cannot lock ref 'refs/remotes/origin/main': is at aaa but expected bbb"
    )) {
        $global:FetchRetryCalls = 0
        $global:FetchRetryFailure = $race
        Invoke-GitFetchWithRetry { git fetch origin main } -RetryDelayMilliseconds 0 | Out-Null
        if ($global:FetchRetryCalls -ne 3 -or $LASTEXITCODE -ne 1) { throw 'persistent ref race must stop after three attempts' }
    }
    foreach ($badScript in @('git -C $InstallDir status --short', 'git fetch origin main', 'git -C $OtherDir fetch origin main', ($fixture + "`ngit fetch origin main"))) {
        $caught = $false
        try { ConvertTo-RetryingInstallerScript $badScript | Out-Null } catch {
            if ($_ -notmatch 'repository fetch') { throw }
            $caught = $true
        }
        if (-not $caught) { throw 'changed upstream fetch contract was silently accepted' }
    }
    $caught = $false
    try { ConvertTo-RetryingInstallerScript 'param([string]$Branch' | Out-Null } catch {
        if ($_ -notmatch 'could not be parsed') { throw }
        $caught = $true
    }
    if (-not $caught) { throw 'malformed upstream script was silently accepted' }
    Write-Output 'bounded fetch-race retry and non-retryable failure checks passed'
} finally {
    Remove-Item Function:git
}

# Real native stderr must not be confused with a command that never starts.
$callerErrorPreference = $ErrorActionPreference
$callerNativePreference = $PSNativeCommandUseErrorActionPreference
try {
    $PSNativeCommandUseErrorActionPreference = $true
    $output = @(Invoke-GitFetchWithRetry { & cmd.exe /d /c 'echo harmless-native-stderr 1>&2 & exit /b 0' } -RetryDelayMilliseconds 0)
    if ($LASTEXITCODE -ne 0 -or ($output -join "`n") -notmatch 'harmless-native-stderr') { throw 'zero-exit native stderr was rejected or hidden' }
    Invoke-GitFetchWithRetry { & cmd.exe /d /c 'echo native-failure 1>&2 & exit /b 23' } -RetryDelayMilliseconds 0 | Out-Null
    if ($LASTEXITCODE -ne 23) { throw 'native nonzero exit status was not preserved' }
    if ($ErrorActionPreference -ne $callerErrorPreference -or $PSNativeCommandUseErrorActionPreference -ne $true) { throw 'fetch helper changed caller error preferences' }
    Write-Output 'native stderr, exact exit status and caller preferences checks passed'
} finally {
    $PSNativeCommandUseErrorActionPreference = $callerNativePreference
}

# Each scenario needs a fresh clone: rewinding a ref in a checkout already
# fetched by an earlier scenario may eliminate this race. The upload-pack hook
# advances the tracking ref after fetch reads its expected old SHA.
$gitExe = (Get-Command git -CommandType Application | Select-Object -First 1).Source
$root = Join-Path $PSScriptRoot ('fetch-retry-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
function Run-TestGit([string[]]$Arguments) {
    & $gitExe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Git fixture failed ($LASTEXITCODE)" }
}
function New-FetchRaceFixture([string]$Name) {
    $directory = Join-Path $root $Name
    New-Item -ItemType Directory -Path $directory | Out-Null
    $remote = Join-Path $directory 'remote'
    $checkout = Join-Path $directory 'checkout'
    Run-TestGit @('init', '-q', '-b', 'main', $remote)
    Run-TestGit @('-C', $remote, 'config', 'user.name', 'Installer Test')
    Run-TestGit @('-C', $remote, 'config', 'user.email', 'installer-test@example.invalid')
    Set-Content (Join-Path $remote 'tracked.txt') 'first'
    Run-TestGit @('-C', $remote, 'add', 'tracked.txt')
    Run-TestGit @('-C', $remote, 'commit', '-q', '-m', 'first')
    $initial = (& $gitExe -C $remote rev-parse HEAD).Trim()
    Run-TestGit @('clone', '-q', '--single-branch', '--branch', 'main', $remote, $checkout)
    Set-Content (Join-Path $remote 'tracked.txt') 'second'
    Run-TestGit @('-C', $remote, 'commit', '-q', '-am', 'second')
    $target = (& $gitExe -C $remote rev-parse HEAD).Trim()
    Run-TestGit @('-C', $checkout, 'fetch', '--refmap=', '--no-write-fetch-head', 'origin', 'main')
    $marker = Join-Path $directory 'race-ran'
    $fetchCount = Join-Path $directory 'upload-pack-count.txt'
    $hook = Join-Path $directory 'race-upload-pack.cmd'
    $hookContent = "@echo off`r`necho upload-pack>>`"$fetchCount`"`r`nif not exist `"$marker`" (`r`n  `"$gitExe`" -C `"$checkout`" update-ref refs/remotes/origin/main $target`r`n  type nul > `"$marker`"`r`n)`r`n`"$gitExe`" upload-pack %*`r`n"
    [IO.File]::WriteAllText($hook, $hookContent, [Text.Encoding]::ASCII)
    Run-TestGit @('-C', $checkout, 'config', 'remote.origin.uploadpack', $hook.Replace('\', '/'))
    return @{ Checkout = $checkout; Initial = $initial; Target = $target; FetchCount = $fetchCount }
}
$previousRepoUrl = $env:HERMES_REPO_URL
try {
    $race = New-FetchRaceFixture 'helper'
    $output = @(Invoke-GitFetchWithRetry {
        & $gitExe -C $race.Checkout fetch --no-auto-maintenance origin '+refs/heads/main:refs/remotes/origin/main'
    } -RetryDelayMilliseconds 0)
    if ($LASTEXITCODE -ne 0) { throw 'real ref race did not recover' }
    if (($output -join "`n") -notmatch '(incorrect old value provided|is at .* but expected)') { throw 'fixture never triggered the real ref race' }
    if (@(Get-Content $race.FetchCount).Count -ne 2) { throw 'real ref race must run fetch exactly twice' }
    if ((& $gitExe -C $race.Checkout rev-parse HEAD).Trim() -ne $race.Initial) { throw 'fetch retry changed the local branch' }
    if ((& $gitExe -C $race.Checkout rev-parse refs/remotes/origin/main).Trim() -ne $race.Target) { throw 'tracking ref was not fetched' }
    if ((Get-Content (Join-Path $race.Checkout 'tracked.txt') -Raw).Trim() -ne 'first') { throw 'fetch retry changed worktree files' }
    Write-Output 'real Git ref race recovered without changing HEAD or worktree'

    # Exercise upstream's actual repository stage through the adapted script.
    $officialPath = Join-Path $PSScriptRoot '..\.work\official-install.ps1'
    if (-not (Test-Path $officialPath)) { throw 'Download the official installer to .work/official-install.ps1 before running this test.' }
    $adapted = ConvertTo-RetryingInstallerScript (Get-Content $officialPath -Raw)
    $officialAst = [Management.Automation.Language.Parser]::ParseInput($adapted.ToString(), [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
    foreach ($name in @('Stage-Repository', 'Invoke-Native', 'Invoke-Logged', 'Fail', 'Log', 'Write-Warn', 'Write-Err', 'Write-StatusLine', 'Test-QuietOutput')) {
        $definition = $officialAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if (-not $definition) { throw "Upstream repository stage dependency missing: $name" }
        Invoke-Expression $definition.Extent.Text
    }
    function Ensure-Git { return $true }
    foreach ($quiet in @($false, $true)) {
        function Test-QuietOutput { return $quiet }
        $race = New-FetchRaceFixture "official-stage-$quiet"
        $InstallDir = $race.Checkout
        $HermesHome = $root
        $Branch = 'main'
        $Commit = ''
        $env:HERMES_REPO_URL = $null
        $stageWarnings = @(Stage-Repository 3>&1)
        $attemptCount = @(Get-Content $race.FetchCount).Count
        if ($attemptCount -ne 2) { throw "official stage did not recover a real race with exactly two fetches (got $attemptCount; warnings: $stageWarnings)" }
        if (($stageWarnings -join "`n") -notmatch 'retrying fetch') { throw 'official stage did not report race recovery' }
        if ((& $gitExe -C $race.Checkout rev-parse HEAD).Trim() -ne $race.Target) { throw 'upstream repository stage did not advance HEAD' }
        if ($quiet -and (Get-Content (Join-Path $HermesHome 'logs/install.log') -Raw) -notmatch '(incorrect old value provided|is at .* but expected)') { throw 'interactive install log did not preserve ref-race diagnostic' }
        Write-Output "adapted official repository stage recovered and fast-forwarded successfully (quiet=$quiet)"

        # A real non-retryable Git failure must still stop the official stage.
        $failureRace = New-FetchRaceFixture "official-failure-$quiet"
        $InstallDir = $failureRace.Checkout
        Run-TestGit @('-C', $InstallDir, 'remote', 'set-url', 'origin', (Join-Path $root 'missing-remote'))
        $caught = $false
        try { Stage-Repository | Out-Null } catch {
            if ($_ -notmatch 'git fetch failed') { throw }
            $caught = $true
        }
        if (-not $caught) { throw 'official repository stage continued after a native fetch error' }
        if ((& $gitExe -C $InstallDir rev-parse HEAD).Trim() -ne $failureRace.Initial) { throw 'official stage advanced HEAD after a fetch error' }
        Write-Output "adapted official repository stage retained native failure (quiet=$quiet)"

        # Exhaustion must stop upstream before it inspects/stashes a dirty tree
        # or checks out/merges. Inject only fetch failures; other Git calls run
        # against the disposable checkout through the real executable.
        foreach ($fault in @('persistent-race', 'invocation-failure')) {
            $blockedRace = New-FetchRaceFixture "official-$fault-$quiet"
            $InstallDir = $blockedRace.Checkout
            Set-Content (Join-Path $InstallDir 'tracked.txt') 'local edit'
            Set-Content (Join-Path $InstallDir 'untracked.txt') 'keep me'
            $global:StageFetchFault = $fault
            $global:StageFetchCalls = 0
            $global:StageBlockedCommands = @()
            function git {
                $PSNativeCommandUseErrorActionPreference = $false
                if ($args -contains 'fetch') {
                    $global:StageFetchCalls++
                    if ($global:StageFetchFault -eq 'invocation-failure') {
                        nonexistent-hermes-git-command fetch origin main
                    } else {
                        & cmd.exe /d /c 'echo error: fetching ref refs/remotes/origin/main failed: incorrect old value provided 1>&2 & exit /b 1'
                    }
                } else {
                    foreach ($blocked in @('status', 'stash', 'checkout', 'merge', 'reset')) {
                        if ($args -contains $blocked) { $global:StageBlockedCommands += $blocked }
                    }
                    & $gitExe @args
                }
            }
            $caught = $false
            try { Stage-Repository | Out-Null } catch {
                if ($_ -notmatch 'git fetch failed' -and $_.Exception -isnot [Management.Automation.CommandNotFoundException]) { throw }
                $caught = $true
            } finally {
                Remove-Item Function:git
            }
            $expectedAttempts = if ($fault -eq 'persistent-race') { 3 } else { 1 }
            if (-not $caught -or $LASTEXITCODE -eq 0 -or $global:StageFetchCalls -ne $expectedAttempts) { throw "upstream stage did not propagate $fault with the correct attempt bound" }
            if ($global:StageBlockedCommands.Count) { throw "upstream stage ran post-fetch commands after $fault" }
            if ((& $gitExe -C $InstallDir rev-parse HEAD).Trim() -ne $blockedRace.Initial) { throw 'failed stage changed HEAD' }
            if ((Get-Content (Join-Path $InstallDir 'tracked.txt') -Raw).Trim() -ne 'local edit' -or (Get-Content (Join-Path $InstallDir 'untracked.txt') -Raw).Trim() -ne 'keep me') { throw 'failed stage changed local files' }
            if (& $gitExe -C $InstallDir stash list) { throw 'failed stage stashed local files' }
            Write-Output "adapted official repository stage blocked later commands for $fault (quiet=$quiet)"
        }
    }
} finally {
    $env:HERMES_REPO_URL = $previousRepoUrl
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
