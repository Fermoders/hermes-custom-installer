$ErrorActionPreference = 'Stop'
# Close Hermes Desktop, CLI and gateway before running this file.
$uri = 'https' + '://raw.githubusercontent.com/Fermoders/hermes-custom-installer/996bd8f86b1446f53279916fbab37bf0728a10a9/Install-HermesCustom.ps1'
$installerSha256 = '27e0b853f2289bf3bebe3f37ca37ae0ea0bf938f1a0fc440e9307809a782f373'
$directory = Join-Path $env:TEMP ('hermes-custom-update-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory | Out-Null
try {
    $installer = Join-Path $directory 'Install-HermesCustom.ps1'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $installer
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() -ne $installerSha256) {
        throw 'Downloaded installer SHA-256 mismatch; no update was started.'
    }
    $global:LASTEXITCODE = 1
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SkipSetup
    if ($global:LASTEXITCODE -ne 0) { throw "Hermes Custom update failed (exit $global:LASTEXITCODE)." }
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
