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
# README собирается из общего шаблона RELEASE-README.txt — тем же, что использует CI,
# чтобы текст для игроков не расходился между локальной сборкой и релизом на GitHub.
$readmeTemplate = Join-Path $scriptDir "RELEASE-README.txt"
if (-not (Test-Path $readmeTemplate)) {
    Write-Host "ERROR: RELEASE-README.txt not found!" -ForegroundColor Red
    exit 1
}
$readme = (Get-Content $readmeTemplate -Raw -Encoding UTF8) -replace [regex]::Escape("{{VERSION}}"), $version

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
