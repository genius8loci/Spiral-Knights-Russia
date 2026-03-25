@echo off
chcp 65001 >nul 2>nul
title Pack Release
echo.
echo ===================================
echo  Упаковка релиза
echo ===================================
echo.

cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "pack-release.ps1"

echo.
pause
