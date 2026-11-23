[CmdletBinding()]
param([switch]$Install)

$ErrorActionPreference = 'Stop'
$hostExe = Join-Path $PSScriptRoot '..\target\release\extscreen-host.exe'
if (-not (Test-Path -LiteralPath $hostExe -PathType Leaf)) {
    Write-Warning 'Build the ExtScreen Windows host before checking or installing its display driver.'
    exit 1
}

if ($Install) {
    & (Join-Path $PSScriptRoot 'setup_portable.ps1') -HostExe $hostExe
    exit $LASTEXITCODE
}

$process = Start-Process -FilePath $hostExe -ArgumentList '--query-display-driver' -WindowStyle Hidden -PassThru -Wait
if ($process.ExitCode -eq 0) {
    Write-Host 'The MttVDD device is present.'
} else {
    Write-Host 'MttVDD is missing. Install it from ExtScreen settings when you want an extended display.'
}
exit $process.ExitCode
