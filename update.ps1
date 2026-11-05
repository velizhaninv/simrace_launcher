<#
  Первая установка и обновление вручную. Запуск в терминале от администратора:
  irm https://raw.githubusercontent.com/velizhaninv/simrace_launcher/main/update.ps1 | iex
#>
& {
    $ErrorActionPreference = 'Stop'
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Открой терминал от имени администратора и повтори команду.' }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        $work = Join-Path $env:TEMP "simrace-update-$PID"
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $archive = Join-Path $work 'launcher.zip'
        Write-Host 'Скачиваю лаунчер с GitHub...'
        Invoke-WebRequest -Uri 'https://github.com/velizhaninv/simrace_launcher/archive/refs/heads/main.zip' -OutFile $archive -UseBasicParsing
        Expand-Archive -LiteralPath $archive -DestinationPath $work -Force
        $pack = Get-ChildItem -LiteralPath $work -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Auto-Install.ps1') } | Select-Object -First 1
        if (-not $pack) { throw 'В архиве нет файлов лаунчера.' }
        $destination = Join-Path $env:SystemDrive 'SimraceLauncher Beta 1\SimraceLauncher'
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Copy-Item -Path (Join-Path $pack.FullName '*') -Destination $destination -Recurse -Force
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        & (Join-Path $destination 'Auto-Install.ps1') -Quick
    }
    catch { Write-Host "Обновление не выполнено: $($_.Exception.Message)" -ForegroundColor Red }
}
