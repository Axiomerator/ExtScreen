[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [switch]$Arm64Only
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\flutter_toolchain.ps1"

$client = Join-Path $PSScriptRoot '..\client'
$sdk = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk')) |
    Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
    Select-Object -First 1
if (-not $sdk) { throw 'Android SDK not found. Set ANDROID_HOME to its installation directory.' }

$previousJavaHome = $env:JAVA_HOME
$previousFlutterRoot = $env:FLUTTER_ROOT
$previousAndroidHome = $env:ANDROID_HOME
$previousNdk = $env:ANDROID_NDK_HOME
try {
    $env:ANDROID_HOME = $sdk
    if (-not $env:ANDROID_NDK_HOME) {
        $ndk = Get-ChildItem -LiteralPath (Join-Path $sdk 'ndk') -Directory |
            Sort-Object { [version]$_.Name } -Descending |
            Select-Object -First 1
        if (-not $ndk) { throw 'Android NDK not found. Install it or set ANDROID_NDK_HOME.' }
        $env:ANDROID_NDK_HOME = $ndk.FullName
    }
    if ($env:EXTSCREEN_JAVA_HOME) {
        if (-not (Test-Path -LiteralPath (Join-Path $env:EXTSCREEN_JAVA_HOME 'bin\java.exe') -PathType Leaf)) {
            throw 'EXTSCREEN_JAVA_HOME must point to a JDK installation.'
        }
        $env:JAVA_HOME = $env:EXTSCREEN_JAVA_HOME
    }

    Invoke-ExtScreenFlutter @('pub', 'get')
    $env:FLUTTER_ROOT = Get-ExtScreenFlutterRoot

    $targets = @('-t', 'arm64-v8a')
    if (-not $Arm64Only) { $targets += @('-t', 'armeabi-v7a', '-t', 'x86_64') }
    Push-Location -LiteralPath (Join-Path $client 'native')
    try {
        & cargo ndk @targets -P 26 -o '..\app\src\main\jniLibs' build --release --locked
        if ($LASTEXITCODE -ne 0) { throw "Android Rust build failed with exit code $LASTEXITCODE." }
    } finally {
        Pop-Location
    }

    Push-Location -LiteralPath $client
    try {
        & .\gradlew.bat "assemble$Configuration" "-Pflutter.sdk=$env:FLUTTER_ROOT" --console=plain
        if ($LASTEXITCODE -ne 0) { throw "Android Gradle build failed with exit code $LASTEXITCODE." }
    } finally {
        Pop-Location
    }
} finally {
    $env:JAVA_HOME = $previousJavaHome
    $env:FLUTTER_ROOT = $previousFlutterRoot
    $env:ANDROID_HOME = $previousAndroidHome
    $env:ANDROID_NDK_HOME = $previousNdk
}
