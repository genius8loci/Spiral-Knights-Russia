@echo off
chcp 65001 >nul 2>nul
title Spiral Knights (Russian) - Debug Mode

:: ============================================================
:: launch-ru-debug.bat
:: Dynamically parses getdown.txt, injects ru-locale.jar.
:: Uses java.exe (not javaw) so the console stays open.
:: ============================================================

cd /d "%~dp0"
setlocal EnableDelayedExpansion

set "JAVA_EXE=java_vm\bin\java.exe"
set "APPDIR=%cd%"

if not exist "code\ru-locale.jar" (
    echo.
    echo ERROR: code\ru-locale.jar not found!
    echo Run build-ru-locale.bat first
    echo.
    pause
    exit /b 1
)

:: ---- Parse getdown.txt ----

set "CP=code\ru-locale.jar"
for /f "usebackq tokens=1,2,* delims==" %%a in ("getdown.txt") do (
    set "key=%%a"
    set "val=%%b"
    if defined key if defined val (
        for /f "tokens=1" %%k in ("!key!") do set "key=%%k"
        for /f "tokens=*" %%v in ("!val!") do set "val=%%v"
        if "!key!"=="code" (
            set "val=!val:/=\!"
            set "CP=!CP!;!val!"
        )
    )
)

set "JVMARGS="
for /f "usebackq tokens=1,* delims==" %%a in ("getdown.txt") do (
    set "key=%%a"
    set "val=%%b"
    if defined key if defined val (
        for /f "tokens=1" %%k in ("!key!") do set "key=%%k"
        for /f "tokens=*" %%v in ("!val!") do set "val=%%v"
        if "!key!"=="jvmarg" (
            echo !val! | findstr /i /c:"[mac" /c:"[linux" >nul 2>nul
            if errorlevel 1 (
                set "val=!val:%%APPDIR%%=%APPDIR%!"
                set "JVMARGS=!JVMARGS! "!val!""
            )
        )
    )
)

set "MAINCLASS=com.threerings.projectx.client.ProjectXApp"
for /f "usebackq tokens=1,* delims==" %%a in ("getdown.txt") do (
    set "key=%%a"
    set "val=%%b"
    if defined key if defined val (
        for /f "tokens=1" %%k in ("!key!") do set "key=%%k"
        for /f "tokens=*" %%v in ("!val!") do set "val=%%v"
        if "!key!"=="class" set "MAINCLASS=!val!"
    )
)

:: ---- Debug info ----
echo ===================================
echo  Spiral Knights - Debug (Russian)
echo ===================================
echo.
echo Java: %JAVA_EXE%
echo AppDir: %APPDIR%
echo Class: %MAINCLASS%
echo CP: %CP%
echo JVMArgs: %JVMARGS%
echo.
echo Launching...
echo.

:: ---- Launch ----
"%JAVA_EXE%" !JVMARGS! -cp "%CP%" %MAINCLASS%

echo.
echo === Game exited (code: %ERRORLEVEL%) ===

endlocal
pause
