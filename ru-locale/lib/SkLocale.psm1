# ============================================================
# SkLocale.psm1
# Общие функции пайплайна локализации:
#   - чтение/запись .properties (UTF-8 без BOM, LF)
#   - маскировка служебных токенов и терминов глоссария
#   - память переводов и автоглоссарий из существующих пар
#   - вызовы MT-провайдеров (DeepL -> Yandex -> Google)
# ============================================================

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Служебные токены: {0}, [[TOKEN]], <br>, \n, \=, \\ и т.п.
# Прилегающие пробелы забираются в подстановку вместе с токеном. Это ключевой
# момент: движок перевода свободно съедает или размножает пробелы вокруг маркера,
# и если бы отступы оставались в тексте, восстановление давало бы «наЗал Героев».
# Внутри подстановки они возвращаются ровно такими, какими были в оригинале.
$script:TokenRx = [regex]'[ \t]*(?:\{\d+\}|\[\[[^\]]*\]\]|<[^<>]+>|\\.)[ \t]*'

function Get-Marker { param([int]$Index) return "ZX${Index}ZX" }

# Пробелы-разделители вокруг маркеров ставятся ОДИН раз, после того как отработали
# оба прохода маскировки. Если ставить их сразу, второй проход (глоссарий) примет
# разделитель за настоящий пробел исходной строки и утащит его в подстановку:
#   "learned this recipe\!" -> "выучили Рецепт \!" — лишний пробел перед "\!".
# Сам разделитель нужен, потому что вплотную к слову движок склеивает маркер
# с соседними буквами: "ZX2ZXList loadouts" -> "ZX2ZXLСоставьте список".
function Add-MarkerPadding {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    return [regex]::Replace($Text, '(ZX\d+ZX)', ' $1 ')
}

# Разбор маркера при восстановлении. Терпим к регистру и к пробелам, которые
# движок мог вставить внутрь или вокруг маркера; прилегающие пробелы съедаются
# целиком, потому что настоящие отступы хранятся внутри подстановки.
$script:MarkerRx = [regex]::new('[ \t]*Z\s*X\s*(\d+)\s*Z\s*X[ \t]*',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

# ------------------------------------------------------------
# .properties
# ------------------------------------------------------------

function Read-PropLines {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) -split "`r?`n"
}

# Строка считается парой ключ=значение, если она не пустая, не комментарий и содержит '='
function Test-PropLine {
    param([string]$Line)
    return ($Line -match '^\s*[^#!\s]') -and $Line.Contains('=')
}

function Read-Props {
    param([Parameter(Mandatory = $true)][string]$Path)
    $map = [ordered]@{}
    foreach ($ln in (Read-PropLines -Path $Path)) {
        if (Test-PropLine -Line $ln) {
            $i = $ln.IndexOf('=')
            $map[$ln.Substring(0, $i).Trim()] = $ln.Substring($i + 1)
        }
    }
    return $map
}

# Пересобирает ru-файл по структуре оригинала: комментарии и порядок ключей
# берутся из original/, значения — из $Ru. Ключи, которых нет в оригинале,
# дописываются в конец. Даёт минимальный git-diff.
function Write-MergedProps {
    param(
        [Parameter(Mandatory = $true)][string]$OriginalPath,
        [Parameter(Mandatory = $true)][string]$RuPath,
        [Parameter(Mandatory = $true)]$Ru
    )
    $out  = New-Object System.Collections.Generic.List[string]
    $used = New-Object System.Collections.Generic.HashSet[string]

    foreach ($ln in (Read-PropLines -Path $OriginalPath)) {
        if (Test-PropLine -Line $ln) {
            $i = $ln.IndexOf('=')
            $k = $ln.Substring(0, $i).Trim()
            $v = if ($Ru.Contains($k)) { $Ru[$k] } else { $ln.Substring($i + 1) }
            [void]$out.Add("$k=$v")
            [void]$used.Add($k)
        }
        else {
            [void]$out.Add($ln)
        }
    }
    foreach ($k in $Ru.Keys) {
        if (-not $used.Contains($k)) { [void]$out.Add("$k=$($Ru[$k])") }
    }

    # Сохраняем окончания строк существующего ru-файла. В репозитории ru/*.properties
    # лежат в CRLF, а original/ — в LF; если писать всегда LF, первый же прогон
    # перепишет все файлы целиком и git-diff перестанет показывать,
    # что именно изменилось в переводе.
    $nl = "`r`n"
    if (Test-Path $RuPath) {
        $existing = [System.IO.File]::ReadAllText($RuPath, [System.Text.Encoding]::UTF8)
        if (-not $existing.Contains("`r`n")) { $nl = "`n" }
    }

    [System.IO.File]::WriteAllText($RuPath, ($out -join $nl), $script:Utf8NoBom)
}

# Определяет группы ключей, которые в этом проекте принципиально не переводятся:
# алиасы чат-команд (chat.properties c.*), привязки клавиш (projectx.properties k.*)
# и т.п. Правило выводится из уже существующего перевода, а не задаётся руками.
#
# Важно: в файле, переведённом на 0% (story.properties, system.properties),
# «все значения совпадают с английским» не означает запрет на перевод — это
# означает, что файл просто ещё не переводили. Поэтому правило берём только
# из файлов, которые переведены хотя бы наполовину.
function Get-SkipRules {
    param(
        [Parameter(Mandatory = $true)]$Files,       # имя файла -> @{ En = ...; Ru = ... }
        [double]$MinFileRatio = 0.5,
        [int]$MinPrefixKeys = 8
    )
    $skip = @{}

    foreach ($name in $Files.Keys) {
        $en = $Files[$name].En
        $ru = $Files[$name].Ru
        $total = 0; $translated = 0
        $stat = @{}

        foreach ($k in $en.Keys) {
            if (-not $ru.Contains($k)) { continue }
            $total++
            $same = ($ru[$k] -ceq $en[$k])
            if (-not $same) { $translated++ }

            $i = $k.IndexOf('.')
            $pre = if ($i -gt 0) { $k.Substring(0, $i) } else { $k }
            if (-not $stat.ContainsKey($pre)) { $stat[$pre] = @{ Total = 0; Same = 0 } }
            $stat[$pre].Total++
            if ($same) { $stat[$pre].Same++ }
        }

        if ($total -eq 0 -or ($translated / $total) -lt $MinFileRatio) { continue }

        foreach ($pre in $stat.Keys) {
            if ($stat[$pre].Total -ge $MinPrefixKeys -and $stat[$pre].Total -eq $stat[$pre].Same) {
                $skip["$name|$pre"] = $true
            }
        }
    }

    return $skip
}

# ------------------------------------------------------------
# Маскировка
# ------------------------------------------------------------

# Заменяет служебные токены и термины глоссария на маркеры ZX<n>ZX.
# Возвращает @{ Text = <текст для MT>; Map = <список подстановок> }.
# Для токена подстановка — он сам, для термина — его русский эквивалент.
function Protect-Text {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        $Terms
    )
    $map = New-Object System.Collections.Generic.List[string]

    $t = $script:TokenRx.Replace($Text, {
        param($m)
        [void]$map.Add($m.Value)
        Get-Marker -Index ($map.Count - 1)
    })

    if ($Terms) {
        foreach ($term in $Terms) {
            # пробелы вокруг термина забираются в подстановку по той же причине,
            # что и вокруг токенов
            $rx = '(?i)([ \t]*)\b' + [regex]::Escape($term.En) + '\b([ \t]*)'
            if ($t -match $rx) {
                $ru = $term.Ru
                $t = [regex]::Replace($t, $rx, {
                    param($m)
                    [void]$map.Add($m.Groups[1].Value + $ru + $m.Groups[2].Value)
                    Get-Marker -Index ($map.Count - 1)
                })
            }
        }
    }

    return @{ Text = (Add-MarkerPadding -Text $t); Map = $map }
}

# Восстанавливает маркеры. Возвращает $null, если хотя бы один маркер потерян —
# такую строку берём у следующего провайдера или оставляем на английском.
function Restore-Text {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)]$Map
    )
    # Один проход по всей строке. Это важно: при последовательной замене маркер i+1
    # откусывал бы пробел, только что вставленный подстановкой маркера i
    # ("{0} {1}" превращалось в "{0}{1}"). За один проход подставленный текст
    # повторно не сканируется, а соседние маркеры не пересекаются.
    $seen = New-Object System.Collections.Generic.HashSet[int]
    $bogus = New-Object System.Collections.Generic.List[int]

    $res = $script:MarkerRx.Replace($Text, {
        param($m)
        $i = [int]$m.Groups[1].Value
        if ($i -lt 0 -or $i -ge $Map.Count) { [void]$bogus.Add($i); return '' }
        [void]$seen.Add($i)
        return $Map[$i]
    })

    if ($bogus.Count -gt 0) { return $null }      # движок выдумал несуществующий маркер
    if ($seen.Count -ne $Map.Count) { return $null }   # потерял существующий
    if ($res -match '(?i)Z\s*X\s*\d+\s*Z\s*X') { return $null }
    return $res
}

# Проверка сохранности плейсхолдеров и экранирования (та же логика, что в diff-update.ps1)
function Test-Tokens {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$En,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Ru
    )
    $issues = @()
    foreach ($pat in @('\{\d+\}', '\[\[.+?\]\]')) {
        $e = @([regex]::Matches($En, $pat) | ForEach-Object { $_.Value } | Sort-Object)
        $r = @([regex]::Matches($Ru, $pat) | ForEach-Object { $_.Value } | Sort-Object)
        if (($e -join '|') -ne ($r -join '|')) { $issues += "плейсхолдеры $pat" }
    }
    foreach ($esc in 'n', 't', ':', '=', '#') {
        $pat = '\\' + $esc
        if (([regex]::Matches($En, $pat)).Count -ne ([regex]::Matches($Ru, $pat)).Count) {
            $issues += "экранирование \$esc"
        }
    }
    return $issues
}

# ------------------------------------------------------------
# Память переводов и автоглоссарий
# ------------------------------------------------------------

# Строит из существующих пар EN->RU:
#   Memory   — точные совпадения строки целиком (берётся самый частый вариант)
#   Terms    — короткие однозначные термины для глоссария, длинные — первыми
function New-TranslationMemory {
    param(
        [Parameter(Mandatory = $true)]$Pairs,   # список @{En=..; Ru=..}
        [int]$MaxTermWords = 4
    )
    $stat = @{}
    foreach ($p in $Pairs) {
        $en = $p.En
        $ru = $p.Ru
        if ([string]::IsNullOrWhiteSpace($en) -or [string]::IsNullOrWhiteSpace($ru)) { continue }
        if (-not $stat.ContainsKey($en)) { $stat[$en] = @{} }
        if (-not $stat[$en].ContainsKey($ru)) { $stat[$en][$ru] = 0 }
        $stat[$en][$ru]++
    }

    $memory = @{}
    $terms  = New-Object System.Collections.Generic.List[object]

    foreach ($en in $stat.Keys) {
        $variants = $stat[$en]
        $best = ($variants.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1)
        $memory[$en] = $best.Key

        # в глоссарий — только короткие, однозначные, без токенов и служебных символов
        if ($variants.Count -eq 1 -and
            $en.Length -ge 3 -and
            $en -match '^\w' -and $en -match '\w$' -and
            $en -notmatch '[{}\[\]<>\\=#]' -and
            ($en -split '\s+').Count -le $MaxTermWords -and
            $best.Key -ne $en) {
            [void]$terms.Add([PSCustomObject]@{ En = $en; Ru = $best.Key })
        }
    }

    $sorted = @($terms | Sort-Object -Property @{ Expression = { $_.En.Length } } -Descending)
    return @{ Memory = $memory; Terms = $sorted }
}

# ------------------------------------------------------------
# MT-провайдеры
# ------------------------------------------------------------

function Invoke-DeepL {
    param([Parameter(Mandatory = $true)][string[]]$Texts, [Parameter(Mandatory = $true)][string]$Key)
    $base = if ($Key -match ':fx$') { 'https://api-free.deepl.com' } else { 'https://api.deepl.com' }
    $json = @{
        text                = $Texts
        source_lang         = 'EN'
        target_lang         = 'RU'
        preserve_formatting = $true
    } | ConvertTo-Json -Depth 3 -Compress
    $r = Invoke-RestMethod -Method Post -Uri "$base/v2/translate" `
        -Headers @{ Authorization = "DeepL-Auth-Key $Key" } `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($json))
    return @($r.translations | ForEach-Object { $_.text })
}

function Invoke-Yandex {
    param(
        [Parameter(Mandatory = $true)][string[]]$Texts,
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$FolderId
    )
    $body = @{
        texts              = $Texts
        sourceLanguageCode = 'en'
        targetLanguageCode = 'ru'
        format             = 'PLAIN_TEXT'
    }
    # folderId нужен только при авторизации IAM-токеном. С API-ключом сервисного
    # аккаунта каталог определяется по самому ключу, и поле можно не слать.
    if ($FolderId) { $body.folderId = $FolderId }
    $json = $body | ConvertTo-Json -Depth 3 -Compress
    $r = Invoke-RestMethod -Method Post -Uri 'https://translate.api.cloud.yandex.net/translate/v2/translate' `
        -Headers @{ Authorization = "Api-Key $Key" } `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($json))
    return @($r.translations | ForEach-Object { $_.text })
}

# MyMemory: документированный бесплатный API, ключ не нужен. Одна строка на запрос,
# лимит по IP на слова в сутки; параметр de=<email> поднимает суточный порог.
# Исчерпание квоты приходит не HTTP-ошибкой, а responseStatus=403 с текстом
# предупреждения в поле перевода — поэтому проверяем и то, и другое.
function Invoke-MyMemoryOne {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Email
    )
    # у сервиса ограничение на длину q; длинные строки отдаём следующему провайдеру
    if ([System.Text.Encoding]::UTF8.GetByteCount($Text) -gt 500) {
        throw "строка длиннее 500 байт, MyMemory её не примет"
    }

    $uri = 'https://api.mymemory.translated.net/get?q=' + [uri]::EscapeDataString($Text) +
           '&langpair=' + [uri]::EscapeDataString('en|ru')
    if ($Email) { $uri += '&de=' + [uri]::EscapeDataString($Email) }

    $r = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 30
    $status = $r.responseStatus
    $out = $r.responseData.translatedText

    if ("$status" -ne '200') { throw "responseStatus=$status" }
    if ([string]::IsNullOrWhiteSpace($out)) { throw "пустой ответ" }
    if ($out -match '(?i)MYMEMORY WARNING|QUOTA|ALL AVAILABLE FREE TRANSLATIONS') {
        throw "квота исчерпана: $out"
    }
    return $out
}

# Argos Translate: нейронная модель en->ru прямо на машине. Ключей и сети не
# требует (кроме первой загрузки модели), лимитов нет — поэтому стоит последним
# и служит гарантией, что каскад всегда чем-то закончится.
function Invoke-Argos {
    param([Parameter(Mandatory = $true)][string[]]$Texts)

    $helper = Join-Path $PSScriptRoot 'argos-translate.py'
    if (-not (Test-Path $helper)) { throw "не найден $helper" }

    $python = $null
    $candidates = @()
    if ($env:ARGOS_PYTHON) { $candidates += $env:ARGOS_PYTHON }
    $candidates += @('python', 'python3', 'py')
    foreach ($c in $candidates) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { $python = $cmd.Source; break }
    }
    if (-not $python) { throw "python не найден (задайте ARGOS_PYTHON)" }

    $inFile  = [System.IO.Path]::GetTempFileName()
    $outFile = [System.IO.Path]::GetTempFileName()
    try {
        # -InputObject, а не конвейер: иначе массив из одной строки развернётся
        # в скаляр и на выходе будет не JSON-массив. И пишем без BOM — его не ждёт
        # json.load на той стороне.
        $json = ConvertTo-Json -InputObject @($Texts) -Depth 3 -Compress
        [System.IO.File]::WriteAllText($inFile, $json, $script:Utf8NoBom)

        & $python $helper $inFile $outFile 2>&1 | ForEach-Object {
            Write-Host "    [argos] $_" -ForegroundColor DarkGray
        }
        if ($LASTEXITCODE -ne 0) { throw "argos-translate.py вернул код $LASTEXITCODE" }

        $res = @(Get-Content $outFile -Raw -Encoding UTF8 | ConvertFrom-Json)
        if ($res.Count -ne $Texts.Count) {
            throw "получено $($res.Count) строк вместо $($Texts.Count)"
        }
        return $res
    }
    finally {
        Remove-Item $inFile, $outFile -Force -ErrorAction SilentlyContinue
    }
}

# Неофициальный эндпоинт Google: без ключа, по одной строке, лимитируется по IP
function Invoke-GoogleOne {
    param([Parameter(Mandatory = $true)][string]$Text)
    $body = 'client=gtx&sl=en&tl=ru&dt=t&q=' + [uri]::EscapeDataString($Text)
    $r = Invoke-WebRequest -Method Post -Uri 'https://translate.googleapis.com/translate_a/single' `
        -ContentType 'application/x-www-form-urlencoded; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -UseBasicParsing
    $j = $r.Content | ConvertFrom-Json
    return (($j[0] | ForEach-Object { $_[0] }) -join '')
}

# Каскад: первый доступный провайдер из $Config.Order, кроме перечисленных в $Exclude.
# Возвращает @{ Provider = 'deepl'; Result = @(...) } или $null.
function Invoke-Mt {
    param(
        [Parameter(Mandatory = $true)][string[]]$Texts,
        [Parameter(Mandatory = $true)]$Config,
        [string[]]$Exclude = @()
    )
    foreach ($p in $Config.Order) {
        if ($Exclude -contains $p) { continue }
        try {
            if ($p -eq 'deepl' -and $Config.DeepLKey) {
                return @{ Provider = 'deepl'; Result = (Invoke-DeepL -Texts $Texts -Key $Config.DeepLKey) }
            }
            elseif ($p -eq 'yandex' -and $Config.YandexKey) {
                # folderId обязателен только при авторизации IAM-токеном; с API-ключом
                # сервисного аккаунта каталог берётся из самого аккаунта
                return @{ Provider = 'yandex'; Result = (Invoke-Yandex -Texts $Texts -Key $Config.YandexKey -FolderId $Config.YandexFolder) }
            }
            elseif ($p -eq 'google') {
                $acc = New-Object System.Collections.Generic.List[string]
                foreach ($t in $Texts) {
                    [void]$acc.Add((Invoke-GoogleOne -Text $t))
                    Start-Sleep -Milliseconds 350
                }
                return @{ Provider = 'google'; Result = $acc.ToArray() }
            }
            elseif ($p -eq 'mymemory') {
                $acc = New-Object System.Collections.Generic.List[string]
                foreach ($t in $Texts) {
                    [void]$acc.Add((Invoke-MyMemoryOne -Text $t -Email $Config.MyMemoryEmail))
                    Start-Sleep -Milliseconds 400
                }
                return @{ Provider = 'mymemory'; Result = $acc.ToArray() }
            }
            elseif ($p -eq 'argos') {
                return @{ Provider = 'argos'; Result = (Invoke-Argos -Texts $Texts) }
            }
        }
        catch {
            Write-Host "    [$p] ошибка: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
    return $null
}

Export-ModuleMember -Function Read-PropLines, Test-PropLine, Read-Props, Write-MergedProps,
    Get-SkipRules, Protect-Text, Restore-Text, Test-Tokens, New-TranslationMemory,
    Invoke-DeepL, Invoke-Yandex, Invoke-GoogleOne, Invoke-MyMemoryOne, Invoke-Argos, Invoke-Mt
