<#
.SYNOPSIS
    Stops third-party services and processes that commonly block Sysprep.

.EXAMPLE
    .\stop-build-services.ps1
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

function Write-Log {
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

$keepService = @(
    'WinRM'
    'Winmgmt'
    'EventLog'
    'RpcSs'
    'PlugPlay'
    'DcomLaunch'
    'Dhcp'
    'Dnscache'
    'PolicyAgent'
    'CryptSvc'
    'Schedule'
    'ProfSvc'
    'LanmanServer'
    'LanmanWorkstation'
    'W32Time'
    'wuauserv'
    'UsoSvc'
    'BITS'
    'TrustedInstaller'
    'WinDefend'
    'Sense'
    'WdNisSvc'
    'mpssvc'
    'BFE'
    'BrokerInfrastructure'
    'LSM'
    'Power'
    'TrkWks'
    'FontCache'
    'UserManager'
    'SamSs'
    'Netlogon'
    'nsi'
    'NlaSvc'
    'iphlpsvc'
    'WinHttpAutoProxySvc'
    'KeyIso'
    'VaultSvc'
    'StateRepository'
    'TokenBroker'
    'WpnService'
    'gpsvc'
    'seclogon'
    'ShellHWDetection'
    'SysMain'
    'WSearch'
    'Spooler'
    'TermService'
    'UmRdpService'
    'SessionEnv'
    'WindowsAzureGuestAgent'
    'WaAppAgent'
    'RdAgent'
    'WindowsAzureTelemetryService'
    'GCArcService'
    'HybridInstanceMetadataService'
)

$keepProcess = @(
    'csrss'
    'smss'
    'wininit'
    'winlogon'
    'services'
    'lsass'
    'svchost'
    'System'
    'Idle'
    'spoolsv'
    'dwm'
    'explorer'
    'MsMpEng'
    'NisSrv'
    'SecurityHealthService'
    'SearchHost'
    'RuntimeBroker'
    'sihost'
    'taskhostw'
    'conhost'
    'powershell'
    'pwsh'
    'WmiPrvSE'
    'LogonUI'
    'fontdrvhost'
    'dllhost'
    'smartscreen'
    'WindowsAzureGuestAgent'
    'WaAppAgent'
    'WindowsAzureNetAgent'
    'RdAgent'
    'packer'
)

function Test-KeepName {
    param(
        [string]$Name,
        [string[]]$List
    )

    foreach ($item in $List) {
        if ($Name -like $item) { return $true }
    }
    return $false
}

function Test-WindowsBinary {
    param([string]$Path)

    if (-not $Path) { return $true }

    $clean = $Path.Trim('"')
    if ($clean -match '^\\SystemRoot\\') { return $true }
    if ($clean -match '(?i)\\Windows\\System32\\') { return $true }
    if ($clean -match '(?i)\\Windows\\SysWOW64\\') { return $true }
    if ($clean -match '(?i)\\WindowsAzure\\') { return $true }
    if ($clean -match '(?i)\\GuestAgent\\') { return $true }
    return $false
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Stop-BuildServices_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

Write-Log 'Stopping third-party services and processes'

try {
    $services = Get-CimInstance Win32_Service | Where-Object { $_.State -eq 'Running' }
    foreach ($svc in $services) {
        if (Test-KeepName -Name $svc.Name -List $keepService) { continue }
        if (Test-WindowsBinary -Path $svc.PathName) { continue }

        Write-Log ("Stopping service {0} ({1})" -f $svc.Name, $svc.PathName)
        Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc.Name -StartupType Manual -ErrorAction SilentlyContinue
    }

    $procs = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -and
        $_.ExecutablePath -and
        -not (Test-KeepName -Name ($_.Name -replace '\.exe$', '') -List $keepProcess) -and
        -not (Test-WindowsBinary -Path $_.ExecutablePath)
    }

    foreach ($proc in $procs) {
        Write-Log ("Stopping process {0} ({1})" -f $proc.Name, $proc.ExecutablePath)
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }

    Write-Log 'Stop pass finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
