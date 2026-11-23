@echo off
title ExtScreen - Wi-Fi Mode
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run_extscreen_wifi.ps1" %*
pause
