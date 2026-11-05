#Requires -Version 5.1
<#
  Скачивает обложки игр из Steam в папку images. Уже скачанные файлы не трогает.
  Можно запустить один раз на компьютере с интернетом и затем разносить папку images вместе с лаунчером.
#>
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'apps.json'),
    [string]$OutDir = (Join-Path $PSScriptRoot 'images')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$missing = 0
foreach ($app in $config.apps) {
    $steamId = if ($app.steamAppId) { $app.steamAppId } else { $app.coverSteamAppId }
    if (-not $steamId) { continue }
    $file = Join-Path $OutDir "$($app.id).jpg"
    # Своя обложка в любом формате важнее скачанной
    if (@('jpg', 'jpeg', 'png') | Where-Object { Test-Path -LiteralPath (Join-Path $OutDir "$($app.id).$_") }) { continue }

    $saved = $false
    foreach ($base in 'https://shared.steamstatic.com/store_item_assets/steam/apps', 'https://cdn.cloudflare.steamstatic.com/steam/apps') {
        foreach ($name in 'library_600x900_2x.jpg', 'library_600x900.jpg', 'header.jpg') {
            if ($saved) { continue }
            try {
                Invoke-WebRequest -Uri "$base/$steamId/$name" -OutFile $file -UseBasicParsing -TimeoutSec 20
                $saved = $true
            }
            catch { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        }
    }
    if ($saved) { Write-Host "Скачана обложка: $($app.name)" }
    else { $missing++; Write-Warning "Обложка не скачана: $($app.name)" }
}
Write-Host "Папка обложек: $OutDir. Не скачано: $missing."
