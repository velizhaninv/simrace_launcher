#Requires -Version 5.1
<#
  Исправляет автовход гостя: находит настоящую гостевую учётную запись, проверяет пароль и записывает автовход.
  Новых учётных записей не создаёт и не удаляет. Запускается через Fix-Autologon.cmd.
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Close-Window([int]$Code = 0) {
    Write-Host ''
    [void](Read-Host 'Нажми Enter, чтобы закрыть окно')
    exit $Code
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        exit 0
    }
    catch {
        Write-Host 'Нужны права администратора.' -ForegroundColor Red
        Close-Window 1
    }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SimraceLogonCheck
{
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LogonUser(string user, string domain, string password, int type, int provider, out IntPtr token);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
    // Возвращает 0, если имя и пароль верны, иначе код ошибки Windows
    public static int Test(string user, string password)
    {
        IntPtr token;
        if (!LogonUser(user, ".", password, 2, 0, out token)) return Marshal.GetLastWin32Error();
        CloseHandle(token);
        return 0;
    }
}
'@

# Коды 1327 и 1385: Windows ограничивает такой способ входа, но сам пароль верный
function Test-GuestPassword([string]$User, [string]$Password) {
    $code = [SimraceLogonCheck]::Test($User, $Password)
    if ($code -eq 0 -or $code -eq 1327 -or $code -eq 1385) { return $true }
    if ($code -eq 1326) { return $false }
    throw "Windows не пускает пользователя ${User}: $((New-Object ComponentModel.Win32Exception($code)).Message)"
}

try {
    # При включённой защите запись пропадёт после перезагрузки
    $uwf = Get-CimInstance -Namespace 'root\standardcimv2\embedded' -ClassName UWF_Filter -ErrorAction SilentlyContinue
    if ($uwf -and $uwf.CurrentEnabled) {
        Write-Host 'Включена защита UWF, исправление пропало бы после перезагрузки.' -ForegroundColor Yellow
        if ((Read-Host 'Выключить защиту и перезагрузить? После перезагрузки войди администратором и запусти этот файл снова. [1 - да (Enter), 2 - нет]').Trim() -ne '2') {
            if ($uwf.NextEnabled) { & (Join-Path $env:SystemRoot 'System32\uwfmgr.exe') filter disable | Out-Null }
            Restart-Computer -Force
        }
        Close-Window 0
    }

    # Гость: включённая учётная запись не из группы администраторов, сначала та, что сейчас в системе, затем последняя по входу
    $admins = @()
    try { $admins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { $_.SID.Value }) }
    catch { Write-Host "Список администраторов не прочитан: $($_.Exception.Message)" -ForegroundColor Yellow }
    $console = [string](Get-CimInstance Win32_ComputerSystem).UserName
    $console = $console.Split('\')[-1]
    $users = @(Get-LocalUser | Where-Object { $_.Enabled -and $admins -notcontains $_.SID.Value } |
        Sort-Object -Property @{ Expression = { $_.Name -eq $console }; Descending = $true }, @{ Expression = { $_.LastLogon }; Descending = $true })
    if ($users.Count -eq 0) { throw 'Нет ни одной включённой обычной учётной записи.' }

    $guest = $users[0]
    if ($users.Count -gt 1) {
        Write-Host 'Обычные учётные записи на этом компьютере:'
        for ($i = 0; $i -lt $users.Count; $i++) {
            $last = if ($users[$i].LastLogon) { $users[$i].LastLogon.ToString('dd.MM.yyyy HH:mm') } else { 'входа не было' }
            Write-Host "  $($i + 1) - $($users[$i].Name), последний вход: $last"
        }
        $answer = 0
        $text = (Read-Host "Под какой входить автоматически? [Enter - $($guest.Name)]").Trim()
        if ($text) {
            if (-not [int]::TryParse($text, [ref]$answer) -or $answer -lt 1 -or $answer -gt $users.Count) { throw 'Нет такого номера.' }
            $guest = $users[$answer - 1]
        }
    }
    Write-Host "Гость: $($guest.Name)" -ForegroundColor Green

    # Проверяем пароль заранее, чтобы при включении ПК не было ошибки
    $password = ''
    if (Test-GuestPassword $guest.Name '') { Write-Host 'Пароля нет, автовход будет без него.' -ForegroundColor Green }
    else {
        $accepted = $false
        for ($try = 1; $try -le 3 -and -not $accepted; $try++) {
            $secure = Read-Host "Пароль пользователя $($guest.Name)" -AsSecureString
            $password = [System.Net.NetworkCredential]::new('', $secure).Password
            $accepted = Test-GuestPassword $guest.Name $password
            if (-not $accepted) { Write-Host 'Пароль не подходит.' -ForegroundColor Yellow }
        }
        if (-not $accepted) { throw 'Пароль не подошёл, автовход не изменён.' }
    }

    # Автовход
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '1' -Type String
    Set-ItemProperty -Path $winlogon -Name DefaultUserName -Value $guest.Name -Type String
    Set-ItemProperty -Path $winlogon -Name DefaultDomainName -Value $env:COMPUTERNAME -Type String
    Set-ItemProperty -Path $winlogon -Name DefaultPassword -Value $password -Type String
    Remove-ItemProperty -Path $winlogon -Name AutoLogonCount -ErrorAction SilentlyContinue
    $saved = Get-ItemProperty -Path $winlogon
    if ($saved.AutoAdminLogon -ne '1' -or $saved.DefaultUserName -ne $guest.Name) { throw 'Автовход не записался.' }
    Write-Host 'Автовход записан.' -ForegroundColor Green

    # Настройки лаунчера и ограничения гостя должны относиться к этой же учётной записи
    $settings = Join-Path $env:ProgramFiles 'SIMRACE\Launcher\apps.json'
    if (Test-Path -LiteralPath $settings) {
        $config = Get-Content -LiteralPath $settings -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$config.guestUser -ne $guest.Name) {
            $config | Add-Member -NotePropertyName guestUser -NotePropertyValue $guest.Name -Force
            [System.IO.File]::WriteAllText($settings, ($config | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
            Write-Host 'Имя гостя в настройках лаунчера исправлено.' -ForegroundColor Green
        }

        $sid = $guest.SID.Value
        $hive = "HKU\$sid"
        $loaded = $false
        if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) {
            $profilePath = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction SilentlyContinue).ProfileImagePath
            if ($profilePath) {
                $hive = 'HKU\SimraceGuest'
                & reg.exe load $hive (Join-Path $profilePath 'NTUSER.DAT') | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Реестр гостя занят. Перезагрузи компьютер и запусти этот файл снова.' }
                $loaded = $true
            }
            else { $hive = $null; Write-Host 'Гость ещё не входил в систему: после первого входа запусти Auto-Install.cmd.' -ForegroundColor Yellow }
        }
        if ($hive) {
            try {
                foreach ($policy in @(@('System', 'DisableTaskMgr'), @('System', 'DisableLockWorkstation'), @('System', 'DisableChangePassword'), @('Explorer', 'NoLogoff'))) {
                    & reg.exe add "$hive\Software\Microsoft\Windows\CurrentVersion\Policies\$($policy[0])" /v $policy[1] /t REG_DWORD /d 1 /f | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Не записан параметр $($policy[1])." }
                }
                Write-Host 'Ограничения гостя применены.' -ForegroundColor Green
            }
            finally {
                if ($loaded) {
                    [GC]::Collect()
                    & reg.exe unload $hive | Out-Null
                }
            }
        }
    }

    Write-Host ''
    Write-Host "Готово. После перезагрузки Windows сама войдёт под $($guest.Name) и откроется лаунчер." -ForegroundColor Green
    if ((Read-Host 'Перезагрузить сейчас? [1 - да (Enter), 2 - нет]').Trim() -ne '2') { Restart-Computer -Force }
}
catch {
    Write-Host ''
    Write-Host "Не получилось: $($_.Exception.Message)" -ForegroundColor Red
    Close-Window 1
}
Close-Window 0
