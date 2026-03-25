# ============================================================
# pack-release.ps1
# Package Russian locale for distribution to other players.
# Creates a ZIP with everything users need to install.
# ============================================================

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$gameDir = Split-Path -Parent $scriptDir

$ruLocaleJar = "$gameDir\code\ru-locale.jar"
$launchSteam = "$scriptDir\launch-ru-steam.bat"
$launchDebug = "$scriptDir\launch-ru-debug.bat"

if (-not (Test-Path $ruLocaleJar)) {
    Write-Host "ERROR: code\ru-locale.jar not found!" -ForegroundColor Red
    Write-Host "Run build-ru-locale.bat first" -ForegroundColor Yellow
    exit 1
}

$version = Get-Date -Format "yyyy-MM-dd"
$outputZip = "$scriptDir\SpiralKnights-RU-$version.zip"

if (Test-Path $outputZip) {
    Remove-Item $outputZip -Force
}

Write-Host "=== Packaging Russian Locale ===" -ForegroundColor Cyan
Write-Host ""

$zip = [System.IO.Compression.ZipFile]::Open($outputZip, [System.IO.Compression.ZipArchiveMode]::Create)

function Add-ToZip($filePath, $entryName) {
    $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
    $stream = $entry.Open()
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
    Write-Host "  + $entryName" -ForegroundColor Green
}

Add-ToZip $ruLocaleJar "code/ru-locale.jar"
Add-ToZip $launchSteam "launch-ru-steam.bat"
if (Test-Path $launchDebug) {
    Add-ToZip $launchDebug "launch-ru-debug.bat"
}

# README
$readme = @"
===============================================
  Spiral Knights — Русская локализация
  Версия: $version
===============================================

УСТАНОВКА:
  1. Закройте игру если она запущена
  2. Распакуйте ВСЕ файлы из этого архива
     прямо в папку с игрой (где crucible.jar)
     Обычно: C:\Program Files (x86)\Steam\steamapps\common\Spiral Knights\
  3. Запускайте через launch-ru-steam.bat

ЗАПУСК ЧЕРЕЗ STEAM (с трекингом времени):
  1. Steam -> ПКМ на Spiral Knights -> Свойства
  2. Общие -> Параметры запуска, вставить:
     "C:\Program Files (x86)\Steam\steamapps\common\Spiral Knights\launch-ru-steam.bat" %command%
  3. Теперь при нажатии Играть в Steam запустится русская версия

ФАЙЛЫ:
  code\ru-locale.jar    — перевод (подменяет английские строки)
  launch-ru-steam.bat   — запуск через Steam (с трекингом времени)
  launch-ru-debug.bat   — запуск с консолью (для отладки)

ВАЖНО:
  - Оригинальные файлы игры НЕ изменяются
  - При обновлении игры перевод может потребовать обновления
  - Чтобы вернуть английский — уберите параметры запуска в Steam

УДАЛЕНИЕ:
  Удалите эти файлы:
    code\ru-locale.jar
    launch-ru-steam.bat
    launch-ru-debug.bat
"@

$readmeEntry = $zip.CreateEntry("README-RU.txt", [System.IO.Compression.CompressionLevel]::Optimal)
$readmeStream = $readmeEntry.Open()
$bom = [byte[]]@(0xEF, 0xBB, 0xBF)
$readmeStream.Write($bom, 0, $bom.Length)
$readmeBytes = [System.Text.Encoding]::UTF8.GetBytes($readme)
$readmeStream.Write($readmeBytes, 0, $readmeBytes.Length)
$readmeStream.Close()
Write-Host "  + README-RU.txt" -ForegroundColor Green

$zip.Dispose()

$zipSize = (Get-Item $outputZip).Length
$zipSizeKB = [math]::Round($zipSize / 1024)

Write-Host ""
Write-Host "Done! Created: $outputZip ($zipSizeKB KB)" -ForegroundColor Cyan
