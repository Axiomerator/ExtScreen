[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$hostExe = Join-Path $root 'extscreen-host.exe'
$inf = Join-Path $PSScriptRoot 'vdd\MttVDD.inf'
$settings = Join-Path $PSScriptRoot 'vdd_settings.xml'
foreach ($file in @($hostExe, $inf, $settings)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Missing $file. Extract the complete ExtScreen ZIP before running this helper."
    }
}

function Invoke-HostSetup([string[]]$HostArguments) {
    $process = Start-Process -FilePath $hostExe -ArgumentList $HostArguments -WindowStyle Hidden -PassThru -Wait
    return $process.ExitCode
}

if ((Invoke-HostSetup @('--query-display-driver')) -eq 0) {
    Write-Host 'The virtual display driver is already installed. Open extscreen.exe to connect.'
    exit 0
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $admin) {
    $process = Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"')
    ) -WindowStyle Hidden -PassThru -Wait
    exit $process.ExitCode
}

$configDir = Join-Path $env:SystemDrive 'VirtualDisplayDriver'
New-Item -ItemType Directory -Path $configDir -Force | Out-Null
Copy-Item -LiteralPath $settings -Destination (Join-Path $configDir 'vdd_settings.xml') -Force
$key = 'HKLM:\SOFTWARE\MikeTheTech\VirtualDisplayDriver'
if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key | Out-Null }
Set-ItemProperty -Path $key -Name VDDPATH -Value $configDir

$exitCode = Invoke-HostSetup @('--install-display-driver', ('"' + $inf + '"'))
if ($exitCode -eq 0) {
    Invoke-HostSetup @('--detach-display-if-host-absent') | Out-Null
}
exit $exitCode
