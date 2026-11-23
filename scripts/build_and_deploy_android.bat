@echo off
setlocal enabledelayedexpansion

title ExtScreen - Android Client Build & Deploy
cls

echo =====================================================================
echo       ExtScreen: Build NDK + Build APK + Deploy to Tablet
echo =====================================================================
echo.

set "REPO_ROOT=%~dp0.."
pushd "%REPO_ROOT%"
set "REPO_ROOT=%CD%"
popd

echo Building the Android app and native library for ARM64...
powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%\scripts\build_android.ps1" -Arm64Only
if errorlevel 1 (
    echo [ERROR] Android build failed!
    pause
    exit /b 1
)

echo Deploying to Android tablet...
set "APK_PATH=%REPO_ROOT%\client\app\build\outputs\apk\debug\app-debug.apk"
adb push "%APK_PATH%" /data/local/tmp/extscreen.apk
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Failed to push APK to tablet. Check USB connection.
    pause
    exit /b 1
)

adb shell pm install -r -t /data/local/tmp/extscreen.apk
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Failed to install APK on tablet!
    pause
    exit /b 1
)

echo [OK] App successfully installed on tablet!
echo Launching app...
adb shell am start -n com.extscreen/.MainActivity

echo.
echo =====================================================================
echo   Deployment completed! Tablet is running the latest ExtScreen.
echo =====================================================================
echo.
pause
