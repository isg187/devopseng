<#
.SYNOPSIS
    Silently installs Win64 OpenSSL from Shining Light Productions.

.DESCRIPTION
    Resolves the latest full Intel 64-bit EXE from the slproweb hash catalog
    and installs it silently. Adds the OpenSSL bin folder to the machine PATH.

.PARAMETER Force
    Reinstall even if OpenSSL is already present.

.PARAMETER LogPath
    Full path to the log file.

.PARAMETER DownloadPath
    Temporary folder for the installer.

.PARAMETER ExpectedSha256
    Optional SHA-256 to enforce. Catalog SHA-256 is used when this is omitted.

.EXAMPLE
    .\install-openssl.ps1
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP 'OpenSslInstall'),
    [string]$ExpectedSha256
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
    if ($sig.Status -eq 'Valid') {
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
        return
    }

    if (-not $ExpectedSha256) {
        throw "Authenticode signature is not valid and no SHA-256 was supplied. Status=$($sig.Status)"
    }

    Write-Log ('Authenticode not valid ({0}); catalog SHA-256 was verified' -f $sig.Status) -Level WARN
}

function Get-InstalledOpenSsl {
    $exe = Join-Path $env:ProgramFiles 'OpenSSL-Win64\bin\openssl.exe'
    if (Test-Path $exe) {
        return (Get-Item $exe).VersionInfo.ProductVersion
    }
    return $null
}

function Add-MachinePath {
    param([string]$Directory)

    if (-not (Test-Path $Directory)) { return }

    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = $current -split ';' | Where-Object { $_ }
    if ($parts -contains $Directory) { return }

    [Environment]::SetEnvironmentVariable('Path', (($parts + $Directory) -join ';'), 'Machine')
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Get-LatestOpenSslDownloadInfo {
    $catalog = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/slproweb/opensslhashes/master/win32_openssl_hashes.json' -TimeoutSec 30
    $candidates = @()

    foreach ($name in $catalog.files.PSObject.Properties.Name) {
        $item = $catalog.files.$name
        $isFull = ($item.light -eq $false)
        $is64 = ($item.bits -eq 64)
        $isExe = ($item.installer -eq 'exe')
        $isIntel = ($item.arch -eq 'INTEL' -or $item.arch -eq 'intel')
        if ($isFull -and $is64 -and $isExe -and $isIntel) {
            $candidates += $item
        }
    }

    if (-not $candidates) {
        throw 'Could not resolve a Win64 OpenSSL EXE from the catalog.'
    }

    $chosen = $candidates |
    Sort-Object { [version](($_.basever -replace '[^\d.].*$', '')) } |
    Select-Object -Last 1

    [pscustomobject]@{
        Version = $chosen.basever
        Url     = $chosen.url
        Sha256  = $chosen.sha256
    }
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-OpenSsl_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

Write-Log 'Starting OpenSSL install'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $installedVersion = Get-InstalledOpenSsl
    if ($installedVersion -and -not $Force) {
        Write-Log ('OpenSSL already installed: {0}' -f $installedVersion) -Level SUCCESS
        Write-Log 'Install finished' -Level SUCCESS
        exit 0
    }

    if ($installedVersion -and $Force) {
        Write-Log ('OpenSSL {0} found; Force specified' -f $installedVersion) -Level WARN
    }
    else {
        Write-Log 'OpenSSL not detected; installing latest'
    }

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $downloadInfo = Get-LatestOpenSslDownloadInfo
    $installerPath = Join-Path $DownloadPath 'Win64OpenSSL.exe'
    Write-Log ('Downloading OpenSSL {0}' -f $downloadInfo.Version)

    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $downloadInfo.Url -OutFile $installerPath -UseBasicParsing

    if (-not (Test-Path $installerPath) -or (Get-Item $installerPath).Length -lt 1MB) {
        throw 'Download failed or file is too small.'
    }

    $hashToUse = $ExpectedSha256
    if (-not $hashToUse) { $hashToUse = $downloadInfo.Sha256 }

    $integrityParams = @{
        Path               = $installerPath
        ExpectedPublishers = @('Shining Light', 'slproweb', 'OpenSSL')
    }
    if ($hashToUse) {
        $integrityParams['ExpectedSha256'] = $hashToUse
    }
    Test-InstallerIntegrity @integrityParams

    $installDir = Join-Path $env:ProgramFiles 'OpenSSL-Win64'
    Write-Log 'Installing OpenSSL'
    $setupArgs = @(
        '/VERYSILENT'
        '/NORESTART'
        '/SUPPRESSMSGBOXES'
        '/SP-'
        '/tasks=copytobin'
        ('/DIR={0}' -f $installDir)
    )
    $processParams = @{
        FilePath     = $installerPath
        ArgumentList = $setupArgs
        Wait         = $true
        PassThru     = $true
    }
    $process = Start-Process @processParams

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "OpenSSL installer returned non-zero exit code: $($process.ExitCode)"
    }

    Add-MachinePath -Directory (Join-Path $installDir 'bin')

    $newVersion = Get-InstalledOpenSsl
    if ($newVersion) {
        Write-Log ('OpenSSL installed: {0}' -f $newVersion) -Level SUCCESS
    }
    else {
        Write-Log 'Installer succeeded but OpenSSL version was not detected.' -Level WARN
    }

    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
