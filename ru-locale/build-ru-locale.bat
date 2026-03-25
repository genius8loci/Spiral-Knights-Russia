@echo off
chcp 65001 >nul 2>nul
title Spiral Knights - Russian Locale Build
echo.
echo ===================================
echo  Сборка русской локализации
echo ===================================
echo.

cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "build-ru-locale.ps1"

echo.
pause
