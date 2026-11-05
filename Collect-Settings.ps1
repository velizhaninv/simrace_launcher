#Requires -Version 5.1
<#
  Собирает настройки с настроенного компьютера в папку с лаунчером: игры, порядок плиток, обложки, ярлыки и программу сервера ACC.
  После этого папку можно копировать на другие компьютеры и запускать Auto-Install.cmd.
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$target = Join-Path $env:ProgramFiles 'SIMRACE\Launcher'
$toolInstalled = Join-Path $env:ProgramData 'SIMRACE\Tools\ACC Server'

try {
    $installedFile = Join-Path $target 'apps.json'
    if (-not (Test-Path -LiteralPath $installedFile)) { throw 'На этом компьютере лаунчер не установлен.' }

    # Настройки. Логины Steam переносятся, паролей в этом файле нет.
    $config = Get-Content -LiteralPath $installedFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $config.adminUser = ''
    foreach ($pair in @{ collectedFrom = $env:COMPUTERNAME; collectedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }.GetEnumerator()) {
        $config | Add-Member -NotePropertyName $pair.Key -NotePropertyValue $pair.Value -Force
    }
    [System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'apps.json'), ($config | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host 'Настройки собраны.'

    # Факты: чтобы правки на этом компьютере попали на другие
    $factsFrom = Join-Path $target 'facts.txt'
    if (Test-Path -LiteralPath $factsFrom) { Copy-Item -LiteralPath $factsFrom -Destination $PSScriptRoot -Force }

    # Обложки: у одной игры остаётся один файл, иначе лаунчер может взять старый
    $imagesFrom = Join-Path $target 'images'
    $imagesTo = Join-Path $PSScriptRoot 'images'
    New-Item -ItemType Directory -Path $imagesTo -Force | Out-Null
    $covers = @(Get-ChildItem -LiteralPath $imagesFrom -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(jpe?g|png)$' })
    foreach ($cover in $covers) {
        Get-ChildItem -LiteralPath $imagesTo -File | Where-Object { $_.BaseName -eq $cover.BaseName -and $_.Extension -ne $cover.Extension } | Remove-Item -Force
        Copy-Item -LiteralPath $cover.FullName -Destination $imagesTo -Force
    }
    Write-Host "Обложек собрано: $($covers.Count)."

    # Ярлыки, выбранные в окне настроек
    $links = @(Get-ChildItem -LiteralPath (Join-Path $target 'shortcuts') -File -ErrorAction SilentlyContinue)
    if ($links.Count -gt 0) {
        $linksTo = Join-Path $PSScriptRoot 'shortcuts'
        New-Item -ItemType Directory -Path $linksTo -Force | Out-Null
        foreach ($link in $links) { Copy-Item -LiteralPath $link.FullName -Destination $linksTo -Force }
        Write-Host "Ярлыков собрано: $($links.Count). На другом компьютере они должны вести на те же пути."
    }

    # Программа сервера ACC, если она уже установлена лаунчером и её ещё нет в этой папке
    $hasTool = @(Get-ChildItem -LiteralPath $PSScriptRoot | Where-Object { $_.Name -match '(?i)acc.*server|dedicated.*server|server.*acc' }).Count -gt 0
    if (-not $hasTool -and (Test-Path -LiteralPath $toolInstalled)) {
        Copy-Item -LiteralPath $toolInstalled -Destination (Join-Path $PSScriptRoot 'ACC Server') -Recurse -Force
        Write-Host 'Программа сервера ACC собрана.'
    }
    Write-Host ''
    Write-Host 'Готово. Копируй всю папку на другой компьютер и запускай Auto-Install.cmd.' -ForegroundColor Green
}
catch { Write-Host "Не получилось: $($_.Exception.Message)" -ForegroundColor Red }
