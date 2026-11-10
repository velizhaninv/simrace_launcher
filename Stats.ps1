#Requires -Version 5.1
<#
  Статистика сеансов SIMRACE: сколько времени провели за каждым кокпитом и в каких играх.
  Сеанс: от «Начать сеанс» до «Завершить» в лаунчере, вместе с настройкой. Игра: от запуска до закрытия.
  Данные хранит служба каждого кокпита на диске Z:. Окно собирает их по локальной сети, права администратора не нужны.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:Port = 47615
$script:Names = @(1..14 | ForEach-Object { "SIMRACE-$_" })

# Опрос в фоне: подключается ко всем кокпитам сразу
$script:QueryScript = {
    param($Names, $Port, $Line)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $items = foreach ($name in $Names) {
        $client = New-Object System.Net.Sockets.TcpClient
        $task = $null
        try { $task = $client.ConnectAsync($name, $Port) } catch { }
        [pscustomobject]@{ Name = $name; Client = $client; Task = $task }
    }
    $deadline = (Get-Date).AddMilliseconds(2500)
    foreach ($item in $items) {
        if (-not $item.Task) { continue }
        $left = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
        try { [void]$item.Task.Wait($left) } catch { }
    }
    $results = @{}
    foreach ($item in $items) {
        $answer = $null
        if ($item.Task -and $item.Task.Status -eq 'RanToCompletion' -and $item.Client.Connected) {
            try {
                $stream = $item.Client.GetStream()
                $stream.ReadTimeout = 8000
                $stream.WriteTimeout = 3000
                $writer = New-Object System.IO.StreamWriter($stream, $encoding, 4096, $true)
                $writer.AutoFlush = $true
                $writer.WriteLine($Line)
                $reader = New-Object System.IO.StreamReader($stream, $encoding, $false, 65536, $true)
                $answer = $reader.ReadLine()
            }
            catch { }
        }
        $item.Client.Close()
        $results[$item.Name] = $answer
    }
    @{ Results = $results }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Статистика сеансов SIMRACE" Width="1380" Height="860" MinWidth="1100" MinHeight="560" WindowStartupLocation="CenterScreen"
        Background="#0E0F11" Foreground="White" FontFamily="Segoe UI" FontSize="15">
  <Window.Resources>
    <Style x:Key="Link" TargetType="Button">
      <Setter Property="Foreground" Value="#C9CCD0"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,4,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="Transparent" CornerRadius="8" Padding="12,6">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="#1C1E21"/><Setter Property="Foreground" Value="White"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <DockPanel Margin="28,16,28,18">
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
      <Button x:Name="BtnRefresh" DockPanel.Dock="Right" Content="↻  Обновить" Style="{StaticResource Link}" Margin="0"/>
      <Button x:Name="BtnExport" DockPanel.Dock="Right" Content="Выгрузить в CSV" Style="{StaticResource Link}"/>
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock Text="Статистика сеансов" FontSize="20" FontWeight="SemiBold" VerticalAlignment="Center" Margin="2,0,22,0"/>
        <Button x:Name="BtnToday" Content="Сегодня" Style="{StaticResource Link}"/>
        <Button x:Name="BtnWeek" Content="7 дней" Style="{StaticResource Link}"/>
        <Button x:Name="BtnMonth" Content="30 дней" Style="{StaticResource Link}"/>
      </StackPanel>
    </DockPanel>
    <TextBlock x:Name="TxtSummary" DockPanel.Dock="Top" Foreground="#C9CCD0" FontSize="15" Margin="2,0,0,12" TextWrapping="Wrap"/>
    <TextBlock DockPanel.Dock="Bottom" Foreground="#7C8085" FontSize="13" Margin="2,12,0,0" TextWrapping="Wrap"
               Text="Сеанс: время от «Начать сеанс» до «Завершить» в лаунчере, вместе с настройкой и паузами. «В играх»: время от запуска игры до её закрытия. Записи ведутся с версии лаунчера 2026.11.10-9 и хранятся на каждом кокпите."/>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="3*"/>
        <ColumnDefinition Width="18"/>
        <ColumnDefinition Width="2*"/>
      </Grid.ColumnDefinitions>
      <Border Grid.Column="0" Background="#141518" BorderBrush="#2A2D31" BorderThickness="1" CornerRadius="14" Padding="10,6">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" Text="ПО КОКПИТАМ" FontSize="12" FontWeight="SemiBold" Foreground="#E2450F" Margin="8,6,0,6"/>
          <ContentControl x:Name="PcHeader" DockPanel.Dock="Top"/>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="PcRows"/></ScrollViewer>
        </DockPanel>
      </Border>
      <Border Grid.Column="2" Background="#141518" BorderBrush="#2A2D31" BorderThickness="1" CornerRadius="14" Padding="10,6">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" Text="ПО ИГРАМ" FontSize="12" FontWeight="SemiBold" Foreground="#E2450F" Margin="8,6,0,6"/>
          <ContentControl x:Name="GameHeader" DockPanel.Dock="Top"/>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="GameRows"/></ScrollViewer>
        </DockPanel>
      </Border>
    </Grid>
  </DockPanel>
</Window>
'@
$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($name in 'BtnRefresh', 'BtnExport', 'BtnToday', 'BtnWeek', 'BtnMonth', 'TxtSummary', 'PcHeader', 'PcRows', 'GameHeader', 'GameRows') {
    Set-Variable -Name $name -Value $Window.FindName($name) -Scope Script
}

function New-Brush([string]$Color) { return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Color) }

# Строка таблицы: ширины столбцов, тексты и цвет
function New-TableRow([double[]]$Widths, [string[]]$Texts, [string]$Color = '#FFFFFF', [bool]$Header = $false) {
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($width in $Widths) {
        $column = New-Object System.Windows.Controls.ColumnDefinition
        $column.Width = $(if ($width -gt 0) { New-Object System.Windows.GridLength($width) } else { New-Object System.Windows.GridLength(1, 'Star') })
        [void]$grid.ColumnDefinitions.Add($column)
    }
    for ($i = 0; $i -lt $Texts.Count; $i++) {
        $block = New-Object System.Windows.Controls.TextBlock
        $block.Text = $Texts[$i]
        $block.Foreground = New-Brush $Color
        $block.TextTrimming = 'CharacterEllipsis'
        $block.Margin = New-Object System.Windows.Thickness(8, 0, 8, 0)
        $block.VerticalAlignment = 'Center'
        if ($Header) {
            $block.FontSize = 12
            $block.FontWeight = [System.Windows.FontWeights]::SemiBold
        }
        elseif ($i -eq 0) { $block.FontWeight = [System.Windows.FontWeights]::SemiBold }
        [System.Windows.Controls.Grid]::SetColumn($block, $i)
        [void]$grid.Children.Add($block)
    }
    $border = New-Object System.Windows.Controls.Border
    $border.Child = $grid
    if ($Header) { $border.Padding = New-Object System.Windows.Thickness(0, 4, 0, 8) }
    else {
        $border.BorderBrush = New-Brush '#22FFFFFF'
        $border.BorderThickness = New-Object System.Windows.Thickness(0, 1, 0, 0)
        $border.Padding = New-Object System.Windows.Thickness(0, 7, 0, 7)
    }
    return $border
}

$script:PcWidths = [double[]]@(130, 90, 140, 140, 0)
$script:GameWidths = [double[]]@(0, 90, 120, 90)
$PcHeader.Content = New-TableRow $script:PcWidths @('КОКПИТ', 'СЕАНСОВ', 'ВРЕМЯ СЕАНСОВ', 'В ИГРАХ', 'ПОСЛЕДНИЙ СЕАНС') '#7C8085' $true
$GameHeader.Content = New-TableRow $script:GameWidths @('ИГРА', 'ЗАПУСКОВ', 'ВРЕМЯ', 'КОКПИТОВ') '#7C8085' $true

function Format-Minutes([double]$Minutes) {
    $total = [int][Math]::Round($Minutes)
    if ($total -lt 60) { return "$total мин" }
    return ('{0} ч {1:00} мин' -f [int][Math]::Floor($total / 60), ($total % 60))
}

# ---------- Данные ----------

$script:Records = @()          # все записи за 31 день со всех кокпитов
$script:Silent = @()           # кокпиты, которые не ответили
$script:Days = 1               # 1: сегодня, 7, 30
$script:Running = $null
$script:LoadedAt = $null

function Get-PeriodRecords {
    $since = (Get-Date).Date.AddDays( - ($script:Days - 1))
    return @($script:Records | Where-Object { $_.Start -ge $since })
}

function Show-Stats {
    foreach ($button in $BtnToday, $BtnWeek, $BtnMonth) { $button.Foreground = New-Brush '#C9CCD0' }
    $active = $(switch ($script:Days) { 1 { $BtnToday } 7 { $BtnWeek } default { $BtnMonth } })
    $active.Foreground = New-Brush '#E2450F'

    $records = Get-PeriodRecords
    $sessions = @($records | Where-Object { $_.Kind -eq 'session' })
    $games = @($records | Where-Object { $_.Kind -eq 'game' })

    $PcRows.Children.Clear()
    foreach ($name in $script:Names) {
        $own = @($sessions | Where-Object { $_.Computer -eq $name })
        $ownGames = @($games | Where-Object { $_.Computer -eq $name })
        $sessionMinutes = ($own | Measure-Object -Property Minutes -Sum).Sum
        $gameMinutes = ($ownGames | Measure-Object -Property Minutes -Sum).Sum
        $last = $own | Sort-Object Start -Descending | Select-Object -First 1
        $lastText = $(if ($last) { $last.Start.ToString('dd.MM HH:mm') + ' · ' + (Format-Minutes $last.Minutes) } else { '—' })
        $color = $(if ($script:Silent -contains $name) { '#7C8085' } elseif ($own.Count -eq 0) { '#A2A6AB' } else { '#FFFFFF' })
        $texts = @($name, [string]$own.Count, $(if ($own.Count) { Format-Minutes $sessionMinutes } else { '—' }), $(if ($ownGames.Count) { Format-Minutes $gameMinutes } else { '—' }), $(if ($script:Silent -contains $name) { 'нет связи' } else { $lastText }))
        [void]$PcRows.Children.Add((New-TableRow $script:PcWidths $texts $color))
    }

    $GameRows.Children.Clear()
    $byGame = @($games | Group-Object Game | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Count = $_.Count; Minutes = ($_.Group | Measure-Object -Property Minutes -Sum).Sum; Pcs = @($_.Group | Select-Object -ExpandProperty Computer -Unique).Count }
    } | Sort-Object Minutes -Descending)
    foreach ($game in $byGame) {
        [void]$GameRows.Children.Add((New-TableRow $script:GameWidths @($game.Name, [string]$game.Count, (Format-Minutes $game.Minutes), [string]$game.Pcs)))
    }
    if ($byGame.Count -eq 0) { [void]$GameRows.Children.Add((New-TableRow $script:GameWidths @('Запусков игр за период нет', '', '', '') '#7C8085')) }

    $period = $(switch ($script:Days) { 1 { 'сегодня' } 7 { 'за 7 дней' } default { 'за 30 дней' } })
    $parts = @("Сеансов $period`: $($sessions.Count)")
    $parts += 'время сеансов: ' + (Format-Minutes (($sessions | Measure-Object -Property Minutes -Sum).Sum))
    $parts += 'в играх: ' + (Format-Minutes (($games | Measure-Object -Property Minutes -Sum).Sum))
    $text = $parts -join ' · '
    if ($script:Silent.Count -gt 0) { $text += ". Нет связи: $($script:Silent -join ', ')" }
    if ($script:LoadedAt) { $text += ". Обновлено в $($script:LoadedAt.ToString('HH:mm'))" }
    $TxtSummary.Text = $text
}

function Start-Load {
    if ($script:Running) { return }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:QueryScript).AddArgument($script:Names).AddArgument($script:Port).AddArgument('{"action":"stats","days":31}')
    $script:Running = @{ Ps = $ps; Async = $ps.BeginInvoke() }
    $BtnRefresh.IsEnabled = $false
    $TxtSummary.Text = 'Собираю статистику с кокпитов...'
}

function Update-Load {
    if (-not $script:Running -or -not $script:Running.Async.IsCompleted) { return }
    $job = $script:Running
    $script:Running = $null
    $BtnRefresh.IsEnabled = $true
    $output = $null
    try { $output = @($job.Ps.EndInvoke($job.Async))[0] } catch { $TxtSummary.Text = "Ошибка опроса: $_" }
    $job.Ps.Dispose()
    if (-not $output) { return }
    $records = New-Object System.Collections.ArrayList
    $silent = @()
    foreach ($name in $script:Names) {
        $answer = $output.Results[$name]
        $data = $null
        if ($answer) { try { $data = $answer | ConvertFrom-Json } catch { } }
        if (-not $data -or -not $data.ok) {
            $silent += $name
            continue
        }
        foreach ($item in @($data.records)) {
            try {
                [void]$records.Add([pscustomobject]@{
                    Computer = [string]$item.computer; Kind = [string]$item.kind; Game = [string]$item.game
                    Start = [datetime]$item.start; Minutes = [double]$item.minutes
                })
            }
            catch { }
        }
    }
    $script:Records = $records.ToArray()
    $script:Silent = $silent
    $script:LoadedAt = Get-Date
    Show-Stats
}

# Выгрузка на общий рабочий стол: файл открывается в Excel
function Export-Stats {
    $records = Get-PeriodRecords | Sort-Object Start
    $lines = @('Тип;Кокпит;Игра;Дата;Начало;Минут')
    foreach ($item in $records) {
        $kind = $(if ($item.Kind -eq 'session') { 'Сеанс' } else { 'Игра' })
        $lines += '{0};{1};{2};{3};{4};{5}' -f $kind, $item.Computer, $item.Game, $item.Start.ToString('dd.MM.yyyy'), $item.Start.ToString('HH:mm'), ([string]$item.Minutes).Replace('.', ',')
    }
    $folder = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $file = Join-Path $folder ("Статистика SIMRACE {0}.csv" -f (Get-Date -Format 'yyyy-MM-dd HH-mm'))
    try {
        [System.IO.File]::WriteAllLines($file, $lines, (New-Object System.Text.UTF8Encoding($true)))
        $TxtSummary.Text = "Выгружено на рабочий стол: $(Split-Path -Leaf $file)"
    }
    catch { $TxtSummary.Text = "Не удалось сохранить файл: $($_.Exception.Message)" }
}

$BtnToday.Add_Click({ $script:Days = 1; Show-Stats })
$BtnWeek.Add_Click({ $script:Days = 7; Show-Stats })
$BtnMonth.Add_Click({ $script:Days = 30; Show-Stats })
$BtnRefresh.Add_Click({ Start-Load })
$BtnExport.Add_Click({ Export-Stats })

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$timer.Add_Tick({
    try { Update-Load }
    catch { $TxtSummary.Text = "Ошибка: $_" }
})
$Window.Dispatcher.Add_UnhandledException({
    param($sender, $e)
    $e.Handled = $true
    $TxtSummary.Text = "Ошибка: $($e.Exception.Message)"
})
$timer.Start()
Show-Stats
Start-Load
[void]$Window.ShowDialog()
$timer.Stop()
