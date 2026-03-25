# ============================================================
# build-ru-locale.ps1
# Build ru-locale.jar — Russian translations replace English
# base .properties files (no _ru suffix, no config.jar patch)
# ============================================================

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$gameDir = Split-Path -Parent $scriptDir
$ruDir = "$scriptDir\ru"
$outputJar = "$gameDir\code\ru-locale.jar"

Write-Host "=== Building ru-locale.jar ===" -ForegroundColor Cyan
Write-Host ""

# Check source files
$ruFiles = Get-ChildItem "$ruDir\*.properties" -ErrorAction SilentlyContinue

if (-not $ruFiles) {
    Write-Host "ERROR: No .properties files found in $ruDir\" -ForegroundColor Red
    exit 1
}

# Remove old JAR
if (Test-Path $outputJar) {
    Remove-Item $outputJar -Force
    Write-Host "Removed old $outputJar"
}

# ============================================================
# ru-locale.jar — write .properties as base .properties
# so they override English without adding a new locale
# ============================================================
$zip = [System.IO.Compression.ZipFile]::Open($outputJar, [System.IO.Compression.ZipArchiveMode]::Create)

$addedCount = 0
foreach ($file in $ruFiles) {
    $entryPath = "rsrc/i18n/$($file.Name)"
    $entry = $zip.CreateEntry($entryPath, [System.IO.Compression.CompressionLevel]::Optimal)
    $stream = $entry.Open()
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
    Write-Host "  $($file.Name)" -ForegroundColor DarkGray
    $addedCount++
}

$zip.Dispose()

$jarSize = (Get-Item $outputJar).Length
Write-Host ""
Write-Host "  + $addedCount files (ru -> base)" -ForegroundColor Green
Write-Host "  Created: $outputJar ($jarSize bytes)" -ForegroundColor Cyan
Write-Host ""
Write-Host "Now launch the game via launch-ru-steam.bat" -ForegroundColor Yellow
