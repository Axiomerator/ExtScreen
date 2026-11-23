[CmdletBinding()]
param(
    [string]$HostExe = (Join-Path $PSScriptRoot '..\extscreen-host.exe')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $HostExe -PathType Leaf)) {
    throw "Cannot find $HostExe. Extract the complete ExtScreen ZIP before running this helper."
}

$hostPath = (Resolve-Path -LiteralPath $HostExe).Path
$process = Start-Process -FilePath $hostPath -Verb RunAs -ArgumentList '--install-bundled-display-driver' -WindowStyle Hidden -PassThru -Wait
if ($process.ExitCode -eq 0) {
    Start-Process -FilePath $hostPath -ArgumentList '--detach-display-if-host-absent' -WindowStyle Hidden -Wait
}
exit $process.ExitCode
