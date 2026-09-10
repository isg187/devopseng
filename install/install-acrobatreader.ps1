<#
.SYNOPSIS
    Downloads and silently installs Adobe Acrobat Reader (Enterprise).

.DESCRIPTION
    Idempotent installer for Adobe Acrobat Reader DC / Continuous Track.
    Uses Adobe's official reader products API to resolve the latest enterprise download.
    Performs a quiet installation suitable for automation.

.PARAMETER Force
    Reinstall even if Acrobat Reader is already present.

.PARAMETER LogPath
    Full path to the log file.

.PARAMETER DownloadPath
    Temporary folder for the installer.

.EXAMPLE
    .\Install-AcrobatReader.ps1

.EXAMPLE
    .\Install-AcrobatReader.ps1 -Force
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP "AcrobatReaderInstall"),
    [string]$ExpectedSha256
)

#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

# Initialize logging
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

    if (-not $LogPath) {
        $LogPath = Join-Path $env:TEMP "SoftwareInstall_$(Get-Date -Format 'yyyyMMdd').log"
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp] [$Level] $Message"

    # Console output with color
    switch ($Level) {
        'ERROR' { Write-Host $entry -ForegroundColor Red }
        'WARN' { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        'DEBUG' { if ($VerbosePreference -eq 'Continue') { Write-Host $entry -ForegroundColor Gray } }
        default { Write-Host $entry }
    }

    # File output
    try {
        $logDir = Split-Path $LogPath -Parent
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $LogPath -Value $entry -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write to log file: $($_.Exception.Message)"
    }
}
$logDir = Join-Path $PSScriptRoot "C:\ProgramData\SDL\scripts\logs"
$LogPath = Join-Path $logDir ("Install-AcrobatReader_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

Write-Log "===== Starting Adobe Acrobat Reader installation ====="
Write-Log "Log file : $LogPath"
Write-Log "Force    : $Force"


# ---------------------------------------------------------------------------
# Integrity: Authenticode + SHA-256
# ---------------------------------------------------------------------------
function Test-InstallerIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedPublishers,

        [string]$ExpectedSha256,

        [switch]$AllowUnsigned
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Integrity check failed: file not found: $Path"
    }

    Write-Log "Running integrity checks on: $Path"

    # --- SHA-256 ---
    $actualHash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    Write-Log "SHA256: $actualHash"

    if ($ExpectedSha256) {
        $expected = $ExpectedSha256.Trim().ToUpperInvariant()
        if ($actualHash -ne $expected) {
            throw "SHA-256 mismatch. Expected $expected but got $actualHash"
        }
        Write-Log "SHA-256 verified against expected value." -Level SUCCESS
    }
    else {
        Write-Log "No ExpectedSha256 supplied — hash recorded for audit; not enforced." -Level WARN
    }

    # --- Authenticode ---
    $sig = Get-AuthenticodeSignature -FilePath $Path
    Write-Log "Authenticode Status : $($sig.Status)"
    if ($sig.SignerCertificate) {
        Write-Log "Signer Subject      : $($sig.SignerCertificate.Subject)"
        Write-Log "Signer Thumbprint   : $($sig.SignerCertificate.Thumbprint)"
    }

    if ($sig.Status -ne 'Valid') {
        if ($AllowUnsigned) {
            Write-Log "Authenticode not valid ($($sig.Status)) but -AllowUnsigned was specified." -Level WARN
            if (-not $ExpectedSha256) {
                throw "Unsigned/invalid signature requires -ExpectedSha256 so the file can still be integrity-checked."
            }
            return
        }
        throw "Authenticode signature is not valid. Status=$($sig.Status)"
    }

    $subject = $sig.SignerCertificate.Subject
    $matched = $false
    foreach ($pub in $ExpectedPublishers) {
        if ($subject -like "*$pub*") {
            $matched = $true
            Write-Log "Publisher matched: $pub" -Level SUCCESS
            break
        }
    }
    if (-not $matched) {
        throw "Unexpected publisher. Subject='$subject'. Expected one of: $($ExpectedPublishers -join ', ')"
    }

    Write-Log "Integrity checks passed." -Level SUCCESS
}


# Helper: Get currently installed Acrobat Reader version
function Get-InstalledAcrobatVersion {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($base in $paths) {
        $apps = Get-ItemProperty $base -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PSObject.Properties['DisplayName'] -and
            ($_.DisplayName -match 'Adobe Acrobat (Reader|DC)' -or $_.DisplayName -match 'Adobe Reader')
        }

        foreach ($app in @($apps)) {
            if ($app.PSObject.Properties['DisplayVersion'] -and $app.DisplayVersion) {
                return $app.DisplayVersion
            }
        }
    }

    $exeCandidates = @(
        "${env:ProgramFiles}\Adobe\Acrobat DC\Acrobat\Acrobat.exe",
        "${env:ProgramFiles(x86)}\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe",
        "${env:ProgramFiles}\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe"
    )

    foreach ($exe in $exeCandidates) {
        if (Test-Path $exe) {
            return (Get-Item $exe).VersionInfo.ProductVersion
        }
    }
    return $null
}

# Helper: Resolve latest Acrobat Reader download via Adobe API
function Get-AcrobatReaderDownloadInfo {
    Write-Log "Querying Adobe Reader products API..."

    $apiKey = "dc-get-adobereader-cdn"
    $productsUri = "https://rdc.adobe.io/reader/products?lang=en&site=enterprise&os=Windows%2010&country=US&nativeOs=Windows%2010&api_key=$apiKey"

    $versionResponse = Invoke-RestMethod -Uri $productsUri -TimeoutSec 30
    $reader = $versionResponse.products.reader

    if (-not $reader) {
        throw "Could not retrieve Reader product information from Adobe API."
    }

    $version = $reader.version
    $displayName = $reader.DisplayName

    Write-Log "Resolved version: $version ($displayName)"

    $downloadUri = "https://rdc.adobe.io/reader/downloadUrl?name=$([uri]::EscapeDataString($displayName))&nativeOs=Windows 10&os=Windows 10&site=enterprise&lang=en&accepted=cr&api_key=$apiKey"

    $downloadResponse = Invoke-RestMethod -Uri $downloadUri -TimeoutSec 30

    if (-not $downloadResponse.downloadURL) {
        throw "Adobe API did not return a download URL."
    }

    [pscustomobject]@{
        Version  = $version
        FileName = $downloadResponse.saveName
        Url      = $downloadResponse.downloadURL
    }
}

# Main logic
try {
    $installedVersion = Get-InstalledAcrobatVersion

    if ($installedVersion -and -not $Force) {
        Write-Log "Adobe Acrobat Reader is already installed (version $installedVersion). Skipping. Use -Force to reinstall." -Level SUCCESS
        exit 0
    }

    if ($installedVersion -and $Force) {
        Write-Log "Acrobat Reader version $installedVersion found. -Force specified, proceeding with reinstall." -Level WARN
    }
    else {
        Write-Log "Acrobat Reader not detected. Proceeding with fresh install."
    }

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $downloadInfo = Get-AcrobatReaderDownloadInfo
    $installerPath = Join-Path $DownloadPath $downloadInfo.FileName

    Write-Log "Downloading Acrobat Reader..."
    Write-Log "URL : $($downloadInfo.Url)"
    Write-Log "Dest: $installerPath"

    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $downloadInfo.Url -OutFile $installerPath -UseBasicParsing

    if (-not (Test-Path $installerPath) -or (Get-Item $installerPath).Length -lt 1MB) {
        throw "Download failed or file is too small."
    }

    $fileSizeMB = [math]::Round((Get-Item $installerPath).Length / 1MB, 2)
    Write-Log "Download complete ($fileSizeMB MB)" -Level SUCCESS

    # Integrity checks (Authenticode + SHA-256)
    Test-InstallerIntegrity -Path $installerPath `
        -ExpectedPublishers @('Adobe', 'Adobe Systems') `
        -ExpectedSha256 $ExpectedSha256

    Write-Log "Starting silent installation..."

    # Adobe Reader EXE typically supports /sAll /rs /rps /msi
    # or just /sAll for basic silent
    $process = Start-Process -FilePath $installerPath -ArgumentList "/sAll /rs /rps /msi /norestart /quiet" -Wait -PassThru

    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
        Write-Log "Acrobat Reader installation completed successfully (ExitCode: $($process.ExitCode))" -Level SUCCESS
    }
    else {
        # Some Adobe installers return other success codes; treat non-zero carefully
        Write-Log "Installer exited with code $($process.ExitCode). Checking if application is present..." -Level WARN
    }

    Start-Sleep -Seconds 3
    $newVersion = Get-InstalledAcrobatVersion
    if ($newVersion) {
        Write-Log "Verified installed version: $newVersion" -Level SUCCESS
    }
    else {
        Write-Log "Installation may have completed but version could not be detected. Please verify manually." -Level WARN
    }

    Write-Log "Cleaning up downloaded installer..."
    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue

    Write-Log "===== Acrobat Reader installation finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}
