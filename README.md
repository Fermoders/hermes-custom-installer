# Hermes Custom Installer

One-command Windows installer for the official Nous Research Hermes Agent plus the maintained custom fixes in [`Fermoders/hermes-agent`](https://github.com/Fermoders/hermes-agent).

## Install or update

Run in **PowerShell**:

```powershell
irm https://raw.githubusercontent.com/Fermoders/hermes-custom-installer/main/Install-HermesCustom.ps1 | iex
```

The same command updates an existing installation.

## What it installs

1. Runs the official installer from `https://hermes-agent.nousresearch.com/install.ps1`.
2. Installs the official prerequisites, Python environment, CLI, Node dependencies, and Desktop app.
3. Switches the managed source checkout to the custom fork.
4. Re-runs the official dependency/build stages from that custom source.
5. Runs `hermes setup`, `hermes --version`, and `hermes doctor`.
6. Launches Hermes Desktop.

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

# CLI only
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
| `-NoDesktop` | off | Install CLI without building Desktop |
| `-NoLaunch` | off | Do not launch Desktop after verification |
| `-Force` | off | Discard local changes in the managed source checkout |

## Update model

The upstream repository remains authoritative. The custom fork is a thin downstream branch:

- upstream: `NousResearch/hermes-agent`;
- custom fork: `Fermoders/hermes-agent`;
- installer: `Fermoders/hermes-custom-installer`.

To ship a new fix, merge/sync upstream into the fork, preserve the custom commits, run the relevant tests/builds, and push `main`. Users then rerun the one-line installer.

## Security

The installer downloads the official Nous installer over HTTPS and then checks out the named custom GitHub repository. Review [`Install-HermesCustom.ps1`](Install-HermesCustom.ps1) before running it if the machine is security-sensitive. Secrets remain in Hermes configuration/credential stores; this repository contains no API keys.
