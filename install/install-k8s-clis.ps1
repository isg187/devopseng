<#
.SYNOPSIS
    Installs kubectl, Helm, and/or Argo CD CLI.

.DESCRIPTION
    Downloads official Windows amd64 binaries and places them in
    C:\Program Files\SDL-CLIs. Adds that folder to the machine PATH.
    Default installs all three. Pass -Kubectl, -Helm, and/or -ArgoCD to
    install only those tools.

.EXAMPLE
    .\install-k8s-clis.ps1
.EXAMPLE
    .\install-k8s-clis.ps1 -Helm
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Kubectl,
    [switch]$Helm,
    [switch]$ArgoCD,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP "K8sCliInstall"),
    [string]$InstallDir = (Join-Path $env:ProgramFiles "SDL-CLIs"),
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
if (-not $LogPath) { $LogPath = Join-Path $logDir ("Install-K8sClis_{0}.log" -f (Get-Date -Format 'yyyyMMdd')) }
$script:LogPath = $LogPath

Write-Log "===== Starting Kubernetes CLI installation ====="
if (-not $Kubectl -and -not $Helm -and -not $ArgoCD) {
    $Kubectl = $true; $Helm = $true; $ArgoCD = $true
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Test-Path $DownloadPath)) { New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null }
    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

    if ($Kubectl) {
        $existing = Join-Path $InstallDir "kubectl.exe"
        if ((Test-Path $existing) -and -not $Force) {
            Write-Log "kubectl already present. Skipping." -Level SUCCESS
        }
        else {
            $ver = (Invoke-WebRequest -Uri "https://dl.k8s.io/release/stable.txt" -UseBasicParsing).Content.Trim()
            Write-Log "kubectl stable version resolved"
            $url = "https://dl.k8s.io/release/$ver/bin/windows/amd64/kubectl.exe"
            $hashUrl = "https://dl.k8s.io/release/$ver/bin/windows/amd64/kubectl.exe.sha256"
            $tmp = Join-Path $DownloadPath "kubectl.exe"
            Invoke-Download -Url $url -OutFile $tmp
            $vendorHash = $null
            try { $vendorHash = (Invoke-WebRequest -Uri $hashUrl -UseBasicParsing).Content.Trim().Split()[0] } catch { }
            $hashToUse = if ($ExpectedSha256) { $ExpectedSha256 } else { $vendorHash }
            Test-InstallerIntegrity -Path $tmp -ExpectedPublishers @('CNCF','Linux Foundation','Google') -ExpectedSha256 $hashToUse -AllowUnsigned
            Copy-Item $tmp $existing -Force
            Write-Log "kubectl installed" -Level SUCCESS
        }
    }

    if ($Helm) {
        $existing = Join-Path $InstallDir "helm.exe"
        if ((Test-Path $existing) -and -not $Force) {
            Write-Log "Helm already present. Skipping." -Level SUCCESS
        }
        else {
            Write-Log "Querying Helm GitHub releases"
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/helm/helm/releases/latest" -Headers @{ 'User-Agent' = 'SDL-ImageBuilder' }
            $asset = $rel.assets | Where-Object { $_.name -match 'windows-amd64\.zip$' } | Select-Object -First 1
            if (-not $asset) { throw "Could not find Helm windows-amd64 zip" }
            $zip = Join-Path $DownloadPath "helm.zip"
            Invoke-Download -Url $asset.browser_download_url -OutFile $zip
            $extract = Join-Path $DownloadPath "helm"
            if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
            Expand-Archive -Path $zip -DestinationPath $extract -Force
            $helmExe = Get-ChildItem -Path $extract -Filter helm.exe -Recurse | Select-Object -First 1
            if (-not $helmExe) { throw "helm.exe not found in zip" }
            Test-InstallerIntegrity -Path $helmExe.FullName -ExpectedPublishers @('CNCF','Linux Foundation') -ExpectedSha256 $ExpectedSha256 -AllowUnsigned
            Copy-Item $helmExe.FullName $existing -Force
            Write-Log "Helm installed" -Level SUCCESS
        }
    }

    if ($ArgoCD) {
        $existing = Join-Path $InstallDir "argocd.exe"
        if ((Test-Path $existing) -and -not $Force) {
            Write-Log "Argo CD CLI already present. Skipping." -Level SUCCESS
        }
        else {
            Write-Log "Querying Argo CD GitHub releases"
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/argoproj/argo-cd/releases/latest" -Headers @{ 'User-Agent' = 'SDL-ImageBuilder' }
            $asset = $rel.assets | Where-Object { $_.name -eq 'argocd-windows-amd64.exe' } | Select-Object -First 1
            if (-not $asset) { throw "Could not find argocd-windows-amd64.exe" }
            $tmp = Join-Path $DownloadPath "argocd.exe"
            Invoke-Download -Url $asset.browser_download_url -OutFile $tmp
            Test-InstallerIntegrity -Path $tmp -ExpectedPublishers @('CNCF','Linux Foundation') -ExpectedSha256 $ExpectedSha256 -AllowUnsigned
            Copy-Item $tmp $existing -Force
            Write-Log "Argo CD CLI installed" -Level SUCCESS
        }
    }

    Add-MachinePath -Directory $InstallDir
    Write-Log "===== Kubernetes CLI installation finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-Log "ERROR during Kubernetes CLI install" -Level ERROR
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
