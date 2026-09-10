<#
.SYNOPSIS
    Downloads and silently installs Google Chrome Enterprise (MSI).

.DESCRIPTION
    Idempotent installer for Google Chrome Enterprise 64-bit MSI.
    - Checks if Chrome is already installed and optionally skips if present.
    - Downloads the official enterprise MSI from Google.
    - Performs a quiet installation suitable for enterprise / Intune / automation.
    - Cleans up the downloaded installer after success.
    - Designed for GCC High / CMMC environments (official Microsoft/Google sources only).

.PARAMETER Force
    Reinstall even if Chrome is already present.

.PARAMETER LogPath
    Full path to the log file. Defaults to scripts\logs\Install-Chrome_yyyyMMdd.log

.PARAMETER DownloadPath
    Folder to store the temporary MSI. Defaults to $env:TEMP\ChromeInstall

.EXAMPLE
    .\Install-Chrome.ps1

.EXAMPLE
    .\Install-Chrome.ps1 -Force -Verbose
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP "ChromeInstall"),
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
$logDir = "C:\ProgramData\SDL\scripts\logs"
$LogPath = Join-Path $logDir ("Install-Chrome_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

Write-Log "===== Starting Chrome Enterprise installation ====="
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


# Helper: Get currently installed Chrome version (if any)
function Get-InstalledChromeVersion {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome',
        'HKLM:\SOFTWARE\Google\Chrome\BLBeacon'
    )

    foreach ($p in $paths) {
        if (Test-Path $p) {
            $ver = (Get-ItemProperty -Path $p -ErrorAction SilentlyContinue).version
            if ($ver) { return $ver }

            $ver = (Get-ItemProperty -Path $p -ErrorAction SilentlyContinue).DisplayVersion
            if ($ver) { return $ver }
        }
    }

    # Fallback: chrome.exe version
    $chromeExe = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe"
    if (Test-Path $chromeExe) {
        return (Get-Item $chromeExe).VersionInfo.ProductVersion
    }

    return $null
}

# Helper: Build official Chrome Enterprise MSI download info
function Get-ChromeEnterpriseDownload {
    # Official Google enterprise MSI (64-bit)
    # Naming: googlechromestandaloneenterprise64.msi
    $fileName = "googlechromestandaloneenterprise64.msi"
    $url = "https://dl.google.com/dl/chrome/install/$fileName"

    [pscustomobject]@{
        FileName = $fileName
        Url      = $url
        Arch     = 'x64'
        Type     = 'MSI'
    }
}

# Main logic
try {
    $installedVersion = Get-InstalledChromeVersion

    if ($installedVersion -and -not $Force) {
        Write-Log "Google Chrome is already installed (version $installedVersion). Skipping. Use -Force to reinstall." -Level SUCCESS
        exit 0
    }

    if ($installedVersion -and $Force) {
        Write-Log "Chrome version $installedVersion found. -Force specified, proceeding with reinstall." -Level WARN
    }
    else {
        Write-Log "Chrome not detected. Proceeding with fresh install."
    }

    # Prepare download folder
    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $downloadInfo = Get-ChromeEnterpriseDownload
    $msiPath = Join-Path $DownloadPath $downloadInfo.FileName

    Write-Log "Downloading Chrome Enterprise MSI..."
    Write-Log "URL : $($downloadInfo.Url)"
    Write-Log "Dest: $msiPath"

    # Download with progress (Invoke-WebRequest is fine for enterprise MSI)
    $ProgressPreference = 'SilentlyContinue'   # cleaner logs
    Invoke-WebRequest -Uri $downloadInfo.Url -OutFile $msiPath -UseBasicParsing

    if (-not (Test-Path $msiPath) -or (Get-Item $msiPath).Length -lt 1MB) {
        throw "Download failed or file is too small. Check network / proxy / firewall."
    }

    $fileSizeMB = [math]::Round((Get-Item $msiPath).Length / 1MB, 2)
    Write-Log "Download complete ($fileSizeMB MB)" -Level SUCCESS

    # Integrity checks (Authenticode + SHA-256)
    Test-InstallerIntegrity -Path $msiPath `
        -ExpectedPublishers @('Google LLC', 'Google Inc') `
        -ExpectedSha256 $ExpectedSha256

    # Silent install
    # /qn = quiet, no UI
    # /norestart = do not reboot
    # Recommended enterprise switches can be added later (e.g. master_preferences)
    Write-Log "Starting silent MSI installation..."

    $msiArgs = @(
        "/i `"$msiPath`""
        "/qn"
        "/norestart"
        "/L*v `"$($msiPath).install.log`""
    )

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru

    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
        # 0 = success, 3010 = success but reboot required
        Write-Log "Chrome installation completed successfully (ExitCode: $($process.ExitCode))" -Level SUCCESS
    }
    else {
        throw "msiexec returned non-zero exit code: $($process.ExitCode). See $($msiPath).install.log"
    }

    # Verify
    Start-Sleep -Seconds 2
    $newVersion = Get-InstalledChromeVersion
    if ($newVersion) {
        Write-Log "Verified installed version: $newVersion" -Level SUCCESS
    }
    else {
        Write-Log "Installation reported success but Chrome version could not be detected afterwards." -Level WARN
    }

    # Cleanup
    Write-Log "Cleaning up downloaded MSI..."
    Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
    # Optionally keep the verbose MSI log for troubleshooting
    # Remove-Item -Path "$msiPath.install.log" -Force -ErrorAction SilentlyContinue

    Write-Log "===== Chrome installation finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}
