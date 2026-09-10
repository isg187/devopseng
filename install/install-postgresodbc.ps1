<#
.SYNOPSIS
    Silently installs the PostgreSQL ODBC driver (psqlODBC x64).

.DESCRIPTION
    Downloads the latest official x64 MSI from PostgreSQL ODBC GitHub
    releases and installs it quietly.

.EXAMPLE
    .\install-postgresodbc.ps1
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP "PostgresOdbcInstall"),
    [string]$ExpectedSha256
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
if (-not $LogPath) { $LogPath = Join-Path $logDir ("Install-PostgresOdbc_{0}.log" -f (Get-Date -Format 'yyyyMMdd')) }
$script:LogPath = $LogPath

Write-Log "===== Starting PostgreSQL ODBC installation ====="

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $installed = Get-ItemProperty HKLM:\SOFTWARE\ODBC\ODBCINST.INI\* -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like '*PostgreSQL*' }
    if ($installed -and -not $Force) {
        Write-Log "PostgreSQL ODBC driver already present. Skipping." -Level SUCCESS
        exit 0
    }

    if (-not (Test-Path $DownloadPath)) { New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null }

    Write-Log "Querying psqlODBC GitHub releases"
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/postgresql-interfaces/psqlodbc/releases/latest" -Headers @{ 'User-Agent' = 'SDL-ImageBuilder' }
    $asset = $rel.assets | Where-Object { $_.name -match 'x64\.msi$' -or $_.name -match 'psqlodbc_x64\.msi$' } | Select-Object -First 1
    if (-not $asset) {
        $zip = $rel.assets | Where-Object { $_.name -match 'x64.*\.zip$' } | Select-Object -First 1
        if (-not $zip) { throw "Could not find psqlODBC x64 MSI or zip" }
        $zipPath = Join-Path $DownloadPath $zip.name
        Invoke-Download -Url $zip.browser_download_url -OutFile $zipPath
        $extract = Join-Path $DownloadPath "odbc"
        Expand-Archive -Path $zipPath -DestinationPath $extract -Force
        $msiItem = Get-ChildItem $extract -Filter *.msi -Recurse | Where-Object { $_.Name -match 'x64|64' } | Select-Object -First 1
        if (-not $msiItem) { $msiItem = Get-ChildItem $extract -Filter *.msi -Recurse | Select-Object -First 1 }
        if (-not $msiItem) { throw "No MSI inside psqlODBC zip" }
        $msi = $msiItem.FullName
    }
    else {
        $msi = Join-Path $DownloadPath $asset.name
        Invoke-Download -Url $asset.browser_download_url -OutFile $msi
    }

    Test-InstallerIntegrity -Path $msi -ExpectedPublishers @('PostgreSQL','PSQL','EnterpriseDB') -ExpectedSha256 $ExpectedSha256 -AllowUnsigned
    Write-Log "Starting silent psqlODBC MSI install"
    $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "psqlODBC MSI exited with a non-zero code" }
    Write-Log "PostgreSQL ODBC installer finished" -Level SUCCESS
    Write-Log "===== PostgreSQL ODBC installation finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-Log "ERROR during PostgreSQL ODBC install" -Level ERROR
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
