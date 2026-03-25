@echo off
chcp 65001 >nul 2>nul
title Diff Update
echo.
echo ===================================
echo  Поиск непереведённых ключей
echo ===================================
echo.

cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "diff-update.ps1"

echo.
pause
