#Requires -Version 5.1
<#
  Автоустановка лаунчера SIMRACE на один компьютер. Запускается через Auto-Install.cmd из папки с лаунчером.
  Сам запрашивает права администратора, проверяет компьютер, ставит или обновляет лаунчер и показывает итог.
  Повторный запуск безопасен.

  Что сделать заранее, руками: один раз войти под гостем и сохранить аккаунты Steam с галочкой «Запомнить меня».
#>
param(
    [string]$GuestUser,
    [switch]$EnableAutologon,     # автовход по умолчанию не трогаем, включается только этим ключом
    [switch]$Quick,               # обновление без вопросов: настройки остаются, в конце перезагрузка
    [switch]$Unattended           # запуск с панели управления: без вопросов и без перезагрузки, ею управляет панель
)
if ($Unattended) { $Quick = $true }

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$target   = Join-Path $env:ProgramFiles 'SIMRACE\Launcher'
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$script:Warnings = New-Object System.Collections.ArrayList

function Close-Window([int]$Code = 0) {
    if ($Unattended) { exit $Code }
    Write-Host ''
    [void](Read-Host 'Нажми Enter, чтобы закрыть окно')
    exit $Code
}

function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Good([string]$Text) { Write-Host "  OK  $Text" -ForegroundColor Green }
function Write-Note([string]$Text) {
    Write-Host "  !   $Text" -ForegroundColor Yellow
    [void]$script:Warnings.Add($Text)
}

# Выбор цифрой: так ответ не зависит от раскладки клавиатуры
function Read-Choice([string]$Question, [bool]$Default) {
    if ($Quick) { return $Default }
    while ($true) {
        $hint = if ($Default) { '1 - да (Enter), 2 - нет' } else { '1 - да, 2 - нет (Enter)' }
        $answer = (Read-Host "$Question [$hint]").Trim()
        if (-not $answer) { return $Default }
        if ($answer -eq '1') { return $true }
        if ($answer -eq '2') { return $false }
    }
}

# ---------- Права администратора ----------

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($Unattended) {
        Write-Host 'Нет прав администратора. Запусти Enable-Remote.cmd на этом компьютере.' -ForegroundColor Red
        exit 1
    }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"$(if ($Quick) { ' -Quick' })"
        exit 0
    }
    catch {
        Write-Host 'Нужны права администратора. Установка отменена.' -ForegroundColor Red
        Close-Window 1
    }
}

# Журнал установки: на Z:, если он есть, иначе рядом со скриптом
$logFolder = if (Test-Path -LiteralPath 'Z:\') { 'Z:\SIMRACE\Logs' } else { $PSScriptRoot }
try {
    New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
    Start-Transcript -LiteralPath (Join-Path $logFolder "$env:COMPUTERNAME-install.log") -Append | Out-Null
}
catch { Write-Host "Журнал установки не записывается: $_" -ForegroundColor Yellow }

try {
    Write-Host "Установка лаунчера SIMRACE на $env:COMPUTERNAME" -ForegroundColor White

    # Файлы из интернета: без этого гостю показывалось бы предупреждение безопасности при запуске программ
    Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    # ---------- UWF ----------
    Write-Step 'Защита UWF'
    $uwf = Get-CimInstance -Namespace 'root\standardcimv2\embedded' -ClassName UWF_Filter -ErrorAction SilentlyContinue
    if ($uwf -and $uwf.CurrentEnabled) {
        if ($Quick) { throw 'Защита UWF включена, обновление пропало бы после перезагрузки. Выключи её и запусти снова.' }
        Write-Host '  Защита включена, поэтому установка пропала бы после перезагрузки.'
        Write-Host '  Нужно выключить защиту и перезагрузить компьютер. Затем войди администратором и снова запусти этот файл.'
        if (Read-Choice 'Выключить защиту и перезагрузить сейчас?' $true) {
            if ($uwf.NextEnabled) { & (Join-Path $env:SystemRoot 'System32\uwfmgr.exe') filter disable | Out-Null }
            if ((Get-CimInstance -Namespace 'root\standardcimv2\embedded' -ClassName UWF_Filter).NextEnabled) {
                throw 'Не удалось выключить защиту. Сделай это через окно UWF и повтори.'
            }
            Restart-Computer -Force
        }
        Close-Window 0
    }
    Write-Good $(if ($uwf) { 'Защита выключена, можно ставить' } else { 'UWF на этом компьютере нет' })

    # ---------- Имя гостя ----------
    Write-Step 'Учётная запись гостя'
    $settingsFiles = @((Join-Path $target 'apps.json'), (Join-Path $PSScriptRoot 'apps.json'))
    if (-not $GuestUser) {
        foreach ($file in $settingsFiles) {
            if (-not (Test-Path -LiteralPath $file)) { continue }
            $known = [string](Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json).guestUser
            if ($known -and (Get-LocalUser -Name $known -ErrorAction SilentlyContinue)) { $GuestUser = $known; break }
        }
    }
    $admins = @()
    try { $admins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { $_.SID.Value }) }
    catch { Write-Host "  Список администраторов не прочитан: $($_.Exception.Message)" -ForegroundColor Yellow }
    if (-not $GuestUser) {
        $users = @(Get-LocalUser | Where-Object { $_.Enabled -and $admins -notcontains $_.SID.Value })
        if ($users.Count -eq 1) { $GuestUser = $users[0].Name }
        else {
            if ($Unattended) { throw 'Не удалось определить учётную запись гостя. Обнови этот компьютер на месте.' }
            Write-Host "  Обычные пользователи: $(($users | ForEach-Object { $_.Name }) -join ', ')"
            $GuestUser = (Read-Host 'Введи имя учётной записи гостя').Trim()
        }
    }
    $guest = Get-LocalUser -Name $GuestUser -ErrorAction SilentlyContinue
    if (-not $guest) { throw "Пользователь «$GuestUser» не найден." }
    if ($admins -contains $guest.SID.Value) { throw "«$GuestUser» входит в группу администраторов: лаунчер у него не откроется." }
    $guestProfile = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($guest.SID.Value)" -ErrorAction SilentlyContinue).ProfileImagePath
    if (-not $guestProfile) { throw "У «$GuestUser» ещё нет профиля. Войди под ним один раз, сохрани аккаунты Steam и запусти установку снова." }
    Write-Good "Гость: $GuestUser"

    # ---------- Запущенный лаунчер ----------
    # Иначе его файлы заняты и не заменятся
    $running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' AND CommandLine LIKE '%SimraceLauncher.ps1%'")
    if ($running.Count -gt 0) {
        Write-Step 'Запущенный лаунчер'
        $ownSession = (Get-Process -Id $PID).SessionId
        if (@($running | Where-Object { $_.SessionId -eq $ownSession }).Count -gt 0) {
            throw 'Лаунчер запущен в этой учётной записи. Закрой его через Ctrl+Shift+F12 и запусти установку снова.'
        }
        Write-Host '  Лаунчер открыт в другой учётной записи. Для установки её нужно завершить, запущенная там игра закроется.'
        if (-not (Read-Choice 'Завершить её?' $true)) { Close-Window 0 }
        foreach ($session in @($running | ForEach-Object { $_.SessionId } | Sort-Object -Unique)) { & logoff.exe $session }
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Seconds 1
            $running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' AND CommandLine LIKE '%SimraceLauncher.ps1%'")
            if ($running.Count -eq 0) { break }
        }
        if ($running.Count -gt 0) { throw 'Учётная запись не завершилась. Закрой лаунчер через Ctrl+Shift+F12 в её сеансе и запусти установку снова.' }
        Start-Sleep -Seconds 3      # реестр гостя освобождается не сразу
        Write-Good 'Учётная запись завершена'
    }

    # ---------- Вопросы до начала установки ----------
    $resetConfig = $false
    $installedFile = Join-Path $target 'apps.json'
    $packFile = Join-Path $PSScriptRoot 'apps.json'
    if (-not $Quick -and (Test-Path -LiteralPath $installedFile)) {
        $installed = Get-Content -LiteralPath $installedFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $pack = Get-Content -LiteralPath $packFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($pack.collectedAt -and $pack.collectedFrom -ne $env:COMPUTERNAME -and $pack.collectedAt -ne $installed.collectedAt) {
            Write-Step 'Настройки'
            Write-Host "  В этой папке настройки с компьютера $($pack.collectedFrom), а здесь уже есть свои."
            $resetConfig = Read-Choice 'Заменить настройки этого компьютера?' $true
        }
    }

    # ---------- Установка ----------
    Write-Step 'Установка'
    $arguments = @{ GuestUser = $GuestUser }
    if ($EnableAutologon) { $arguments.EnableAutologon = $true }
    if ($resetConfig) { $arguments.ResetConfig = $true }
    & (Join-Path $PSScriptRoot 'Install-Launcher.ps1') @arguments

    # ---------- Проверка результата ----------
    Write-Step 'Проверка'
    $config = Get-Content -LiteralPath $installedFile -Raw -Encoding UTF8 | ConvertFrom-Json

    if (Get-ScheduledTask -TaskName 'SIMRACE Launcher' -TaskPath '\SIMRACE\' -ErrorAction SilentlyContinue) { Write-Good 'Автозапуск настроен' }
    else { Write-Note 'Нет задачи автозапуска' }

    if ((Test-Path -LiteralPath 'Z:\SIMRACE\Logs')) { Write-Good 'Журнал пишется на Z:' }
    else { Write-Note 'Нет диска Z: журнал не переживёт перезагрузку при включённой защите, и подкачки на Z: тоже нет' }

    $number = [regex]::Match($env:COMPUTERNAME, '(\d+)$')
    if ($number.Success) { Write-Good "Race Position на приборке: $([int]$number.Value)" }
    else { Write-Note "В имени компьютера $env:COMPUTERNAME нет номера на конце: Race Position будет пустым" }

    $noCover = @(@($config.apps) | Where-Object {
        $id = $_.id
        -not (@('jpg', 'jpeg', 'png') | Where-Object { Test-Path -LiteralPath (Join-Path $target "images\$id.$_") })
    } | ForEach-Object { $_.name })
    if ($noCover.Count -eq 0) { Write-Good 'Обложки есть у всех игр' }
    else { Write-Note "Нет своей обложки: $($noCover -join ', ')" }

    # Перенесённые ярлыки могут вести на пути, которых на этом компьютере нет
    $shell = New-Object -ComObject WScript.Shell
    foreach ($link in @(Get-ChildItem -LiteralPath (Join-Path $target 'shortcuts') -Filter '*.lnk' -File -ErrorAction SilentlyContinue)) {
        $linkTarget = $shell.CreateShortcut($link.FullName).TargetPath
        if ($linkTarget -and -not (Test-Path -LiteralPath $linkTarget)) { Write-Note "Ярлык $($link.Name) ведёт на несуществующий файл: $linkTarget" }
    }

    $steam = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath
    if ($steam) { Write-Good 'Steam установлен' } else { Write-Note 'Steam не найден' }

    $acc = @($config.apps) | Where-Object { $_.id -eq 'acc' } | Select-Object -First 1
    if ($acc -and $acc.extra) {
        $toolPath = @($acc.extra.paths | Where-Object { $_ } | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) } | Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1
        if ($toolPath) { Write-Good "Сервер ACC, правая кнопка мыши на плитке: $toolPath" }
        elseif ($acc.extra.shortcut) { Write-Good 'Сервер ACC привязан через ярлык' }
        else { Write-Note 'Программа сервера ACC не найдена по пути из настроек' }

    }
    else { Write-Note 'Программа сервера ACC не привязана: положи её папку рядом со скриптом и запусти установку снова' }

    # ---------- Итог ----------
    Write-Host ''
    if ($script:Warnings.Count -eq 0) { Write-Host 'Установка завершена, замечаний нет.' -ForegroundColor Green }
    else { Write-Host "Установка завершена, замечаний: $($script:Warnings.Count). Они перечислены выше." -ForegroundColor Yellow }
    Write-Host 'Защита UWF пока выключена. Проверь лаунчер под гостем и включи её шестерёнкой: Защита UWF.'
    if ($Unattended) {
        try { Stop-Transcript | Out-Null } catch { }
        exit 0
    }
    if ($Quick) {
        Write-Host 'Перезагрузка через 15 секунд. Отмена: закрой это окно.'
        Start-Sleep -Seconds 15
    }
    if (Read-Choice 'Перезагрузить компьютер сейчас?' $true) {
        try { Stop-Transcript | Out-Null } catch { }
        Restart-Computer -Force
    }
}
catch {
    Write-Host ''
    Write-Host "Установка не завершена: $($_.Exception.Message)" -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch { }
    Close-Window 1
}

try { Stop-Transcript | Out-Null } catch { }
Close-Window 0
