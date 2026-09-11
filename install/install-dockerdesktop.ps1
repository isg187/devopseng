<#
.SYNOPSIS
    Silently installs Docker Desktop for Windows.

.DESCRIPTION
    Downloads the official Docker Desktop installer and runs
    install --quiet --accept-license.
    Default backend is Hyper-V. Nested virtualization is required.
    A reboot may be needed.

.PARAMETER Force
    Reinstall even if Docker Desktop is already present.

.PARAMETER Backend
    Container backend: hyper-v or wsl-2.

.PARAMETER LogPath
    Full path to the log file.

.PARAMETER DownloadPath
    Temporary folder for the installer.

.PARAMETER ExpectedSha256
    Optional SHA-256 to enforce.

.EXAMPLE
    .\install-dockerdesktop.ps1
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP 'DockerDesktopInstall'),
    [string]$ExpectedSha256,
    [ValidateSet('hyper-v', 'wsl-2')]
    [string]$Backend = 'hyper-v'
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    if (-not $script:LogPath) {
        $script:LogPath = Join-Path $env:TEMP ("SoftwareInstall_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    }

    $entry = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    switch ($Level) {
        'ERROR' { Write-Host $entry -ForegroundColor Red }
        'WARN' { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default { Write-Host $entry }
    }

    $logDir = Split-Path $script:LogPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path $script:LogPath -Value $entry
}

function Test-InstallerIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedPublishers,
        [string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Integrity check failed: file not found: $Path"
    }

    if ($ExpectedSha256) {
        $actualHash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant()
        $expected = $ExpectedSha256.Trim().ToUpperInvariant()
        if ($actualHash -ne $expected) {
            throw "SHA-256 mismatch. Expected $expected but got $actualHash"
        }
    }

    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') {
        throw "Authenticode signature is not valid. Status=$($sig.Status)"
    }

    $subject = $sig.SignerCertificate.Subject
    $matched = $false
    foreach ($pub in $ExpectedPublishers) {
        if ($subject -like "*$pub*") {
            $matched = $true
            break
        }
    }
    if (-not $matched) {
        throw "Unexpected publisher. Subject='$subject'"
    }
}

function Get-InstalledDockerDesktopVersion {
    $exe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (Test-Path $exe) {
        return (Get-Item $exe).VersionInfo.ProductVersion
    }
    return $null
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-DockerDesktop_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

Write-Log ('Starting Docker Desktop install (backend={0})' -f $Backend)

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $installedVersion = Get-InstalledDockerDesktopVersion
    if ($installedVersion -and -not $Force) {
        Write-Log ('Docker Desktop already installed: {0}' -f $installedVersion) -Level SUCCESS
        Write-Log 'Install finished' -Level SUCCESS
        exit 0
    }

    if ($installedVersion -and $Force) {
        Write-Log ('Docker Desktop {0} found; Force specified' -f $installedVersion) -Level WARN
    }
    else {
        Write-Log 'Docker Desktop not detected; installing latest'
    }

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $installerPath = Join-Path $DownloadPath 'DockerDesktopInstaller.exe'
    Write-Log 'Downloading Docker Desktop installer'

    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe' -OutFile $installerPath -UseBasicParsing

    if (-not (Test-Path $installerPath) -or (Get-Item $installerPath).Length -lt 10MB) {
        throw 'Download failed or file is too small.'
    }

    $integrityParams = @{
        Path               = $installerPath
        ExpectedPublishers = @('Docker Inc', 'Docker')
    }
    if ($ExpectedSha256) {
        $integrityParams['ExpectedSha256'] = $ExpectedSha256
    }
    Test-InstallerIntegrity @integrityParams

    Write-Log 'Installing Docker Desktop'
    $setupArgs = @(
        'install'
        '--quiet'
        '--accept-license'
        ('--backend={0}' -f $Backend)
    )
    $processParams = @{
        FilePath     = $installerPath
        ArgumentList = $setupArgs
        Wait         = $true
        PassThru     = $true
    }
    $process = Start-Process @processParams

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "Docker Desktop installer returned non-zero exit code: $($process.ExitCode)"
    }

    if ($process.ExitCode -eq 3010) {
        Write-Log 'Reboot required to complete Docker Desktop install' -Level WARN
    }

    $newVersion = Get-InstalledDockerDesktopVersion
    if ($newVersion) {
        Write-Log ('Docker Desktop installed: {0}' -f $newVersion) -Level SUCCESS
    }
    else {
        Write-Log 'Installer succeeded but Docker Desktop version was not detected.' -Level WARN
    }

    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
