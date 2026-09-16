<#
.SYNOPSIS
    Silently installs PostgreSQL 18 (64-bit server and command-line tools).

.PARAMETER Force
    Reinstall even if PostgreSQL 18 is already present.

.PARAMETER SuperPassword
    Optional override. If omitted, a random alphanumeric password is generated
    and not written to the log.

.PARAMETER Port
    Server port. Default is 5432.

.EXAMPLE
    .\install-postgresql.ps1
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP 'PostgreSqlInstall'),
    [string]$ExpectedSha256,
    [string]$SuperPassword,
    [int]$Port = 5432
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ConfirmPreference = 'None'

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

function New-RandomPassword {
    param(
        [int]$Length = 12,
        [switch]$IncludeSpecialChars
    )

    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    if ($IncludeSpecialChars) {
        $chars += '!@#$%^&*()-_=+[]{}|;:,.<>?'
    }
    -join (1..$Length | ForEach-Object { $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)] })
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
        throw "Integrity check failed: file not found $Path"
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
            throw "Unexpected publisher $subject"
        }
        return
    }

    Write-Log ('Authenticode not valid ({0})' -f $sig.Status) -Level WARN
}

function Get-InstalledPostgreSql18 {
    $exe = Join-Path $env:ProgramFiles 'PostgreSQL\18\bin\postgres.exe'
    if (Test-Path $exe) {
        return (Get-Item $exe).VersionInfo.ProductVersion
    }

    $svc = Get-Service -Name 'postgresql-x64-18' -ErrorAction SilentlyContinue
    if ($svc) { return $svc.DisplayName }
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

function Get-PostgreSql18DownloadInfo {
    for ($minor = 20; $minor -ge 0; $minor--) {
        foreach ($rev in 5..1) {
            $fileName = 'postgresql-18.{0}-{1}-windows-x64.exe' -f $minor, $rev
            $url = 'https://get.enterprisedb.com/postgresql/{0}' -f $fileName
            try {
                $head = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 20
                if ($head.StatusCode -ge 200 -and $head.StatusCode -lt 400) {
                    return [pscustomobject]@{
                        Version  = ('18.{0}-{1}' -f $minor, $rev)
                        FileName = $fileName
                        Url      = $url
                    }
                }
            }
            catch { }
        }
    }

    throw 'Could not resolve a PostgreSQL 18 Windows x64 installer from EnterpriseDB.'
}

function Set-PostgreSqlLocalOnly {
    param([string]$DataDir)

    $conf = Join-Path $DataDir 'postgresql.conf'
    $hba = Join-Path $DataDir 'pg_hba.conf'
    if (Test-Path $conf) {
        $text = Get-Content -Path $conf -Raw
        if ($text -match '(?m)^\s*listen_addresses\s*=') {
            $text = [regex]::Replace($text, '(?m)^\s*listen_addresses\s*=.*$', "listen_addresses = 'localhost'")
        }
        else {
            $text = $text.TrimEnd() + "`r`nlisten_addresses = 'localhost'`r`n"
        }
        Set-Content -Path $conf -Value $text -Encoding ASCII
    }
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-PostgreSql_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

Write-Log 'Starting PostgreSQL 18 install'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $installed = Get-InstalledPostgreSql18
    if ($installed -and -not $Force) {
        Write-Log ('PostgreSQL 18 already installed: {0}' -f $installed) -Level SUCCESS
        Write-Log 'Install finished' -Level SUCCESS
        exit 0
    }

    if (-not $SuperPassword) {
        $SuperPassword = New-RandomPassword -Length 24
        Write-Log 'Generated random superuser password (not logged)'
    }

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $downloadInfo = Get-PostgreSql18DownloadInfo
    $installerPath = Join-Path $DownloadPath $downloadInfo.FileName
    Write-Log ('Downloading PostgreSQL {0}' -f $downloadInfo.Version)
    Invoke-WebRequest -Uri $downloadInfo.Url -OutFile $installerPath -UseBasicParsing

    if (-not (Test-Path $installerPath) -or (Get-Item $installerPath).Length -lt 50MB) {
        throw 'Download failed or file is too small.'
    }

    $integrityParams = @{
        Path               = $installerPath
        ExpectedPublishers = @('EnterpriseDB', 'PostgreSQL', 'EDB')
    }
    if ($ExpectedSha256) {
        $integrityParams['ExpectedSha256'] = $ExpectedSha256
    }
    Test-InstallerIntegrity @integrityParams

    $installDir = Join-Path $env:ProgramFiles 'PostgreSQL\18'
    $dataDir = Join-Path $installDir 'data'
    Write-Log 'Installing PostgreSQL 18'
    $setupArgs = @(
        '--mode'
        'unattended'
        '--unattendedmodeui'
        'none'
        '--install_runtimes'
        '0'
        '--enable-components'
        'server,commandlinetools'
        '--prefix'
        ('"{0}"' -f $installDir)
        '--datadir'
        ('"{0}"' -f $dataDir)
        '--servicename'
        'postgresql-x64-18'
        '--superaccount'
        'postgres'
        '--superpassword'
        $SuperPassword
        '--serverport'
        ([string]$Port)
    )
    $processParams = @{
        FilePath     = $installerPath
        ArgumentList = ($setupArgs -join ' ')
        Wait         = $true
        PassThru     = $true
    }
    $process = Start-Process @processParams

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "PostgreSQL installer returned non-zero exit code $($process.ExitCode)"
    }

    Set-PostgreSqlLocalOnly -DataDir $dataDir
    Add-MachinePath -Directory (Join-Path $installDir 'bin')

    $svc = Get-Service -Name 'postgresql-x64-18' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Restart-Service -Name 'postgresql-x64-18' -Force -ErrorAction SilentlyContinue
    }

    $newVersion = Get-InstalledPostgreSql18
    if ($newVersion) {
        Write-Log ('PostgreSQL 18 installed: {0}' -f $newVersion) -Level SUCCESS
    }
    else {
        Write-Log 'Installer succeeded but PostgreSQL 18 was not detected.' -Level WARN
    }

    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
