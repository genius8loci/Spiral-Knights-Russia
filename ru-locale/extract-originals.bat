@echo off
chcp 65001 >nul 2>nul
title Extract English Originals
echo.
echo ===================================
echo  Извлечение английских оригиналов
echo ===================================
echo.

cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "extract-originals.ps1"

echo.
pause
