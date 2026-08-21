@echo off
chcp 65001 >nul 2>nul
title Update Translation
echo.
echo ===================================
echo  Обновление перевода после патча
echo ===================================
echo.

cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "update.ps1" %*

echo.
pause
