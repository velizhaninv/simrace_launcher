#Requires -Version 5.1
<#
  Окно настроек лаунчера: игры, ярлыки, обложки и аккаунты Steam. Запускать через Settings-Launcher.cmd.
  Пишет apps.json, папки shortcuts и images рядом с собой. Раздел utilities и записи отдельных компьютеров не меняет.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:Root       = $PSScriptRoot
$script:ConfigPath = Join-Path $script:Root 'apps.json'
$script:Index      = -1
$script:Loading    = $false

function Set-Prop($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Remove-Prop($Object, [string]$Name) {
    if ($Object.PSObject.Properties[$Name]) { $Object.PSObject.Properties.Remove($Name) }
}

function Get-CoverFile([string]$Id) {
    foreach ($extension in 'jpg', 'jpeg', 'png') {
        $file = Join-Path $script:Root "images\$Id.$extension"
        if (Test-Path -LiteralPath $file) { return $file }
    }
    return $null
}

function Get-AccountSection {
    if (-not $script:Config.PSObject.Properties['steamAccounts'] -or -not $script:Config.steamAccounts) {
        Set-Prop $script:Config 'steamAccounts' ([pscustomobject]@{})
    }
    if (-not $script:Config.steamAccounts.PSObject.Properties['default']) {
        Set-Prop $script:Config.steamAccounts 'default' ([pscustomobject]@{})
    }
    return $script:Config.steamAccounts.default
}

function Get-TargetText($App) {
    $masks = @($App.shortcut | Where-Object { $_ })
    if ($masks.Count -gt 0) {
        $own = Get-ChildItem -LiteralPath (Join-Path $script:Root 'shortcuts') -Filter "$($App.id).*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($own) { return "Ярлык из настроек: $($own.Name)" }
        return "Ярлык на рабочем столе: $($masks -join ', ')"
    }
    $paths = @($App.paths | Where-Object { $_ })
    if ($paths.Count -gt 0) { return $paths -join ', ' }
    if ($App.steamAppId) { return 'Напрямую через Steam' }
    return 'Не выбрано'
}

# Текст поля дополнительной кнопки под плиткой
function Get-ExtraTargetText($App) {
    if (-not $App.extra) { return 'Кнопки нет' }
    return Get-TargetText $App.extra
}

function Show-Cover([string]$Id) {
    $file = Get-CoverFile $Id
    $ImgCover.Source = $null
    if (-not $file) {
        $TxtCover.Text = 'Своей обложки нет: будет кэш Steam или название'
        return
    }
    $TxtCover.Text = [IO.Path]::GetFileName($file)
    try {
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.UriSource = New-Object System.Uri($file)
        $bitmap.DecodePixelWidth = 220
        $bitmap.CacheOption = 'OnLoad'      # файл не блокируется, его можно заменить
        $bitmap.EndInit()
        $bitmap.Freeze()
        $ImgCover.Source = $bitmap
    }
    catch { $TxtCover.Text = 'Картинка не читается, выбери другую' }
}

# Переносит значения из полей формы в выбранную игру
function Save-Form {
    if ($script:Index -lt 0 -or $script:Index -ge $script:Apps.Count) { return }
    $app = $script:Apps[$script:Index]
    Set-Prop $app 'name' $TxtName.Text.Trim()
    Set-Prop $app 'category' $TxtCategory.Text.Trim().ToLowerInvariant()

    $steamId = $TxtSteamId.Text.Trim()
    if ($steamId) { Set-Prop $app 'steamAppId' $steamId } else { Remove-Prop $app 'steamAppId' }

    $watch = @($TxtWatch.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($watch.Count -gt 0) { Set-Prop $app 'watch' $watch } else { Remove-Prop $app 'watch' }

    if ($app.extra) {
        $extraName = $TxtExtraName.Text.Trim()
        Set-Prop $app.extra 'name' $(if ($extraName) { $extraName } else { 'Запустить сервер' })
    }

    $section = Get-AccountSection
    $login = $TxtAccount.Text.Trim()
    if ($login -or $section.PSObject.Properties[$app.id]) { Set-Prop $section $app.id $login }
}

function Show-Form {
    $has = $script:Index -ge 0 -and $script:Index -lt $script:Apps.Count
    $FormPanel.IsEnabled = $has
    if (-not $has) {
        $TxtExtraName.Text = ''; $TxtExtraTarget.Text = ''; $TxtCategory.Text = ''
        $TxtName.Text = ''; $TxtTarget.Text = ''; $TxtSteamId.Text = ''; $TxtAccount.Text = ''; $TxtWatch.Text = ''; $TxtCover.Text = ''
        $ImgCover.Source = $null
        return
    }
    $app = $script:Apps[$script:Index]
    $TxtName.Text = [string]$app.name
    $TxtCategory.Text = [string]$app.category
    $TxtTarget.Text = Get-TargetText $app
    $TxtSteamId.Text = [string]$app.steamAppId
    $TxtWatch.Text = (@($app.watch | Where-Object { $_ }) -join ', ')
    $TxtAccount.Text = [string](Get-AccountSection).($app.id)
    $TxtExtraName.Text = $(if ($app.extra) { [string]$app.extra.name } else { 'Запустить сервер' })
    $TxtExtraTarget.Text = Get-ExtraTargetText $app
    Show-Cover $app.id
}

function Update-List([int]$Select) {
    $script:Loading = $true
    $AppList.Items.Clear()
    foreach ($app in $script:Apps) {
        $label = [string]$app.name
        if ($app.category) { $label = "$(([string]$app.category).ToUpperInvariant()): $label" }
        [void]$AppList.Items.Add($label)
    }
    $script:Index = [Math]::Min($Select, $script:Apps.Count - 1)
    $AppList.SelectedIndex = $script:Index
    $script:Loading = $false
    Show-Form
}

function Move-App([int]$Offset) {
    Save-Form
    $new = $script:Index + $Offset
    if ($script:Index -lt 0 -or $new -lt 0 -or $new -ge $script:Apps.Count) { return }
    $app = $script:Apps[$script:Index]
    $script:Apps.RemoveAt($script:Index)
    $script:Apps.Insert($new, $app)
    Update-List $new
}

# Диалог выбора ярлыка или программы. Записывает результат в запись игры или её дополнительной кнопки.
function Set-TargetFromDialog($Item) {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = 'Выбери ярлык или программу'
    $dialog.Filter = 'Ярлыки и программы (*.lnk;*.url;*.exe)|*.lnk;*.url;*.exe'
    $dialog.DereferenceLinks = $false     # нужен сам ярлык, а не файл, на который он указывает
    $dialog.InitialDirectory = Join-Path $env:PUBLIC 'Desktop'
    if (-not $dialog.ShowDialog()) { return $false }

    $extension = [IO.Path]::GetExtension($dialog.FileName).ToLowerInvariant()
    $folder = Join-Path $script:Root 'shortcuts'
    # Сначала читаем выбранный файл: он может оказаться прежней копией из этой папки
    $bytes = if ($extension -ne '.exe') { [IO.File]::ReadAllBytes($dialog.FileName) } else { $null }
    Get-ChildItem -LiteralPath $folder -Filter "$($Item.id).*" -ErrorAction SilentlyContinue | Remove-Item -Force

    if ($extension -eq '.exe') {
        Remove-Prop $Item 'shortcut'
        Set-Prop $Item 'paths' @($dialog.FileName)
    }
    else {
        # Копия нужна, потому что гость может не видеть рабочий стол другого пользователя
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $folder "$($Item.id)$extension"), $bytes)
        Set-Prop $Item 'shortcut' @([string]$Item.id)
        Remove-Prop $Item 'paths'
    }
    return $true
}

function Select-Target {
    $app = $script:Apps[$script:Index]
    if (Set-TargetFromDialog $app) { $TxtTarget.Text = Get-TargetText $app }
}

function Select-ExtraTarget {
    $app = $script:Apps[$script:Index]
    $extraName = $TxtExtraName.Text.Trim()
    $extra = $app.extra
    if (-not $extra) { $extra = [pscustomobject]@{ id = "$($app.id)-extra"; name = $(if ($extraName) { $extraName } else { 'Запустить сервер' }) } }
    if (Set-TargetFromDialog $extra) {
        Set-Prop $app 'extra' $extra
        $TxtExtraTarget.Text = Get-ExtraTargetText $app
    }
}

function Remove-ExtraButton {
    $app = $script:Apps[$script:Index]
    if ($app.extra) {
        Get-ChildItem -LiteralPath (Join-Path $script:Root 'shortcuts') -Filter "$($app.extra.id).*" -ErrorAction SilentlyContinue | Remove-Item -Force
        Remove-Prop $app 'extra'
    }
    $TxtExtraTarget.Text = Get-ExtraTargetText $app
}

# Перетаскивание игры в списке: порядок в списке равен порядку плиток в категории
function Get-ListIndex($Source) {
    $container = [System.Windows.Controls.ItemsControl]::ContainerFromElement($AppList, $Source)
    if (-not $container) { return -1 }
    return $AppList.ItemContainerGenerator.IndexFromContainer($container)
}

function Move-DraggedApp([int]$From, [int]$To) {
    Save-Form
    if ($From -lt 0 -or $From -ge $script:Apps.Count) { return }
    if ($To -lt 0 -or $To -ge $script:Apps.Count) { $To = $script:Apps.Count - 1 }
    if ($From -eq $To) { return }
    $app = $script:Apps[$From]
    $script:Apps.RemoveAt($From)
    $script:Apps.Insert($To, $app)
    Update-List $To
    $TxtStatus.Text = 'Порядок изменён. Нажми «Сохранить».'
}

function Select-Cover {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = 'Выбери обложку, лучше с пропорциями 2:3'
    $dialog.Filter = 'Картинки (*.jpg;*.jpeg;*.png)|*.jpg;*.jpeg;*.png'
    if (-not $dialog.ShowDialog()) { return }

    $app = $script:Apps[$script:Index]
    $folder = Join-Path $script:Root 'images'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $extension = [IO.Path]::GetExtension($dialog.FileName).ToLowerInvariant()
    $destination = Join-Path $folder "$($app.id)$extension"
    # Сначала читаем выбранный файл: он может лежать в этой же папке
    $bytes = [IO.File]::ReadAllBytes($dialog.FileName)
    Get-ChildItem -LiteralPath $folder -Filter "$($app.id).*" -ErrorAction SilentlyContinue | Remove-Item -Force
    [IO.File]::WriteAllBytes($destination, $bytes)
    Show-Cover $app.id
}

function Save-Config {
    Save-Form
    if (@($script:Apps | Where-Object { -not $_.name }).Count -gt 0) {
        $TxtStatus.Text = 'У каждой игры должно быть название.'
        return
    }
    if (@($script:Apps | Where-Object { $_.steamAppId -and $_.steamAppId -notmatch '^\d+$' }).Count -gt 0) {
        $TxtStatus.Text = 'Steam ID должен состоять только из цифр.'
        return
    }
    $empty = @($script:Apps | Where-Object { (Get-TargetText $_) -eq 'Не выбрано' } | ForEach-Object { $_.name })
    $script:Config.apps = @($script:Apps.ToArray())
    Copy-Item -LiteralPath $script:ConfigPath -Destination "$($script:ConfigPath).bak" -Force
    [IO.File]::WriteAllText($script:ConfigPath, ($script:Config | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    Update-List $script:Index
    $TxtStatus.Text = if ($empty.Count -gt 0) { "Сохранено. Плитки не появятся, не выбран запуск: $($empty -join ', ')" }
                      else { 'Сохранено. Изменения появятся при следующем запуске лаунчера.' }
    # Лаунчер следит за этим файлом и перезапускается, когда видит свежую отметку. Во время игры он дождётся её окончания.
    if ([System.Windows.MessageBox]::Show($Window, 'Перезапустить лаунчер сейчас, чтобы изменения появились? Если идёт игра, лаунчер перезапустится после неё.', 'Настройки лаунчера', 'YesNo', 'Question') -eq 'Yes') {
        try {
            Set-Content -LiteralPath (Join-Path (Split-Path -Parent $script:ConfigPath) 'restart-request.txt') -Value (Get-Date -Format o) -Encoding ASCII
            $TxtStatus.Text = 'Сохранено. Лаунчер перезапускается.'
        }
        catch { $TxtStatus.Text = "Сохранено, но перезапуск не запрошен: $_" }
    }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Настройки лаунчера SIMRACE" Width="1040" Height="720" MinWidth="900" MinHeight="620" WindowStartupLocation="CenterScreen"
        Background="#121315" Foreground="White" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="15">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#F7931E"/>
    <SolidColorBrush x:Key="Muted" Color="#A2A6AB"/>
    <SolidColorBrush x:Key="Graphite" Color="#1F2124"/>
    <SolidColorBrush x:Key="Line" Color="#34373B"/>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Graphite}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="CaretBrush" Value="White"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="8,6"/>
    </Style>
    <Style x:Key="Caption" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Margin" Value="0,14,0,5"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="{StaticResource Graphite}" BorderBrush="{StaticResource Line}" BorderThickness="1" Padding="14,7">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{StaticResource Muted}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="24">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock x:Name="TxtUwf" Grid.Row="0" Visibility="Collapsed" Foreground="{StaticResource Accent}" TextWrapping="Wrap" Margin="0,0,0,16"
               Text="UWF включён: после перезагрузки все изменения пропадут. Чтобы сохранить их, выключи UWF, перезагрузи компьютер и повтори настройку."/>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="300"/>
        <ColumnDefinition Width="28"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <DockPanel Grid.Column="0">
        <UniformGrid DockPanel.Dock="Bottom" Columns="2" Margin="0,10,0,0">
          <Button x:Name="BtnAdd" Content="Добавить" Margin="0,0,5,5"/>
          <Button x:Name="BtnRemove" Content="Удалить" Margin="5,0,0,5"/>
          <Button x:Name="BtnUp" Content="Выше" Margin="0,5,5,0"/>
          <Button x:Name="BtnDown" Content="Ниже" Margin="5,5,0,0"/>
        </UniformGrid>
        <TextBlock DockPanel.Dock="Top" Text="Порядок меняется перетаскиванием" Foreground="#A2A6AB" Margin="0,0,0,6"/>
        <ListBox x:Name="AppList" Background="#1F2124" Foreground="White" BorderBrush="#34373B" AllowDrop="True"/>
      </DockPanel>

      <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="FormPanel">
          <TextBlock Text="Название на экране" Style="{StaticResource Caption}" Margin="0,0,0,5"/>
          <TextBox x:Name="TxtName"/>

          <TextBlock x:Name="TxtCategoryCaption" Text="Категория" Style="{StaticResource Caption}"/>
          <TextBox x:Name="TxtCategory"/>

          <TextBlock Text="Что запускать" Style="{StaticResource Caption}"/>
          <DockPanel>
            <Button x:Name="BtnTarget" Content="Выбрать ярлык" DockPanel.Dock="Right" Margin="10,0,0,0"/>
            <TextBox x:Name="TxtTarget" IsReadOnly="True"/>
          </DockPanel>

          <TextBlock Text="Обложка" Style="{StaticResource Caption}"/>
          <DockPanel>
            <Border DockPanel.Dock="Left" Width="110" Height="165" Background="#1F2124" Margin="0,0,14,0">
              <Image x:Name="ImgCover" Stretch="UniformToFill"/>
            </Border>
            <StackPanel>
              <TextBlock x:Name="TxtCover" TextWrapping="Wrap" Margin="0,0,0,10"/>
              <Button x:Name="BtnCover" Content="Выбрать обложку" HorizontalAlignment="Left"/>
            </StackPanel>
          </DockPanel>

 <TextBlock Text="Правая кнопка мыши на плитке, необязательно. Например «Запустить сервер»" Style="{StaticResource Caption}"/>
          <TextBox x:Name="TxtExtraName" Margin="0,0,0,8"/>
          <DockPanel>
            <Button x:Name="BtnExtraClear" Content="Убрать" DockPanel.Dock="Right" Margin="10,0,0,0"/>
            <Button x:Name="BtnExtraTarget" Content="Выбрать программу" DockPanel.Dock="Right" Margin="10,0,0,0"/>
            <TextBox x:Name="TxtExtraTarget" IsReadOnly="True"/>
          </DockPanel>

          <TextBlock Text="Логин Steam для этой игры, необязательно" Style="{StaticResource Caption}"/>
          <TextBox x:Name="TxtAccount"/>

          <TextBlock Text="Steam ID игры, необязательно. Нужен для запуска без ярлыка и обложки из Steam" Style="{StaticResource Caption}"/>
          <TextBox x:Name="TxtSteamId"/>

          <TextBlock Text="Процессы игры через запятую, без .exe. Нужны, если лаунчер возвращается раньше времени" Style="{StaticResource Caption}"/>
          <TextBox x:Name="TxtWatch"/>
        </StackPanel>
      </ScrollViewer>
    </Grid>

    <DockPanel Grid.Row="2" Margin="0,18,0,0">
      <Button x:Name="BtnClose" Content="Закрыть" DockPanel.Dock="Right" Margin="10,0,0,0"/>
      <Button x:Name="BtnSave" Content="Сохранить" DockPanel.Dock="Right"/>
      <TextBlock x:Name="TxtStatus" Foreground="{StaticResource Muted}" TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,16,0"/>
    </DockPanel>
  </Grid>
</Window>
'@

try {
    $script:Config = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:Apps = New-Object System.Collections.ArrayList
    foreach ($entry in @($script:Config.apps)) { [void]$script:Apps.Add($entry) }

    $Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    foreach ($name in 'TxtUwf', 'BtnAdd', 'BtnRemove', 'BtnUp', 'BtnDown', 'AppList', 'FormPanel', 'TxtName', 'BtnTarget', 'TxtTarget',
                      'ImgCover', 'TxtCover', 'BtnCover', 'TxtAccount', 'TxtSteamId', 'TxtWatch', 'BtnClose', 'BtnSave', 'TxtStatus', 'TxtExtraName', 'TxtExtraTarget', 'BtnExtraTarget', 'BtnExtraClear', 'TxtCategory', 'TxtCategoryCaption') {
        Set-Variable -Name $name -Value $Window.FindName($name) -Scope Script
    }

    $uwf = Get-CimInstance -Namespace 'root\standardcimv2\embedded' -ClassName UWF_Filter -ErrorAction SilentlyContinue
    if ($uwf -and $uwf.CurrentEnabled) { $TxtUwf.Visibility = 'Visible' }

    # Ошибка в обработчике не должна молча закрывать окно: показываем её в строке состояния
    $AppList.Add_SelectionChanged({
        if ($script:Loading) { return }
        try {
            Save-Form
            $script:Index = $AppList.SelectedIndex
            Show-Form
            # Список перестраиваем после завершения события: менять его внутри обработчика нельзя
            [void]$Window.Dispatcher.BeginInvoke([Action]{ Update-List $script:Index })
        }
        catch { $TxtStatus.Text = "Ошибка: $_" }
    })
    $script:DragIndex = -1
    $AppList.Add_PreviewMouseLeftButtonDown({
        param($sender, $e)
        $script:DragIndex = -1
        try {
            $script:DragIndex = Get-ListIndex $e.OriginalSource
            $script:DragStart = $e.GetPosition($AppList)
        }
        catch { $script:DragIndex = -1 }
    })
    $AppList.Add_PreviewMouseMove({
        param($sender, $e)
        if ($script:DragIndex -lt 0 -or $e.LeftButton -ne 'Pressed') { return }
        $position = $e.GetPosition($AppList)
        if ([Math]::Abs($position.Y - $script:DragStart.Y) -lt 6) { return }
        $from = $script:DragIndex
        $script:DragIndex = -1
        [void][System.Windows.DragDrop]::DoDragDrop($AppList, [string]$from, [System.Windows.DragDropEffects]::Move)
    })
    $AppList.Add_Drop({
        param($sender, $e)
        try {
            $from = [int]$e.Data.GetData([string])
            Move-DraggedApp $from (Get-ListIndex $e.OriginalSource)
        }
        catch { $TxtStatus.Text = "Порядок не изменён: $_" }
    })
    $BtnAdd.Add_Click({
        try {
            Save-Form
            $id = 'app-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            [void]$script:Apps.Add([pscustomobject]@{ id = $id; name = 'Новая игра' })
            Update-List ($script:Apps.Count - 1)
            [void]$TxtName.Focus()
            $TxtName.SelectAll()
        }
        catch { $TxtStatus.Text = "Ошибка: $_" }
    })
    $BtnRemove.Add_Click({
        if ($script:Index -lt 0) { return }
        $question = "Убрать «$($script:Apps[$script:Index].name)» из лаунчера?"
        if ([System.Windows.MessageBox]::Show($question, 'Настройки лаунчера', 'YesNo') -ne 'Yes') { return }
        $script:Apps.RemoveAt($script:Index)
        Update-List ([Math]::Max(0, $script:Index))
        $TxtStatus.Text = 'Игра убрана из списка. Нажми «Сохранить».'
    })
    $BtnUp.Add_Click({ try { Move-App -1 } catch { $TxtStatus.Text = "Ошибка: $_" } })
    $BtnDown.Add_Click({ try { Move-App 1 } catch { $TxtStatus.Text = "Ошибка: $_" } })
    $BtnTarget.Add_Click({ try { Select-Target } catch { $TxtStatus.Text = "Ярлык не сохранён: $_" } })
    $BtnExtraTarget.Add_Click({ try { Select-ExtraTarget } catch { $TxtStatus.Text = "Кнопка не настроена: $_" } })
    $BtnExtraClear.Add_Click({ try { Remove-ExtraButton } catch { $TxtStatus.Text = "Кнопка не убрана: $_" } })
    $BtnCover.Add_Click({ try { Select-Cover } catch { $TxtStatus.Text = "Обложка не сохранена: $_" } })
    $BtnSave.Add_Click({ try { Save-Config } catch { $TxtStatus.Text = "Не сохранено: $_" } })
    $BtnClose.Add_Click({ $Window.Close() })

    $ids = @($script:Config.categories | Where-Object { $_ } | ForEach-Object { $_.id })
    if ($ids.Count -gt 0) { $TxtCategoryCaption.Text = "Категория: $($ids -join ', ')" }
    Update-List 0
    [void]$Window.ShowDialog()
}
catch {
    [void][System.Windows.MessageBox]::Show("Настройки не открылись.`n$_", 'Настройки лаунчера SIMRACE')
    exit 1
}
