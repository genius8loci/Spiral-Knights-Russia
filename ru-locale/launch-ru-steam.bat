@echo off
chcp 65001 >nul 2>nul
title Spiral Knights (Russian)
:: ============================================================
:: launch-ru-steam.bat
:: Dynamically parses getdown.txt for classpath and JVM args,
:: injects ru-locale.jar first so Russian overrides English.
::
:: Steam setup: Right-click Spiral Knights -> Properties ->
::   General -> Launch Options, paste:
::   "C:\Program Files (x86)\Steam\steamapps\common\Spiral Knights\launch-ru-steam.bat" %%command%%
::
:: Uses "start" so the bat exits immediately after launching.
:: ============================================================

cd /d "%~dp0"
setlocal EnableDelayedExpansion

set "JAVA_EXE=java_vm\bin\javaw.exe"
set "APPDIR=%cd%"

:: ---- Parse getdown.txt ----

:: Build classpath: ru-locale.jar FIRST, then code entries from getdown.txt
set "CP=code\ru-locale.jar"
for /f "usebackq tokens=1,2,* delims==" %%a in ("getdown.txt") do (
    set "key=%%a"
    set "val=%%b"
    if defined key if defined val (
        for /f "tokens=1" %%k in ("!key!") do set "key=%%k"
        for /f "tokens=*" %%v in ("!val!") do set "val=%%v"

        if "!key!"=="code" (
            rem Platform tag: strip [windows], skip [linux] and [mac os x].
            rem LWJGL 3 ships its natives inside classpath jars, so leaving the
            rem tag in makes the path bogus and the game dies with
            rem UnsatisfiedLinkError: Failed to locate library: lwjgl.dll
            rem Keep this file pure ASCII - chcp 65001 above makes cmd lose its
            rem read position on multi-byte characters and garble the parsing.
            rem Inside a parenthesised block use rem, not double-colon comments.
            set "keep=1"
            if "!val:~0,1!"=="[" (
                if /i "!val:~0,9!"=="[windows]" (set "val=!val:*] =!") else (set "keep=0")
            )
            if "!keep!"=="1" (
                set "val=!val:/=\!"
                set "CP=!CP!;!val!"
            )
        )
    )
)

:: Build JVM args from getdown.txt (skip platform-specific non-windows entries)
set "JVMARGS="
for /f "usebackq tokens=1,* delims==" %%a in ("getdown.txt") do (
    set "key=%%a"
    set "val=%%b"
    if defined key if defined val (
        for /f "tokens=1" %%k in ("!key!") do set "key=%%k"
        for /f "tokens=*" %%v in ("!val!") do set "val=%%v"

        if "!key!"=="jvmarg" (
            rem same platform-tag handling as for code above
            set "keep=1"
            if "!val:~0,1!"=="[" (
                if /i "!val:~0,9!"=="[windows]" (set "val=!val:*] =!") else (set "keep=0")
            )
            if "!keep!"=="1" (
                set "val=!val:%%APPDIR%%=%APPDIR%!"
                set "JVMARGS=!JVMARGS! "!val!""
            )
        )
    )
)

:: Get main class
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

:: ---- Launch ----
start "" "%JAVA_EXE%" !JVMARGS! -cp "%CP%" %MAINCLASS%

endlocal
