#Requires -Version 5.1
<#
  Кокпиты SIMRACE: состояние всех компьютеров клуба и обновление лаунчера по локальной сети.
  Запускается на администраторском компьютере SIMRACE-14. Права администратора не нужны.
  Обновление ставит только официальную версию с GitHub и начинается, когда на кокпите закончился сеанс.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:Port = 47615
$script:Names = @(1..14 | ForEach-Object { "SIMRACE-$_" })
$script:VersionUrl = 'https://raw.githubusercontent.com/velizhaninv/simrace_launcher/main/version.txt'

# Опрос в фоне: подключается ко всем кокпитам сразу, ждёт не дольше 2,5 секунды
$script:QueryScript = {
    param($Names, $Port, $Line, $VersionUrl, $Lines)
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
                $stream.ReadTimeout = 4000
                $stream.WriteTimeout = 3000
                $writer = New-Object System.IO.StreamWriter($stream, $encoding, 4096, $true)
                $writer.AutoFlush = $true
                # Своя команда для отдельного кокпита, если задана
                $writer.WriteLine($(if ($Lines -and $Lines.ContainsKey($item.Name)) { $Lines[$item.Name] } else { $Line }))
                $reader = New-Object System.IO.StreamReader($stream, $encoding, $false, 4096, $true)
                $answer = $reader.ReadLine()
            }
            catch { }
        }
        $item.Client.Close()
        $results[$item.Name] = $answer
    }
    $latest = ''
    if ($VersionUrl) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $latest = ([string](Invoke-WebRequest -Uri "$VersionUrl`?t=$([DateTime]::UtcNow.Ticks)" -UseBasicParsing -TimeoutSec 6).Content).Trim()
        }
        catch { }
    }
    @{ Results = $results; Latest = $latest }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Кокпиты SIMRACE" Width="1320" Height="860" MinWidth="1100" MinHeight="600" WindowStartupLocation="CenterScreen"
        Background="#0E0F11" Foreground="White" FontFamily="Segoe UI" FontSize="16">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="#1C1E21" BorderBrush="#2E3135" BorderThickness="1" CornerRadius="10" Padding="20,10">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#E2450F"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="#D23F0D" CornerRadius="10" Padding="22,10">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="#E8501B"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <DockPanel Margin="32,26,32,24">
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,18">
      <TextBlock x:Name="TxtLatest" DockPanel.Dock="Right" FontSize="16" Foreground="#A2A6AB" VerticalAlignment="Center"/>
      <TextBlock Text="Кокпиты SIMRACE" FontSize="30" FontWeight="SemiBold"/>
    </DockPanel>
    <StackPanel DockPanel.Dock="Bottom" Margin="0,14,0,0">
      <TextBlock x:Name="TxtStatus" Foreground="#A2A6AB" TextWrapping="Wrap" Margin="2,0,0,12"/>
      <DockPanel>
        <!-- Выбор кокпитов справа, команды слева -->
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <Button x:Name="BtnSelectOld" Content="Устаревшие" Style="{StaticResource Btn}"/>
          <Button x:Name="BtnSelectAll" Content="Все" Style="{StaticResource Btn}"/>
          <Button x:Name="BtnSelectNone" Content="Снять выбор" Style="{StaticResource Btn}"/>
          <Button x:Name="BtnRefresh" Content="Обновить список" Style="{StaticResource Btn}" Margin="0"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal">
          <Button x:Name="BtnUpdate" Content="Обновить лаунчер" Style="{StaticResource Primary}"/>
          <Button x:Name="BtnLock" Content="Заблокировать" Style="{StaticResource Btn}"/>
          <Button x:Name="BtnReboot" Content="Перезагрузить" Style="{StaticResource Btn}"/>
        </StackPanel>
      </DockPanel>
    </StackPanel>
    <Border Background="#141518" BorderBrush="#2A2D31" BorderThickness="1" CornerRadius="14" Padding="10,6">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="Rows"/>
      </ScrollViewer>
    </Border>
  </DockPanel>
</Window>
'@
$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($name in 'TxtLatest', 'TxtStatus', 'BtnUpdate', 'BtnLock', 'BtnReboot', 'BtnSelectOld', 'BtnSelectAll', 'BtnSelectNone', 'BtnRefresh', 'Rows') {
    Set-Variable -Name $name -Value $Window.FindName($name) -Scope Script
}

$script:Widths = @(44, 170, 130, 150, 120, 230, 170, 0)
function New-Brush([string]$Color) { return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Color) }

function New-Cell([System.Windows.Controls.Grid]$Grid, [int]$Column, [string]$Text, [string]$Color = '#FFFFFF', [bool]$Bold = $false) {
    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $Text
    $block.Foreground = New-Brush $Color
    $block.VerticalAlignment = 'Center'
    $block.TextTrimming = 'CharacterEllipsis'
    $block.Margin = New-Object System.Windows.Thickness(6, 0, 6, 0)
    if ($Bold) { $block.FontWeight = [System.Windows.FontWeights]::SemiBold }
    [System.Windows.Controls.Grid]::SetColumn($block, $Column)
    [void]$Grid.Children.Add($block)
    return $block
}

function New-RowGrid {
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($width in $script:Widths) {
        $column = New-Object System.Windows.Controls.ColumnDefinition
        $column.Width = $(if ($width -gt 0) { New-Object System.Windows.GridLength($width) } else { New-Object System.Windows.GridLength(1, 'Star') })
        [void]$grid.ColumnDefinitions.Add($column)
    }
    return $grid
}

# Заголовок таблицы
$header = New-RowGrid
$header.Margin = New-Object System.Windows.Thickness(0, 6, 0, 8)
$column = 1
foreach ($title in 'КОКПИТ', 'СВЯЗЬ', 'ВЕРСИЯ', 'ЗАЩИТА', 'OVERLAY', 'ФАЙЛ ПОДКАЧКИ', 'СЕЙЧАС') {
    $cell = New-Cell $header $column $title '#7C8085' $true
    $cell.FontSize = 12
    $column++
}
[void]$Rows.Children.Add($header)

# Строки создаются один раз, чтобы выбор не сбрасывался при обновлении списка
$script:RowMap = @{}
foreach ($name in $script:Names) {
    $border = New-Object System.Windows.Controls.Border
    $border.BorderBrush = New-Brush '#22FFFFFF'
    $border.BorderThickness = New-Object System.Windows.Thickness(0, 1, 0, 0)
    $border.Padding = New-Object System.Windows.Thickness(0, 9, 0, 9)
    $grid = New-RowGrid
    $check = New-Object System.Windows.Controls.CheckBox
    $check.VerticalAlignment = 'Center'
    $check.HorizontalAlignment = 'Center'
    $check.LayoutTransform = New-Object System.Windows.Media.ScaleTransform(1.3, 1.3)
    [void]$grid.Children.Add($check)
    $row = [pscustomobject]@{
        Name = $name; Check = $check; Online = $false; Version = ''; Busy = $false; State = ''; Pending = ''; BusyText = ''
        Link = (New-Cell $grid 2 '...' '#A2A6AB')
        Ver = (New-Cell $grid 3 '')
        Uwf = (New-Cell $grid 4 '')
        Over = (New-Cell $grid 5 '')
        Page = (New-Cell $grid 6 '')
        Now = (New-Cell $grid 7 '')
    }
    [void](New-Cell $grid 1 $name '#FFFFFF' $true)
    $border.Child = $grid
    [void]$Rows.Children.Add($border)
    $script:RowMap[$name] = $row
}

function Show-Result($Row, $Answer, [string]$Latest) {
    $data = $null
    if ($Answer) { try { $data = $Answer | ConvertFrom-Json } catch { } }
    if (-not $data -or -not $data.ok) {
        $Row.Online = $false
        $Row.Link.Text = 'нет связи'
        $Row.Link.Foreground = New-Brush '#E5301A'
        foreach ($cell in $Row.Ver, $Row.Uwf, $Row.Over, $Row.Page, $Row.Now) { $cell.Text = '' }
        $Row.Now.Text = 'выключен или служба старая'
        $Row.Now.Foreground = New-Brush '#7C8085'
        return
    }
    $Row.Online = $true
    $Row.Version = [string]$data.version
    $Row.Link.Text = 'на связи'
    $Row.Link.Foreground = New-Brush '#37C552'
    $Row.Ver.Text = $Row.Version
    $Row.Ver.Foreground = New-Brush $(if ($Latest -and $Row.Version -ne $Latest) { '#FFB020' } else { '#FFFFFF' })

    $now = $(if ($data.uwfNow) { 'включена' } else { 'выключена' })
    if ([bool]$data.uwfNow -ne [bool]$data.uwfNext) { $now += $(if ($data.uwfNext) { ' → вкл' } else { ' → выкл' }) }
    $Row.Uwf.Text = $now
    $Row.Uwf.Foreground = New-Brush $(if ($data.uwfNow) { '#37C552' } else { '#E5301A' })

    $total = [double]$data.usedMb + [double]$data.freeMb
    if ($data.uwfNow -and $total -gt 0) {
        $part = [double]$data.usedMb / $total
        $Row.Over.Text = '{0:0.0} / {1:0} ГБ' -f ($data.usedMb / 1024), ($total / 1024)
        $Row.Over.Foreground = New-Brush $(if ($part -ge 0.9) { '#E5301A' } elseif ($part -ge 0.75) { '#FFB020' } else { '#FFFFFF' })
    }
    else {
        $Row.Over.Text = '—'
        $Row.Over.Foreground = New-Brush '#7C8085'
    }

    $pages = @($data.pages | Where-Object { $_ } | ForEach-Object {
        $parts = ([string]$_).Split('|')
        [pscustomobject]@{ Name = $parts[0]; Mb = [double]$parts[1] }
    } | Where-Object { $_.Mb -gt 0 })
    if ($pages.Count -eq 0) {
        $Row.Page.Text = 'не работает'
        $Row.Page.Foreground = New-Brush '#E5301A'
    }
    else {
        $Row.Page.Text = (@($pages | ForEach-Object { '{0} {1:0.0} ГБ' -f $_.Name.Substring(0, 2), ($_.Mb / 1024) }) -join ', ')
        $Row.Page.Foreground = New-Brush $(if (@($pages | Where-Object { $_.Name -like 'Z:*' }).Count -gt 0) { '#37C552' } else { '#FFB020' })
    }

    $Row.Busy = [bool]$data.busy
    $Row.State = [string]$data.state
    $Row.Pending = [string]$data.pending
    $Row.BusyText = [string]$data.busy
    $text = switch ([string]$data.state) {
        'waiting-idle' {
            $verb = $(switch ([string]$data.pending) { 'lock' { 'заблокируется' } 'reboot' { 'перезагрузится' } default { 'обновится' } })
            $(if ($data.busy) { "$verb после сеанса ($($data.busy))" } else { "$verb через несколько секунд" })
        }
        'updating' { 'обновляется' }
        'rebooting' { 'перезагружается' }
        'await-decision' { 'ждёт ответа на экране' }
        default { $(if ($data.busy) { [string]$data.busy } else { 'свободен' }) }
    }
    $color = $(if ($data.state -and $data.state -ne 'idle') { '#FFB020' } elseif ($data.busy) { '#B4B8BC' } else { '#37C552' })
    if ($data.message -and $data.updateOk -eq $false) {
        $text = [string]$data.message
        $color = '#FF6A55'
    }
    $Row.Now.Text = $text
    $Row.Now.ToolTip = $text
    $Row.Now.Foreground = New-Brush $color
}

# ---------- Запросы ----------

$script:Running = $null
$script:Latest = ''

function Start-Query([string[]]$Names, [string]$Line, [bool]$WithVersion, [scriptblock]$Done, [hashtable]$Lines = @{}) {
    if ($script:Running) { return $false }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:QueryScript).AddArgument($Names).AddArgument($script:Port).AddArgument($Line).AddArgument($(if ($WithVersion) { $script:VersionUrl } else { '' })).AddArgument($Lines)
    $script:Running = @{ Ps = $ps; Async = $ps.BeginInvoke(); Done = $Done }
    foreach ($button in $BtnRefresh, $BtnUpdate, $BtnLock, $BtnReboot) { $button.IsEnabled = $false }
    return $true
}

function Update-Query {
    if (-not $script:Running -or -not $script:Running.Async.IsCompleted) { return }
    $job = $script:Running
    $script:Running = $null
    foreach ($button in $BtnRefresh, $BtnUpdate, $BtnLock, $BtnReboot) { $button.IsEnabled = $true }
    $output = $null
    try { $output = @($job.Ps.EndInvoke($job.Async))[0] } catch { $TxtStatus.Text = "Ошибка опроса: $_" }
    $job.Ps.Dispose()
    if ($output) { & $job.Done $output }
}

function Start-Refresh {
    [void](Start-Query $script:Names '{"action":"status"}' $true {
        param($Output)
        if ($Output.Latest) { $script:Latest = $Output.Latest }
        $TxtLatest.Text = $(if ($script:Latest) { "Последняя версия на GitHub: $($script:Latest)" } else { 'Версию на GitHub проверить не удалось' })
        foreach ($name in $script:Names) { Show-Result $script:RowMap[$name] $Output.Results[$name] $script:Latest }
        $online = @($script:RowMap.Values | Where-Object { $_.Online }).Count
        if (-not $script:StatusHold -or (Get-Date) -gt $script:StatusHold) { $TxtStatus.Text = "На связи: $online из $($script:Names.Count). Обновлено в $((Get-Date).ToString('HH:mm:ss'))" }
    })
}

# Тексты для трёх команд: обновление, блокировка, перезагрузка
$script:Commands = @{
    update = @{ Verb = 'Обновить лаунчер на'; Now = 'Обновить их сразу'; Note = 'Защита UWF будет выключена на время обновления и включена обратно, компьютеры перезагрузятся.'; Done = 'обновятся' }
    lock   = @{ Verb = 'Заблокировать'; Now = 'Заблокировать их сразу'; Note = 'Включится защита UWF, компьютеры перезагрузятся. Разблокировать можно только на месте, в панели администратора.'; Done = 'заблокируются' }
    reboot = @{ Verb = 'Перезагрузить'; Now = 'Перезагрузить их сразу'; Note = 'Компьютеры перезагрузятся.'; Done = 'перезагрузятся' }
}

function Start-RemoteCommand([string]$Action) {
    $text = $script:Commands[$Action]
    $selected = @($script:Names | Where-Object { $script:RowMap[$_].Check.IsChecked })
    if ($selected.Count -eq 0) {
        $TxtStatus.Text = 'Отметь кокпиты галочками.'
        return
    }
    if ($Action -ne 'update' -and $env:COMPUTERNAME -ne 'SIMRACE-14') {
        $TxtStatus.Text = 'Блокировать и перезагружать кокпиты можно только с SIMRACE-14.'
        return
    }
    $lines = @{}
    $line = "{`"action`":`"$Action`"}"
    $forceLine = "{`"action`":`"$Action`",`"force`":true}"
    # Кокпит уже ждёт конца сеанса с этой же командой: можно выполнить сразу
    $waiting = @($selected | Where-Object { $script:RowMap[$_].State -eq 'waiting-idle' -and $script:RowMap[$_].Pending -eq $Action })
    if ($waiting.Count -gt 0) {
        $reasons = @($waiting | ForEach-Object { $busyText = $script:RowMap[$_].BusyText; "$_" + $(if ($busyText) { " ($busyText)" } else { '' }) }) -join "`n"
        $question = "Эти кокпиты уже ждут конца сеанса:`n$reasons`n`n$($text.Now), не дожидаясь? Если там идёт игра, она закроется при перезагрузке."
        $answer = [System.Windows.MessageBox]::Show($Window, $question, 'Кокпиты SIMRACE', 'YesNoCancel', 'Warning')
        if ($answer -eq 'Cancel') { return }
        if ($answer -eq 'Yes') { foreach ($name in $waiting) { $lines[$name] = $forceLine } }
        $selected = @($selected | Where-Object { $waiting -notcontains $_ -or $lines.ContainsKey($_) })
        if ($selected.Count -eq 0) { return }
    }
    $fresh = @($selected | Where-Object { -not $lines.ContainsKey($_) })
    if ($fresh.Count -gt 0) {
        $busy = @($fresh | Where-Object { $script:RowMap[$_].Busy })
        $question = "$($text.Verb): $($fresh -join ', ')?`n`n$($text.Note)"
        if ($busy.Count -gt 0) { $question += "`n`nСейчас заняты: $($busy -join ', '). Они $($text.Done), когда закончится сеанс." }
        if ([System.Windows.MessageBox]::Show($Window, $question, 'Кокпиты SIMRACE', 'YesNo', 'Question') -ne 'Yes') { $selected = @($selected | Where-Object { $lines.ContainsKey($_) }) }
        if ($selected.Count -eq 0) { return }
    }
    $started = Start-Query $selected $line $false {
        param($Output)
        $silent = @()
        $refused = @()
        foreach ($name in ($Output.Results.Keys | Sort-Object)) {
            $answer = $Output.Results[$name]
            if (-not $answer) { $silent += $name; continue }
            try { $data = $answer | ConvertFrom-Json } catch { $data = $null }
            if (-not $data -or -not $data.ok) { $refused += "$name ($(if ($data) { $data.error } else { 'непонятный ответ' }))" }
        }
        $parts = @('Команда отправлена.')
        if ($silent.Count -gt 0) { $parts += "Не ответили: $($silent -join ', ')." }
        if ($refused.Count -gt 0) { $parts += "Отказ: $($refused -join '; ')." }
        if ($silent.Count + $refused.Count -eq 0) { $parts += 'Ход выполнения видно в столбце «Сейчас».' }
        $TxtStatus.Text = $parts -join ' '
        $script:StatusHold = (Get-Date).AddSeconds(30)
        foreach ($name in $Output.Results.Keys) { $script:RowMap[$name].Check.IsChecked = $false }
        $script:NextRefresh = (Get-Date).AddSeconds(3)
    } $lines
    if (-not $started) { $TxtStatus.Text = 'Дождись окончания опроса и нажми ещё раз.' }
}

$BtnRefresh.Add_Click({ Start-Refresh })
$BtnUpdate.Add_Click({ Start-RemoteCommand 'update' })
$BtnLock.Add_Click({ Start-RemoteCommand 'lock' })
$BtnReboot.Add_Click({ Start-RemoteCommand 'reboot' })
$BtnSelectAll.Add_Click({ foreach ($row in $script:RowMap.Values) { if ($row.Online) { $row.Check.IsChecked = $true } } })
$BtnSelectNone.Add_Click({ foreach ($row in $script:RowMap.Values) { $row.Check.IsChecked = $false } })
$BtnSelectOld.Add_Click({
    foreach ($row in $script:RowMap.Values) { $row.Check.IsChecked = [bool]($row.Online -and $script:Latest -and $row.Version -ne $script:Latest) }
})

$script:NextRefresh = [datetime]::MinValue
$script:StatusHold = $null
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$timer.Add_Tick({
    try {
        Update-Query
        if (-not $script:Running -and (Get-Date) -ge $script:NextRefresh) {
            $script:NextRefresh = (Get-Date).AddSeconds(10)
            Start-Refresh
        }
    }
    catch { $TxtStatus.Text = "Ошибка: $_" }
})
$timer.Start()
[void]$Window.ShowDialog()
$timer.Stop()
