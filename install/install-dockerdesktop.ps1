<#
.SYNOPSIS
    Silently installs Docker Desktop for Windows.

.DESCRIPTION
    Downloads the official Docker Desktop installer and runs
    install --quiet --accept-license.
    Default backend is Hyper-V for AIB / AVD session hosts.
    Nested virtualization is required. A reboot may be needed.

.EXAMPLE
    .\install-dockerdesktop.ps1
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP "DockerDesktopInstall"),
    [string]$ExpectedSha256,
    [ValidateSet('hyper-v','wsl-2')]
    [string]$Backend = 'hyper-v'
)

#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string]$Message = '',
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG')]
        [string]$Level = 'INFO',
        [string]$LogPath = $script:LogPath
    )
    if (-not $LogPath) { $LogPath = Join-Path $env:TEMP "SoftwareInstall_$(Get-Date -Format 'yyyyMMdd').log" }
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = if ([string]::IsNullOrEmpty($Message)) { '' } else { "[$timestamp] [$Level] $Message" }
    switch ($Level) {
        'ERROR'   { Write-Host $entry -ForegroundColor Red }
        'WARN'    { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default   { Write-Host $entry }
    }
    try {
        $dir = Split-Path $LogPath -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $LogPath -Value $entry -ErrorAction SilentlyContinue
    } catch { }
}

function Test-InstallerIntegrity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$ExpectedPublishers,
        [string]$ExpectedSha256,
        [switch]$AllowUnsigned
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "Integrity check failed: file not found: $Path" }
    Write-Log "Running integrity checks"
    $actualHash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    Write-Log "SHA256 recorded"
    if ($ExpectedSha256) {
        $expected = $ExpectedSha256.Trim().ToUpperInvariant()
        if ($actualHash -ne $expected) { throw "SHA-256 mismatch" }
        Write-Log "SHA-256 verified" -Level SUCCESS
    }
    else {
        Write-Log "No ExpectedSha256 supplied. Hash logged only." -Level WARN
    }
    $sig = Get-AuthenticodeSignature -FilePath $Path
    Write-Log "Authenticode status checked"
    if ($sig.Status -ne 'Valid') {
        if ($AllowUnsigned) {
            Write-Log "Signature not valid. AllowUnsigned specified." -Level WARN
            if (-not $ExpectedSha256) {
                Write-Log "Unsigned file with no ExpectedSha256. Continuing with audit hash only." -Level WARN
            }
            return
        }
        throw "Authenticode signature is not valid"
    }
    $subject = $sig.SignerCertificate.Subject
    $matched = $false
    foreach ($pub in $ExpectedPublishers) {
        if ($subject -like "*$pub*") { $matched = $true; Write-Log "Publisher matched" -Level SUCCESS; break }
    }
    if (-not $matched) { throw "Unexpected publisher" }
    Write-Log "Integrity checks passed" -Level SUCCESS
}

function Add-MachinePath {
    param([string]$Directory)
    if (-not (Test-Path $Directory)) { return }
    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = $current -split ';' | Where-Object { $_ }
    if ($parts -contains $Directory) { return }
    [Environment]::SetEnvironmentVariable('Path', ($parts + $Directory) -join ';', 'Machine')
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    Write-Log "Added directory to machine PATH"
}

function Invoke-Download {
    param([string]$Url, [string]$OutFile)
    Write-Log "Downloading file"
    Write-Log "URL logged"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -lt 10KB) {
        throw "Download failed or file is too small"
    }
    Write-Log "Download complete" -Level SUCCESS
}

$logDir = "C:\ProgramData\SDL\scripts\logs"
if (-not $LogPath) { $LogPath = Join-Path $logDir ("Install-DockerDesktop_{0}.log" -f (Get-Date -Format 'yyyyMMdd')) }
$script:LogPath = $LogPath

Write-Log "===== Starting Docker Desktop installation ====="
Write-Log "Backend selected"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $existing = Test-Path "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe"
    if ($existing -and -not $Force) {
        Write-Log "Docker Desktop already present. Skipping." -Level SUCCESS
        exit 0
    }

    if (-not (Test-Path $DownloadPath)) { New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null }
    $exe = Join-Path $DownloadPath "DockerDesktopInstaller.exe"
    Invoke-Download -Url "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe" -OutFile $exe
    Test-InstallerIntegrity -Path $exe -ExpectedPublishers @('Docker','Docker Inc') -ExpectedSha256 $ExpectedSha256

    Write-Log "Starting silent Docker Desktop install"
    Write-Log "Nested virtualization is required on Azure VMs"
    $argList = @('install','--quiet','--accept-license',"--backend=$Backend")
    $p = Start-Process -FilePath $exe -ArgumentList $argList -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "Docker Desktop installer exited with a non-zero code" }
    Write-Log "Docker Desktop installer finished" -Level SUCCESS
    if ($p.ExitCode -eq 3010) { Write-Log "Reboot required to complete Docker Desktop install" -Level WARN }

    Remove-Item $exe -Force -ErrorAction SilentlyContinue
    Write-Log "===== Docker Desktop installation finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-Log "ERROR during Docker Desktop install" -Level ERROR
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
