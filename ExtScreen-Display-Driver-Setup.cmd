@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0driver\setup_portable.ps1"
set "RESULT=%ERRORLEVEL%"
if "%RESULT%"=="0" (
    echo Virtual display driver ready. Open extscreen.exe to connect.
) else if "%RESULT%"=="3010" (
    echo Driver installation succeeded. Restart Windows before connecting.
) else (
    echo Driver setup failed with exit code %RESULT%. Open the driver README for details.
)
pause
exit /b %RESULT%
