<#
.SYNOPSIS
    Installs kubectl, Helm, and/or Argo CD CLI.

.DESCRIPTION
    Downloads official Windows amd64 binaries into C:\Program Files\SDL-CLIs
    and adds that folder to the machine PATH.
    Default installs all three. Pass -Kubectl, -Helm, and/or -ArgoCD to
    install only those tools.

.PARAMETER Force
    Replace binaries even if they already exist.

.EXAMPLE
    .\install-k8s-clis.ps1

.EXAMPLE
    .\install-k8s-clis.ps1 -Helm
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Kubectl,
    [switch]$Helm,
    [switch]$ArgoCD,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP 'K8sCliInstall'),
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'SDL-CLIs')
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

function Test-BinaryIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
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
    if ($sig.Status -eq 'Valid') { return }

    Write-Log ('Authenticode not valid ({0}); official CLI binaries are often unsigned' -f $sig.Status) -Level WARN
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

function Get-GitHubLatestRelease {
    param([string]$Repo)

    $headers = @{
        'User-Agent' = 'PowerShell-K8sCli-Installer'
        'Accept'     = 'application/vnd.github+json'
    }
    Invoke-RestMethod -Uri ("https://api.github.com/repos/{0}/releases/latest" -f $Repo) -Headers $headers -TimeoutSec 30
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-K8sClis_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

if (-not $Kubectl -and -not $Helm -and -not $ArgoCD) {
    $Kubectl = $true
    $Helm = $true
    $ArgoCD = $true
}

Write-Log 'Starting Kubernetes CLI install'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    $ProgressPreference = 'SilentlyContinue'

    if ($Kubectl) {
        $dest = Join-Path $InstallDir 'kubectl.exe'
        if ((Test-Path $dest) -and -not $Force) {
            Write-Log 'kubectl already installed' -Level SUCCESS
        }
        else {
            $ver = (Invoke-WebRequest -Uri 'https://dl.k8s.io/release/stable.txt' -UseBasicParsing).Content.Trim()
            Write-Log ('Downloading kubectl {0}' -f $ver)
            $tmp = Join-Path $DownloadPath 'kubectl.exe'
            Invoke-WebRequest -Uri ("https://dl.k8s.io/release/{0}/bin/windows/amd64/kubectl.exe" -f $ver) -OutFile $tmp -UseBasicParsing

            $vendorHash = $null
            try {
                $hashContent = (Invoke-WebRequest -Uri ("https://dl.k8s.io/release/{0}/bin/windows/amd64/kubectl.exe.sha256" -f $ver) -UseBasicParsing).Content.Trim()
                $vendorHash = ($hashContent -split '\s+')[0]
            }
            catch { }

            Test-BinaryIntegrity -Path $tmp -ExpectedSha256 $vendorHash
            Copy-Item -Path $tmp -Destination $dest -Force
            Write-Log 'kubectl installed' -Level SUCCESS
        }
    }

    if ($Helm) {
        $dest = Join-Path $InstallDir 'helm.exe'
        if ((Test-Path $dest) -and -not $Force) {
            Write-Log 'Helm already installed' -Level SUCCESS
        }
        else {
            $release = Get-GitHubLatestRelease -Repo 'helm/helm'
            $ver = $release.tag_name
            if ($ver -notmatch '^v\d') {
                throw "Unexpected Helm tag $ver"
            }

            $zipUrl = 'https://get.helm.sh/helm-{0}-windows-amd64.zip' -f $ver
            $hashUrl = 'https://get.helm.sh/helm-{0}-windows-amd64.zip.sha256sum' -f $ver
            $zipPath = Join-Path $DownloadPath 'helm.zip'
            Write-Log ('Downloading Helm {0}' -f ($ver -replace '^v', ''))
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

            $vendorHash = $null
            try {
                $hashContent = (Invoke-WebRequest -Uri $hashUrl -UseBasicParsing).Content.Trim()
                $vendorHash = ($hashContent -split '\s+')[0]
            }
            catch { }

            $extractPath = Join-Path $DownloadPath 'helm'
            if (Test-Path $extractPath) {
                Remove-Item -Path $extractPath -Recurse -Force
            }
            Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

            $helmExe = Get-ChildItem -Path $extractPath -Filter 'helm.exe' -Recurse | Select-Object -First 1
            if (-not $helmExe) {
                throw 'helm.exe not found in zip.'
            }

            Test-BinaryIntegrity -Path $helmExe.FullName -ExpectedSha256 $vendorHash
            Copy-Item -Path $helmExe.FullName -Destination $dest -Force
            Write-Log 'Helm installed' -Level SUCCESS
        }
    }

    if ($ArgoCD) {
        $dest = Join-Path $InstallDir 'argocd.exe'
        if ((Test-Path $dest) -and -not $Force) {
            Write-Log 'Argo CD CLI already installed' -Level SUCCESS
        }
        else {
            $release = Get-GitHubLatestRelease -Repo 'argoproj/argo-cd'
            $asset = $release.assets | Where-Object { $_.name -eq 'argocd-windows-amd64.exe' } | Select-Object -First 1
            if (-not $asset) {
                throw 'Could not find argocd-windows-amd64.exe.'
            }

            Write-Log ('Downloading Argo CD CLI {0}' -f ($release.tag_name -replace '^v', ''))
            $tmp = Join-Path $DownloadPath 'argocd.exe'
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing

            Test-BinaryIntegrity -Path $tmp
            Copy-Item -Path $tmp -Destination $dest -Force
            Write-Log 'Argo CD CLI installed' -Level SUCCESS
        }
    }

    Add-MachinePath -Directory $InstallDir
    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
