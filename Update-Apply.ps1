#Requires -Version 5.1
<#
  Скачивает последнюю версию лаунчера с GitHub и устанавливает её. Запускается службой лаунчера.
  Настройки, обложки и ярлыки остаются. Результат записывается в update-result.txt.
#>
$ErrorActionPreference = 'Stop'
$zipUrl = 'https://github.com/velizhaninv/simrace_launcher/archive/refs/heads/main.zip'
$installed = $PSScriptRoot
$work = Join-Path $env:ProgramData 'SIMRACE\Update'
$resultFile = Join-Path $env:ProgramData 'SIMRACE\update-result.txt'

# Папки может не быть: она создаётся только вместе с программой сервера ACC
New-Item -ItemType Directory -Path (Split-Path -Parent $resultFile) -Force | Out-Null

function Set-Result([string]$Text) {
    [System.IO.File]::WriteAllText($resultFile, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

try {
    Set-Result ''
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'

    # После загрузки сеть появляется не сразу
    $archive = Join-Path $work 'launcher.zip'
    $lastError = $null
    for ($try = 1; $try -le 12; $try++) {
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $archive -UseBasicParsing -TimeoutSec 120
            $lastError = $null
            break
        }
        catch {
            $lastError = $_
            Start-Sleep -Seconds 15
        }
    }
    if ($lastError) { throw "Нет связи с GitHub: $($lastError.Exception.Message)" }

    Expand-Archive -LiteralPath $archive -DestinationPath $work -Force
    $pack = Get-ChildItem -LiteralPath $work -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Install-Launcher.ps1') } | Select-Object -First 1
    if (-not $pack) { throw 'В архиве нет файлов лаунчера.' }
    Get-ChildItem -LiteralPath $pack.FullName -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    $config = Get-Content -LiteralPath (Join-Path $installed 'apps.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $guest = [string]$config.guestUser
    if (-not $guest) { throw 'В настройках не указана учётная запись гостя.' }
    $admin = [string]$config.adminUser
    if (-not $admin) {
        $number = [regex]::Match($env:COMPUTERNAME, '(\d+)$')
        $admin = $(if ($number.Success) { "admin$([int]$number.Value)" } else { '' })
    }

    & (Join-Path $pack.FullName 'Install-Launcher.ps1') -GuestUser $guest -AdminUser $admin | Out-Null

    $version = ([string](Get-Content -LiteralPath (Join-Path $installed 'version.txt') -Raw -ErrorAction SilentlyContinue)).Trim()
    Set-Result "Версия $version."
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}
catch {
    Set-Result $_.Exception.Message
    exit 1
}
