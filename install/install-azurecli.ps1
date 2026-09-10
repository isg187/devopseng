<#
.SYNOPSIS
    Silently installs Azure CLI and/or Bicep.

.DESCRIPTION
    Azure CLI from the official 64-bit MSI (aka.ms).
    Bicep via "az bicep install" when Azure CLI is present, otherwise the
    official bicep-win-x64.exe from GitHub.
    Default installs both. Use switches to choose one.

.PARAMETER AzureCli
    Install Azure CLI only (still default if no switches are passed).

.PARAMETER Bicep
    Install Bicep.

.EXAMPLE
    .\install-azurecli.ps1
.EXAMPLE
    .\install-azurecli.ps1 -AzureCli
.EXAMPLE
    .\install-azurecli.ps1 -Bicep
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$AzureCli,
    [switch]$Bicep,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP "AzureCliInstall"),
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
if (-not $LogPath) { $LogPath = Join-Path $logDir ("Install-AzureCli_{0}.log" -f (Get-Date -Format 'yyyyMMdd')) }
$script:LogPath = $LogPath

Write-Log "===== Starting Azure CLI / Bicep installation ====="
if (-not $AzureCli -and -not $Bicep) { $AzureCli = $true; $Bicep = $true }
Write-Log "AzureCli switch set"
Write-Log "Bicep switch set"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Test-Path $DownloadPath)) { New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null }

    if ($AzureCli) {
        $azCmd = Get-Command az -ErrorAction SilentlyContinue
        if ($azCmd -and -not $Force) {
            Write-Log "Azure CLI already present. Skipping CLI install." -Level SUCCESS
        }
        else {
            $msi = Join-Path $DownloadPath "AzureCLI.msi"
            Invoke-Download -Url "https://aka.ms/installazurecliwindowsx64" -OutFile $msi
            Test-InstallerIntegrity -Path $msi -ExpectedPublishers @('Microsoft Corporation','Microsoft') -ExpectedSha256 $ExpectedSha256
            Write-Log "Starting silent Azure CLI MSI install"
            $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') -Wait -PassThru
            if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "Azure CLI MSI exited with a non-zero code" }
            Write-Log "Azure CLI installer finished" -Level SUCCESS
            $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
            Remove-Item $msi -Force -ErrorAction SilentlyContinue
        }
    }

    if ($Bicep) {
        $azCmd = Get-Command az -ErrorAction SilentlyContinue
        if ($azCmd) {
            Write-Log "Installing Bicep with az bicep install"
            & az bicep install 2>$null
            if ($Force) { & az bicep upgrade 2>$null }
            Write-Log "az bicep install completed" -Level SUCCESS
        }
        else {
            Write-Log "Azure CLI not on PATH. Installing standalone Bicep binary."
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/Azure/bicep/releases/latest" -Headers @{ 'User-Agent' = 'SDL-ImageBuilder' }
            $asset = $rel.assets | Where-Object { $_.name -eq 'bicep-win-x64.exe' } | Select-Object -First 1
            if (-not $asset) { throw "Could not find bicep-win-x64.exe" }
            $destDir = Join-Path $env:ProgramFiles "Bicep"
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            $dest = Join-Path $destDir "bicep.exe"
            Invoke-Download -Url $asset.browser_download_url -OutFile $dest
            Test-InstallerIntegrity -Path $dest -ExpectedPublishers @('Microsoft Corporation','Microsoft') -ExpectedSha256 $ExpectedSha256 -AllowUnsigned
            Add-MachinePath -Directory $destDir
            Write-Log "Standalone Bicep installed" -Level SUCCESS
        }
    }

    Write-Log "===== Azure CLI / Bicep installation finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-Log "ERROR during Azure CLI / Bicep install" -Level ERROR
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
