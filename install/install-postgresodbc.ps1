<#
.SYNOPSIS
    Silently installs the PostgreSQL ODBC driver (psqlODBC x64).

.PARAMETER Force
    Reinstall even if the driver is already present.

.PARAMETER LogPath
    Full path to the log file.

.PARAMETER DownloadPath
    Temporary folder for the installer.

.PARAMETER ExpectedSha256
    Optional SHA-256 to enforce.

.EXAMPLE
    .\install-postgresodbc.ps1
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP 'PostgresOdbcInstall'),
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
        'ERROR'   { Write-Host $entry -ForegroundColor Red }
        'WARN'    { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default   { Write-Host $entry }
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

    Write-Log ('Authenticode not valid ({0}); psqlODBC packages are often unsigned' -f $sig.Status) -Level WARN
}

function Get-InstalledPostgresOdbc {
    Get-ItemProperty 'HKLM:\SOFTWARE\ODBC\ODBCINST.INI\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like '*PostgreSQL*' }
}

function Get-PostgresOdbcDownloadInfo {
    $headers = @{
        'User-Agent' = 'PowerShell-PostgresOdbc-Installer'
        'Accept'     = 'application/vnd.github+json'
    }

    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/postgresql-interfaces/psqlodbc/releases/latest' -Headers $headers -TimeoutSec 30
    $version = $release.tag_name -replace '^v', ''
    $msiAsset = $release.assets |
        Where-Object { $_.name -match 'x64\.msi$' -or $_.name -match 'psqlodbc_x64\.msi$' } |
        Select-Object -First 1
    $zipAsset = $release.assets |
        Where-Object { $_.name -match 'x64.*\.zip$' } |
        Select-Object -First 1

    if (-not $msiAsset -and -not $zipAsset) {
        throw 'Could not find a psqlODBC x64 MSI or zip in the latest release.'
    }

    [pscustomobject]@{
        Version  = $version
        MsiAsset = $msiAsset
        ZipAsset = $zipAsset
    }
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-PostgresOdbc_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

Write-Log 'Starting PostgreSQL ODBC install'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $installed = Get-InstalledPostgresOdbc
    if ($installed -and -not $Force) {
        Write-Log 'PostgreSQL ODBC driver already installed' -Level SUCCESS
        Write-Log 'Install finished' -Level SUCCESS
        exit 0
    }

    if ($installed -and $Force) {
        Write-Log 'PostgreSQL ODBC driver found; Force specified' -Level WARN
    }
    else {
        Write-Log 'PostgreSQL ODBC driver not detected; installing latest'
    }

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $downloadInfo = Get-PostgresOdbcDownloadInfo
    $msiPath = $null
    Write-Log ('Downloading psqlODBC {0}' -f $downloadInfo.Version)

    $ProgressPreference = 'SilentlyContinue'
    if ($downloadInfo.MsiAsset) {
        $msiPath = Join-Path $DownloadPath $downloadInfo.MsiAsset.name
        Invoke-WebRequest -Uri $downloadInfo.MsiAsset.browser_download_url -OutFile $msiPath -UseBasicParsing
    }
    else {
        $zipPath = Join-Path $DownloadPath $downloadInfo.ZipAsset.name
        Invoke-WebRequest -Uri $downloadInfo.ZipAsset.browser_download_url -OutFile $zipPath -UseBasicParsing
        $extractPath = Join-Path $DownloadPath 'odbc'
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
        $msiItem = Get-ChildItem $extractPath -Filter '*.msi' -Recurse |
            Where-Object { $_.Name -match 'x64|64' } |
            Select-Object -First 1
        if (-not $msiItem) {
            $msiItem = Get-ChildItem $extractPath -Filter '*.msi' -Recurse | Select-Object -First 1
        }
        if (-not $msiItem) {
            throw 'No MSI found inside the psqlODBC zip.'
        }
        $msiPath = $msiItem.FullName
    }

    if (-not (Test-Path $msiPath) -or (Get-Item $msiPath).Length -lt 100KB) {
        throw 'Download failed or file is too small.'
    }

    $integrityParams = @{
        Path               = $msiPath
        ExpectedPublishers = @('PostgreSQL', 'PSQL', 'EnterpriseDB')
    }
    if ($ExpectedSha256) {
        $integrityParams['ExpectedSha256'] = $ExpectedSha256
    }
    Test-InstallerIntegrity @integrityParams

    Write-Log 'Installing PostgreSQL ODBC'
    $msiArgs = @(
        '/i'
        $msiPath
        '/qn'
        '/norestart'
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

    if (Get-InstalledPostgresOdbc) {
        Write-Log 'PostgreSQL ODBC driver installed' -Level SUCCESS
    }
    else {
        Write-Log 'Installer succeeded but driver was not detected.' -Level WARN
    }

    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
