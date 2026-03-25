# ============================================================
# extract-originals.ps1
# Extract all i18n .properties from projectx-config.jar
# into original/ folder for reference during translation.
# Run this after game updates to get fresh English originals.
# ============================================================

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$gameDir = Split-Path -Parent $scriptDir
$sourceJar = "$gameDir\code\projectx-config.jar"
$outDir = "$scriptDir\original"

if (-not (Test-Path $sourceJar)) {
    Write-Host "ERROR: $sourceJar not found!" -ForegroundColor Red
    Write-Host "Make sure this folder is inside the Spiral Knights game directory." -ForegroundColor Yellow
    exit 1
}

Write-Host "=== Extracting i18n from projectx-config.jar ===" -ForegroundColor Cyan
Write-Host "Source: $sourceJar"
Write-Host "Target: $outDir"
Write-Host ""

if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}

$zip = [System.IO.Compression.ZipFile]::OpenRead($sourceJar)
$extracted = 0

foreach ($entry in $zip.Entries) {
    if ($entry.FullName -match "^rsrc/i18n/[^/]+\.properties$" -and $entry.FullName -notmatch '_[a-z]{2}\.properties$') {
        $fileName = [System.IO.Path]::GetFileName($entry.FullName)
        $destPath = "$outDir\$fileName"
        $stream = $entry.Open()
        $fileStream = [System.IO.File]::Create($destPath)
        $stream.CopyTo($fileStream)
        $fileStream.Close()
        $stream.Close()
        Write-Host "  $fileName" -ForegroundColor DarkGray
        $extracted++
    }
}

$zip.Dispose()

Write-Host ""
Write-Host "Extracted $extracted files" -ForegroundColor Green
Write-Host "Done!" -ForegroundColor Cyan
