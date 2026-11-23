<#
.SYNOPSIS
    Builds a complete ExtScreen release into dist\: the Android APK, the portable Windows ZIP and
    SHA256SUMS.txt.
.DESCRIPTION
    Runs the tests, builds the Android native library for every supported CPU (arm64-v8a,
    armeabi-v7a, x86_64), the APK, Windows host, and Flutter dashboard with its portable runtime.

    Needs: Rust (with the Android targets and cargo-ndk), the Android SDK + NDK, JDK 17,
    FVM with the pinned Flutter SDK. The APK is signed when a keystore is configured (see client/app/build.gradle.kts:
    EXTSCREEN_KEYSTORE_PROPERTIES or client/keystore.properties); otherwise it is left unsigned.
.PARAMETER SkipTests
    Skip the unit tests.
#>
[CmdletBinding()]
param([switch]$SkipTests)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path "$PSScriptRoot\..").Path
$dist = Join-Path $root "dist"

function Step($text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }
function Run($exe, [string[]]$arguments, $dir = $root) {
    Push-Location $dir
    try {
        & $exe @arguments
        if ($LASTEXITCODE -ne 0) { throw "$exe $($arguments -join ' ') failed with exit code $LASTEXITCODE" }
    } finally { Pop-Location }
}

$version = (Select-String -Path (Join-Path $root "host\Cargo.toml") -Pattern '^version\s*=\s*"([^"]+)"').Matches[0].Groups[1].Value
Write-Host "ExtScreen $version" -ForegroundColor Yellow

New-Item -ItemType Directory -Force $dist | Out-Null

if (-not $SkipTests) {
    Step "Tests"
    Run cargo @("test", "--release", "--workspace", "--locked")
    Run cargo @("test", "--release", "--locked") (Join-Path $root "client\native")
}

Step "Android APK and native libraries"
& (Join-Path $PSScriptRoot 'build_android.ps1') -Configuration Release
$apkDir = Join-Path $root "client\app\build\outputs\apk\release"
$gradleOutput = Get-Content -LiteralPath (Join-Path $apkDir 'output-metadata.json') -Raw | ConvertFrom-Json
$apk = Join-Path $apkDir $gradleOutput.elements[0].outputFile
if (-not (Test-Path -LiteralPath $apk -PathType Leaf)) { throw "No APK produced in $apkDir" }
if ($apk -like "*unsigned*") { Write-Warning "The APK is unsigned (no keystore configured); Android will not install it as is." }
Copy-Item -LiteralPath $apk -Destination (Join-Path $dist "ExtScreen-$version.apk") -Force

Step "Windows host"
$defaultHostExe = Join-Path $root "target\release\extscreen-host.exe"
$hostLocked = $false
if (Test-Path $defaultHostExe) {
    try {
        $fs = [System.IO.File]::Open($defaultHostExe, 'Open', 'ReadWrite', 'None')
        $fs.Close()
    } catch {
        $hostLocked = $true
    }
}
if ($hostLocked) {
    Write-Warning "target\release\extscreen-host.exe is currently running; building into target\release-stage so your live display is not interrupted."
    $stageDir = Join-Path $root "target\release-stage"
    Run cargo @("build", "--release", "--locked", "-p", "extscreen-host", "--bin", "extscreen-host", "--target-dir", $stageDir)
    $hostExe = Join-Path $stageDir "release\extscreen-host.exe"
} else {
    Run cargo @("build", "--release", "--locked", "-p", "extscreen-host", "--bin", "extscreen-host")
    $hostExe = $defaultHostExe
}

Step "Windows Prism dashboard"
& (Join-Path $PSScriptRoot 'build_windows_ui.ps1')
$dashboardDir = Join-Path $root 'ui\build\windows\x64\runner\Release'

Step "Windows portable ZIP"
$windowsZip = "ExtScreen-$version-Windows-x64.zip"
& (Join-Path $PSScriptRoot 'package_windows.ps1') -DashboardDir $dashboardDir -HostExe $hostExe -OutputZip (Join-Path $dist $windowsZip)

Step "Checksums"
$files = @("ExtScreen-$version.apk", $windowsZip)
$lines = foreach ($f in $files) {
    $hash = (Get-FileHash (Join-Path $dist $f) -Algorithm SHA256).Hash.ToLower()
    "$hash  $f"
}
# LF line endings, so `sha256sum -c SHA256SUMS.txt` works on Linux and macOS too.
[System.IO.File]::WriteAllText((Join-Path $dist "SHA256SUMS.txt"), (($lines -join "`n") + "`n"))
$lines | ForEach-Object { Write-Host "  $_" }

Write-Host ""
Write-Host "Done. Release files are in $dist" -ForegroundColor Green
