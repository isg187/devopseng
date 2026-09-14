#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Downloads the devopseng repo, flattens scripts to C:\ProgramData\SDL\scripts,
    and runs every installer in the install folder.

.DESCRIPTION
    Single master script for Azure Image Builder / AVD image customization.
    No parameters — all paths and behavior are hardcoded for GCC High builds.
#>

$ErrorActionPreference = 'Stop'
$Destination = "C:\ProgramData\SDL\scripts"
$TempPath = "C:\Temp\SoftwareInstall"
$RepoZipUrl = "https://github.com/isg187/devopseng/archive/refs/heads/main.zip"
$InstallDir = Join-Path $Destination "install"
$LogDir = Join-Path $Destination "logs"

# Logger
function Write-Log {
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string]$Message = '',
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG')]
        [string]$Level = 'INFO'
    )

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    if ([string]::IsNullOrEmpty($Message)) {
        $entry = ''
    }
    else {
        $entry = "[$ts] [$Level] $Message"
    }

    switch ($Level) {
        'ERROR' { Write-Host $entry -ForegroundColor Red }
        'WARN' { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default { Write-Host $entry }
    }

    if ($script:LogPath) {
        try {
            $dir = Split-Path $script:LogPath -Parent
            if ($dir -and -not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            Add-Content -Path $script:LogPath -Value $entry -ErrorAction SilentlyContinue
        }
        catch { }
    }
}
# Prepare folders and log
try {
    if (Test-Path $TempPath) {
        Remove-Item -Path $TempPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $TempPath -Force | Out-Null
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

    $script:LogPath = Join-Path $LogDir ("Bootstrap-And-Install_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

    Write-Log "===== Bootstrap And Install (Master) ====="
    Write-Log "Destination : $Destination"
    Write-Log "InstallDir  : $InstallDir"
    Write-Log "TempPath    : $TempPath"
    Write-Log "Zip URL     : $RepoZipUrl"
    Write-Log "Log         : $script:LogPath"

    # Download repo zip
    $zipPath = Join-Path $TempPath "devopseng.zip"
    Write-Log "Downloading repository zip..."
    Invoke-WebRequest -Uri $RepoZipUrl -OutFile $zipPath -UseBasicParsing

    if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -lt 1KB) {
        throw "Download failed or zip file is empty."
    }
    Write-Log "Download complete ($([math]::Round((Get-Item $zipPath).Length / 1KB, 1)) KB)" -Level SUCCESS

    # Extract into Destination
    Write-Log "Extracting zip to $Destination ..."
    Expand-Archive -Path $zipPath -DestinationPath $Destination -Force

    # Flatten single root folder (e.g. devopseng-main)
    $rootFolder = Get-ChildItem -Path $Destination -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "devopseng-*" -or $_.Name -like "*-main" -or $_.Name -like "*-master" } |
    Select-Object -First 1

    if (-not $rootFolder) {
        # Fallback: any single top-level directory that contains an install folder
        $dirs = @(Get-ChildItem -Path $Destination -Directory -ErrorAction SilentlyContinue)
        if ($dirs.Count -eq 1 -and (Test-Path (Join-Path $dirs[0].FullName "install"))) {
            $rootFolder = $dirs[0]
        }
    }

    if ($rootFolder) {
        Write-Log "Flattening extracted folder: $($rootFolder.Name)"
        Get-ChildItem -Path $rootFolder.FullName -Force | Move-Item -Destination $Destination -Force
        Remove-Item -Path $rootFolder.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Verify install folder
    if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) {
        Write-Log "Install folder not found after extract: $InstallDir" -Level ERROR
        Write-Log "Contents of Destination:" -Level ERROR
        Get-ChildItem -Path $Destination -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Log "  $($_.FullName)" -Level ERROR
        }
        throw "Install directory missing: $InstallDir"
    }

    $installerScripts = @(
        Get-ChildItem -Path $InstallDir -Filter "*.ps1" -File -ErrorAction Stop |
        Where-Object { $_.Name -notmatch '(?i)^Install-All\.ps1$' } |
        Sort-Object Name
    )

    if ($installerScripts.Count -eq 0) {
        throw "No installer .ps1 files found in $InstallDir"
    }

    Write-Log "Discovered $($installerScripts.Count) installer script(s):"
    $installerScripts | ForEach-Object { Write-Log "  - $($_.Name)" }

    # Run each installer
    $results = @()
    $overallSuccess = $true

    foreach ($scriptFile in $installerScripts) {
        $scriptPath = $scriptFile.FullName
        $name = $scriptFile.BaseName

        Write-Log "--------------------------------------------------"
        Write-Log "Starting: $name"
        Write-Log "Script  : $scriptPath"

        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            Write-Log "Script not found $scriptPath" -Level ERROR
            $results += [pscustomobject]@{ Name = $name; Success = $false; Message = "File not found" }
            $overallSuccess = $false
            continue
        }

        try {
            & $scriptPath -Force
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                throw "Exit code $LASTEXITCODE"
            }
            Write-Log "$name completed successfully." -Level SUCCESS
            $results += [pscustomobject]@{ Name = $name; Success = $true; Message = "OK" }
        }
        catch {
            Write-Log "$name failed: $($_.Exception.Message)" -Level ERROR
            $results += [pscustomobject]@{ Name = $name; Success = $false; Message = $_.Exception.Message }
            $overallSuccess = $false
        }
    }

    # Summary
    Write-Log "=============================================="
    Write-Log "  Summary"
    Write-Log "=============================================="
    $results | ForEach-Object {
        $status = if ($_.Success) { "SUCCESS" } else { "FAILED" }
        Write-Log ("{0,-40} {1}" -f $_.Name, $status)
    }

    # Cleanup temp only
    Remove-Item -Path $TempPath -Recurse -Force -ErrorAction SilentlyContinue

    if ($overallSuccess) {
        Write-Log "All installers completed successfully." -Level SUCCESS
        Write-Log "===== Finished =====" -Level SUCCESS
        exit 0
    }
    else {
        Write-Log "One or more installations failed. Review the log: $script:LogPath" -Level ERROR
        exit 1
    }
}
catch {
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log "MASTER SCRIPT FAILED: $($_.Exception.Message)" -Level ERROR
    }
    else {
        Write-Host "[ERROR] MASTER SCRIPT FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
    exit 1
}
