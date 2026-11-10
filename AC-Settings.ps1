<#
.SYNOPSIS
    SIMRACE: сбор настроек Assetto Corsa на эталонном ПК и перенос на другие кокпиты.

.DESCRIPTION
    Collect  - собирает настройки в пакет (на эталоне ничего не меняет).
    Apply    - применяет пакет на текущем ПК. С -Preview только показывает изменения.
    Restore  - возвращает резервную копию, которую сделал Apply. Без -BackupPath берётся последняя копия этого ПК.
    ResetCarFfb - удаляет файлы ffb.ini машин в Documents\Assetto Corsa: FFB каждой машины возвращается к стоку.

    Обычно запускается двойным щелчком по файлам .cmd рядом с ним.

    ПЕРЕНОСИТСЯ: папка Documents\Assetto Corsa\cfg (HUD, CSP, NeckFX, геймплей, графика),
    настройки FFB и клавиатурные бинды из controls.ini, FFB-секции assetto_corsa.ini,
    пресеты Content Manager (кроме пресетов управления).

    НЕ ПЕРЕНОСИТСЯ: оси, кнопки, ID устройств, угол поворота и калибровка педалей,
    разрешение экрана, cfg\controllers, cfg\race.ini, FFB отдельных машин (ffb.ini).
    При переносе FFB машин на целевом ПК сбрасывается к стоку.

.EXAMPLE
    .\AC-Settings.ps1 -Mode Collect -UserName Guest
    .\AC-Settings.ps1 -Mode Apply -UserName Guest -Preview
    .\AC-Settings.ps1 -Mode Apply -UserName Guest
    .\AC-Settings.ps1 -Mode Restore -UserName Guest -BackupPath "<папка из Backups>"
#>
[CmdletBinding()]
param(
    [ValidateSet('Collect', 'Apply', 'Restore', 'ResetCarFfb')]
    [string]$Mode = 'Collect',

    # Учётная запись, под которой гости запускают игру. Если не указана, скрипт найдёт профили с AC сам.
    [string]$UserName,

    # Папка профиля, если автоматический поиск не подходит (например C:\Users\Guest).
    [string]$ProfilePath,

    # Папка пакета. По умолчанию рядом со скриптом.
    [string]$PackagePath,

    # Папка игры, если поиск через Steam не сработал.
    [string]$GamePath,

    # Папка резервной копии для режима Restore.
    [string]$BackupPath,

    # Папка резервных копий. По умолчанию Backups внутри пакета.
    [string]$BackupRoot,

    # Только показать, что изменится.
    [switch]$Preview,

    # Запуск из окна: не задавать вопросов в консоли.
    [switch]$NonInteractive,

    # Дублировать вывод в файл.
    [string]$OutFile,

    # Перед изменениями показать план и спросить подтверждение.
    [switch]$Ask
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
if (-not $PackagePath) { $PackagePath = Join-Path $PSScriptRoot 'AC-Reference' }
if (-not $BackupRoot) { $BackupRoot = Join-Path $PackagePath 'Backups' }
# Гостевая учётная запись из настроек лаунчера, если скрипт лежит рядом с ним
if (-not $UserName -and -not $ProfilePath) {
    $appsJson = Join-Path $PSScriptRoot 'apps.json'
    if (Test-Path -LiteralPath $appsJson) {
        try { $UserName = [string](Get-Content -LiteralPath $appsJson -Raw -Encoding UTF8 | ConvertFrom-Json).guestUser } catch { }
    }
}
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$OnWindows = ($env:OS -eq 'Windows_NT')
$Script:Warnings = New-Object System.Collections.Generic.List[string]

# Latin-1 читает и пишет байты один в один, поэтому ANSI и UTF-8 в ini не портятся.
$Latin1 = [Text.Encoding]::GetEncoding(28591)
$SectionRx = '^(?:\xEF\xBB\xBF)?\s*\[([^\]]+)\]'
$KeyRx = '^\s*([^;#=\s\[][^=]*?)\s*=(.*)$'

# Эти файлы не копируются при сборе. ffb.ini в подпапках - FFB отдельных машин, на других ПК он сбрасывается к стоку.
$CollectExcludeRx = '^(race\.ini|controllers/.*)$|\.(log|tmp|bak)$|^.+/ffb\.ini$'
# FFB отдельных машин
$CarFfbName = 'ffb.ini'
$KeepBackups = 5
# Эти файлы не трогаются обычным копированием при применении: первые два сливаются отдельно.
$ApplyExcludeRx = '^(controls\.ini|video\.ini|race\.ini|controllers/.*)$|\.(log|tmp|bak)$'
# Ключи привязки к устройству в остальных ini (например, горячие клавиши CSP на кнопках руля).
$DeviceKeyRx = '(^|_)(JOY|JOYSTICK|BUTTON|AXLE|AXIS|POV|PGUID\d*|GUID|DEVICE)\d*($|_)'
# Параметры экрана остаются свои на каждом ПК.
$VideoKeepKeys = @{ 'VIDEO' = @('WIDTH', 'HEIGHT', 'REFRESH', 'INDEX'); 'CAMERA' = @('MODE') }

function Say([string]$Text, [string]$Color = 'Gray') {
    Write-Host $Text -ForegroundColor $Color
    if ($OutFile) { try { [IO.File]::AppendAllText($OutFile, $Text + "`r`n", $Utf8NoBom) } catch { } }
}
function Warn([string]$Text) { [void]$Script:Warnings.Add($Text); Say "ВНИМАНИЕ: $Text" 'Yellow' }
function NormalPath([string]$Path) { (Get-Item -LiteralPath $Path -Force).FullName.TrimEnd('\', '/') }

# ---------- Работа с ini ----------

function Read-IniLines([string]$Path) {
    $head = New-Object byte[] 2
    $fs = [IO.File]::OpenRead($Path)
    try { [void]$fs.Read($head, 0, 2) } finally { $fs.Close() }
    if (($head[0] -eq 0xFF -and $head[1] -eq 0xFE) -or ($head[0] -eq 0xFE -and $head[1] -eq 0xFF)) {
        throw "Файл в кодировке UTF-16, слияние не поддерживается: $Path"
    }
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($l in [IO.File]::ReadAllLines($Path, $Latin1)) { [void]$list.Add($l) }
    return , $list
}

function Write-IniLines([string]$Path, $Lines) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [IO.File]::WriteAllLines($Path, [string[]]$Lines.ToArray(), $Latin1)
}

function Get-IniMap($Lines) {
    $map = [ordered]@{}
    $sec = $null
    foreach ($l in $Lines) {
        if ($l -match $SectionRx) {
            $sec = $Matches[1].Trim()
            if (-not $map.Contains($sec)) { $map[$sec] = [ordered]@{} }
            continue
        }
        if ($null -ne $sec -and $l -match $KeyRx) { $map[$sec][$Matches[1]] = $Matches[2].Trim() }
    }
    return $map
}

function Get-IniValue($Map, [string]$Section, [string]$Key) {
    if (-not $Map.Contains($Section)) { return $null }
    return $Map[$Section][$Key]
}

function Get-SectionRange($Lines, [string]$Section) {
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $SectionRx) {
            if ($start -ge 0) { return @($start, $i) }
            if ($Matches[1].Trim() -ieq $Section) { $start = $i }
        }
    }
    if ($start -ge 0) { return @($start, $Lines.Count) }
    return $null
}

function Set-IniValue($Lines, [string]$Section, [string]$Key, [string]$Value) {
    $r = Get-SectionRange $Lines $Section
    if (-not $r) {
        if ($Lines.Count -gt 0 -and $Lines[$Lines.Count - 1].Trim()) { [void]$Lines.Add('') }
        [void]$Lines.Add("[$Section]")
        [void]$Lines.Add("$Key=$Value")
        return
    }
    for ($i = $r[0] + 1; $i -lt $r[1]; $i++) {
        if ($Lines[$i] -match $KeyRx -and $Matches[1] -ieq $Key) { $Lines[$i] = "$Key=$Value"; return }
    }
    $at = $r[1]
    while ($at -gt ($r[0] + 1) -and -not $Lines[$at - 1].Trim()) { $at-- }
    $Lines.Insert($at, "$Key=$Value")
}

function Remove-IniValue($Lines, [string]$Section, [string]$Key) {
    $r = Get-SectionRange $Lines $Section
    if (-not $r) { return }
    for ($i = $r[1] - 1; $i -gt $r[0]; $i--) {
        if ($Lines[$i] -match $KeyRx -and $Matches[1] -ieq $Key) { $Lines.RemoveAt($i) }
    }
}

# ---------- Что переносить из controls.ini ----------

function Test-FfbSection([string]$Section) { $Section -match '^(FF_|FORCE_FEEDBACK)' }

function Test-FfbKey([string]$Section, [string]$Key) {
    if (Test-FfbSection $Section) { return $true }
    return ($Section -ieq 'STEER' -and $Key -match '^(FF_|FILTER_FF$)')
}

function Test-KeyboardKey([string]$Section, [string]$Key) {
    if ($Section -ieq 'CONTROLLERS' -or $Section -ieq 'X360') { return $false }
    if ($Section -ieq 'KEYBOARD') { return $true }
    return ($Key -match '(^|_)KEY($|_)')
}

function Test-TransferKey([string]$Section, [string]$Key) {
    return ((Test-FfbKey $Section $Key) -or (Test-KeyboardKey $Section $Key))
}

# Переносит из эталона только разрешённые ключи. Все остальные строки цели остаются как есть.
function Merge-Ini([string]$ReferencePath, [string]$TargetPath, [scriptblock]$Filter) {
    $ref = Get-IniMap (Read-IniLines $ReferencePath)
    $lines = Read-IniLines $TargetPath
    $before = Get-IniMap $lines
    $changes = New-Object System.Collections.Generic.List[string]
    foreach ($sec in @($ref.Keys)) {
        foreach ($key in @($ref[$sec].Keys)) {
            if (-not (& $Filter $sec $key)) { continue }
            $new = [string]$ref[$sec][$key]
            $old = Get-IniValue $before $sec $key
            if ($null -eq $old -or [string]$old -cne $new) {
                Set-IniValue $lines $sec $key $new
                [void]$changes.Add("[$sec] $key`: '$old' -> '$new'")
            }
        }
    }
    return [pscustomobject]@{ Lines = $lines; Changes = $changes; Before = $before; Reference = $ref }
}

# Берёт video.ini эталона, но оставляет разрешение и режим экрана этого ПК.
function Merge-Video([string]$ReferencePath, [string]$TargetPath) {
    $lines = Read-IniLines $ReferencePath
    $target = Get-IniMap (Read-IniLines $TargetPath)
    foreach ($sec in $VideoKeepKeys.Keys) {
        foreach ($key in $VideoKeepKeys[$sec]) {
            $v = Get-IniValue $target $sec $key
            if ($null -ne $v) { Set-IniValue $lines $sec $key ([string]$v) }
            else { Remove-IniValue $lines $sec $key }
        }
    }
    return , $lines
}

# Ini эталона, в котором привязки к устройствам заменены значениями этого ПК.
function Get-DeviceSafeIni([string]$SourcePath, [string]$TargetPath) {
    $lines = Read-IniLines $SourcePath
    $map = Get-IniMap $lines
    $found = 0
    $targetMap = $null
    if (Test-Path -LiteralPath $TargetPath) { $targetMap = Get-IniMap (Read-IniLines $TargetPath) }
    foreach ($sec in @($map.Keys)) {
        foreach ($key in @($map[$sec].Keys)) {
            if ($key -notmatch $DeviceKeyRx) { continue }
            $found++
            $v = $null
            if ($targetMap) { $v = Get-IniValue $targetMap $sec $key }
            if ($null -ne $v) { Set-IniValue $lines $sec $key ([string]$v) }
            else { Remove-IniValue $lines $sec $key }
        }
    }
    # Привязки, которые есть только на этом ПК, тоже остаются.
    if ($targetMap) {
        foreach ($sec in @($targetMap.Keys)) {
            foreach ($key in @($targetMap[$sec].Keys)) {
                if ($key -notmatch $DeviceKeyRx) { continue }
                $found++
                if ($null -eq (Get-IniValue $map $sec $key)) { Set-IniValue $lines $sec $key ([string]$targetMap[$sec][$key]) }
            }
        }
    }
    return [pscustomobject]@{ Lines = $lines; Count = $found }
}

# ---------- Файлы ----------

function Get-RelativeFiles([string]$Root) {
    $result = @{}
    if (-not (Test-Path -LiteralPath $Root)) { return $result }
    $rootFull = NormalPath $Root
    foreach ($f in Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force) {
        $rel = ($f.FullName.Substring($rootFull.Length).TrimStart('\', '/')) -replace '\\', '/'
        $result[$rel] = $f.FullName
    }
    return $result
}

function Copy-Tree([string]$Source, [string]$Destination, [string]$ExcludeRx) {
    $n = 0
    $files = Get-RelativeFiles $Source
    foreach ($rel in $files.Keys) {
        if ($ExcludeRx -and $rel -match $ExcludeRx) { continue }
        $dst = Join-Path $Destination ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        $dir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        Copy-Item -LiteralPath $files[$rel] -Destination $dst -Force
        $n++
    }
    return $n
}

function Test-SameFile([string]$A, [string]$B) {
    if (-not (Test-Path -LiteralPath $B)) { return $false }
    if ((Get-Item -LiteralPath $A -Force).Length -ne (Get-Item -LiteralPath $B -Force).Length) { return $false }
    return ((Get-FileHash -LiteralPath $A).Hash -eq (Get-FileHash -LiteralPath $B).Hash)
}

# ---------- Поиск профиля и игры ----------

function Get-CfgInProfile([string]$Profile) {
    foreach ($docs in @('Documents', 'OneDrive/Documents')) {
        $cfg = Join-Path (Join-Path $Profile $docs) 'Assetto Corsa/cfg'
        if (Test-Path -LiteralPath $cfg) { return $cfg }
    }
    return $null
}

function Resolve-UserProfile {
    if ($ProfilePath) {
        $cfg = Get-CfgInProfile $ProfilePath
        if (-not $cfg) { throw "В профиле нет папки Documents\Assetto Corsa\cfg: $ProfilePath" }
        return [pscustomobject]@{ Name = (Split-Path -Leaf $ProfilePath); Path = (NormalPath $ProfilePath); Cfg = (NormalPath $cfg) }
    }
    $found = @()
    $list = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    foreach ($k in Get-ChildItem $list) {
        $p = (Get-ItemProperty $k.PSPath).ProfileImagePath
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $cfg = Get-CfgInProfile $p
        if ($cfg) { $found += [pscustomobject]@{ Name = (Split-Path -Leaf $p); Path = $p; Cfg = (NormalPath $cfg) } }
    }
    if ($UserName) { $found = @($found | Where-Object { $_.Name -ieq $UserName }) }
    if ($found.Count -eq 0) { throw 'Не найден профиль с настройками AC. Запусти игру под этой учётной записью или укажи -ProfilePath.' }
    if ($found.Count -eq 1) { return $found[0] }
    if ($NonInteractive) {
        throw "Найдено несколько профилей с настройками AC: $(($found | ForEach-Object { $_.Name }) -join ', '). Укажи гостя в настройках лаунчера."
    }

    Say 'Найдено несколько профилей с настройками AC:' 'Cyan'
    for ($i = 0; $i -lt $found.Count; $i++) {
        $ctl = Join-Path $found[$i].Cfg 'controls.ini'
        $time = '-'
        if (Test-Path -LiteralPath $ctl) { $time = (Get-Item -LiteralPath $ctl).LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
        Say ("  {0}. {1}  (controls.ini изменён: {2})" -f ($i + 1), $found[$i].Name, $time)
    }
    $n = [int](Read-Host 'Номер профиля гостя')
    if ($n -lt 1 -or $n -gt $found.Count) { throw 'Неверный номер профиля.' }
    return $found[$n - 1]
}

function Resolve-GamePath {
    if ($GamePath) {
        if (-not (Test-Path -LiteralPath (Join-Path $GamePath 'acs.exe'))) { throw "В указанной папке нет acs.exe: $GamePath" }
        return (NormalPath $GamePath)
    }
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($reg in @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        $v = (Get-ItemProperty $reg -ErrorAction SilentlyContinue).InstallPath
        if ($v) { [void]$roots.Add($v) }
    }
    foreach ($steam in @($roots)) {
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
                [void]$roots.Add(($m.Groups[1].Value -replace '\\\\', '\'))
            }
        }
    }
    foreach ($r in $roots) {
        $g = Join-Path $r 'steamapps\common\assettocorsa'
        if (Test-Path -LiteralPath (Join-Path $g 'acs.exe')) { return (NormalPath $g) }
    }
    throw 'Папка Assetto Corsa не найдена через Steam. Укажи её параметром -GamePath.'
}

function Get-AppList([string]$Game, [string]$Kind) {
    $p = Join-Path (Join-Path $Game 'apps') $Kind
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    return @(Get-ChildItem -LiteralPath $p -Directory | Select-Object -ExpandProperty Name | Sort-Object)
}

function Get-GameInfo([string]$Game) {
    $dll = Join-Path $Game 'dwrite.dll'
    $hash = $null; $ver = $null
    if (Test-Path -LiteralPath $dll) {
        $hash = (Get-FileHash -LiteralPath $dll).Hash
        $ver = (Get-Item -LiteralPath $dll).VersionInfo.FileVersion
    }
    return [pscustomobject]@{
        CspHash = $hash; CspVersion = $ver
        PythonApps = @(Get-AppList $Game 'python'); LuaApps = @(Get-AppList $Game 'lua')
    }
}

# ---------- Резервные копии и FFB машин ----------

# Папка Documents\Assetto Corsa (над cfg)
function Get-AcDocs($User) { return (Split-Path -Parent $User.Cfg) }

# Файлы ffb.ini отдельных машин. Корень cfg не трогаем: там общих настроек FFB нет, но и рисковать незачем.
function Get-CarFfbFiles($User) {
    $docs = Get-AcDocs $User
    $rootCfg = Join-Path $User.Cfg $CarFfbName
    return @(Get-ChildItem -LiteralPath $docs -Recurse -File -Force -Filter $CarFfbName -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $rootCfg } | Sort-Object FullName)
}

function Get-DocsRelative($User, [string]$Path) {
    $docs = NormalPath (Get-AcDocs $User)
    return ($Path.Substring($docs.Length).TrimStart('\', '/') -replace '\\', '/')
}

# Полная копия cfg, assetto_corsa.ini и ffb.ini машин вне cfg. Хранится не больше $KeepBackups копий на ПК.
function New-Backup($User, [string]$GameIni) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $prefix = "$($env:COMPUTERNAME)_$($User.Name)_"
    $backup = Join-Path $BackupRoot "$prefix$stamp"
    [void](Copy-Tree $User.Cfg (Join-Path $backup 'cfg') '')
    if ($GameIni -and (Test-Path -LiteralPath $GameIni)) {
        [void](New-Item -ItemType Directory -Path (Join-Path $backup 'game') -Force)
        Copy-Item -LiteralPath $GameIni -Destination (Join-Path $backup 'game/assetto_corsa.ini') -Force
    }
    $cfgFull = NormalPath $User.Cfg
    foreach ($f in Get-CarFfbFiles $User) {
        if ($f.FullName.StartsWith($cfgFull + [IO.Path]::DirectorySeparatorChar)) { continue }
        $dst = Join-Path (Join-Path $backup 'docs') ((Get-DocsRelative $User $f.FullName) -replace '/', [IO.Path]::DirectorySeparatorChar)
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force)
        Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
    }
    $old = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith($prefix) } | Sort-Object Name -Descending | Select-Object -Skip $KeepBackups)
    foreach ($d in $old) { Remove-Item -LiteralPath $d.FullName -Recurse -Force }
    Say "Резервная копия: $backup" 'Cyan'
    return $backup
}

function Get-LatestBackup($User) {
    $prefix = "$($env:COMPUTERNAME)_$($User.Name)_"
    $last = Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith($prefix) -and (Test-Path -LiteralPath (Join-Path $_.FullName 'cfg')) } |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $last) { throw "Нет резервных копий этого ПК в $BackupRoot. Откатывать нечего." }
    return $last.FullName
}

# Подтверждение перед изменениями (только с -Ask)
function Confirm-Step([string]$Question) {
    if (-not $Ask) { return $true }
    Say ''
    $answer = Read-Host "$Question Введи Д и нажми Enter, любой другой ответ отменит"
    if ($answer.Trim() -match '^(д|да|y|yes|l)$') { return $true }
    Say 'Отменено, файлы не менялись.' 'Yellow'
    return $false
}

# ---------- Проверки окружения ----------

function Assert-Admin {
    if (-not $OnWindows) { return }
    $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Запусти PowerShell от имени администратора.'
    }
}

function Test-GameRunning {
    if (-not $OnWindows) { return $false }
    $p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(acs|acs_x86|AssettoCorsa|Content Manager.*)$' }
    if ($p) { Say ('Запущено: ' + (($p | Select-Object -ExpandProperty ProcessName -Unique) -join ', ')) 'Yellow'; return $true }
    return $false
}

function Get-UwfEnabled {
    if (-not $OnWindows) { return $false }
    try {
        $f = Get-CimInstance -Namespace 'root\standardcimv2\embedded' -ClassName 'UWF_Filter' -ErrorAction Stop
        return [bool]$f.CurrentEnabled
    } catch { return $false }
}

function Assert-CanWrite {
    if (Test-GameRunning) { throw 'Закрой Assetto Corsa и Content Manager: при выходе они перезапишут настройки.' }
    if (-not $Preview -and (Get-UwfEnabled)) {
        throw 'Защита UWF включена, изменения пропадут после перезагрузки. Разблокируй ПК в панели администратора лаунчера (компьютер перезагрузится) и запусти этот файл снова.'
    }
}

# ---------- COLLECT ----------

function Invoke-Collect {
    Assert-Admin
    if (Test-GameRunning) { throw 'Закрой Assetto Corsa и Content Manager: часть настроек записывается при выходе.' }

    $user = Resolve-UserProfile
    $game = Resolve-GamePath
    $info = Get-GameInfo $game
    Say "Профиль: $($user.Name)   Настройки: $($user.Cfg)" 'Cyan'
    Say "Игра: $game" 'Cyan'

    $ctlSource = Join-Path $user.Cfg 'controls.ini'
    if (-not (Test-Path -LiteralPath $ctlSource)) { throw "Нет файла $ctlSource. Настрой управление на эталоне и запусти сбор снова." }

    # Старый пакет удаляем, только если это точно наш пакет. Папку Backups не трогаем.
    if (Test-Path -LiteralPath $PackagePath) {
        if (Test-Path -LiteralPath (Join-Path $PackagePath 'manifest.json')) {
            foreach ($d in @('cfg', 'game', 'cm_presets')) {
                $old = Join-Path $PackagePath $d
                if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
            }
        } elseif (@(Get-ChildItem -LiteralPath $PackagePath -Force).Count -gt 0) {
            throw "Папка не пуста и не похожа на пакет: $PackagePath"
        }
    } else {
        [void](New-Item -ItemType Directory -Path $PackagePath -Force)
    }
    $pkg = NormalPath $PackagePath

    $cfgCount = Copy-Tree $user.Cfg (Join-Path $pkg 'cfg') $CollectExcludeRx

    $gameIni = Join-Path $game 'system/cfg/assetto_corsa.ini'
    $hasGameIni = Test-Path -LiteralPath $gameIni
    if ($hasGameIni) {
        [void](New-Item -ItemType Directory -Path (Join-Path $pkg 'game') -Force)
        Copy-Item -LiteralPath $gameIni -Destination (Join-Path $pkg 'game/assetto_corsa.ini') -Force
    } else { Warn "Не найден $gameIni" }

    # Пресеты Content Manager, кроме пресетов управления с ID устройств.
    $cmPresets = Join-Path $user.Path 'AppData/Local/AcTools Content Manager/Presets'
    $cmCount = 0
    $cmFolders = @()
    if (Test-Path -LiteralPath $cmPresets) {
        foreach ($d in Get-ChildItem -LiteralPath $cmPresets -Directory -Force) {
            if ($d.Name -match 'control') { continue }
            $cmCount += Copy-Tree $d.FullName (Join-Path (Join-Path $pkg 'cm_presets') $d.Name) ''
            $cmFolders += $d.Name
        }
    } else { Warn 'Папка пресетов Content Manager не найдена в этом профиле.' }

    # Манифест нужен, чтобы на цели сравнить версию CSP и список приложений.
    [pscustomobject]@{
        Computer = $env:COMPUTERNAME; User = $user.Name; Created = (Get-Date).ToString('s')
        CspHash = $info.CspHash; CspVersion = $info.CspVersion
        PythonApps = $info.PythonApps; LuaApps = $info.LuaApps
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $pkg 'manifest.json') -Encoding UTF8

    # Отчёт для проверки глазами.
    $map = Get-IniMap (Read-IniLines $ctlSource)
    $r = New-Object System.Collections.Generic.List[string]
    [void]$r.Add("Эталон: $env:COMPUTERNAME, профиль $($user.Name), $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    [void]$r.Add("Версия CSP: $($info.CspVersion)   SHA256 dwrite.dll: $($info.CspHash)")
    [void]$r.Add("Файлов cfg: $cfgCount; файлов пресетов CM: $cmCount; папки: $($cmFolders -join ', ')")
    [void]$r.Add('')
    [void]$r.Add('=== FFB (controls.ini) ===')
    foreach ($s in $map.Keys) { foreach ($k in $map[$s].Keys) { if (Test-FfbKey $s $k) { [void]$r.Add("[$s] $k=$($map[$s][$k])") } } }
    if ($hasGameIni) {
        [void]$r.Add('')
        [void]$r.Add('=== FFB (assetto_corsa.ini) ===')
        $g = Get-IniMap (Read-IniLines $gameIni)
        foreach ($s in $g.Keys) { if (Test-FfbSection $s) { foreach ($k in $g[$s].Keys) { [void]$r.Add("[$s] $k=$($g[$s][$k])") } } }
    }
    [void]$r.Add('')
    [void]$r.Add('=== Клавиатурные бинды (controls.ini, только назначенные) ===')
    foreach ($s in $map.Keys) {
        foreach ($k in $map[$s].Keys) {
            if ((Test-KeyboardKey $s $k) -and $map[$s][$k] -notin @('', '-1', '0')) { [void]$r.Add("[$s] $k=$($map[$s][$k])") }
        }
    }
    [void]$r.Add('')
    [void]$r.Add('=== Файлы cfg, где найдены привязки к устройствам (на цели значения останутся свои) ===')
    $pkgFiles = Get-RelativeFiles (Join-Path $pkg 'cfg')
    foreach ($rel in ($pkgFiles.Keys | Sort-Object)) {
        if ($rel -notmatch '\.ini$' -or $rel -match '^controls\.ini$') { continue }
        try {
            $m = Get-IniMap (Read-IniLines $pkgFiles[$rel])
            foreach ($s in $m.Keys) { foreach ($k in $m[$s].Keys) { if ($k -match $DeviceKeyRx) { [void]$r.Add("$rel [$s] $k=$($m[$s][$k])") } } }
        } catch { [void]$r.Add("$rel - не удалось прочитать: $($_.Exception.Message)") }
    }
    [void]$r.Add('')
    [void]$r.Add('=== Файлы не-ini с похожими на GUID значениями (проверить вручную) ===')
    foreach ($rel in ($pkgFiles.Keys | Sort-Object)) {
        if ($rel -match '\.ini$') { continue }
        if ($rel -notmatch '\.(json|txt|cfg|lua|data)$') { continue }
        if ((Get-Item -LiteralPath $pkgFiles[$rel]).Length -gt 2MB) { continue }
        if ([IO.File]::ReadAllText($pkgFiles[$rel], $Latin1) -match '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}') { [void]$r.Add($rel) }
    }
    [void]$r.Add('')
    [void]$r.Add('=== FFB отдельных машин (не собирается, на других ПК сбрасывается к стоку) ===')
    foreach ($f in Get-CarFfbFiles $user) { [void]$r.Add((Get-DocsRelative $user $f.FullName)) }
    [void]$r.Add('')
    [void]$r.Add('=== Все файлы cfg в пакете ===')
    foreach ($rel in ($pkgFiles.Keys | Sort-Object)) { [void]$r.Add($rel) }
    $r | Set-Content -LiteralPath (Join-Path $pkg 'report.txt') -Encoding UTF8

    if ((Get-UwfEnabled) -and $OnWindows -and $pkg.StartsWith($env:SystemDrive, [StringComparison]::OrdinalIgnoreCase)) {
        Warn 'UWF включён, а пакет лежит на системном диске: после перезагрузки он пропадёт. Скопируй его на флешку, диск Z: или в сетевую папку.'
    }

    Say ''
    Say "Готово. Пакет: $pkg" 'Green'
    Say "cfg: $cfgCount файлов; пресеты CM: $cmCount файлов. Отчёт: $(Join-Path $pkg 'report.txt')" 'Green'
    return 0
}

# ---------- APPLY ----------

function Invoke-Apply {
    Assert-Admin
    Assert-CanWrite
    $pkgCfg = Join-Path $PackagePath 'cfg'
    $manifestPath = Join-Path $PackagePath 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath) -or -not (Test-Path -LiteralPath $pkgCfg)) { throw "Пакет не найден: $PackagePath" }
    $pkg = NormalPath $PackagePath
    $pkgCfg = Join-Path $pkg 'cfg'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $user = Resolve-UserProfile
    $game = Resolve-GamePath
    $info = Get-GameInfo $game
    $mode = if ($Preview) { 'ПРЕДПРОСМОТР, ничего не меняю' } else { 'ПРИМЕНЕНИЕ' }
    Say "$mode | Эталон: $($manifest.Computer) | Цель: $env:COMPUTERNAME, профиль $($user.Name)" 'Cyan'

    if ($manifest.CspHash -ne $info.CspHash) {
        Warn "Версия CSP отличается: эталон '$($manifest.CspVersion)', этот ПК '$($info.CspVersion)'. Настройки могут примениться не полностью."
    }
    foreach ($kind in @(@('python', $manifest.PythonApps, $info.PythonApps), @('lua', $manifest.LuaApps, $info.LuaApps))) {
        $missing = @($kind[1] | Where-Object { $_ -and ($kind[2] -notcontains $_) })
        if ($missing.Count -gt 0) { Warn "На этом ПК нет приложений $($kind[0]): $($missing -join ', '). Они не появятся на экране." }
    }

    # План изменений cfg.
    $src = Get-RelativeFiles $pkgCfg
    $dst = Get-RelativeFiles $user.Cfg
    $toCopy = New-Object System.Collections.Generic.List[string]
    $toDelete = New-Object System.Collections.Generic.List[string]
    $safeIni = @{}
    foreach ($rel in $src.Keys) {
        if ($rel -match $ApplyExcludeRx) { continue }
        $target = Join-Path $user.Cfg ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if ($rel -match '\.ini$') {
            $safe = $null
            try { $safe = Get-DeviceSafeIni $src[$rel] $target }
            catch { Warn "Не удалось проверить привязки устройств, файл будет скопирован как есть: $rel" }
            if ($safe -and $safe.Count -gt 0) {
                $safeIni[$rel] = $safe.Lines
                $same = $false
                if (Test-Path -LiteralPath $target) {
                    try { $same = (($safe.Lines -join "`n") -ceq ((Read-IniLines $target) -join "`n")) } catch { $same = $false }
                }
                if (-not $same) { [void]$toCopy.Add($rel) }
                continue
            }
        }
        if (-not (Test-SameFile $src[$rel] $target)) { [void]$toCopy.Add($rel) }
    }
    # CSP хранит в ini только отличия от умолчаний, поэтому лишние файлы на цели нужно убрать.
    foreach ($rel in $dst.Keys) {
        if ($rel -match $ApplyExcludeRx) { continue }
        if (-not $src.ContainsKey($rel)) { [void]$toDelete.Add($rel) }
    }

    $ctlRef = Join-Path $pkgCfg 'controls.ini'
    $ctlDst = Join-Path $user.Cfg 'controls.ini'
    if (-not (Test-Path -LiteralPath $ctlDst)) { throw "На этом ПК нет controls.ini. Сначала настрой руль и педали в игре: $ctlDst" }
    $ctl = Merge-Ini $ctlRef $ctlDst ${function:Test-TransferKey}

    $gameRef = Join-Path $pkg 'game/assetto_corsa.ini'
    $gameDst = Join-Path $game 'system/cfg/assetto_corsa.ini'
    $gameMerge = $null
    if ((Test-Path -LiteralPath $gameRef) -and (Test-Path -LiteralPath $gameDst)) {
        $gameMerge = Merge-Ini $gameRef $gameDst { param($s, $k) Test-FfbSection $s }
    }

    $vidRef = Join-Path $pkgCfg 'video.ini'
    $vidDst = Join-Path $user.Cfg 'video.ini'
    $vidLines = $null
    if ((Test-Path -LiteralPath $vidRef) -and (Test-Path -LiteralPath $vidDst)) {
        $vidLines = Merge-Video $vidRef $vidDst
        $vidOld = Get-IniMap (Read-IniLines $vidDst)
        $vidNew = Get-IniMap $vidLines
        Say 'video.ini: разрешение и режим экрана остаются свои'
        foreach ($s in $vidNew.Keys) {
            foreach ($k in $vidNew[$s].Keys) {
                $o = Get-IniValue $vidOld $s $k
                if ([string]$o -cne [string]$vidNew[$s][$k]) { Say "  [$s] $k`: '$o' -> '$($vidNew[$s][$k])'" }
            }
        }
    }
    $cfgFull = NormalPath $user.Cfg
    $ffbOutside = @(Get-CarFfbFiles $user | Where-Object { -not $_.FullName.StartsWith($cfgFull + [IO.Path]::DirectorySeparatorChar) })
    $ffbInCfg = @($toDelete | Where-Object { $_ -match '^.+/ffb\.ini$' })
    Say "cfg: скопировать/обновить $($toCopy.Count), удалить лишних $($toDelete.Count)"
    foreach ($x in ($toDelete | Sort-Object)) { Say "  удалить: $x" 'DarkYellow' }
    Say "FFB машин: сбросить к стоку $($ffbInCfg.Count + $ffbOutside.Count)"
    foreach ($f in $ffbOutside) { Say "  удалить: $(Get-DocsRelative $user $f.FullName)" 'DarkYellow' }
    Say "controls.ini: изменений $($ctl.Changes.Count)"
    foreach ($x in $ctl.Changes) { Say "  $x" }
    if ($gameMerge) {
        Say "assetto_corsa.ini: изменений $($gameMerge.Changes.Count)"
        foreach ($x in $gameMerge.Changes) { Say "  $x" }
    }

    if ($Preview) {
        Say ''
        Say 'Предпросмотр завершён, файлы не менялись.' 'Green'
        return 0
    }
    if (-not (Confirm-Step 'Применить эти изменения?')) { return 0 }

    # Резервная копия до любых изменений.
    $backup = New-Backup $user $gameDst

    foreach ($rel in $toCopy) {
        $target = Join-Path $user.Cfg ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if ($safeIni.ContainsKey($rel)) { Write-IniLines $target $safeIni[$rel]; continue }
        $dir = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        Copy-Item -LiteralPath $src[$rel] -Destination $target -Force
    }
    foreach ($rel in $toDelete) {
        Remove-Item -LiteralPath $dst[$rel] -Force
    }
    foreach ($f in $ffbOutside) { Remove-Item -LiteralPath $f.FullName -Force }

    Write-IniLines $ctlDst $ctl.Lines
    if ($vidLines) { Write-IniLines $vidDst $vidLines }
    elseif (Test-Path -LiteralPath $vidRef) { Warn 'На этом ПК нет video.ini: разрешение не с чем сравнить, файл не перенесён.' }
    if ($gameMerge) { Write-IniLines $gameDst $gameMerge.Lines }

    $cmSrc = Join-Path $pkg 'cm_presets'
    if (Test-Path -LiteralPath $cmSrc) {
        $cmDst = Join-Path $user.Path 'AppData/Local/AcTools Content Manager/Presets'
        [void](Copy-Tree $cmSrc $cmDst '')
    }

    # ---------- Проверка результата ----------
    $errors = New-Object System.Collections.Generic.List[string]
    $after = Get-IniMap (Read-IniLines $ctlDst)
    foreach ($s in $ctl.Reference.Keys) {
        foreach ($k in $ctl.Reference[$s].Keys) {
            if ((Test-TransferKey $s $k) -and [string](Get-IniValue $after $s $k) -cne [string]$ctl.Reference[$s][$k]) {
                [void]$errors.Add("controls.ini: [$s] $k не совпадает с эталоном")
            }
        }
    }
    # Всё, что не FFB и не клавиатура, обязано остаться прежним: это защита биндов устройств.
    foreach ($s in $ctl.Before.Keys) {
        foreach ($k in $ctl.Before[$s].Keys) {
            if (-not (Test-TransferKey $s $k) -and [string](Get-IniValue $after $s $k) -cne [string]$ctl.Before[$s][$k]) {
                [void]$errors.Add("controls.ini: изменился бинд устройства [$s] $k")
            }
        }
    }
    foreach ($rel in $src.Keys) {
        if ($rel -match $ApplyExcludeRx -or $safeIni.ContainsKey($rel)) { continue }
        $target = Join-Path $user.Cfg ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-SameFile $src[$rel] $target)) { [void]$errors.Add("Файл не совпадает с эталоном: $rel") }
    }
    foreach ($rel in $safeIni.Keys) {
        $target = Join-Path $user.Cfg ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        $got = Get-IniMap (Read-IniLines $target)
        $want = Get-IniMap (Read-IniLines $src[$rel])
        foreach ($s in $want.Keys) {
            foreach ($k in $want[$s].Keys) {
                if ($k -notmatch $DeviceKeyRx -and [string](Get-IniValue $got $s $k) -cne [string]$want[$s][$k]) {
                    [void]$errors.Add("$rel`: [$s] $k не совпадает с эталоном")
                }
            }
        }
    }
    if (@(Get-CarFfbFiles $user).Count -gt 0) { [void]$errors.Add('Остались файлы FFB машин (ffb.ini)') }
    if ($OnWindows) {
        $acl = (Get-Acl -LiteralPath $ctlDst).Access | Where-Object { $_.IdentityReference -match [regex]::Escape($user.Name) }
        if (-not $acl) { Warn "В правах controls.ini явно не указан $($user.Name). Проверь, сохраняются ли настройки под гостем." }
    }

    Say ''
    if ($errors.Count -gt 0) {
        foreach ($e in $errors) { Say "ОШИБКА: $e" 'Red' }
        Say "Откат: файл «3. Откатить последнее применение» или -Mode Restore -BackupPath `"$backup`"" 'Yellow'
        return 2
    }
    Say 'Готово. Настройки совпадают с эталоном, бинды устройств не изменились.' 'Green'
    Say "Откат: файл «3. Откатить последнее применение» или -Mode Restore -BackupPath `"$backup`"" 'Gray'
    return 0
}

# ---------- RESTORE ----------

function Invoke-Restore {
    Assert-Admin
    Assert-CanWrite
    $user = Resolve-UserProfile
    if (-not $BackupPath) { $BackupPath = Get-LatestBackup $user }
    if (-not (Test-Path -LiteralPath (Join-Path $BackupPath 'cfg'))) { throw "В папке нет резервной копии (папки cfg): $BackupPath" }
    Say "Резервная копия: $BackupPath" 'Cyan'
    $bakCfg = NormalPath (Join-Path $BackupPath 'cfg')
    $src = Get-RelativeFiles $bakCfg
    $dst = Get-RelativeFiles $user.Cfg
    $extra = @($dst.Keys | Where-Object { -not $src.ContainsKey($_) })
    Say "Вернуть файлов: $($src.Count); удалить добавленных: $($extra.Count)" 'Cyan'
    if ($Preview) { return 0 }
    if (-not (Confirm-Step 'Откатить настройки к этой копии?')) { return 0 }
    foreach ($rel in $extra) { Remove-Item -LiteralPath $dst[$rel] -Force }
    [void](Copy-Tree $bakCfg $user.Cfg '')
    $bakDocs = Join-Path $BackupPath 'docs'
    if (Test-Path -LiteralPath $bakDocs) { [void](Copy-Tree $bakDocs (Get-AcDocs $user) '') }
    $bakGame = Join-Path $BackupPath 'game/assetto_corsa.ini'
    if (Test-Path -LiteralPath $bakGame) {
        $game = Resolve-GamePath
        Copy-Item -LiteralPath $bakGame -Destination (Join-Path $game 'system/cfg/assetto_corsa.ini') -Force
    }
    # Проверка: cfg совпадает с копией
    $bad = @($src.Keys | Where-Object { -not (Test-SameFile $src[$_] (Join-Path $user.Cfg ($_ -replace '/', [IO.Path]::DirectorySeparatorChar))) })
    if ($bad.Count -gt 0) {
        foreach ($b in $bad) { Say "ОШИБКА: файл не восстановлен: $b" 'Red' }
        return 2
    }
    Say 'Готово. Настройки cfg и assetto_corsa.ini возвращены. Добавленные пресеты CM остаются, они ни на что не влияют, пока их не выбрали.' 'Green'
    return 0
}

# ---------- СБРОС FFB МАШИН ----------

function Invoke-ResetCarFfb {
    Assert-Admin
    Assert-CanWrite
    $user = Resolve-UserProfile
    $files = @(Get-CarFfbFiles $user)
    Say "Профиль: $($user.Name). Файлов FFB машин: $($files.Count)" 'Cyan'
    foreach ($f in $files) { Say "  $(Get-DocsRelative $user $f.FullName)" }
    if ($files.Count -eq 0) {
        Say 'Готово. FFB всех машин уже стоковый.' 'Green'
        return 0
    }
    if ($Preview) { return 0 }
    $game = $null
    try { $game = Resolve-GamePath } catch { }
    $gameIni = $(if ($game) { Join-Path $game 'system/cfg/assetto_corsa.ini' } else { $null })
    [void](New-Backup $user $gameIni)
    foreach ($f in $files) { Remove-Item -LiteralPath $f.FullName -Force }
    $left = @(Get-CarFfbFiles $user).Count
    if ($left -gt 0) {
        Say "ОШИБКА: не удалось удалить файлов: $left" 'Red'
        return 2
    }
    Say "Готово. FFB машин сброшен к стоку: $($files.Count)." 'Green'
    return 0
}

# ---------- Запуск ----------

try {
    switch ($Mode) {
        'Collect' { $code = Invoke-Collect }
        'Apply'   { $code = Invoke-Apply }
        'Restore' { $code = Invoke-Restore }
        'ResetCarFfb' { $code = Invoke-ResetCarFfb }
    }
    if ($Script:Warnings.Count -gt 0) { Say "Предупреждений: $($Script:Warnings.Count)" 'Yellow' }
    exit $code
} catch {
    Say "ОШИБКА: $($_.Exception.Message)" 'Red'
    exit 1
}
