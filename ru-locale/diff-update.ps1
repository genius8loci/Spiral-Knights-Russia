# ============================================================
# diff-update.ps1
# Compare current originals with translated files to find
# new/changed keys that need translation.
# ============================================================

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$originalDir = "$scriptDir\original"
$ruDir = "$scriptDir\ru"

if (-not (Test-Path $originalDir)) {
    Write-Host "ERROR: original/ folder not found. Run extract-originals first." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $ruDir)) {
    Write-Host "ERROR: ru\ folder not found." -ForegroundColor Red
    exit 1
}

Write-Host "=== Comparing originals vs translations ===" -ForegroundColor Cyan
Write-Host ""

# Get all base English files (no locale suffix)
$baseFiles = Get-ChildItem "$originalDir\*.properties" | Where-Object {
    $_.Name -notmatch '_[a-z]{2}\.properties$'
}

$totalMissing = 0
$totalNew = 0
$totalTokenIssues = 0

foreach ($baseFile in $baseFiles) {
    $ruFile = "$ruDir\$($baseFile.Name)"

    if (-not (Test-Path $ruFile)) {
        Write-Host "  [NEW FILE] $($baseFile.Name) - no translation exists" -ForegroundColor Yellow
        $totalNew++
        continue
    }

    # Parse keys and values from both files
    $enKeys = @{}
    Get-Content $baseFile.FullName -Encoding UTF8 | ForEach-Object {
        if ($_ -match '^\s*([^#=\s][^=]*?)\s*=(.*)') {
            $enKeys[$Matches[1].Trim()] = $Matches[2]
        }
    }

    $ruKeys = @{}
    Get-Content $ruFile -Encoding UTF8 | ForEach-Object {
        if ($_ -match '^\s*([^#=\s][^=]*?)\s*=(.*)') {
            $ruKeys[$Matches[1].Trim()] = $Matches[2]
        }
    }

    $missing = $enKeys.Keys | Where-Object { -not $ruKeys.ContainsKey($_) }

    if ($missing.Count -gt 0) {
        Write-Host "  $($baseFile.Name): $($missing.Count) missing keys" -ForegroundColor Yellow
        foreach ($key in $missing | Sort-Object) {
            Write-Host "    - $key" -ForegroundColor DarkGray
        }
        $totalMissing += $missing.Count
    }

    # --- Validate special tokens in translated keys ---
    $commonKeys = $enKeys.Keys | Where-Object { $ruKeys.ContainsKey($_) }
    $fileIssues = @()

    foreach ($key in $commonKeys | Sort-Object) {
        $enVal = $enKeys[$key]
        $ruVal = $ruKeys[$key]
        $issues = @()

        # Check {N} format placeholders
        $enPH = @([regex]::Matches($enVal, '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        $ruPH = @([regex]::Matches($ruVal, '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        $missingPH = @($enPH | Where-Object { $_ -notin $ruPH })
        $extraPH   = @($ruPH | Where-Object { $_ -notin $enPH })
        if ($missingPH.Count -gt 0) { $issues += "missing placeholders: $($missingPH -join ', ')" }
        if ($extraPH.Count -gt 0)   { $issues += "extra placeholders: $($extraPH -join ', ')" }

        # Check [[TOKEN]] bracket tokens
        $enBT = @([regex]::Matches($enVal, '\[\[.+?\]\]') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        $ruBT = @([regex]::Matches($ruVal, '\[\[.+?\]\]') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        $missingBT = @($enBT | Where-Object { $_ -notin $ruBT })
        $extraBT   = @($ruBT | Where-Object { $_ -notin $enBT })
        if ($missingBT.Count -gt 0) { $issues += "missing tokens: $($missingBT -join ', ')" }
        if ($extraBT.Count -gt 0)   { $issues += "extra tokens: $($extraBT -join ', ')" }

        # Check escape sequences: \n \t \: \= \#
        # Note: \! is skipped — ! never needs escaping in .properties values
        foreach ($esc in @('n', 't', ':', '=', '#')) {
            $pat = '\\' + $esc
            $label = '\' + $esc
            $enC = ([regex]::Matches($enVal, $pat)).Count
            $ruC = ([regex]::Matches($ruVal, $pat)).Count
            if ($enC -ne $ruC) { $issues += "$label count: EN=$enC RU=$ruC" }
        }

        if ($issues.Count -gt 0) {
            $fileIssues += [PSCustomObject]@{ Key = $key; Issues = $issues }
        }
    }

    if ($fileIssues.Count -gt 0) {
        Write-Host "  $($baseFile.Name): $($fileIssues.Count) keys with token issues" -ForegroundColor Red
        foreach ($fi in $fileIssues) {
            foreach ($issue in $fi.Issues) {
                Write-Host "    [$($fi.Key)] $issue" -ForegroundColor DarkYellow
            }
        }
        $totalTokenIssues += $fileIssues.Count
    }
}

Write-Host ""
if ($totalNew -eq 0 -and $totalMissing -eq 0 -and $totalTokenIssues -eq 0) {
    Write-Host "All keys are translated and valid!" -ForegroundColor Green
} else {
    if ($totalNew -gt 0) {
        Write-Host "  Files without translation: $totalNew" -ForegroundColor Yellow
    }
    if ($totalMissing -gt 0) {
        Write-Host "  Missing keys total: $totalMissing" -ForegroundColor Yellow
    }
    if ($totalTokenIssues -gt 0) {
        Write-Host "  Keys with token/escape issues: $totalTokenIssues" -ForegroundColor Red
    }
}
