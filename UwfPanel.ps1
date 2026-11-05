#Requires -Version 5.1
<#
  Окно обслуживания UWF для SIMRACE. Открывается из лаунчера кнопкой с шестерёнкой, Windows запрашивает пароль администратора.
  При включении защиты: системный диск защищается, диск с файлом подкачки исключается, файл подкачки прописывается заново.
#>

# ===== Настройки (при необходимости меняются только здесь) =====
$SystemDrive = $env:SystemDrive   # системный диск, обычно C:
$PageDrive   = 'Z:'               # диск под файл подкачки, UWF его НЕ защищает
$PageFileMB  = 15000              # фиксированный размер файла подкачки, МБ
# ===============================================================

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Запуск без лаунчера: перезапускаемся с правами администратора
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
    }
    catch { [void][System.Windows.MessageBox]::Show('Нужны права администратора. Запуск отменён.', 'Защита UWF') }
    exit
}

$Ns    = 'root\standardcimv2\embedded'
$MmKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
$Uwf   = Join-Path $env:SystemRoot 'System32\uwfmgr.exe'

try { Get-CimInstance -Namespace $Ns -ClassName UWF_Filter -ErrorAction Stop | Out-Null }
catch {
    [void][System.Windows.MessageBox]::Show("Компонент UWF не установлен на этом компьютере ($env:COMPUTERNAME).", 'Защита UWF')
    exit
}

# ---------- Служебные функции ----------

function Get-UwfFilter { Get-CimInstance -Namespace $Ns -ClassName UWF_Filter -ErrorAction Stop }

# Будет ли том защищён после перезагрузки
function Test-NextProtected([string]$Letter) {
    $volume = Get-CimInstance -Namespace $Ns -ClassName UWF_Volume -ErrorAction Stop |
        Where-Object { -not $_.CurrentSession -and $_.DriveLetter -eq $Letter -and $_.Protected }
    return [bool]$volume
}

function Add-LogLine([string]$Text) {
    $TxtLog.AppendText(('{0:HH:mm:ss}  {1}' -f (Get-Date), $Text) + "`r`n")
    $TxtLog.ScrollToEnd()
}

# Вызов uwfmgr с записью в журнал. Результат каждой операции затем проверяется по настройкам UWF.
function Invoke-Uwf {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & $Uwf @args 2>&1 | Out-String }
    finally { $ErrorActionPreference = $previous }
    Add-LogLine "uwfmgr $($args -join ' ')"
    if ($output.Trim()) { Add-LogLine $output.Trim() }
}

# Файл подкачки фиксированного размера на диске $PageDrive
function Set-PageFile {
    Set-ItemProperty -Path $MmKey -Name PagingFiles -Type MultiString -Value @("$PageDrive\pagefile.sys $PageFileMB $PageFileMB") -ErrorAction Stop
}

function Get-PageFileInfo {
    Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$PageDrive*" } | Select-Object -First 1
}

# Настройки оверлея: текущая сессия ($true) или следующая ($false)
function Get-OverlayConfig([bool]$Current) {
    Get-CimInstance -Namespace $Ns -ClassName UWF_OverlayConfig -ErrorAction Stop |
        Where-Object { [bool]$_.CurrentSession -eq $Current } | Select-Object -First 1
}

function Get-OverlayTypeName($Config) {
    if ($null -eq $Config) { return '?' }
    if ($Config.Type -eq 0) { return 'ОЗУ' }
    return 'диск'
}

# Допустимый максимум, ГБ: для ОЗУ половина памяти, для диска свободное место на системном диске минус 2 ГБ
function Get-OverlayMaxGB($Config) {
    if ($Config -and $Config.Type -eq 0) {
        $ramGB = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB
        return [int][math]::Max(1, [math]::Floor($ramGB / 2))
    }
    $volume = Get-Volume -DriveLetter $SystemDrive.TrimEnd(':') -ErrorAction SilentlyContinue
    if ($volume) { return [int][math]::Max(1, [math]::Floor($volume.SizeRemaining / 1GB) - 2) }
    return 4
}

function Show-Question([string]$Text) {
    return ([System.Windows.MessageBox]::Show($Window, $Text, 'Защита UWF', 'YesNo', 'Question') -eq 'Yes')
}

function Show-Message([string]$Text, [string]$Icon = 'Information') {
    [void][System.Windows.MessageBox]::Show($Window, $Text, 'Защита UWF', 'OK', $Icon)
}

function Request-Reboot([string]$What) {
    if (Show-Question "$What`r`n`r`nИзменения вступят в силу после перезагрузки.`r`nПерезагрузить компьютер сейчас?") {
        Restart-Computer -Force
    }
}

function Update-Status {
    try {
        $filter = Get-UwfFilter
        $TxtState.Text = if ($filter.CurrentEnabled) { 'Защита включена' } else { 'Защита выключена' }
        $TxtStateNext.Text = 'После перезагрузки: ' + $(if ($filter.NextEnabled) { 'включена' } else { 'выключена' })

        $page = Get-PageFileInfo
        $TxtPage.Text = if ($page) { "Файл подкачки на ${PageDrive}: работает, $($page.AllocatedBaseSize) МБ" }
                        else { "Файл подкачки на ${PageDrive}: не найден" }

        $current = Get-OverlayConfig $true
        $next = Get-OverlayConfig $false
        $TxtOverlay.Text = "Сейчас: $(Get-OverlayTypeName $current), $([math]::Round($current.MaximumSize / 1024, 1)) ГБ. " +
                           "После перезагрузки: $(Get-OverlayTypeName $next), $([math]::Round($next.MaximumSize / 1024, 1)) ГБ."
        $script:MaxGB = Get-OverlayMaxGB $next
        $TxtSizeLabel.Text = "Размер, ГБ (до $script:MaxGB)"
        $TxtSize.Text = [string][math]::Min($script:MaxGB, [math]::Max(1, [math]::Round($next.MaximumSize / 1024)))
        $RadioRam.IsChecked = ($next.Type -eq 0)
        $RadioDisk.IsChecked = ($next.Type -ne 0)

        $overlay = Get-CimInstance -Namespace $Ns -ClassName UWF_Overlay -ErrorAction SilentlyContinue
        if ($filter.CurrentEnabled -and $overlay) {
            $total = [double]$overlay.OverlayConsumption + [double]$overlay.AvailableSpace
            $TxtConsumption.Text = "Занято $([math]::Round($overlay.OverlayConsumption / 1024, 1)) ГБ, свободно $([math]::Round($overlay.AvailableSpace / 1024, 1)) ГБ"
            $BarConsumption.Value = if ($total -gt 0) { 100 * $overlay.OverlayConsumption / $total } else { 0 }
        }
        else {
            $TxtConsumption.Text = 'Оверлей сейчас не используется'
            $BarConsumption.Value = 0
        }

        $pending = ($filter.CurrentEnabled -ne $filter.NextEnabled) -or ($current.MaximumSize -ne $next.MaximumSize) -or ($current.Type -ne $next.Type)
        $TxtHint.Text = if ($pending) { 'Требуется перезагрузка, чтобы изменения вступили в силу.' } else { '' }
    }
    catch {
        $TxtState.Text = 'Не удалось прочитать состояние UWF'
        Add-LogLine "Ошибка: $($_.Exception.Message)"
    }
}

function Enable-Protection {
    $filter = Get-UwfFilter
    if ($filter.CurrentEnabled -and $filter.NextEnabled) {
        Show-Message 'Защита уже включена.'
        return
    }
    if (-not (Test-Path "$PageDrive\")) {
        if (-not (Show-Question "Диск $PageDrive не найден. Без него не будет файла подкачки, и некоторые игры не запустятся.`r`n`r`nВсё равно включить защиту?")) { return }
    }
    elseif (-not (Show-Question 'Включить защиту системы?')) { return }

    try {
        # 1. Диск подкачки без защиты
        if ((Test-Path "$PageDrive\") -and (Test-NextProtected $PageDrive)) { Invoke-Uwf volume unprotect $PageDrive }
        # 2. Системный диск под защиту
        if (-not (Test-NextProtected $SystemDrive)) { Invoke-Uwf volume protect $SystemDrive }
        # 3. Включить фильтр со следующей загрузки
        Invoke-Uwf filter enable
        # 4. Заново прописать подкачку: включение UWF может её отключить.
        #    Пишем только пока защита в текущей сессии выключена, иначе запись уйдёт в оверлей.
        if (-not $filter.CurrentEnabled -and (Test-Path "$PageDrive\")) { Set-PageFile }

        $ok = (Get-UwfFilter).NextEnabled -and (Test-NextProtected $SystemDrive)
        if (Test-Path "$PageDrive\") { $ok = $ok -and -not (Test-NextProtected $PageDrive) }
    }
    catch {
        $ok = $false
        Add-LogLine "Ошибка: $($_.Exception.Message)"
    }
    Update-Status
    if ($ok) { Request-Reboot 'Защита будет включена.' }
    else { Show-Message 'Не удалось включить защиту. Подробности в журнале.' 'Error' }
}

function Disable-Protection {
    $filter = Get-UwfFilter
    if (-not $filter.CurrentEnabled -and -not $filter.NextEnabled) {
        Show-Message 'Защита уже выключена.'
        return
    }
    if (-not (Show-Question "Выключить защиту?`r`n`r`nПосле перезагрузки ВСЕ изменения на компьютере будут сохраняться. Не забудь включить защиту после обслуживания.")) { return }
    try {
        Invoke-Uwf filter disable
        $ok = -not (Get-UwfFilter).NextEnabled
    }
    catch {
        $ok = $false
        Add-LogLine "Ошибка: $($_.Exception.Message)"
    }
    Update-Status
    if ($ok) { Request-Reboot 'Защита будет выключена.' }
    else { Show-Message 'Не удалось выключить защиту. Подробности в журнале.' 'Error' }
}

function Set-OverlaySize {
    $gb = 0
    if (-not [int]::TryParse($TxtSize.Text.Trim(), [ref]$gb) -or $gb -lt 1 -or $gb -gt $script:MaxGB) {
        Show-Message "Укажи размер целым числом от 1 до $script:MaxGB ГБ." 'Warning'
        return
    }
    $mb = $gb * 1024
    $next = Get-OverlayConfig $false
    if ($next.MaximumSize -eq $mb) {
        Show-Message "Размер оверлея уже $gb ГБ."
        return
    }
    if (-not (Show-Question "Установить размер оверлея $gb ГБ ($(Get-OverlayTypeName $next))?")) { return }
    try {
        Invoke-Uwf overlay set-size $mb
        # Пороги: предупреждение при 2/3 заполнения, критический при 90%
        Invoke-Uwf overlay set-warningthreshold ([math]::Round($mb * 2 / 3))
        Invoke-Uwf overlay set-criticalthreshold ([math]::Round($mb * 0.9))
        $ok = ((Get-OverlayConfig $false).MaximumSize -eq $mb)
    }
    catch {
        $ok = $false
        Add-LogLine "Ошибка: $($_.Exception.Message)"
    }
    Update-Status
    if ($ok) { Request-Reboot "Размер оверлея будет $gb ГБ." }
    else { Show-Message 'Не удалось изменить размер. Подробности в журнале.' 'Error' }
}

function Set-OverlayType {
    $kind = if ($RadioRam.IsChecked) { 'RAM' } else { 'DISK' }
    $wanted = if ($RadioRam.IsChecked) { 0 } else { 1 }
    $next = Get-OverlayConfig $false
    if ($next.Type -eq $wanted) {
        Show-Message 'Этот тип уже выбран.'
        return
    }
    if (-not (Show-Question "Сменить тип оверлея на «$(if ($wanted -eq 0) { 'ОЗУ' } else { 'диск' })»?`r`n`r`nЕсли защита сейчас включена, Windows может отказать: тогда сначала выключи её и перезагрузи компьютер.")) { return }
    try {
        Invoke-Uwf overlay set-type $kind
        $ok = ((Get-OverlayConfig $false).Type -eq $wanted)
    }
    catch {
        $ok = $false
        Add-LogLine "Ошибка: $($_.Exception.Message)"
    }
    Update-Status
    if ($ok) { Request-Reboot 'Тип оверлея будет изменён.' }
    else { Show-Message 'Тип не изменился. Подробности в журнале.' 'Error' }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Защита UWF" Width="760" Height="790" MinWidth="680" MinHeight="680" WindowStartupLocation="CenterScreen" Topmost="True"
        Background="#121315" Foreground="White" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="15">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#E2450F"/>
    <SolidColorBrush x:Key="Muted" Color="#A2A6AB"/>
    <SolidColorBrush x:Key="Graphite" Color="#1F2124"/>
    <SolidColorBrush x:Key="Line" Color="#34373B"/>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="{StaticResource Graphite}" BorderBrush="{StaticResource Line}" BorderThickness="1" Padding="16,9">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Graphite}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="CaretBrush" Value="White"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="8,6"/>
    </Style>
    <Style TargetType="RadioButton"><Setter Property="Foreground" Value="White"/><Setter Property="Margin" Value="0,0,20,0"/></Style>
    <Style x:Key="Head" TargetType="TextBlock"><Setter Property="FontSize" Value="20"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,20,0,8"/></Style>
    <Style x:Key="Note" TargetType="TextBlock"><Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="TextWrapping" Value="Wrap"/></Style>
  </Window.Resources>
  <Grid Margin="26">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel Grid.Row="0">
      <TextBlock x:Name="TxtState" FontSize="30" FontWeight="SemiBold"/>
      <TextBlock x:Name="TxtStateNext" Style="{StaticResource Note}" Margin="0,2,0,2"/>
      <TextBlock x:Name="TxtPage" Style="{StaticResource Note}" Margin="0,0,0,2"/>
      <TextBlock x:Name="TxtHint" Foreground="{StaticResource Accent}" TextWrapping="Wrap" Margin="0,0,0,12"/>
      <StackPanel Orientation="Horizontal">
        <Button x:Name="BtnEnable" Content="Включить защиту" Margin="0,0,10,0"/>
        <Button x:Name="BtnDisable" Content="Выключить защиту"/>
      </StackPanel>
      <TextBlock Style="{StaticResource Note}" Margin="0,10,0,0" Text="Выключать защиту только для обслуживания: установка и обновление игр, драйверов, Windows. После обслуживания обязательно включить."/>

      <TextBlock Text="Оверлей" Style="{StaticResource Head}"/>
      <TextBlock x:Name="TxtOverlay" TextWrapping="Wrap" Margin="0,0,0,8"/>
      <TextBlock x:Name="TxtConsumption" Style="{StaticResource Note}" Margin="0,0,0,6"/>
      <ProgressBar x:Name="BarConsumption" Height="6" Minimum="0" Maximum="100" Background="#34373B" Foreground="{StaticResource Accent}" BorderThickness="0" Margin="0,0,0,12"/>
      <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
        <TextBlock x:Name="TxtSizeLabel" VerticalAlignment="Center" Margin="0,0,12,0"/>
        <TextBox x:Name="TxtSize" Width="90" Margin="0,0,10,0"/>
        <Button x:Name="BtnSize" Content="Изменить размер"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
        <TextBlock Text="Тип" VerticalAlignment="Center" Margin="0,0,12,0"/>
        <RadioButton x:Name="RadioRam" Content="ОЗУ" GroupName="Kind" VerticalAlignment="Center"/>
        <RadioButton x:Name="RadioDisk" Content="Диск" GroupName="Kind" VerticalAlignment="Center"/>
        <Button x:Name="BtnType" Content="Изменить тип"/>
      </StackPanel>
      <TextBlock Text="Журнал" Style="{StaticResource Head}"/>
    </StackPanel>
    <TextBox x:Name="TxtLog" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="13"/>
    <DockPanel Grid.Row="2" Margin="0,16,0,0" LastChildFill="False">
      <Button x:Name="BtnClose" Content="Закрыть" DockPanel.Dock="Right" Margin="10,0,0,0"/>
      <Button x:Name="BtnRestart" Content="Перезагрузить компьютер" DockPanel.Dock="Right" Margin="10,0,0,0"/>
      <Button x:Name="BtnRefresh" Content="Обновить" DockPanel.Dock="Left"/>
      <Button x:Name="BtnLog" Content="Журнал лаунчера" DockPanel.Dock="Left" Margin="10,0,0,0"/>
    </DockPanel>
  </Grid>
</Window>
'@

try {
    $script:MaxGB = 4
    $Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $Window.Title = "Защита UWF: $env:COMPUTERNAME"
    foreach ($name in 'TxtState', 'TxtStateNext', 'TxtPage', 'TxtHint', 'BtnEnable', 'BtnDisable', 'TxtOverlay', 'TxtConsumption', 'BarConsumption',
                      'TxtSizeLabel', 'TxtSize', 'BtnSize', 'RadioRam', 'RadioDisk', 'BtnType', 'TxtLog', 'BtnClose', 'BtnRestart', 'BtnRefresh', 'BtnLog') {
        Set-Variable -Name $name -Value $Window.FindName($name) -Scope Script
    }
    # Ошибка кнопки попадает в журнал и не закрывает окно
    $BtnEnable.Add_Click({ try { Enable-Protection } catch { Add-LogLine "Ошибка: $_" } })
    $BtnDisable.Add_Click({ try { Disable-Protection } catch { Add-LogLine "Ошибка: $_" } })
    $BtnSize.Add_Click({ try { Set-OverlaySize } catch { Add-LogLine "Ошибка: $_" } })
    $BtnType.Add_Click({ try { Set-OverlayType } catch { Add-LogLine "Ошибка: $_" } })
    $BtnRefresh.Add_Click({ Update-Status })
    $BtnLog.Add_Click({
        $log = Join-Path 'Z:\SIMRACE\Logs' "$env:COMPUTERNAME-launcher.log"
        if (Test-Path -LiteralPath $log) { Start-Process -FilePath notepad.exe -ArgumentList "`"$log`"" }
        else { Add-LogLine "Журнал не найден: $log" }
    })
    $BtnClose.Add_Click({ $Window.Close() })
    $BtnRestart.Add_Click({
        try { if (Show-Question 'Перезагрузить компьютер сейчас?') { Restart-Computer -Force } }
        catch { Add-LogLine "Ошибка: $_" }
    })

    Update-Status
    [void]$Window.ShowDialog()
}
catch {
    [void][System.Windows.MessageBox]::Show("Окно обслуживания не открылось.`n$_", 'Защита UWF')
    exit 1
}
