#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
  Установка лаунчера на один компьютер. Запускать от администратора при выключенном UWF.
  Повторный запуск безопасен: файлы, задача и настройки обновляются.

  Установка:
    .\Install-Launcher.ps1 -GuestUser Guest1
  С автовходом гостя при включении компьютера:
    .\Install-Launcher.ps1 -GuestUser Guest1 -EnableAutologon
  Удаление:
    .\Install-Launcher.ps1 -Uninstall -GuestUser Guest1
#>
param(
    [Parameter(Mandatory = $true)][string]$GuestUser,
    [string]$AdminUser = $env:USERNAME,
    [switch]$EnableAutologon,
    [switch]$SkipCovers,
    [switch]$ResetConfig,      # заменить настройки на стандартные (apps.json из архива)
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$target    = Join-Path $env:ProgramFiles 'SIMRACE\Launcher'
$taskName  = 'SIMRACE Launcher'
$taskPath  = '\SIMRACE\'
$agentTask = 'SIMRACE Agent'
$settingsLink = Join-Path $env:PUBLIC 'Desktop\Настройки лаунчера SIMRACE.lnk'
$launcherLink = Join-Path $env:PUBLIC 'Desktop\Лаунчер SIMRACE.lnk'
$fleetLink = Join-Path $env:PUBLIC 'Desktop\Кокпиты SIMRACE.lnk'
$firewallRule = 'SIMRACE Agent'
$oldLink   = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp\SIMRACE Launcher.lnk'
$winlogon  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$toolsRoot = Join-Path $env:ProgramData 'SIMRACE\Tools'
$toolTarget = Join-Path $toolsRoot 'ACC Server'

# Настройки только для гостя: отключают диспетчер задач, блокировку, смену пароля и выход из системы.
$guestPolicies = @(
    @{ Key = 'Software\Microsoft\Windows\CurrentVersion\Policies\System';   Name = 'DisableTaskMgr' },
    @{ Key = 'Software\Microsoft\Windows\CurrentVersion\Policies\System';   Name = 'DisableLockWorkstation' },
    @{ Key = 'Software\Microsoft\Windows\CurrentVersion\Policies\System';   Name = 'DisableChangePassword' },
    @{ Key = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoLogoff' }
)

function Set-GuestPolicies([string]$User, [bool]$Enable) {
    $sid = (New-Object System.Security.Principal.NTAccount($User)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    $hiveRoot = "HKU\$sid"
    $loaded = $false
    if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) {
        # Гость не в системе: временно подключаем его раздел реестра
        $profile = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $profile) { throw "У пользователя $User ещё нет профиля. Войди под ним один раз и запусти установку снова." }
        $hiveRoot = 'HKU\SimraceGuest'
        & reg.exe load $hiveRoot (Join-Path $profile 'NTUSER.DAT') | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Не удалось подключить реестр пользователя $User. Выйди из его учётной записи и повтори." }
        $loaded = $true
    }
    try {
        foreach ($policy in $guestPolicies) {
            if ($Enable) {
                & reg.exe add "$hiveRoot\$($policy.Key)" /v $policy.Name /t REG_DWORD /d 1 /f | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Не записан параметр $($policy.Name)." }
            }
            else {
                # Отсутствие параметра здесь не ошибка: значит, его уже убрали
                cmd.exe /c "reg delete `"$hiveRoot\$($policy.Key)`" /v $($policy.Name) /f >nul 2>nul"
            }
        }
    }
    finally {
        if ($loaded) {
            [GC]::Collect()
            & reg.exe unload $hiveRoot | Out-Null
        }
    }
}

# Программа сервера ACC рядом со скриптом: папка, архив .zip или один .exe, в имени есть ACC и Server либо Dedicated и Server.
function Find-ServerToolSource {
    $items = @(Get-ChildItem -LiteralPath $PSScriptRoot | Where-Object { $_.Name -match '(?i)acc.*server|dedicated.*server|server.*acc' })
    $folder = $items | Where-Object { $_.PSIsContainer } | Select-Object -First 1
    if ($folder) { return $folder.FullName }
    $zip = $items | Where-Object { $_.Extension -eq '.zip' } | Select-Object -First 1
    if ($zip) {
        $unpacked = Join-Path $PSScriptRoot $zip.BaseName
        Expand-Archive -LiteralPath $zip.FullName -DestinationPath $unpacked -Force
        return $unpacked
    }
    $exe = $items | Where-Object { $_.Extension -eq '.exe' } | Select-Object -First 1
    if ($exe) { return $exe.FullName }
    return $null
}

# Какой .exe запускать. Выбор сохраняется в run.txt, чтобы не спрашивать на следующих компьютерах.
function Select-ServerExe([string]$Folder) {
    $saved = Join-Path $Folder 'run.txt'
    if (Test-Path -LiteralPath $saved) {
        $name = (Get-Content -LiteralPath $saved -Raw -Encoding UTF8).Trim()
        if ($name -and (Test-Path -LiteralPath (Join-Path $Folder $name))) { return $name }
    }
    $prefix = (Get-Item -LiteralPath $Folder).FullName.TrimEnd('\').Length + 1
    $all = @(Get-ChildItem -LiteralPath $Folder -Recurse -Filter '*.exe' -File |
        Where-Object { $_.BaseName -notmatch '(?i)unins|setup|install|update|crash|redist|createdump|^accServer$' } |
        ForEach-Object { $_.FullName.Substring($prefix) })
    if ($all.Count -eq 0) { return $null }
    $choice = $null
    if ($all.Count -eq 1) { $choice = $all[0] }
    foreach ($pattern in '(?i)gui', '(?i)server') {
        if ($choice) { break }
        $matched = @($all | Where-Object { (Split-Path -Leaf $_) -match $pattern })
        if ($matched.Count -eq 1) { $choice = $matched[0] }
    }
    while (-not $choice) {
        Write-Host 'Какой файл запускает программу сервера ACC?'
        for ($i = 0; $i -lt $all.Count; $i++) { Write-Host "  $($i + 1) - $($all[$i])" }
        $answer = 0
        if ([int]::TryParse((Read-Host 'Номер'), [ref]$answer) -and $answer -ge 1 -and $answer -le $all.Count) { $choice = $all[$answer - 1] }
    }
    try { [System.IO.File]::WriteAllText($saved, $choice, (New-Object System.Text.UTF8Encoding($false))) } catch { }
    return $choice
}

# Имя сервера по номеру компьютера: SimRace 10 на SIMRACE-10. Заданное вручную имя не меняется.
function Set-AccServerName {
    $settings = Join-Path $toolTarget 'cfg\settings.json'
    $number = [regex]::Match($env:COMPUTERNAME, '(\d+)$')
    if (-not (Test-Path -LiteralPath $settings) -or -not $number.Success) { return }
    $text = [System.IO.File]::ReadAllText($settings)
    if ($text -notmatch '"serverName"\s*:\s*"SimRace"') { return }
    $text = $text -replace '"serverName"\s*:\s*"SimRace"', "`"serverName`": `"SimRace $([int]$number.Value)`""
    [System.IO.File]::WriteAllText($settings, $text, [System.Text.Encoding]::Unicode)    # UTF-16 LE, как у сервера Kunos
}

# Копирует программу и привязывает её к правой кнопке мыши на плитке ACC.
function Install-ServerTool($Config) {
    $source = Find-ServerToolSource
    if (-not $source) { return }
    $acc = @($Config.apps) | Where-Object { $_.id -eq 'acc' } | Select-Object -First 1
    if (-not $acc) {
        Write-Warning 'В настройках нет плитки ACC, программа сервера не привязана.'
        return
    }
    if (Test-Path -LiteralPath $source -PathType Leaf) { $relative = Split-Path -Leaf $source }
    else { $relative = Select-ServerExe $source }
    if (-not $relative) {
        Write-Warning "В папке $source нет файла .exe для запуска, программа сервера не привязана. Если там только установщик, сначала установи её и положи рядом папку с установленной программой."
        return
    }

    New-Item -ItemType Directory -Path $toolTarget -Force | Out-Null
    # Программа может быть открыта: тогда файл занят, остаётся прежняя версия, а обновление лаунчера продолжается
    try {
        if (Test-Path -LiteralPath $source -PathType Leaf) { Copy-Item -LiteralPath $source -Destination $toolTarget -Force }
        else {
            $prefix = (Get-Item -LiteralPath $source).FullName.TrimEnd('\').Length + 1
            foreach ($file in @(Get-ChildItem -LiteralPath $source -Recurse -File -Force)) {
                $relativeFile = $file.FullName.Substring($prefix)
                $destination = Join-Path $toolTarget $relativeFile
                # Настройки сервера кладём только при первой установке: правки, сделанные на компьютере, остаются
                if (($relativeFile -like 'cfg\*' -or $relativeFile -eq 'schedule.json') -and (Test-Path -LiteralPath $destination)) { continue }
                New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
            }
        }
    }
    catch { Write-Warning "Программа сервера ACC не обновлена, возможно, она открыта: $($_.Exception.Message)" }
    Set-AccServerName
    Get-ChildItem -LiteralPath $toolTarget -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
    # Программа работает под гостем и должна сохранять свои настройки. При включённом UWF они сбрасываются после перезагрузки.
    & icacls.exe $toolsRoot /grant '*S-1-5-32-545:(OI)(CI)M' /T /Q | Out-Null

    $name = if ($acc.extra -and $acc.extra.name) { [string]$acc.extra.name } else { 'Запустить сервер' }
    $extra = [pscustomobject]@{ id = 'acc-extra'; name = $name; paths = @("%ProgramData%\SIMRACE\Tools\ACC Server\$relative") }
    $acc | Add-Member -NotePropertyName extra -NotePropertyValue $extra -Force
    Get-ChildItem -LiteralPath (Join-Path $target 'shortcuts') -Filter 'acc-extra.*' -File -ErrorAction SilentlyContinue | Remove-Item -Force
    Write-Host "Программа сервера ACC установлена: $relative"
}

# При включённом UWF всё записанное исчезнет после перезагрузки, поэтому останавливаемся
$uwf = Get-CimInstance -Namespace 'root\standardcimv2\embedded' -ClassName UWF_Filter -ErrorAction SilentlyContinue
if ($uwf -and $uwf.CurrentEnabled) {
    throw 'UWF включён. Отключи его (uwfmgr filter disable), перезагрузи компьютер и запусти установку снова.'
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName $agentTask -TaskPath $taskPath -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $agentTask -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $oldLink) { Remove-Item -LiteralPath $oldLink -Force }
    if (Test-Path -LiteralPath $settingsLink) { Remove-Item -LiteralPath $settingsLink -Force }
    if (Test-Path -LiteralPath $launcherLink) { Remove-Item -LiteralPath $launcherLink -Force }
    if (Test-Path -LiteralPath $fleetLink) { Remove-Item -LiteralPath $fleetLink -Force }
    Remove-NetFirewallRule -Name $firewallRule -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -Name 'SIMRACE ACC Server' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $target)  { Remove-Item -LiteralPath $target -Recurse -Force }
    if (Test-Path -LiteralPath $toolsRoot) { Remove-Item -LiteralPath $toolsRoot -Recurse -Force }
    Set-GuestPolicies $GuestUser $false
    Write-Host 'Лаунчер удалён, ограничения гостя сняты. Автовход не менялся.'
    return
}

# Копируем файлы
New-Item -ItemType Directory -Path (Join-Path $target 'images') -Force | Out-Null
foreach ($file in 'SimraceLauncher.ps1', 'LauncherSettings.ps1', 'Settings-Launcher.cmd', 'Start-Launcher.cmd', 'Fleet.ps1', 'Fleet.cmd', 'UwfPanel.ps1', 'SimraceAgent.ps1', 'Update-Apply.ps1', 'version.txt', 'apps.json', 'facts.txt', 'logo.png', 'background.jpg', 'dash.png', 'dash-off.png', 'qr-telegram.png', 'qr-site.png', 'wheel-nardi.png', 'wheel-cs.png', 'wheel-ks.png') {
    $source = Join-Path $PSScriptRoot $file
    # При обновлении настройки сохраняются: игры, логины и кнопки под плитками
    if ($file -eq 'apps.json' -and -not $ResetConfig -and (Test-Path -LiteralPath (Join-Path $target 'apps.json'))) {
        Write-Host 'Настройки сохранены. Заменить их можно ключом -ResetConfig.'
        continue
    }
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $target -Force }
    elseif ($file -match '\.(png|jpg)$') { Write-Warning "Нет файла оформления $file." }
    else { throw "Не найден файл $file рядом с установщиком." }
}
$imagesSource = Join-Path $PSScriptRoot 'images'
if (Test-Path -LiteralPath $imagesSource) {
    # У игры остаётся один файл обложки: лаунчер ищет сначала .jpg и мог бы взять старый вместо нового .png
    $imagesTarget = Join-Path $target 'images'
    foreach ($cover in @(Get-ChildItem -LiteralPath $imagesSource -File | Where-Object { $_.Extension -match '^\.(jpe?g|png)$' })) {
        Get-ChildItem -LiteralPath $imagesTarget -File | Where-Object { $_.BaseName -eq $cover.BaseName -and $_.Extension -ne $cover.Extension } | Remove-Item -Force
        Copy-Item -LiteralPath $cover.FullName -Destination $imagesTarget -Force
    }
}

$fontsSource = Join-Path $PSScriptRoot 'fonts'
if (Test-Path -LiteralPath $fontsSource) { Copy-Item -LiteralPath $fontsSource -Destination $target -Recurse -Force }

$shortcutsSource = Join-Path $PSScriptRoot 'shortcuts'
if (Test-Path -LiteralPath $shortcutsSource) {
    Copy-Item -LiteralPath $shortcutsSource -Destination $target -Recurse -Force
}

# Записываем имя администратора для окна выхода. Пароль нигде не хранится.
$configPath = Join-Path $target 'apps.json'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

# При обновлении добавляем только новые параметры, всё уже настроенное остаётся
function Add-MissingProperties($To, $From) {
    foreach ($property in $From.PSObject.Properties) {
        if (-not $To.PSObject.Properties[$property.Name]) {
            $To | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
        }
    }
}
$defaults = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'apps.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$installedLayout = [int]$config.layoutVersion
$installedAxes = [int]$config.axesVersion
$installedInfo = [int]$config.infoVersion
Add-MissingProperties $config $defaults
foreach ($section in 'apps', 'utilities', 'categories') {
    foreach ($item in @($defaults.$section)) {
        $existing = @($config.$section) | Where-Object { $_.id -eq $item.id } | Select-Object -First 1
        if ($existing) {
            Add-MissingProperties $existing $item
            # Новые маски ярлыков добавляем после уже заданных
            if ($item.shortcut) { $existing.shortcut = @(@($existing.shortcut) + @($item.shortcut) | Select-Object -Unique) }
        }
        elseif ($section -eq 'utilities') { $config.utilities = @(@($config.utilities) + $item) }
    }
}
# Версия 2026.11.09-5 отключала растягивание окна City Car Driving. Отменено: возвращаем как у остальных игр.
$ccd = @($config.apps) | Where-Object { $_.id -eq 'city-car-driving-2' } | Select-Object -First 1
if ($ccd -and $ccd.PSObject.Properties['forceFullscreen']) { $ccd.PSObject.Properties.Remove('forceFullscreen') }
# Индикатор педалей повторяет базу: старые настройки с одной базой заменяем
if (@($config.devices).Count -lt @($defaults.devices).Count) { $config.devices = $defaults.devices }
# Новая раскладка плиток применяется один раз: категории и порядок из архива, свои игры остаются в конце
if ($installedLayout -lt [int]$defaults.layoutVersion) {
    $defaultIds = @($defaults.apps | ForEach-Object { $_.id })
    $ordered = @($defaultIds | ForEach-Object { $id = $_; @($config.apps) | Where-Object { $_.id -eq $id } })
    foreach ($item in $ordered) { $item.category = (@($defaults.apps) | Where-Object { $_.id -eq $item.id } | Select-Object -First 1).category }
    $config.apps = @($ordered + @(@($config.apps) | Where-Object { $defaultIds -notcontains $_.id }))
    $config.categories = $defaults.categories
    $config.layoutVersion = $defaults.layoutVersion
}
# Описания игр из новой версии заменяют старые один раз. Свои правки после этого не затрагиваются.
if ($installedInfo -lt [int]$defaults.infoVersion) {
    foreach ($item in @($defaults.apps)) {
        $existing = @($config.apps) | Where-Object { $_.id -eq $item.id } | Select-Object -First 1
        if ($existing -and $item.info) { $existing | Add-Member -NotePropertyName info -NotePropertyValue $item.info -Force }
    }
    $config | Add-Member -NotePropertyName infoVersion -NotePropertyValue $defaults.infoVersion -Force
}
# Новая привязка осей применяется один раз
if ($installedAxes -lt [int]$defaults.axesVersion) {
    $config.axes = $defaults.axes
    $config.axesVersion = $defaults.axesVersion
}
$config.adminUser = $AdminUser
$config.guestUser = $GuestUser
Install-ServerTool $config

# Обложка с другим именем не найдётся: файл должен называться как id игры
$imagesSource = Join-Path $PSScriptRoot 'images'
if (Test-Path -LiteralPath $imagesSource) {
    $appIds = @(@($config.apps) | ForEach-Object { $_.id })
    foreach ($cover in @(Get-ChildItem -LiteralPath $imagesSource -File | Where-Object { $_.Extension -match '^\.(jpe?g|png)$' -and $appIds -notcontains $_.BaseName })) {
        Write-Warning "Обложка $($cover.Name) не подходит ни к одной игре. Имена: $($appIds -join ', ')"
    }
}
[System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

# Обложки. Без интернета лаунчер всё равно работает: возьмёт кэш Steam или покажет название.
if (-not $SkipCovers) {
    try { & (Join-Path $PSScriptRoot 'Get-Covers.ps1') -ConfigPath $configPath -OutDir (Join-Path $target 'images') }
    catch { Write-Warning "Обложки не скачаны: $_" }
}

# Папка журнала на незащищённом диске Z:, запись разрешена обычным пользователям
if (Test-Path -LiteralPath 'Z:\') {
    New-Item -ItemType Directory -Path 'Z:\SIMRACE\Logs' -Force | Out-Null
    & icacls.exe 'Z:\SIMRACE' /grant '*S-1-5-32-545:(OI)(CI)M' /T /Q | Out-Null
}

# Запуск при входе пользователя, сразу и без отложенной автозагрузки Windows.
if (Test-Path -LiteralPath $oldLink) { Remove-Item -LiteralPath $oldLink -Force }
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$target\SimraceLauncher.ps1`" -Autostart"
$action    = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $target
$trigger   = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited      # группа «Пользователи»
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

# Служба лаунчера: от имени SYSTEM, с загрузки компьютера. Она выполняет обновление и переключает UWF после проверки пароля.
$agentAction    = New-ScheduledTaskAction -Execute $powershell -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target\SimraceAgent.ps1`"" -WorkingDirectory $target
$agentTrigger   = New-ScheduledTaskTrigger -AtStartup
$agentPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$agentSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $agentTask -TaskPath $taskPath -Action $agentAction -Trigger $agentTrigger -Principal $agentPrincipal -Settings $agentSettings -Force | Out-Null
# Обновление запускает сама служба: её не останавливаем, новая версия начнёт работать после перезагрузки
if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
    Stop-ScheduledTask -TaskName $agentTask -TaskPath $taskPath -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $agentTask -TaskPath $taskPath
}

Set-GuestPolicies $GuestUser $true

# Ярлык настроек на общем рабочем столе. Гость его не увидит: рабочий стол закрыт лаунчером.
$link = (New-Object -ComObject WScript.Shell).CreateShortcut($settingsLink)
$link.TargetPath = Join-Path $target 'Settings-Launcher.cmd'
$link.WorkingDirectory = $target
$link.WindowStyle = 7
$link.Save()

# Ярлык самого лаунчера: запустить его снова после закрытия. Второй копии не будет, лишний запуск просто завершится.
$link = (New-Object -ComObject WScript.Shell).CreateShortcut($launcherLink)
$link.TargetPath = Join-Path $target 'Start-Launcher.cmd'
$link.WorkingDirectory = $target
$link.WindowStyle = 7
$link.Save()

# Сервер ACC: подключения кокпитов из локальной сети. Без правила Windows спросит разрешение, а гость его дать не может.
$accServerExe = Join-Path $toolTarget 'accServer.exe'
Remove-NetFirewallRule -Name 'SIMRACE ACC Server' -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $accServerExe) {
    New-NetFirewallRule -Name 'SIMRACE ACC Server' -DisplayName 'SIMRACE: сервер ACC' -Direction Inbound -Program $accServerExe -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null
}

# Обновление по сети: служба принимает подключения только из локальной сети
Remove-NetFirewallRule -Name $firewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule -Name $firewallRule -DisplayName 'SIMRACE: обновление лаунчера по сети' -Direction Inbound -Protocol TCP -LocalPort 47615 -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null

# Окно «Кокпиты SIMRACE» нужно только на администраторском компьютере
if ($env:COMPUTERNAME -match '(?i)-14$') {
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($fleetLink)
    $link.TargetPath = Join-Path $target 'Fleet.cmd'
    $link.WorkingDirectory = $target
    $link.WindowStyle = 7
    $link.Save()
}

# Автовход нужен, чтобы при включении компьютера гость входил без экрана входа.
# Windows хранит этот пароль в реестре открытым текстом, поэтому у гостя должен быть отдельный простой пароль.
if ($EnableAutologon) {
    $secure = Read-Host "Пароль пользователя $GuestUser (Enter, если пароля нет)" -AsSecureString
    $password = [System.Net.NetworkCredential]::new('', $secure).Password
    Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '1' -Type String
    Set-ItemProperty -Path $winlogon -Name DefaultUserName -Value $GuestUser -Type String
    Set-ItemProperty -Path $winlogon -Name DefaultDomainName -Value $env:COMPUTERNAME -Type String
    Set-ItemProperty -Path $winlogon -Name DefaultPassword -Value $password -Type String
    Write-Host 'Автовход включён.'
}

# Проверка результата
$task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
if (-not $task -or -not (Test-Path -LiteralPath (Join-Path $target 'SimraceLauncher.ps1'))) {
    throw 'Установка не завершена: файлы или задача не найдены.'
}
Write-Host "Готово. Папка: $target"
Write-Host 'Проверь лаунчер под гостем и только потом включай UWF.'
