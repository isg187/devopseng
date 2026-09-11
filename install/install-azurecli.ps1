<#
.SYNOPSIS
    Silently installs Azure CLI and/or Bicep.

.DESCRIPTION
    Azure CLI from the official 64-bit MSI (aka.ms).
    Bicep via "az bicep install" when Azure CLI is present, otherwise the
    official bicep-win-x64.exe from GitHub.
    Default installs both.

.PARAMETER Force
    Reinstall even if already present.

.EXAMPLE
    .\install-azurecli.ps1

.EXAMPLE
    .\install-azurecli.ps1 -AzureCli

.EXAMPLE
    .\install-azurecli.ps1 -Bicep
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$AzureCli,
    [switch]$Bicep,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP 'AzureCliInstall'),
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
        throw "Authenticode signature is not valid. Status=$($sig.Status)"
    }

    Write-Log ('Authenticode not valid ({0}); SHA-256 was verified' -f $sig.Status) -Level WARN
}

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Add-MachinePath {
    param([string]$Directory)

    if (-not (Test-Path $Directory)) { return }

    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = $current -split ';' | Where-Object { $_ }
    if ($parts -contains $Directory) { return }

    [Environment]::SetEnvironmentVariable('Path', (($parts + $Directory) -join ';'), 'Machine')
    Update-SessionPath
}

function Get-AzCommand {
    Update-SessionPath
    $cmd = Get-Command az -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $azCmd = Join-Path ${env:ProgramFiles} 'Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
    if (Test-Path $azCmd) { return $azCmd }

    return $null
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-AzureCli_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

if (-not $AzureCli -and -not $Bicep) {
    $AzureCli = $true
    $Bicep = $true
}

Write-Log 'Starting Azure CLI / Bicep install'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $ProgressPreference = 'SilentlyContinue'

    if ($AzureCli) {
        $az = Get-AzCommand
        if ($az -and -not $Force) {
            Write-Log 'Azure CLI already installed' -Level SUCCESS
        }
        else {
            $msiPath = Join-Path $DownloadPath 'AzureCLI.msi'
            Write-Log 'Downloading Azure CLI MSI'
            Invoke-WebRequest -Uri 'https://aka.ms/installazurecliwindowsx64' -OutFile $msiPath -UseBasicParsing

            if (-not (Test-Path $msiPath) -or (Get-Item $msiPath).Length -lt 1MB) {
                throw 'Azure CLI download failed or file is too small.'
            }

            $integrityParams = @{
                Path               = $msiPath
                ExpectedPublishers = @('Microsoft Corporation', 'Microsoft')
            }
            if ($ExpectedSha256) {
                $integrityParams['ExpectedSha256'] = $ExpectedSha256
            }
            Test-InstallerIntegrity @integrityParams

            Write-Log 'Installing Azure CLI'
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

            Update-SessionPath
            Write-Log 'Azure CLI installed' -Level SUCCESS
            Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($Bicep) {
        $az = Get-AzCommand
        if ($az) {
            Write-Log 'Installing Bicep with az bicep install'
            & $az bicep install
            if ($Force) {
                & $az bicep upgrade
            }
            Write-Log 'Bicep installed via Azure CLI' -Level SUCCESS
        }
        else {
            Write-Log 'Azure CLI not found; installing standalone Bicep'
            $headers = @{
                'User-Agent' = 'PowerShell-AzureCli-Installer'
                'Accept'     = 'application/vnd.github+json'
            }
            $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/Azure/bicep/releases/latest' -Headers $headers -TimeoutSec 30
            $asset = $release.assets | Where-Object { $_.name -eq 'bicep-win-x64.exe' } | Select-Object -First 1
            if (-not $asset) {
                throw 'Could not find bicep-win-x64.exe.'
            }

            $destDir = Join-Path $env:ProgramFiles 'Bicep'
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            $dest = Join-Path $destDir 'bicep.exe'
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dest -UseBasicParsing

            Test-InstallerIntegrity -Path $dest -ExpectedPublishers @('Microsoft Corporation', 'Microsoft')
            Add-MachinePath -Directory $destDir
            Write-Log 'Standalone Bicep installed' -Level SUCCESS
        }
    }

    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
