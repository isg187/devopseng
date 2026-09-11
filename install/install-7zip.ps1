<#
.SYNOPSIS
    Downloads and silently installs 7-Zip (x64).

.DESCRIPTION
    Idempotent installer for 7-Zip 64-bit.
    Prefers the MSI when available; falls back to EXE.
    Source: official GitHub releases (ip7z/7zip).
    Official 7-Zip installers are often unsigned; Authenticode is checked
    when present, otherwise the SHA-256 is recorded.

.PARAMETER Force
    Reinstall even if 7-Zip is already present.

.PARAMETER PreferExe
    Force the .exe installer instead of MSI.

.PARAMETER LogPath
    Full path to the log file.

.PARAMETER DownloadPath
    Temporary folder for the installer.

.PARAMETER ExpectedSha256
    Optional SHA-256 to enforce.

.EXAMPLE
    .\Install-7Zip.ps1

.EXAMPLE
    .\Install-7Zip.ps1 -Force
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$PreferExe,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP '7ZipInstall'),
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

    $actualHash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    Write-Log ('SHA256: {0}' -f $actualHash)

    if ($ExpectedSha256) {
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

    Write-Log ('Authenticode not valid ({0}); 7-Zip installers are often unsigned' -f $sig.Status) -Level WARN
}

function Get-Installed7ZipVersion {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\7-Zip',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\7-Zip'
    )

    foreach ($p in $paths) {
        if (Test-Path $p) {
            $ver = (Get-ItemProperty -Path $p -ErrorAction SilentlyContinue).DisplayVersion
            if ($ver) { return $ver }
        }
    }

    $exe = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    if (Test-Path $exe) {
        return (Get-Item $exe).VersionInfo.ProductVersion
    }
    return $null
}

function Get-7ZipDownloadInfo {
    param([switch]$PreferExe)

    $headers = @{
        'User-Agent' = 'PowerShell-7Zip-Installer'
        'Accept'     = 'application/vnd.github+json'
    }

    $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/ip7z/7zip/releases/latest' -Headers $headers -TimeoutSec 30
    $version = $releases.tag_name -replace '^v', ''
    $assets = $releases.assets

    $msi = $assets | Where-Object { $_.name -match 'x64.*\.msi$' -or $_.name -match '7z.*-x64\.msi$' } | Select-Object -First 1
    $exe = $assets | Where-Object { $_.name -match 'x64\.exe$' -or $_.name -match '7z.*-x64\.exe$' } | Select-Object -First 1

    if ($PreferExe -and $exe) {
        $chosen = $exe
        $type = 'EXE'
    }
    elseif ($msi) {
        $chosen = $msi
        $type = 'MSI'
    }
    elseif ($exe) {
        $chosen = $exe
        $type = 'EXE'
    }
    else {
        throw 'Could not find a suitable x64 installer asset in the latest release.'
    }

    [pscustomobject]@{
        Version  = $version
        FileName = $chosen.name
        Url      = $chosen.browser_download_url
        Type     = $type
    }
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-7Zip_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

Write-Log 'Starting 7-Zip install'

try {
    $installedVersion = Get-Installed7ZipVersion

    if ($installedVersion -and -not $Force) {
        Write-Log ('7-Zip already installed: {0}' -f $installedVersion) -Level SUCCESS
        Write-Log 'Install finished' -Level SUCCESS
        exit 0
    }

    if ($installedVersion -and $Force) {
        Write-Log ('7-Zip {0} found; Force specified' -f $installedVersion) -Level WARN
    }
    else {
        Write-Log '7-Zip not detected; installing latest'
    }

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $downloadInfo = Get-7ZipDownloadInfo -PreferExe:$PreferExe
    $installerPath = Join-Path $DownloadPath $downloadInfo.FileName
    Write-Log ('Downloading 7-Zip {0} ({1})' -f $downloadInfo.Version, $downloadInfo.Type)

    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $downloadInfo.Url -OutFile $installerPath -UseBasicParsing

    if (-not (Test-Path $installerPath) -or (Get-Item $installerPath).Length -lt 500KB) {
        throw 'Download failed or file is too small.'
    }

    $integrityParams = @{
        Path               = $installerPath
        ExpectedPublishers = @('Igor Pavlov', '7-Zip')
    }
    if ($ExpectedSha256) {
        $integrityParams['ExpectedSha256'] = $ExpectedSha256
    }
    Test-InstallerIntegrity @integrityParams

    Write-Log 'Installing 7-Zip'

    if ($downloadInfo.Type -eq 'MSI') {
        $msiArgs = @(
            '/i'
            $installerPath
            '/qn'
            '/norestart'
            '/L*v'
            ($installerPath + '.install.log')
        )
        $processParams = @{
            FilePath     = 'msiexec.exe'
            ArgumentList = $msiArgs
            Wait         = $true
            PassThru     = $true
        }
        $process = Start-Process @processParams
    }
    else {
        $processParams = @{
            FilePath     = $installerPath
            ArgumentList = @('/S')
            Wait         = $true
            PassThru     = $true
        }
        $process = Start-Process @processParams
    }

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "Installer returned non-zero exit code: $($process.ExitCode)"
    }

    Start-Sleep -Seconds 2
    $newVersion = Get-Installed7ZipVersion
    if ($newVersion) {
        Write-Log ('7-Zip installed: {0}' -f $newVersion) -Level SUCCESS
    }
    else {
        Write-Log 'Installer succeeded but 7-Zip version was not detected.' -Level WARN
    }

    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
