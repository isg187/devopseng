<#
.SYNOPSIS
    Downloads and silently installs PowerShell 7 (x64 MSI).

.DESCRIPTION
    Idempotent installer for the latest stable PowerShell 7 release.
    - Uses the official GitHub releases (PowerShell/PowerShell).
    - Prefers the x64 MSI.
    - Performs a quiet installation suitable for enterprise automation.
    - Checks whether PowerShell 7 is already present and skips unless -Force is used.
    - StrictMode-safe and consistent with the other installers in this suite.

.PARAMETER Force
    Reinstall even if PowerShell 7 is already present.

.PARAMETER LogPath
    Full path to the log file.

.PARAMETER DownloadPath
    Temporary folder for the MSI. Defaults to $env:TEMP\PowerShell7Install

.EXAMPLE
    .\Install-PowerShell7.ps1

.EXAMPLE
    .\Install-PowerShell7.ps1 -Force
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP "PowerShell7Install"),
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
$LogPath = Join-Path $logDir ("Install-PowerShell7_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

Write-Log "===== Starting PowerShell 7 installation ====="
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


# Helper: Get currently installed PowerShell 7 version
function Get-InstalledPowerShell7Version {
    # Check the well-known install location first
    $pwsh = "${env:ProgramFiles}\PowerShell\7\pwsh.exe"
    if (Test-Path $pwsh) {
        try {
            $ver = & $pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
            if ($ver) { return $ver.Trim() }
        }
        catch { }
    }

    # Registry fallback
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($base in $paths) {
        $apps = Get-ItemProperty $base -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PSObject.Properties['DisplayName'] -and
            ($_.DisplayName -match '^PowerShell 7' -or $_.DisplayName -match '^PowerShell [0-9]')
        }

        foreach ($app in @($apps)) {
            if ($app.PSObject.Properties['DisplayVersion'] -and $app.DisplayVersion) {
                return $app.DisplayVersion
            }
        }
    }

    return $null
}

# Helper: Get latest PowerShell 7 x64 MSI from GitHub
function Get-PowerShell7DownloadInfo {
    $repo = "PowerShell/PowerShell"
    Write-Log "Querying GitHub releases for $repo..."

    $headers = @{
        "User-Agent" = "PowerShell-Installer-Script"
        "Accept"     = "application/vnd.github+json"
    }

    # Use the 'latest' release (stable)
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $headers -TimeoutSec 30

    $version = $release.tag_name -replace '^v', ''
    Write-Log "Latest stable version: $version"

    # Look for the x64 MSI (Windows)
    # Typical name: PowerShell-7.x.x-win-x64.msi
    $asset = $release.assets |
    Where-Object { $_.name -match 'win-x64\.msi$' -and $_.name -notmatch 'preview|rc|alpha|beta' } |
    Select-Object -First 1

    if (-not $asset) {
        throw "Could not find a stable win-x64 MSI asset in the latest PowerShell release."
    }

    [pscustomobject]@{
        Version  = $version
        FileName = $asset.name
        Url      = $asset.browser_download_url
        Type     = 'MSI'
    }
}

# Main logic
try {
    $installedVersion = Get-InstalledPowerShell7Version

    if ($installedVersion -and -not $Force) {
        Write-Log "PowerShell 7 is already installed (version $installedVersion). Skipping. Use -Force to reinstall." -Level SUCCESS
        exit 0
    }

    if ($installedVersion -and $Force) {
        Write-Log "PowerShell 7 version $installedVersion found. -Force specified, proceeding with reinstall." -Level WARN
    }
    else {
        Write-Log "PowerShell 7 not detected. Proceeding with fresh install."
    }

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $downloadInfo = Get-PowerShell7DownloadInfo
    $msiPath = Join-Path $DownloadPath $downloadInfo.FileName

    Write-Log "Downloading PowerShell 7 MSI..."
    Write-Log "URL : $($downloadInfo.Url)"
    Write-Log "Dest: $msiPath"

    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $downloadInfo.Url -OutFile $msiPath -UseBasicParsing

    if (-not (Test-Path $msiPath) -or (Get-Item $msiPath).Length -lt 1MB) {
        throw "Download failed or file is too small."
    }

    $fileSizeMB = [math]::Round((Get-Item $msiPath).Length / 1MB, 2)
    Write-Log "Download complete ($fileSizeMB MB)" -Level SUCCESS

    # Integrity checks (Authenticode + SHA-256)
    Test-InstallerIntegrity -Path $msiPath `
        -ExpectedPublishers @('Microsoft Corporation', 'Microsoft') `
        -ExpectedSha256 $ExpectedSha256

    Write-Log "Starting silent MSI installation..."

    # ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1  → useful right-click option
    # ENABLE_PSREMOTING=0                         → leave remoting decision to the org
    # REGISTER_MANIFEST=1                         → standard
    $msiArgs = @(
        "/i `"$msiPath`""
        "/qn"
        "/norestart"
        "ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1"
        "ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1"
        "ENABLE_PSREMOTING=0"
        "REGISTER_MANIFEST=1"
        "/L*v `"$($msiPath).install.log`""
    )

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru

    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
        Write-Log "PowerShell 7 installation completed successfully (ExitCode: $($process.ExitCode))" -Level SUCCESS
    }
    else {
        throw "msiexec returned non-zero exit code: $($process.ExitCode). See $($msiPath).install.log"
    }

    Start-Sleep -Seconds 2
    $newVersion = Get-InstalledPowerShell7Version
    if ($newVersion) {
        Write-Log "Verified installed version: $newVersion" -Level SUCCESS
    }
    else {
        Write-Log "Installation reported success but PowerShell 7 version could not be detected afterwards." -Level WARN
    }

    Write-Log "Cleaning up downloaded MSI..."
    Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue

    Write-Log "===== PowerShell 7 installation finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}
