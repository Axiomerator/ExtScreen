<#
.SYNOPSIS
    Packages the Windows dashboard, host, and setup files into a portable ZIP.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DashboardDir,
    [Parameter(Mandatory)][string]$HostExe,
    [Parameter(Mandatory)][string]$OutputZip
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$dashboard = (Resolve-Path -LiteralPath $DashboardDir).Path
$hostFile = (Resolve-Path -LiteralPath $HostExe).Path
$output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputZip)

foreach ($file in @(
    'extscreen.exe', 'flutter_windows.dll', 'data\app.so', 'data\icudtl.dat',
    'data\flutter_assets\NOTICES.Z', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $dashboard $file) -PathType Leaf)) {
        throw "Missing Windows dashboard bundle file: $file"
    }
}
if (-not (Test-Path -LiteralPath $hostFile -PathType Leaf)) {
    throw "The Windows host executable is missing: $HostExe"
}

$outputDir = Split-Path -Parent $output
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$temporary = Join-Path $outputDir ('.extscreen-' + [Guid]::NewGuid().ToString('N') + '.zip')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Add-ZipFile($archive, [string]$source, [string]$destination) {
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $archive,
        $source,
        $destination.Replace('\', '/'),
        [IO.Compression.CompressionLevel]::Optimal
    )
}

try {
    $archive = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $prefix = $dashboard.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
        foreach ($file in (Get-ChildItem -LiteralPath $dashboard -Recurse -File)) {
            $relative = $file.FullName.Substring($prefix.Length)
            if ($file.Extension -eq '.pdb' -or $relative -eq 'extscreen-host.exe') { continue }
            if ($relative -eq 'extscreen.exe') {
                $relative = 'ExtScreen.exe'
            }
            Add-ZipFile $archive $file.FullName $relative
        }

        Add-ZipFile $archive $hostFile 'support/extscreen-host.exe'
        # The native host's app-local CRT goes beside the host executable.
        Add-ZipFile $archive (Join-Path $dashboard 'vcruntime140.dll') 'support/vcruntime140.dll'
        Add-ZipFile $archive (Join-Path $root 'docs\WINDOWS_QUICK_START.txt') '开始使用.txt'
        foreach ($relative in @(
            'README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'ARCHITECTURE.md', 'DESIGN.md',
            'host\assets\extscreen-512.png', 'driver\README.md', 'driver\vdd_settings.xml',
            'driver\setup_portable.ps1', 'ExtScreen-Display-Driver-Setup.cmd',
            'ExtScreen-USB-Tethering-Setup.cmd', 'scripts\setup_usb_tethering.ps1',
            'ExtScreen-USB-Setup.cmd', 'scripts\usb_setup.ps1'
        )) {
            Add-ZipFile $archive (Join-Path $root $relative) "support/$relative"
        }
        $uiGuide = 'docs\PRISM_UI_DEVELOPMENT.md'
        if (Test-Path -LiteralPath (Join-Path $root $uiGuide) -PathType Leaf) {
            Add-ZipFile $archive (Join-Path $root $uiGuide) "support/$uiGuide"
        }
        foreach ($file in @('MttVDD.inf', 'MttVDD.dll', 'mttvdd.cat', 'LICENSE.txt')) {
            Add-ZipFile $archive (Join-Path $root "installer\redist\vdd\$file") "support/driver/vdd/$file"
        }
    } finally {
        $archive.Dispose()
    }
    Move-Item -LiteralPath $temporary -Destination $output -Force
} finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
        Remove-Item -LiteralPath $temporary
    }
}
Write-Host "Windows portable ZIP: $output"
