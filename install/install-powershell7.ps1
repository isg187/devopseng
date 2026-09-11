<#
.SYNOPSIS
    Downloads and silently installs PowerShell 7 (x64 MSI).

.PARAMETER Force
    Reinstall even if PowerShell 7 is already present.

.PARAMETER LogPath
    Full path to the log file.

.PARAMETER DownloadPath
    Temporary folder for the installer.

.PARAMETER ExpectedSha256
    Optional SHA-256 to enforce.

.EXAMPLE
    .\Install-PowerShell7.ps1

.EXAMPLE
    .\Install-PowerShell7.ps1 -Force
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP 'PowerShell7Install'),
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

function Get-InstalledPowerShell7Version {
    $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path $pwsh) {
        $ver = & $pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
        if ($ver) { return ([string]$ver).Trim() }
    }

    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($base in $paths) {
        $apps = Get-ItemProperty $base -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '^PowerShell 7' }
        foreach ($app in @($apps)) {
            if ($app.DisplayVersion) { return $app.DisplayVersion }
        }
    }

    return $null
}

function Get-PowerShell7DownloadInfo {
    $headers = @{
        'User-Agent' = 'PowerShell-Installer-Script'
        'Accept'     = 'application/vnd.github+json'
    }

    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers $headers -TimeoutSec 30
    $version = $release.tag_name -replace '^v', ''
    $asset = $release.assets |
    Where-Object { $_.name -match 'win-x64\.msi$' -and $_.name -notmatch 'preview|rc|alpha|beta' } |
    Select-Object -First 1

    if (-not $asset) {
        throw 'Could not find a stable win-x64 MSI asset in the latest PowerShell release.'
    }

    [pscustomobject]@{
        Version  = $version
        FileName = $asset.name
        Url      = $asset.browser_download_url
    }
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-PowerShell7_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

Write-Log 'Starting PowerShell 7 install'

try {
    $installedVersion = Get-InstalledPowerShell7Version

    if ($installedVersion -and -not $Force) {
        Write-Log ('PowerShell 7 already installed: {0}' -f $installedVersion) -Level SUCCESS
        Write-Log 'Install finished' -Level SUCCESS
        exit 0
    }

    if ($installedVersion -and $Force) {
        Write-Log ('PowerShell 7 {0} found; Force specified' -f $installedVersion) -Level WARN
    }
    else {
        Write-Log 'PowerShell 7 not detected; installing latest'
    }

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $downloadInfo = Get-PowerShell7DownloadInfo
    $msiPath = Join-Path $DownloadPath $downloadInfo.FileName
    Write-Log ('Downloading PowerShell 7 {0}' -f $downloadInfo.Version)

    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $downloadInfo.Url -OutFile $msiPath -UseBasicParsing

    if (-not (Test-Path $msiPath) -or (Get-Item $msiPath).Length -lt 1MB) {
        throw 'Download failed or file is too small.'
    }

    $integrityParams = @{
        Path               = $msiPath
        ExpectedPublishers = @('Microsoft Corporation', 'Microsoft')
    }
    if ($ExpectedSha256) {
        $integrityParams['ExpectedSha256'] = $ExpectedSha256
    }
    Test-InstallerIntegrity @integrityParams

    Write-Log 'Installing PowerShell 7'
    $msiArgs = @(
        '/i'
        $msiPath
        '/qn'
        '/norestart'
        'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1'
        'ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1'
        'ENABLE_PSREMOTING=0'
        'REGISTER_MANIFEST=1'
        '/L*v'
        ($msiPath + '.install.log')
    )
    $processParams = @{
        FilePath     = 'msiexec.exe'
        ArgumentList = $msiArgs
        Wait         = $true
        PassThru     = $true
    }
    $process = Start-Process @processParams

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "msiexec returned non-zero exit code: $($process.ExitCode)"
    }

    Start-Sleep -Seconds 2
    $newVersion = Get-InstalledPowerShell7Version
    if ($newVersion) {
        Write-Log ('PowerShell 7 installed: {0}' -f $newVersion) -Level SUCCESS
    }
    else {
        Write-Log 'Installer succeeded but PowerShell 7 version was not detected.' -Level WARN
    }

    Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
