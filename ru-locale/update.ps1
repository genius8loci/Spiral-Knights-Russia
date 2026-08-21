# ============================================================
# update.ps1
# Единая точка входа после обновления игры:
#   1. извлекает свежие английские оригиналы из projectx-config.jar
#   2. находит новые и изменившиеся ключи
#   3. допереводит их (память переводов -> кэш -> DeepL -> Yandex -> Google)
#   4. вписывает результат в ru/*.properties
#   5. собирает ru-locale.jar и архив релиза
#
# Ключи API: mt-config.local.json рядом со скриптом либо переменные окружения
#   DEEPL_KEY, YANDEX_KEY, YANDEX_FOLDER
# ============================================================

[CmdletBinding()]
param(
    [switch]$SkipExtract,   # не перечитывать projectx-config.jar
    [switch]$DryRun,        # ничего не писать на диск, только отчёт
    [switch]$NoBuild,       # не собирать jar и архив
    [int]$Limit = 0,        # максимум строк на машинный перевод (0 = без лимита)
    [int]$BatchSize = 40,   # строк в одном запросе к API
    [string]$ReportPath = ''  # куда положить JSON-сводку прогона (для CI)
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module "$scriptDir\lib\SkLocale.psm1" -Force

$originalDir = "$scriptDir\original"
$ruDir       = "$scriptDir\ru"
$cacheDir    = "$scriptDir\cache"
$cachePath   = "$cacheDir\mt-cache.json"
$snapPath    = "$cacheDir\en-snapshot.json"
$failPath    = "$cacheDir\untranslated.txt"
$glossPath   = "$cacheDir\glossary.auto.json"

# ------------------------------------------------------------
# Конфигурация провайдеров
# ------------------------------------------------------------
# Порядок каскада. Первым идёт провайдер с ключом (если он задан), дальше —
# бесключевые, и замыкает argos: он работает оффлайн, без лимитов и без сети,
# поэтому гарантирует, что перевод не встанет совсем.
$cfg = @{
    Order         = @('yandex', 'google', 'deepl', 'mymemory', 'argos')
    DeepLKey      = $env:DEEPL_KEY
    YandexKey     = $env:YANDEX_KEY
    YandexFolder  = $env:YANDEX_FOLDER
    MyMemoryEmail = $env:MYMEMORY_EMAIL
}
$cfgPath = "$scriptDir\mt-config.local.json"
if (Test-Path $cfgPath) {
    $j = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($j.order)        { $cfg.Order        = @($j.order) }
    if ($j.deeplKey)     { $cfg.DeepLKey     = $j.deeplKey }
    if ($j.yandexKey)    { $cfg.YandexKey    = $j.yandexKey }
    if ($j.yandexFolder) { $cfg.YandexFolder = $j.yandexFolder }
    if ($j.myMemoryEmail) { $cfg.MyMemoryEmail = $j.myMemoryEmail }
}

function ConvertTo-Hash {
    param($Obj)
    $h = @{}
    if ($null -ne $Obj) { foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    return $h
}

# Сводка прогона для автоматики: по ней CI решает, есть ли что публиковать
# и не развалился ли каскад провайдеров.
function Write-RunReport {
    param([int]$New, [int]$Changed, [int]$Applied, [int]$Failed, $Sources)
    if (-not $ReportPath) { return }
    $dir = Split-Path -Parent $ReportPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [ordered]@{
        new       = $New
        changed   = $Changed
        applied   = $Applied
        failed    = $Failed
        sources   = $Sources
    } | ConvertTo-Json -Depth 3 | Set-Content $ReportPath -Encoding UTF8
}

Write-Host "=== Обновление русской локализации ===" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------
# 1. Свежие оригиналы
# ------------------------------------------------------------
if (-not $SkipExtract) {
    & "$scriptDir\extract-originals.ps1"
    Write-Host ""
}
if (-not (Test-Path $originalDir)) {
    Write-Host "ОШИБКА: папка original\ не найдена." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir | Out-Null }

# ------------------------------------------------------------
# 2. Дельта: новые и изменившиеся ключи
# ------------------------------------------------------------
$snapshot = @{}
if (Test-Path $snapPath) { $snapshot = ConvertTo-Hash (Get-Content $snapPath -Raw -Encoding UTF8 | ConvertFrom-Json) }

$mtCache = @{}
if (Test-Path $cachePath) { $mtCache = ConvertTo-Hash (Get-Content $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json) }

$baseFiles = Get-ChildItem "$originalDir\*.properties" | Where-Object { $_.Name -notmatch '_[a-z]{2}\.properties$' }

$files    = [ordered]@{}   # имя файла -> @{ En; Ru }
$pending  = New-Object System.Collections.Generic.List[object]
$pairs    = New-Object System.Collections.Generic.List[object]
$newSnap  = @{}
$cntNew = 0; $cntChanged = 0

foreach ($bf in $baseFiles) {
    $name   = $bf.Name
    $ruPath = "$ruDir\$name"
    $en = Read-Props -Path $bf.FullName
    $ru = if (Test-Path $ruPath) { Read-Props -Path $ruPath } else { [ordered]@{} }
    $files[$name] = @{ En = $en; Ru = $ru }

    foreach ($k in $en.Keys) {
        $enVal = $en[$k]
        $sk = "$name|$k"
        $newSnap[$sk] = $enVal

        if (-not $ru.Contains($k)) {
            [void]$pending.Add([PSCustomObject]@{ File = $name; Key = $k; En = $enVal })
            $cntNew++
        }
        elseif ($snapshot.ContainsKey($sk) -and $snapshot[$sk] -ne $enVal) {
            [void]$pending.Add([PSCustomObject]@{ File = $name; Key = $k; En = $enVal })
            $cntChanged++
        }
        else {
            [void]$pairs.Add(@{ En = $enVal; Ru = $ru[$k] })
        }
    }
}

Write-Host "Новых ключей: $cntNew, изменившихся: $cntChanged" -ForegroundColor Yellow

if ($pending.Count -eq 0) {
    Write-Host "Переводить нечего." -ForegroundColor Green
    Write-RunReport -New 0 -Changed 0 -Applied 0 -Failed 0 -Sources @{}
    if (-not $DryRun) { $newSnap | ConvertTo-Json -Depth 2 -Compress | Set-Content $snapPath -Encoding UTF8 }
    if (-not $NoBuild -and -not $DryRun) {
        Write-Host ""
        & "$scriptDir\build-ru-locale.ps1"
        & "$scriptDir\pack-release.ps1"
    }
    exit 0
}

# ------------------------------------------------------------
# 3. Память переводов и автоглоссарий из уже переведённых пар
# ------------------------------------------------------------
$tm = New-TranslationMemory -Pairs $pairs
Write-Host "Память переводов: $($tm.Memory.Count) строк, глоссарий: $($tm.Terms.Count) терминов" -ForegroundColor DarkGray
if (-not $DryRun) {
    $tm.Terms | ConvertTo-Json -Depth 2 | Set-Content $glossPath -Encoding UTF8
}

# Группы ключей, которые в проекте не переводятся: алиасы чат-команд, привязки
# клавиш и т.п. Машинный перевод здесь не улучшает текст, а ломает функциональность
# (переведённый c.saveloadout сломал бы команду /saveloadout).
$skipRules = Get-SkipRules -Files $files
if ($skipRules.Count -gt 0) {
    Write-Host "Не переводится: $(($skipRules.Keys | Sort-Object) -join ', ')" -ForegroundColor DarkGray
}

# Уникальные английские строки -> элементы, которые их используют
$uniq = [ordered]@{}
$skipItems = New-Object System.Collections.Generic.List[object]
foreach ($it in $pending) {
    $dot = $it.Key.IndexOf('.')
    $pre = if ($dot -gt 0) { $it.Key.Substring(0, $dot) } else { $it.Key }
    if ($skipRules.ContainsKey("$($it.File)|$pre")) { [void]$skipItems.Add($it); continue }

    if (-not $uniq.Contains($it.En)) { $uniq[$it.En] = New-Object System.Collections.Generic.List[object] }
    [void]$uniq[$it.En].Add($it)
}

$result = @{}   # en -> ru
$srcCnt = @{ 'память' = 0; 'кэш' = 0; 'как есть' = 0
             'deepl' = 0; 'yandex' = 0; 'google' = 0; 'mymemory' = 0; 'argos' = 0
             'не переводится' = $skipItems.Count }
$failed = New-Object System.Collections.Generic.List[string]
$prot   = @{}
$todo   = New-Object System.Collections.Generic.List[string]

foreach ($en in $uniq.Keys) {
    if ($tm.Memory.ContainsKey($en)) { $result[$en] = $tm.Memory[$en]; $srcCnt['память']++; continue }
    if ($mtCache.ContainsKey($en))   { $result[$en] = $mtCache[$en];   $srcCnt['кэш']++;   continue }

    # Глоссарий применяем только к коротким строкам: в длинных предложениях
    # подстановка термина ломает согласование
    $useTerms = if (($en -split '\s+').Count -le 6) { $tm.Terms } else { $null }
    $p = Protect-Text -Text $en -Terms $useTerms
    $prot[$en] = $p

    # строки без букв (только токены, числа, символы) переводить не нужно
    $plain = [regex]::Replace($p.Text, '(?i)ZX\d+ZX', '')
    if ($plain -notmatch '[A-Za-z]') { $result[$en] = $en; $srcCnt['как есть']++; continue }

    [void]$todo.Add($en)
}

# ------------------------------------------------------------
# 4. Машинный перевод каскадом
# ------------------------------------------------------------
$list = @($todo.ToArray())
if ($Limit -gt 0 -and $list.Count -gt $Limit) {
    Write-Host "Лимит: обрабатываем $Limit из $($list.Count) строк" -ForegroundColor DarkYellow
    $list = @($list[0..($Limit - 1)])
}

if ($list.Count -gt 0) {
    Write-Host "На машинный перевод: $($list.Count) строк" -ForegroundColor Yellow

    for ($i = 0; $i -lt $list.Count; $i += $BatchSize) {
        $last  = [Math]::Min($i + $BatchSize - 1, $list.Count - 1)
        $slice = @($list[$i..$last])
        $texts = @($slice | ForEach-Object { $prot[$_].Text })

        Write-Host ("  строки {0}-{1} из {2}" -f ($i + 1), ($last + 1), $list.Count) -ForegroundColor DarkGray
        $res = Invoke-Mt -Texts $texts -Config $cfg

        for ($j = 0; $j -lt $slice.Count; $j++) {
            $en   = $slice[$j]
            $done = $false

            if ($null -ne $res -and $res.Result.Count -eq $slice.Count) {
                $cand = Restore-Text -Text $res.Result[$j] -Map $prot[$en].Map
                if ($null -ne $cand -and (Test-Tokens -En $en -Ru $cand).Count -eq 0) {
                    $result[$en] = $cand
                    $srcCnt[$res.Provider]++
                    $mtCache[$en] = $cand
                    $done = $true
                }
            }

            # повтор по одной строке следующим провайдером каскада
            if (-not $done) {
                $skip = if ($null -ne $res) { @($res.Provider) } else { @() }
                $alt = Invoke-Mt -Texts @($prot[$en].Text) -Config $cfg -Exclude $skip
                if ($null -ne $alt -and $alt.Result.Count -ge 1) {
                    $cand = Restore-Text -Text $alt.Result[0] -Map $prot[$en].Map
                    if ($null -ne $cand -and (Test-Tokens -En $en -Ru $cand).Count -eq 0) {
                        $result[$en] = $cand
                        $srcCnt[$alt.Provider]++
                        $mtCache[$en] = $cand
                        $done = $true
                    }
                }
            }

            if (-not $done) {
                $result[$en] = $en          # оставляем английский
                [void]$failed.Add($en)
            }
        }
    }
}

# ------------------------------------------------------------
# 5. Слияние и запись
# ------------------------------------------------------------
$applied = 0
foreach ($it in $skipItems) {
    $files[$it.File].Ru[$it.Key] = $it.En   # оставляем как в оригинале
    $applied++
}
foreach ($en in $uniq.Keys) {
    if (-not $result.ContainsKey($en)) { continue }
    foreach ($it in $uniq[$en]) {
        $files[$it.File].Ru[$it.Key] = $result[$en]
        $applied++
    }
}

if ($DryRun) {
    Write-Host ""
    Write-Host "DryRun: файлы не изменены. Готово к записи строк: $applied" -ForegroundColor Cyan
}
else {
    foreach ($name in $files.Keys) {
        Write-MergedProps -OriginalPath "$originalDir\$name" -RuPath "$ruDir\$name" -Ru $files[$name].Ru
    }
    $mtCache  | ConvertTo-Json -Depth 2 -Compress | Set-Content $cachePath -Encoding UTF8
    $newSnap  | ConvertTo-Json -Depth 2 -Compress | Set-Content $snapPath  -Encoding UTF8
    if ($failed.Count -gt 0) { $failed | Set-Content $failPath -Encoding UTF8 } elseif (Test-Path $failPath) { Remove-Item $failPath -Force }
}

# ------------------------------------------------------------
# 6. Отчёт и сборка
# ------------------------------------------------------------
Write-RunReport -New $cntNew -Changed $cntChanged -Applied $applied -Failed $failed.Count -Sources $srcCnt

Write-Host ""
Write-Host "Записано строк: $applied" -ForegroundColor Green
foreach ($k in $srcCnt.Keys) {
    if ($srcCnt[$k] -gt 0) { Write-Host ("  {0,-9} {1}" -f $k, $srcCnt[$k]) -ForegroundColor DarkGray }
}
if ($failed.Count -gt 0) {
    Write-Host "  не переведено: $($failed.Count) (список: cache\untranslated.txt)" -ForegroundColor Red
}

if (-not $NoBuild -and -not $DryRun) {
    Write-Host ""
    & "$scriptDir\build-ru-locale.ps1"
    & "$scriptDir\pack-release.ps1"
    Write-Host ""
    Write-Host "Дальше: git add ru cache && git commit && git tag v… && git push --tags" -ForegroundColor Yellow
}
