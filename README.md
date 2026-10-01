# Hermes Custom Installer

One-command Windows installer for the official Nous Research Hermes Agent plus the maintained custom fixes in [`Fermoders/hermes-agent`](https://github.com/Fermoders/hermes-agent).

## Install or update

Run in **PowerShell**:

```powershell
irm https://raw.githubusercontent.com/Fermoders/hermes-custom-installer/main/Install-HermesCustom.ps1 | iex
```

The same command updates an existing installation.

Before updating, close Hermes Desktop, CLI, and gateway processes and run the
installer from a separate PowerShell window. On older builds a passive update
check may race the installer's Git fetch and report `incorrect old value provided`.
The wrapper retries that specific tracking-ref race up to three times without
deleting refs, resetting source files, or rerunning later install stages. Other
Git failures are still reported immediately.

If a previous run stopped at this fetch error, download the wrapper again and
rerun it after closing Hermes. Do not delete `.git`, tracking refs, or the user
data directory: the failed fetch does not require reinstalling from scratch.

If the existing managed checkout contains local edits from an older custom
installation, the installer automatically saves them in a timestamped Git
stash before switching to the maintained fork. It does not require `-Force`
and does not delete the previous work.

## What it installs

1. Saves existing tracked/untracked source edits in a recovery stash unless `-Force` is requested.
2. Runs the official installer once with `HERMES_REPO_URL` set to the custom repository and `Branch` set to `-Ref`.
3. Lets upstream manage checkout recovery, PM-managed Python 3.14, dependencies, source completion, and the requested Desktop build.
4. Checks installer status, source origin/branch, required PM/runtime files, and the requested Desktop artifact.
5. Runs `hermes setup` and `hermes --version`, stopping on failure, then runs `hermes doctor` as a diagnostic report.
6. Launches Hermes Desktop unless disabled, including when doctor reports unresolved findings.

`hermes doctor` returns `0` when no unresolved problems remain and `1` when
its report contains diagnostic issues ([official exit-status contract](https://hermes-agent.nousresearch.com/docs/reference/cli-commands#hermes-doctor)).
The wrapper runs `hermes doctor --result-json <fresh temporary path>` and
preserves the human report. It accepts `0` or `1` only with a valid version-1
JSON result identifying `doctor`, `completed: true`, matching exit status and
findings. A Python crash returning `1` without that result remains fatal and
prevents Desktop launch. Completed findings produce a warning and the handled
status is cleared. Temporary results are removed even on failure; caller-local
`LASTEXITCODE` values cannot shadow the explicitly global reset/read.
It does not run `doctor --fix` or change configuration/dependencies to silence
findings. Command-launch errors, missing process status, unexpected doctor exit
codes, setup/version failures, and Desktop-launch exceptions still stop the
wrapper. An installed build is not necessarily a healthy configuration.

Regression checks (no live installation):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Installer.Invocation.Tests.ps1
pwsh -NoProfile -File tests/Installer.Invocation.Tests.ps1
```

The official pass uses `-NonInteractive`; `-SkipSetup` controls the wrapper's
subsequent setup wizard. Caller repository/home environment values are restored
on success or failure. Upstream preserves displaced local commits with recovery
refs; the wrapper keeps its migration stash for manual inspection.

This wrapper requires a modern downstream source tree containing `pm/lock.json`,
`pm/cli.py`, `hermes_cli/source_completion.py`, and
`scripts/desktop-update/runtime.ps1`. Publish the upstream merge in the fork
before deploying this wrapper. Parser and mocked tests are not a live-install
smoke test.

The custom source currently includes:

- remote AI limits and usage in the Desktop sidebar from the configured `test` provider (`/v0/user/ai-limits` and `/v0/user/usage`);
- safe handling of missing file-preview paths without Electron `ENOENT` log floods;
- trusted `simple-git` custom-binary warning suppression while retaining its safety gate;
- idempotent patch handling for already-applied V4A updates;
- streaming/Codex reliability fixes carried by the custom branch.

## Non-interactive examples

Download the script first when passing options:

```powershell
irm https://raw.githubusercontent.com/Fermoders/hermes-custom-installer/main/Install-HermesCustom.ps1 -OutFile "$env:TEMP\Install-HermesCustom.ps1"

# Install without opening the setup wizard or launching Desktop
& "$env:TEMP\Install-HermesCustom.ps1" -SkipSetup -NoLaunch

# Do not request a new Desktop build (existing Desktop may still be rebuilt)
& "$env:TEMP\Install-HermesCustom.ps1" -NoDesktop -NoLaunch

# Replace local modifications in the managed checkout
& "$env:TEMP\Install-HermesCustom.ps1" -Force
```

## Parameters

| Parameter | Default | Purpose |
|---|---:|---|
| `-Repository` | `Fermoders/hermes-agent` | Custom source repository or full Git URL |
| `-Ref` | `main` | Branch to install and follow |
| `-HermesHome` | `%LOCALAPPDATA%\hermes` | Hermes data/install root |
| `-SkipSetup` | off | Do not open `hermes setup` |
| `-NoDesktop` | off | Do not request a new Desktop build; upstream may rebuild an existing Desktop |
| `-SkipBrowser` | off | Pass upstream's persistent PM browser-tools opt-out |
| `-SkipComputerUse` | off | Pass upstream's persistent PM computer-use opt-out |
| `-NoLaunch` | off | Do not launch Desktop after verification |
| `-Force` | off | Explicitly discard local changes instead of preserving them in a recovery stash |

## Update model

The upstream repository remains authoritative. The custom fork is a thin downstream branch:

- upstream: `NousResearch/hermes-agent`;
- custom fork: `Fermoders/hermes-agent`;
- installer: `Fermoders/hermes-custom-installer`.

To ship a new fix, merge/sync upstream into the fork, preserve the custom commits, run the relevant tests/builds, and push `main`. Users then rerun the one-line installer.

## Security

The installer downloads the official Nous installer over HTTPS and then checks out the named custom GitHub repository. Review [`Install-HermesCustom.ps1`](Install-HermesCustom.ps1) before running it if the machine is security-sensitive. Secrets remain in Hermes configuration/credential stores; this repository contains no API keys.
