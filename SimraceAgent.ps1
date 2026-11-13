#Requires -Version 5.1
<#
  Служба лаунчера. Работает от имени SYSTEM, запускается задачей при загрузке компьютера.
  Принимает команды только с этого компьютера. Сама проверяет пароль администратора и выдаёт
  временный ключ, поэтому гостевая учётная запись ничего не может сделать без пароля.
  Пароль не записывается ни на диск, ни в журнал.
#>
$ErrorActionPreference = 'Stop'

$script:Root = $PSScriptRoot
$script:PipeName = 'SimraceAgent'
$script:RawUrl = 'https://raw.githubusercontent.com/velizhaninv/simrace_launcher/main'
$script:Uwfmgr = Join-Path $env:SystemRoot 'System32\uwfmgr.exe'
$script:State = 'idle'           # idle, updating, await-decision
$script:Message = ''
$script:Token = $null
$script:TokenUntil = [datetime]::MinValue
$script:UpdateProcess = $null
$script:UpdateOk = $true
$script:OverlayNext = [datetime]::MinValue
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Listener = $null
$script:NetPort = 47615
$script:RemoteUpdate = $false
$script:RemoteRelock = $false
$script:LauncherBusy = $false
$script:LauncherSeen = [datetime]::MinValue
$script:IdleNext = [datetime]::MinValue
$script:ForceUpdate = $false
$script:WaitAction = 'update'
$script:WaitTitles = @{ update = 'Обновление'; lock = 'Блокировка'; unlock = 'Разблокировка'; reboot = 'Перезагрузка'; shutdown = 'Выключение' }
$script:LauncherReport = $null      # последний отчёт лаунчера: игра, сеанс, громкость
$script:VolumeCmd = $null           # громкость с управляющего компьютера: лаунчер заберёт её при следующем опросе
# Управляющий компьютер клуба берём из настроек (club.adminComputer). В первом клубе это SIMRACE-14, в филиале SIMRACE-1.
$script:AdminComputer = 'SIMRACE-14'
try {
    $clubAdmin = [string](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'apps.json') -Raw -Encoding UTF8 | ConvertFrom-Json).club.adminComputer
    if ($clubAdmin) { $script:AdminComputer = $clubAdmin }
} catch { }
$script:AdminIps = @()
$script:AdminIpsUntil = [datetime]::MinValue
$script:RestartSelf = $false
$script:AgentHash = $(try { (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash } catch { '' })
$script:LastBusy = ''
$script:OverlayData = @{ ok = $true; enabled = $false; usedMb = 0; freeMb = 0 }

$logFolder = if (Test-Path -LiteralPath 'Z:\') { 'Z:\SIMRACE\Logs' } else { Join-Path $env:ProgramData 'SIMRACE\Logs' }
New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
$script:LogFile = Join-Path $logFolder "$env:COMPUTERNAME-agent.log"

function Write-Log([string]$Text) {
    try { Add-Content -LiteralPath $script:LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Text) -Encoding UTF8 } catch { }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security.Principal;

public static class SimraceAgentNative
{
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LogonUser(string user, string domain, string password, int type, int provider, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr buffer, int length, out int needed);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    private static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool DuplicateTokenEx(IntPtr token, uint access, IntPtr attributes, int level, int type, out IntPtr result);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool SetTokenInformation(IntPtr token, int infoClass, ref uint value, int length);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb; public string reserved; public string desktop; public string title;
        public int x; public int y; public int xSize; public int ySize; public int xChars; public int yChars;
        public int fill; public int flags; public short show; public short reserved2;
        public IntPtr reserved3; public IntPtr input; public IntPtr output; public IntPtr error;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION { public IntPtr process; public IntPtr thread; public int processId; public int threadId; }

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessAsUser(IntPtr token, string application, string commandLine, IntPtr processAttributes,
        IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory, ref STARTUPINFO startup, out PROCESS_INFORMATION info);

    // Проверяет имя и пароль в Windows и входит ли учётная запись в группу администраторов.
    public static bool IsAdminPassword(string user, string password)
    {
        string domain = ".";
        int slash = user.IndexOf('\\');
        if (slash >= 0) { domain = user.Substring(0, slash); user = user.Substring(slash + 1); }
        IntPtr token;
        if (!LogonUser(user, domain, password, 2, 0, out token)) return false;   // 2 = интерактивный вход
        IntPtr buffer = IntPtr.Zero;
        try
        {
            int needed;
            GetTokenInformation(token, 2, IntPtr.Zero, 0, out needed);           // 2 = TokenGroups
            buffer = Marshal.AllocHGlobal(needed);
            if (!GetTokenInformation(token, 2, buffer, needed, out needed)) return false;
            int count = Marshal.ReadInt32(buffer);
            IntPtr item = IntPtr.Add(buffer, IntPtr.Size);
            for (int i = 0; i < count; i++)
            {
                IntPtr sid = Marshal.ReadIntPtr(item);
                if (new SecurityIdentifier(sid).Value == "S-1-5-32-544") return true;
                item = IntPtr.Add(item, IntPtr.Size * 2);
            }
            return false;
        }
        finally
        {
            if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
            CloseHandle(token);
        }
    }

    // Открывает окно на экране текущего пользователя с правами службы. Возвращает 0 или код ошибки Windows.
    public static int StartOnConsole(string commandLine, string directory)
    {
        const uint ALL_ACCESS = 0xF01FF;
        IntPtr own, duplicate = IntPtr.Zero;
        if (!OpenProcessToken(GetCurrentProcess(), ALL_ACCESS, out own)) return Marshal.GetLastWin32Error();
        try
        {
            if (!DuplicateTokenEx(own, ALL_ACCESS, IntPtr.Zero, 2, 1, out duplicate)) return Marshal.GetLastWin32Error();
            uint session = WTSGetActiveConsoleSessionId();
            if (!SetTokenInformation(duplicate, 12, ref session, 4)) return Marshal.GetLastWin32Error();   // 12 = TokenSessionId
            STARTUPINFO startup = new STARTUPINFO();
            startup.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            startup.desktop = "winsta0\\default";
            PROCESS_INFORMATION info;
            if (!CreateProcessAsUser(duplicate, null, commandLine, IntPtr.Zero, IntPtr.Zero, false, 0, IntPtr.Zero, directory, ref startup, out info))
                return Marshal.GetLastWin32Error();
            CloseHandle(info.thread);
            CloseHandle(info.process);
            return 0;
        }
        finally
        {
            if (duplicate != IntPtr.Zero) CloseHandle(duplicate);
            CloseHandle(own);
        }
    }
}
'@

# ---------- Запись о начатом обновлении: должна пережить перезагрузку ----------

# На диске Z: она сохраняется сама. На защищённом C: файл фиксируется командой uwfmgr, поэтому создаём его заранее.
function Get-StateFile {
    $folder = if (Test-Path -LiteralPath 'Z:\') { 'Z:\SIMRACE-Agent' } else { Join-Path $env:ProgramData 'SIMRACE\Agent' }
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        & icacls.exe $folder /inheritance:r /grant '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /Q | Out-Null
    }
    $file = Join-Path $folder 'pending.txt'
    if (-not (Test-Path -LiteralPath $file)) { Set-Content -LiteralPath $file -Value '' -Encoding ASCII }
    return $file
}

function Set-Pending([string]$Value) {
    $file = Get-StateFile
    Set-Content -LiteralPath $file -Value $Value -Encoding ASCII
    if ($file -like 'C:*' -or $file -like "$env:SystemDrive*") { & $script:Uwfmgr file commit $file | Out-Null }
}

function Get-Pending {
    return ([string](Get-Content -LiteralPath (Get-StateFile) -Raw -ErrorAction SilentlyContinue)).Trim()
}

# ---------- UWF и перезагрузка ----------

function Get-UwfFilter { return (Get-CimInstance -Namespace 'root\standardcimv2\embedded' -ClassName UWF_Filter -ErrorAction SilentlyContinue) }

# ---------- Файл подкачки на диске Z: ----------

$script:PageDrive = 'Z:'
$script:PageFileMB = 15000
$script:MemoryKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'

# Защищён ли диск после следующей загрузки
function Test-NextProtected([string]$Letter) {
    return [bool](Get-CimInstance -Namespace 'root\standardcimv2\embedded' -ClassName UWF_Volume -ErrorAction SilentlyContinue |
        Where-Object { -not $_.CurrentSession -and $_.DriveLetter -eq $Letter -and $_.Protected })
}

# Файл подкачки фиксированного размера на Z:, сам диск Z: без защиты UWF.
# Вызывается при каждой загрузке и перед включением защиты. Если всё уже настроено, ничего не меняет.
# Новый файл подкачки начинает работать после следующей перезагрузки.
function Set-PageFileOnZ {
    if (-not (Test-Path -LiteralPath "$($script:PageDrive)\")) {
        Write-Log "Диска $($script:PageDrive) нет, файл подкачки не настроен"
        return
    }
    $wanted = "$($script:PageDrive)\pagefile.sys $($script:PageFileMB) $($script:PageFileMB)"
    $current = @((Get-ItemProperty -Path $script:MemoryKey -Name PagingFiles -ErrorAction SilentlyContinue).PagingFiles | Where-Object { $_ })
    if ($current.Count -eq 1 -and $current[0] -eq $wanted) { return }
    # Как в UWF-Panel: пишем только пока защита в текущей сессии выключена, иначе запись уйдёт в оверлей
    $filter = Get-UwfFilter
    if ($filter -and $filter.CurrentEnabled) {
        Write-Log "Файл подкачки в реестре: $($current -join '; '). Защита включена, исправится при обслуживании с выключенной защитой"
        return
    }
    # Явная запись размера заодно выключает «Автоматически выбирать объём файла подкачки»
    Set-ItemProperty -Path $script:MemoryKey -Name PagingFiles -Type MultiString -Value @($wanted)
    Write-Log "Файл подкачки прописан: $wanted (было: $($current -join '; ')). Заработает после перезагрузки"
}

# ---------- Размер overlay ----------

$script:OverlayMB = 12288      # 12 ГБ

# Overlay UWF на диске: 12 ГБ, пороги как в UWF-Panel (предупреждение 2/3, критический 90%).
# Размер меняется со следующей загрузки. Меняем только при выключенной защите: тогда свободное место на C: известно точно.
function Set-OverlaySize {
    $filter = Get-UwfFilter
    if (-not $filter -or $filter.CurrentEnabled) { return }
    $next = Get-CimInstance -Namespace 'root\standardcimv2\embedded' -ClassName UWF_OverlayConfig -ErrorAction SilentlyContinue |
        Where-Object { -not $_.CurrentSession } | Select-Object -First 1
    if (-not $next -or [int]$next.MaximumSize -eq $script:OverlayMB) { return }
    if ($next.Type -eq 0) {
        # Overlay в ОЗУ: 12 ГБ памяти под него не отдаём, раньше это приводило к перезагрузкам
        Write-Log "Overlay в оперативной памяти, $($next.MaximumSize) МБ: размер не меняю. Переведи overlay на диск в панели UWF"
        return
    }
    $volume = Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction SilentlyContinue
    $limitMb = $(if ($volume) { ([math]::Floor($volume.SizeRemaining / 1GB) - 2) * 1024 } else { 0 })
    if ($limitMb -lt $script:OverlayMB) {
        Write-Log "Overlay 12 ГБ не помещается на $($env:SystemDrive): можно $limitMb МБ. Оставлено $($next.MaximumSize) МБ"
        return
    }
    $mb = $script:OverlayMB
    & $script:Uwfmgr overlay set-size $mb | Out-Null
    & $script:Uwfmgr overlay set-warningthreshold ([math]::Round($mb * 2 / 3)) | Out-Null
    & $script:Uwfmgr overlay set-criticalthreshold ([math]::Round($mb * 0.9)) | Out-Null
    $check = Get-CimInstance -Namespace 'root\standardcimv2\embedded' -ClassName UWF_OverlayConfig -ErrorAction SilentlyContinue |
        Where-Object { -not $_.CurrentSession } | Select-Object -First 1
    Write-Log "Overlay после перезагрузки: $($check.MaximumSize) МБ (было $($next.MaximumSize) МБ)"
}

# Включение и выключение защиты: те же шаги и проверки, что в UWF-Panel
function Set-Uwf([bool]$Enable) {
    $filter = Get-UwfFilter
    if (-not $filter) { throw 'UWF на этом компьютере нет.' }
    $page = "$($script:PageDrive)\"
    if ($Enable) {
        # 1. Диск подкачки без защиты
        if ((Test-Path -LiteralPath $page) -and (Test-NextProtected $script:PageDrive)) { & $script:Uwfmgr volume unprotect $script:PageDrive | Out-Null }
        # 2. Системный диск под защиту
        if (-not (Test-NextProtected $env:SystemDrive)) { & $script:Uwfmgr volume protect $env:SystemDrive | Out-Null }
        # 3. Включить фильтр со следующей загрузки
        & $script:Uwfmgr filter enable | Out-Null
        # Overlay 12 ГБ. Ошибка размера не мешает включить защиту.
        try { Set-OverlaySize } catch { Write-Log "Ошибка настройки overlay: $_" }
        # 4. Заново прописать подкачку, только пока защита в текущей сессии выключена: иначе запись уйдёт в оверлей
        if (-not $filter.CurrentEnabled -and (Test-Path -LiteralPath $page)) {
            Set-ItemProperty -Path $script:MemoryKey -Name PagingFiles -Type MultiString -Value @("$($script:PageDrive)\pagefile.sys $($script:PageFileMB) $($script:PageFileMB)")
        }
        # Проверка результата
        $ok = (Get-UwfFilter).NextEnabled -and (Test-NextProtected $env:SystemDrive)
        if (Test-Path -LiteralPath $page) { $ok = $ok -and -not (Test-NextProtected $script:PageDrive) }
        if (-not $ok) { throw 'Не удалось включить защиту: проверь UWF на этом компьютере.' }
    }
    else {
        & $script:Uwfmgr filter disable | Out-Null
        if ((Get-UwfFilter).NextEnabled) { throw 'Не удалось выключить защиту.' }
    }
    Write-Log "UWF после перезагрузки: $(if ($Enable) { 'включён' } else { 'выключен' })"
}

function Restart-Pc {
    Write-Log 'Перезагрузка'
    [void](Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r /t 3 /f' -WindowStyle Hidden)
}

# ---------- Обновление ----------

function Start-Update {
    if ($script:State -eq 'updating') { return }
    $script:State = 'updating'
    $script:Message = ''
    Write-Log 'Обновление запущено'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $script:Root 'Update-Apply.ps1')`""
    $script:UpdateProcess = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $null = $script:UpdateProcess.Handle      # без этого ExitCode будет пустым
}

# Шкала оверлея: значения обновляются здесь раз в 10 секунд, а лаунчер получает готовый ответ без задержки
function Update-OverlayCache {
    if ((Get-Date) -lt $script:OverlayNext) { return }
    $script:OverlayNext = (Get-Date).AddSeconds(10)
    try {
        $filter = Get-UwfFilter
        $overlay = Get-CimInstance -Namespace 'root\standardcimv2\embedded' -ClassName UWF_Overlay -ErrorAction Stop | Select-Object -First 1
        $script:OverlayData = @{ ok = $true; enabled = [bool]($filter -and $filter.CurrentEnabled); usedMb = [double]$overlay.OverlayConsumption; freeMb = [double]$overlay.AvailableSpace }
    }
    catch {
        $script:OverlayData = @{ ok = $true; enabled = $false; usedMb = 0; freeMb = 0 }
    }
    # Файл подкачки, который работает прямо сейчас: путь и размер в МБ
    try {
        $pages = @(Get-CimInstance Win32_PageFileUsage -ErrorAction Stop | ForEach-Object { "$($_.Name)|$($_.AllocatedBaseSize)" })
        $script:OverlayData.pages = $pages
    }
    catch { $script:OverlayData.pages = @() }
}

# Вызывается раз в секунду, пока никто не подключён
function Update-AgentState {
    if ($script:RestartSelf) {
        # Ответ на последнюю команду уже отправлен: выходим, через полминуты задание запустит новую версию
        try { if ($script:Listener) { $script:Listener.Stop() } } catch { }
        [Environment]::Exit(0)
    }
    Update-OverlayCache
    Update-Network
    Update-WaitingUpdate
    if ($script:State -ne 'updating' -or -not $script:UpdateProcess -or -not $script:UpdateProcess.HasExited) { return }
    $code = $script:UpdateProcess.ExitCode
    $script:UpdateProcess = $null
    $result = Join-Path $env:ProgramData 'SIMRACE\update-result.txt'
    $text = ''
    $script:UpdateOk = $code -eq 0
    if (Test-Path -LiteralPath $result) { $text = ([string](Get-Content -LiteralPath $result -Raw -Encoding UTF8)).Trim() }
    if ($code -eq 0) { $script:Message = "Лаунчер обновлён. $text".Trim() }
    else { $script:Message = "Обновить не удалось. Прежняя версия осталась. $text".Trim() }
    Write-Log "Обновление завершено, код $code. $text"
    if ($script:RemoteUpdate) {
        # Обновление с администраторского компьютера: без вопросов возвращаем защиту, как была
        $script:RemoteUpdate = $false
        if ($script:RemoteRelock) {
            $script:RemoteRelock = $false
            try {
                Set-Uwf $true
                $script:State = 'rebooting'
                Restart-Pc
                return
            }
            catch {
                $script:UpdateOk = $false
                $script:Message = "Защита не включилась после обновления: $($_.Exception.Message)"
                Write-Log $script:Message
            }
        }
        Request-LauncherRestart
        $script:State = 'idle'
        Restart-AgentIfChanged
        return
    }
    $script:State = 'await-decision'
}

# ---------- Обновление по команде с администраторского компьютера ----------

# После обновления без перезагрузки на диске уже новая служба, а работает старая.
# Разовое задание запускает новую через 30 секунд, а эта служба завершается.
function Restart-AgentIfChanged {
    try {
        if ((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash -eq $script:AgentHash) { return }
        $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\schtasks.exe') -Argument '/Run /TN "\SIMRACE\SIMRACE Agent"'
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(30)
        $trigger.EndBoundary = (Get-Date).AddMinutes(10).ToString('s')
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DeleteExpiredTaskAfter (New-TimeSpan -Minutes 5)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName 'SIMRACE Agent Restart' -TaskPath '\SIMRACE\' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
        Write-Log 'Служба обновилась: перезапускаю, чтобы заработала новая версия'
        $script:RestartSelf = $true
    }
    catch { Write-Log "Новая версия службы заработает после перезагрузки: $_" }
}

# Лаунчер сам перезапустится, когда закончится сеанс
function Request-LauncherRestart {
    try { Set-Content -LiteralPath (Join-Path $script:Root 'restart-request.txt') -Value (Get-Date -Format o) -Encoding ASCII }
    catch { Write-Log "Запрос перезапуска лаунчера не записан: $_" }
}

# Чем занят кокпит. Пустая строка: свободен.
# Ограничитель один: сеанс в лаунчере. Сеанс завершён — можно обновлять.
function Get-BusyReason {
    if ($script:LauncherBusy -and ((Get-Date) - $script:LauncherSeen).TotalSeconds -lt 15) { return 'идёт сеанс' }
    return ''
}

function Update-WaitingUpdate {
    if ($script:State -ne 'waiting-idle' -or (Get-Date) -lt $script:IdleNext) { return }
    $script:IdleNext = (Get-Date).AddSeconds(30)
    $busy = $(if ($script:ForceUpdate) { '' } else { Get-BusyReason })
    $title = $script:WaitTitles[$script:WaitAction]
    if ($busy) {
        # Причину ожидания пишем в журнал один раз, при её смене
        if ($busy -ne $script:LastBusy) { Write-Log "$title по сети ждёт: $busy" }
        $script:LastBusy = $busy
        return
    }
    $script:ForceUpdate = $false
    Write-Log "$title по сети: кокпит свободен, начинаю"
    if ($script:WaitAction -eq 'reboot') {
        $script:State = 'rebooting'
        Restart-Pc
        return
    }
    if ($script:WaitAction -eq 'shutdown') {
        $script:State = 'shutdown'
        Write-Log 'Выключение'
        [void](Start-Process -FilePath 'shutdown.exe' -ArgumentList '/s /t 3 /f' -WindowStyle Hidden)
        return
    }
    if ($script:WaitAction -eq 'unlock') {
        try {
            $filter = Get-UwfFilter
            Set-Uwf $false
            if (-not $filter.CurrentEnabled) {
                # Защита уже выключена: перезагрузка не нужна
                $script:State = 'idle'
                Write-Log 'Разблокировка по сети: защита уже выключена'
                return
            }
            $script:State = 'rebooting'
            Restart-Pc
        }
        catch {
            $script:State = 'idle'
            $script:UpdateOk = $false
            $script:Message = "Разблокировка по сети не выполнена: $($_.Exception.Message)"
            Write-Log $script:Message
        }
        return
    }
    if ($script:WaitAction -eq 'lock') {
        try {
            $filter = Get-UwfFilter
            Set-Uwf $true
            if ($filter.CurrentEnabled) {
                # Защита уже работает: перезагрузка не нужна
                $script:State = 'idle'
                Write-Log 'Блокировка по сети: защита уже включена'
                return
            }
            $script:State = 'rebooting'
            Restart-Pc
        }
        catch {
            $script:State = 'idle'
            $script:UpdateOk = $false
            $script:Message = "Блокировка по сети не выполнена: $($_.Exception.Message)"
            Write-Log $script:Message
        }
        return
    }
    $filter = Get-UwfFilter
    if ($filter -and $filter.CurrentEnabled) {
        Set-Pending 'remote-relock'
        try { Set-Uwf $false }
        catch {
            Set-Pending ''
            $script:State = 'idle'
            $script:UpdateOk = $false
            $script:Message = "Обновление по сети не выполнено: $($_.Exception.Message)"
            Write-Log $script:Message
            return
        }
        $script:State = 'rebooting'
        Restart-Pc
        return
    }
    $script:RemoteUpdate = $true
    $script:RemoteRelock = $false
    $script:State = 'idle'
    Start-Update
}

function Update-Network {
    if (-not $script:Listener) { return }
    while ($script:Listener.Pending()) {
        $client = $script:Listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 3000
            $client.SendTimeout = 3000
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream, $script:Utf8, $false, 4096, $true)
            $writer = New-Object System.IO.StreamWriter($stream, $script:Utf8, 4096, $true)
            $writer.AutoFlush = $true
            $line = $reader.ReadLine()
            $response = $null
            $remote = $client.Client.RemoteEndPoint.Address
            try { $response = Invoke-NetRequest ($line | ConvertFrom-Json) $remote }
            catch { $response = @{ ok = $false; error = $_.Exception.Message } }
            $writer.WriteLine(($response | ConvertTo-Json -Compress -Depth 4))
        }
        catch { Write-Log "Ошибка сетевой команды: $_" }
        finally { $client.Close() }
    }
}

# Блокировку и перезагрузку принимаем только с управляющего компьютера клуба ($script:AdminComputer).
# У него может быть несколько адресов (локальная сеть, Radmin VPN), поэтому проверяем двумя способами:
# адреса по имени управляющего компьютера и имя компьютера по адресу, с которого пришла команда.
# Что сейчас на кокпите по словам лаунчера: игра, начало сеанса, длительность, громкость
function Get-SessionReport {
    $report = $script:LauncherReport
    if (-not $report -or ((Get-Date) - $script:LauncherSeen).TotalSeconds -ge 15) { return $null }
    $elapsed = [double]$report.elapsed
    # Отчёт приходит раз в 2 секунды: добавляем время с его прихода, если сеанс не на паузе
    if ($report.session -and -not $report.paused) { $elapsed += ((Get-Date) - $script:LauncherSeen).TotalSeconds }
    return @{
        active = [bool]$report.session; paused = [bool]$report.paused; game = [string]$report.game
        start = [string]$report.start; elapsed = [int]$elapsed
        system = $report.volSystem; gameVolume = $report.volGame; mumble = $report.volMumble
        net = [string]$report.net; internet = $report.internet; vpn = [string]$report.vpn; base = $report.base
    }
}

# ---------- Статистика ----------
# Файл на незащищённом диске Z: записи переживают перезагрузку при включённой защите
function Get-StatFile {
    $root = $(if (Test-Path -LiteralPath 'Z:\') { 'Z:\SIMRACE\Stats' } else { Join-Path $env:ProgramData 'SIMRACE\Stats' })
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    return (Join-Path $root 'sessions.jsonl')
}

function Add-StatLine([string]$Line) {
    try { Add-Content -LiteralPath (Get-StatFile) -Value $Line -Encoding UTF8 }
    catch { Write-Log "Статистика не записана: $_" }
}

function Get-StatLines([int]$Days) {
    $file = Get-StatFile
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    $since = (Get-Date).Date.AddDays(-$Days)
    $result = New-Object System.Collections.ArrayList
    foreach ($line in [System.IO.File]::ReadAllLines($file)) {
        if (-not $line) { continue }
        try {
            $item = $line | ConvertFrom-Json
            if ([datetime]$item.start -ge $since) { [void]$result.Add($item) }
        }
        catch { }
    }
    return $result.ToArray()
}

# ---------- Включение по сети ----------
# MAC-адреса проводных сетевых карт: по ним SIMRACE-14 будит выключенный кокпит
$script:WakeMacs = @()
$script:WakeMacsUntil = [datetime]::MinValue
function Get-WakeMacs {
    if ((Get-Date) -lt $script:WakeMacsUntil) { return $script:WakeMacs }
    $script:WakeMacsUntil = (Get-Date).AddMinutes(10)
    try {
        $script:WakeMacs = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.MediaType -eq '802.3' -and $_.MacAddress } | ForEach-Object { $_.MacAddress })
    }
    catch { $script:WakeMacs = @() }
    return $script:WakeMacs
}

# Windows-часть Wake-on-LAN: пробуждение сетевой карты по «магическому пакету» и выключенный быстрый запуск.
# Пишем только при выключенной защите, иначе изменения пропадут. BIOS настраивается вручную.
function Set-WakeOnLan {
    $filter = Get-UwfFilter
    if ($filter -and $filter.CurrentEnabled) { return }
    foreach ($adapter in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.MediaType -eq '802.3' })) {
        try {
            $power = Get-NetAdapterPowerManagement -Name $adapter.Name -ErrorAction Stop
            if ([string]$power.WakeOnMagicPacket -ne 'Enabled') {
                Set-NetAdapterPowerManagement -Name $adapter.Name -WakeOnMagicPacket Enabled -NoRestart -ErrorAction Stop
                Write-Log "Wake-on-LAN включён в Windows: $($adapter.Name)"
            }
        }
        catch { Write-Log "Wake-on-LAN не включён на $($adapter.Name): $_" }
        $property = Get-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword '*WakeOnMagicPacket' -ErrorAction SilentlyContinue
        if ($property -and [string]$property.RegistryValue -ne '1') {
            try { Set-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword '*WakeOnMagicPacket' -RegistryValue 1 -NoRestart -ErrorAction Stop } catch { }
        }
    }
    # Быстрый запуск мешает пробуждению из выключенного состояния
    $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    if ((Get-ItemProperty -Path $powerKey -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled -ne 0) {
        Set-ItemProperty -Path $powerKey -Name HiberbootEnabled -Type DWord -Value 0
        Write-Log 'Быстрый запуск Windows выключен: нужен для включения по сети'
    }
}

# ---------- Обновления игр в Steam ----------
# У каждой установленной игры ставим «Обновлять игру только при её запуске» (AutoUpdateBehavior = 1),
# чтобы Steam не качал обновления в фоне и не заполнял overlay при включённой защите.
# Пишем только при выключенной защите и закрытом Steam: иначе изменения пропадут или Steam их перезапишет.
function Set-SteamUpdateOnLaunch {
    $filter = Get-UwfFilter
    if ($filter -and $filter.CurrentEnabled) { return }
    if (Get-Process -Name steam -ErrorAction SilentlyContinue) {
        Write-Log 'Обновления Steam: Steam запущен, настройку игр пропускаю до следующей загрузки'
        return
    }
    $roots = @()
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        $value = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).InstallPath
        if ($value) { $roots += $value }
    }
    $libraries = @()
    foreach ($root in $roots) {
        $libraries += $root
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($match in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw -Encoding UTF8), '"path"\s+"([^"]+)"')) { $libraries += ($match.Groups[1].Value -replace '\\\\', '\') }
        }
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $changed = 0
    $total = 0
    foreach ($library in @($libraries | Sort-Object -Unique)) {
        $apps = Join-Path $library 'steamapps'
        if (-not (Test-Path -LiteralPath $apps)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $apps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue)) {
            $total++
            try {
                $text = [System.IO.File]::ReadAllText($file.FullName, $encoding)
                if ($text -notmatch '"AutoUpdateBehavior"\s+"(\d+)"' -or $Matches[1] -eq '1') { continue }
                $text = [regex]::Replace($text, '("AutoUpdateBehavior"\s+")\d+(")', '${1}1${2}')
                [System.IO.File]::WriteAllText($file.FullName, $text, $encoding)
                $changed++
            }
            catch { Write-Log "Обновления Steam: не изменён $($file.Name): $_" }
        }
    }
    if ($changed -gt 0) { Write-Log "Обновления Steam: игр переведено на «только при запуске»: $changed из $total" }
}

function Test-AdminSource([System.Net.IPAddress]$Remote) {
    if (-not $Remote) { return $false }
    if ($Remote.IsIPv4MappedToIPv6) { $Remote = $Remote.MapToIPv4() }
    $ip = $Remote.ToString()
    if ($env:COMPUTERNAME -eq $script:AdminComputer -and [System.Net.IPAddress]::IsLoopback($Remote)) { return $true }
    # 1. Адреса по имени: при несовпадении узнаём заново, вдруг адрес сменился
    foreach ($fresh in $false, $true) {
        if ($fresh -or (Get-Date) -ge $script:AdminIpsUntil) {
            try { $script:AdminIps = @([System.Net.Dns]::GetHostAddresses($script:AdminComputer) | ForEach-Object { $(if ($_.IsIPv4MappedToIPv6) { $_.MapToIPv4() } else { $_ }).ToString() }) }
            catch { $script:AdminIps = @() }
            # Пустой ответ не запоминаем
            $script:AdminIpsUntil = $(if ($script:AdminIps.Count -gt 0) { (Get-Date).AddMinutes(5) } else { [datetime]::MinValue })
        }
        if ($script:AdminIps -contains $ip) { return $true }
    }
    # 2. Имя по адресу
    $name = ''
    try { $name = ([System.Net.Dns]::GetHostEntry($Remote).HostName -split '\.')[0] } catch { }
    if ($name -and $name -eq $script:AdminComputer) { return $true }
    Write-Log "Проверка источника: команда с $ip, адреса $($script:AdminComputer): $($script:AdminIps -join ', '), имя по адресу: $(if ($name) { $name } else { 'не найдено' })"
    return $false
}

function Invoke-NetRequest($Request, [System.Net.IPAddress]$Remote) {
    switch ([string]$Request.action) {
        'status' {
            $filter = Get-UwfFilter
            $data = $script:OverlayData
            return @{
                ok = $true; computer = $env:COMPUTERNAME; version = Get-InstalledVersion; state = $script:State
                message = $script:Message; updateOk = $script:UpdateOk
                uwfNow = [bool]($filter -and $filter.CurrentEnabled); uwfNext = [bool]($filter -and $filter.NextEnabled)
                usedMb = $data.usedMb; freeMb = $data.freeMb; pages = @($data.pages); busy = Get-BusyReason
                pending = $(if ($script:State -eq 'waiting-idle') { $script:WaitAction } else { '' })
                session = Get-SessionReport
                macs = @(Get-WakeMacs)
            }
        }
        'stats' {
            # Записи за последние дни, не больше 31
            $days = [math]::Max(1, [math]::Min(31, [int]$(if ($Request.days) { $Request.days } else { 31 })))
            return @{ ok = $true; computer = $env:COMPUTERNAME; records = @(Get-StatLines $days) }
        }
        'volume' {
            if (-not (Test-AdminSource $Remote)) {
                Write-Log "Отказано: громкость с $Remote, а не с $($script:AdminComputer)"
                return @{ ok = $false; error = "Команда принимается только с $($script:AdminComputer)." }
            }
            # Значение от 0 до 100 или пусто: эту громкость не меняем
            $levels = @{}
            foreach ($name in 'system', 'game', 'mumble') {
                $value = $Request.$name
                if ($null -ne $value -and "$value" -ne '') { $levels[$name] = [math]::Max(0, [math]::Min(100, [int]$value)) }
            }
            $script:VolumeCmd = @{ id = [guid]::NewGuid().ToString('N'); system = $levels['system']; game = $levels['game']; mumble = $levels['mumble'] }
            Write-Log "Громкость с $Remote`: система $($levels['system']), игра $($levels['game']), Mumble $($levels['mumble'])"
            return @{ ok = $true }
        }
        { $_ -eq 'lock' -or $_ -eq 'unlock' -or $_ -eq 'reboot' -or $_ -eq 'shutdown' } {
            $action = [string]$Request.action
            if (-not (Test-AdminSource $Remote)) {
                Write-Log "Отказано: команда «$action» пришла с $Remote, а не с $($script:AdminComputer)"
                return @{ ok = $false; error = "Команда принимается только с $($script:AdminComputer)." }
            }
            if ($action -ne 'reboot' -and $action -ne 'shutdown' -and -not (Get-UwfFilter)) { return @{ ok = $false; error = 'UWF на этом компьютере нет.' } }
            if ($script:State -eq 'idle') {
                $script:State = 'waiting-idle'
                $script:WaitAction = $action
                $script:IdleNext = [datetime]::MinValue
                $script:Message = ''
                $script:UpdateOk = $true
                $script:LastBusy = ''
                Write-Log "$($script:WaitTitles[$action]) по сети: команда с $Remote"
            }
            elseif ($script:State -ne 'waiting-idle' -or $script:WaitAction -ne $action) {
                return @{ ok = $false; error = "Кокпит занят другой командой: $($script:State) $($script:WaitAction)" }
            }
            if ($Request.force) {
                $script:ForceUpdate = $true
                $script:IdleNext = [datetime]::MinValue
                Write-Log "$($script:WaitTitles[$action]) по сети: без ожидания конца сеанса"
            }
            return @{ ok = $true; state = $script:State }
        }
        'update' {
            if ($script:State -eq 'waiting-idle' -and $script:WaitAction -ne 'update') {
                return @{ ok = $false; error = "Кокпит ждёт другую команду: $($script:WaitAction)" }
            }
            if ($script:State -eq 'idle') {
                $script:State = 'waiting-idle'
                $script:WaitAction = 'update'
                $script:IdleNext = [datetime]::MinValue
                $script:Message = ''
                $script:UpdateOk = $true
                $script:LastBusy = ''
                Write-Log 'Обновление по сети: команда получена'
            }
            # Администратор решил не ждать: обновляемся при следующей проверке, даже если кокпит занят
            if ($Request.force -and $script:State -eq 'waiting-idle') {
                $script:ForceUpdate = $true
                $script:IdleNext = [datetime]::MinValue
                Write-Log 'Обновление по сети: без ожидания конца сеанса'
            }
            return @{ ok = $true; state = $script:State }
        }
        default { throw 'Неизвестная команда.' }
    }
}

# ---------- Команды ----------

function Get-InstalledVersion {
    $file = Join-Path $script:Root 'version.txt'
    if (Test-Path -LiteralPath $file) { return ([string](Get-Content -LiteralPath $file -Raw)).Trim() }
    return 'нет данных'
}

function Test-Token($Request) {
    if (-not $script:Token -or [string]$Request.token -ne $script:Token -or (Get-Date) -gt $script:TokenUntil) { throw 'Войди в панель заново.' }
    $script:TokenUntil = (Get-Date).AddMinutes(30)
}

function Invoke-Request($Request) {
    switch ([string]$Request.action) {
        'status' {
            # Лаунчер сообщает, идёт ли сеанс: обновление по сети его дождётся
            if ($Request.PSObject.Properties['session']) {
                $script:LauncherBusy = [bool]$Request.session
                $script:LauncherSeen = Get-Date
                $script:LauncherReport = $Request
            }
            # Лаунчер применил громкость: больше её не передаём
            if ($script:VolumeCmd -and [string]$Request.volAck -eq $script:VolumeCmd.id) { $script:VolumeCmd = $null }
            $filter = Get-UwfFilter
            return @{ ok = $true; state = $script:State; message = $script:Message; updateOk = $script:UpdateOk; uwfNow = [bool]($filter -and $filter.CurrentEnabled); version = Get-InstalledVersion; volume = $script:VolumeCmd }
        }
        'overlay' { return $script:OverlayData }
        'record' {
            # Запись статистики от лаунчера: одна строка JSON на сеанс или игру
            $entry = [ordered]@{ computer = $env:COMPUTERNAME; kind = [string]$Request.kind; start = [string]$Request.start; minutes = [double]$Request.minutes }
            if ($Request.game) { $entry.game = [string]$Request.game }
            if ($null -ne $Request.wallMinutes) { $entry.wallMinutes = [double]$Request.wallMinutes }
            Add-StatLine ($entry | ConvertTo-Json -Compress)
            return @{ ok = $true }
        }
        'auth' {
            $allowed = $false
            try { $allowed = [SimraceAgentNative]::IsAdminPassword(([string]$Request.user).Trim(), [string]$Request.password) } catch { Write-Log "Ошибка проверки пароля: $_" }
            if (-not $allowed) {
                Write-Log "Неверный пароль: $($Request.user)"
                Start-Sleep -Seconds 1
                return @{ ok = $false; error = 'Неверный пароль или это не администратор' }
            }
            Write-Log "Вход в панель: $($Request.user)"
            $script:Token = [guid]::NewGuid().ToString('N')
            $script:TokenUntil = (Get-Date).AddMinutes(30)
            return @{ ok = $true; token = $script:Token }
        }
        'logout' {
            $script:Token = $null
            return @{ ok = $true }
        }
        'check' {
            Test-Token $Request
            $latest = ''
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $latest = ([string](Invoke-WebRequest -Uri "$($script:RawUrl)/version.txt" -UseBasicParsing -TimeoutSec 6).Content).Trim()
            }
            catch { Write-Log "Версия на GitHub не получена: $_" }
            return @{ ok = $true; installed = Get-InstalledVersion; latest = $latest }
        }
        'update' {
            Test-Token $Request
            $filter = Get-UwfFilter
            if ($filter -and $filter.CurrentEnabled) {
                Set-Pending 'update'
                try { Set-Uwf $false }
                catch {
                    Set-Pending ''
                    throw
                }
                Restart-Pc
                return @{ ok = $true; reboot = $true }
            }
            Start-Update
            return @{ ok = $true; reboot = $false }
        }
        'uwf' {
            Test-Token $Request
            Set-Uwf ([bool]$Request.enable)
            Restart-Pc
            return @{ ok = $true; reboot = $true }
        }
        'reboot' {
            Test-Token $Request
            Restart-Pc
            return @{ ok = $true; reboot = $true }
        }
        'shutdown' {
            Test-Token $Request
            Write-Log 'Выключение'
            [void](Start-Process -FilePath 'shutdown.exe' -ArgumentList '/s /t 3 /f' -WindowStyle Hidden)
            return @{ ok = $true; reboot = $true }
        }
        'open' {
            Test-Token $Request
            $name = [string]$Request.file
            if ('UwfPanel.ps1', 'LauncherSettings.ps1', 'Fleet.ps1', 'Stats.ps1', 'taskmgr' -notcontains $name) { throw 'Неизвестное окно.' }
            $powershell = Join-Path $PSHOME 'powershell.exe'
            $command = if ($name -eq 'taskmgr') { "`"$(Join-Path $env:SystemRoot 'System32\Taskmgr.exe')`"" } else { "`"$powershell`" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$(Join-Path $script:Root $name)`"" }
            $code = [SimraceAgentNative]::StartOnConsole($command, $script:Root)
            if ($code -ne 0) { throw "Окно не открылось, код Windows $code." }
            Write-Log "Открыто окно: $name"
            return @{ ok = $true }
        }
        'decide' {
            # Вопрос после обновления: пароль не нужен, команда работает только в этот момент
            if ($script:State -ne 'await-decision') { throw 'Сейчас нечего подтверждать.' }
            $script:State = 'idle'
            $script:Message = ''
            if ([bool]$Request.lock -and (Get-UwfFilter)) {
                Set-Uwf $true
                Restart-Pc
                return @{ ok = $true; reboot = $true }
            }
            Restart-AgentIfChanged
            return @{ ok = $true; reboot = $false }
        }
        default { throw 'Неизвестная команда.' }
    }
}

# ---------- Запуск ----------

Write-Log "Служба запущена, версия $(Get-InstalledVersion)"

try { Set-PageFileOnZ }
catch { Write-Log "Ошибка настройки файла подкачки: $_" }
try { Set-OverlaySize }
catch { Write-Log "Ошибка настройки overlay: $_" }
try { Set-WakeOnLan }
catch { Write-Log "Ошибка настройки Wake-on-LAN: $_" }
try { Set-SteamUpdateOnLaunch }
catch { Write-Log "Ошибка настройки обновлений Steam: $_" }

# Сетевые команды из локальной сети
try {
    $script:Listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $script:NetPort)
    $script:Listener.Start()
}
catch {
    $script:Listener = $null
    Write-Log "Сетевые команды недоступны: $_"
}

# Продолжаем обновление, начатое до перезагрузки
try {
    $pending = Get-Pending
    if ($pending -eq 'maintain') {
        # Обслуживание из прежней версии: функцию убрали, защиту возвращаем
        Set-Pending ''
        $filter = Get-UwfFilter
        if ($filter -and -not $filter.CurrentEnabled) {
            Write-Log 'Прежнее обслуживание не закончено: включаю защиту обратно'
            try { Set-Uwf $true; $script:State = 'rebooting'; Restart-Pc } catch { Write-Log "Защита не включилась: $_" }
        }
    }
    if ($pending -eq 'remote-relock') {
        Set-Pending ''
        $filter = Get-UwfFilter
        if ($filter -and $filter.CurrentEnabled) {
            $script:UpdateOk = $false
            $script:Message = 'Обновление по сети не выполнено: защита UWF не выключилась.'
            Write-Log $script:Message
        }
        else {
            $script:RemoteUpdate = $true
            $script:RemoteRelock = $true
            Start-Update
        }
    }
    if ($pending -eq 'update') {
        Set-Pending ''
        $filter = Get-UwfFilter
        if ($filter -and $filter.CurrentEnabled) {
            $script:State = 'await-decision'
            $script:Message = 'Обновить не удалось: защита UWF не выключилась.'
            $script:UpdateOk = $false
        }
        else { Start-Update }
    }
}
catch { Write-Log "Ошибка продолжения обновления: $_" }

# Канал доступен только локально: сетевым подключениям запрещён, пользователи могут только отправлять команды
$security = New-Object System.IO.Pipes.PipeSecurity
$security.AddAccessRule((New-Object System.IO.Pipes.PipeAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-2')), 'FullControl', 'Deny')))
$security.AddAccessRule((New-Object System.IO.Pipes.PipeAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')), 'FullControl', 'Allow')))
$security.AddAccessRule((New-Object System.IO.Pipes.PipeAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')), 'ReadWrite', 'Allow')))

$encoding = New-Object System.Text.UTF8Encoding($false)
while ($true) {
    $server = $null
    try {
        $server = New-Object System.IO.Pipes.NamedPipeServerStream($script:PipeName, [System.IO.Pipes.PipeDirection]::InOut, 1, [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous, 4096, 4096, $security)
        $connection = $server.BeginWaitForConnection($null, $null)
        while (-not $connection.AsyncWaitHandle.WaitOne(1000)) { Update-AgentState }
        $server.EndWaitForConnection($connection)
        Update-AgentState

        $reader = New-Object System.IO.StreamReader($server, $encoding, $false, 4096, $true)
        $writer = New-Object System.IO.StreamWriter($server, $encoding, 4096, $true)
        $writer.AutoFlush = $true
        $line = $reader.ReadLineAsync()
        $response = $null
        if ($line.Wait(3000) -and $line.Result) {
            try { $response = Invoke-Request ($line.Result | ConvertFrom-Json) }
            catch { $response = @{ ok = $false; error = $_.Exception.Message } }
        }
        if ($response) {
            $writer.WriteLine(($response | ConvertTo-Json -Compress))
            $server.WaitForPipeDrain()
        }
    }
    catch {
        Write-Log "Ошибка канала: $_"
        Start-Sleep -Seconds 1
    }
    finally {
        if ($server) { $server.Dispose() }
    }
}
