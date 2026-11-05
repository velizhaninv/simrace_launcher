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

function Set-Uwf([bool]$Enable) {
    if (-not (Get-UwfFilter)) { throw 'UWF на этом компьютере нет.' }
    & $script:Uwfmgr filter $(if ($Enable) { 'enable' } else { 'disable' }) | Out-Null
    if ([bool](Get-UwfFilter).NextEnabled -ne $Enable) { throw 'Защита UWF не переключилась.' }
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

# Вызывается раз в секунду, пока никто не подключён
function Update-AgentState {
    if ($script:State -ne 'updating' -or -not $script:UpdateProcess -or -not $script:UpdateProcess.HasExited) { return }
    $code = $script:UpdateProcess.ExitCode
    $script:UpdateProcess = $null
    $result = Join-Path $env:ProgramData 'SIMRACE\update-result.txt'
    $text = ''
    if (Test-Path -LiteralPath $result) { $text = ([string](Get-Content -LiteralPath $result -Raw -Encoding UTF8)).Trim() }
    if ($code -eq 0) { $script:Message = "Лаунчер обновлён. $text".Trim() }
    else { $script:Message = "Обновить не удалось. Прежняя версия осталась. $text".Trim() }
    Write-Log "Обновление завершено, код $code. $text"
    $script:State = 'await-decision'
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
            $filter = Get-UwfFilter
            return @{ ok = $true; state = $script:State; message = $script:Message; uwfNow = [bool]($filter -and $filter.CurrentEnabled); version = Get-InstalledVersion }
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
            if ('UwfPanel.ps1', 'LauncherSettings.ps1' -notcontains $name) { throw 'Неизвестное окно.' }
            $powershell = Join-Path $PSHOME 'powershell.exe'
            $code = [SimraceAgentNative]::StartOnConsole("`"$powershell`" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$(Join-Path $script:Root $name)`"", $script:Root)
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
            return @{ ok = $true; reboot = $false }
        }
        default { throw 'Неизвестная команда.' }
    }
}

# ---------- Запуск ----------

Write-Log "Служба запущена, версия $(Get-InstalledVersion)"

# Продолжаем обновление, начатое до перезагрузки
try {
    if ((Get-Pending) -eq 'update') {
        Set-Pending ''
        $filter = Get-UwfFilter
        if ($filter -and $filter.CurrentEnabled) {
            $script:State = 'await-decision'
            $script:Message = 'Обновить не удалось: защита UWF не выключилась.'
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
