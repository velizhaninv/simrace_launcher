#Requires -Version 5.1
<#
  SIMRACE Launcher: полноэкранный выбор игр для гостевой учётной записи.
  Настройки в apps.json. Выход для сотрудника: Ctrl+Shift+F12 и пароль администратора Windows.

  Запуск состоит из двух процессов. Первый следит за вторым и поднимает его заново, если он упал.
  Второй (-Child) показывает окно. Оба защищены от завершения обычным пользователем.
#>
param(
    [switch]$Autostart,                 # запуск при входе: для администраторов лаунчер не открывается
    [switch]$Child,                     # внутренний ключ, вручную не указывать
    [switch]$Boot,                      # внутренний ключ: первые секунды после включения компьютера
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$script:Root    = $PSScriptRoot
# Журнал на диске Z: он не защищён UWF и переживает перезагрузку. Нет доступа к Z: пишем во временную папку.
$script:LogPath = Join-Path $env:TEMP 'SimraceLauncher.log'
try {
    if (Test-Path -LiteralPath 'Z:\') {
        $logFolder = 'Z:\SIMRACE\Logs'
        if (-not (Test-Path -LiteralPath $logFolder)) { New-Item -ItemType Directory -Path $logFolder -Force | Out-Null }
        $logFile = Join-Path $logFolder "$env:COMPUTERNAME-launcher.log"
        # Большой журнал откладываем: хранится текущий и один предыдущий
        if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -gt 5MB) {
            Move-Item -LiteralPath $logFile -Destination "$logFile.old" -Force
        }
        Add-Content -LiteralPath $logFile -Value '' -Encoding UTF8
        $script:LogPath = $logFile
    }
}
catch { $script:LogPath = Join-Path $env:TEMP 'SimraceLauncher.log' }
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:Root 'apps.json' }

function Write-Log([string]$Message) {
    try { Add-Content -LiteralPath $script:LogPath -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) -Encoding UTF8 } catch { }
}

# Для администратора автозапуск не срабатывает. Группа ищется по SID, поэтому
# проверка не зависит от языка Windows и видит администратора и при включённом UAC.
if ($Autostart) {
    $groups = (& whoami.exe /groups) -join "`n"
    if ($groups -match 'S-1-5-32-544') { exit 0 }
}

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Text;
using System.Threading;
using System.Security.Principal;

public static class SimraceNative
{
    private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    private static readonly HookProc Proc = Callback;   // держим ссылку, иначе сборщик мусора удалит делегат
    private static IntPtr hook = IntPtr.Zero;
    public static IntPtr LauncherWindow = IntPtr.Zero;
    private static volatile bool adminRequested = false;
    private static volatile bool mixerRequested = false;
    private static volatile bool menuRequested = false;
    private static readonly bool[] hotkeyRegistered = new bool[3];
    private static readonly uint[] hotkeyKeys = { 0x23, 0x7A, 0x7B };   // End, F11, F12
    public static volatile bool AllowSwitching = false;
    public static volatile bool ServiceMode = false;     // лаунчер свёрнут администратором: клавиши не перехватываем

    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr window, int id);
    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint attach, uint attachTo, bool enable);
    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr window);
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")]
    private static extern bool ShowWindowAsync(IntPtr window, int command);
    private static Thread hookThread = null;
    private static uint hookThreadId = 0;

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int x; public int y; }
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")]
    private static extern int GetMessage(out MSG message, IntPtr window, uint min, uint max);
    [DllImport("user32.dll")]
    private static extern bool PostThreadMessage(uint thread, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int size);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")]
    private static extern bool UnhookWindowsHookEx(IntPtr handle);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr handle, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")]
    private static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll")]
    private static extern int SetWindowLong(IntPtr window, int index, int value);
    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindow(string className, string title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string title);
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string name);
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetKernelObjectSecurity(IntPtr handle, int info, byte[] descriptor, uint length, out uint needed);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool SetKernelObjectSecurity(IntPtr handle, int info, byte[] descriptor);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LogonUser(string user, string domain, string password, int type, int provider, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr buffer, int length, out int needed);

    // Перехват клавиш. Win и Ctrl+Esc закрыты всегда, пока лаунчер запущен, в том числе в игре.
    // Alt+Tab, Alt+Esc и Alt+F4 закрыты, только пока лаунчер на переднем плане.
    // Ctrl+Alt+Del перехватить нельзя: это ограничение Windows.
    // Перехват работает в своём потоке: занятое окно лаунчера не задерживает клавиши в игре,
    // иначе Windows может молча отключить перехват.
    public static bool InstallKeyGuard()
    {
        if (hookThread != null) return hook != IntPtr.Zero;
        ManualResetEvent ready = new ManualResetEvent(false);
        hookThread = new Thread(delegate ()
        {
            hookThreadId = GetCurrentThreadId();
            hook = SetWindowsHookEx(13, Proc, GetModuleHandle(null), 0);   // 13 = WH_KEYBOARD_LL
            MSG message;
            // Системные сочетания клавиш дают лаунчеру право выйти на передний план поверх игры.
            // 0 = Ctrl+Shift+End, 1 = Ctrl+Shift+F11, 2 = Ctrl+Shift+F12. Ctrl=2, Shift=4, без автоповтора=0x4000.
            for (int i = 0; i < 3; i++) hotkeyRegistered[i] = RegisterHotKey(IntPtr.Zero, i, 0x4006, hotkeyKeys[i]);
            ready.Set();
            while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0)
            {
                if (message.message == 0x312) RaiseHotkey(message.wParam.ToInt32());   // 0x312 = WM_HOTKEY
            }
            for (int i = 0; i < 3; i++) UnregisterHotKey(IntPtr.Zero, i);
            if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
        });
        hookThread.IsBackground = true;
        hookThread.Start();
        ready.WaitOne(3000);
        return hook != IntPtr.Zero;
    }

    public static void RemoveKeyGuard()
    {
        if (hookThreadId != 0) PostThreadMessage(hookThreadId, 0x12, IntPtr.Zero, IntPtr.Zero);   // 0x12 = WM_QUIT
    }

    private static IntPtr Callback(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            int vk = Marshal.ReadInt32(lParam);
            int flags = Marshal.ReadInt32(lParam, 8);
            bool alt = (flags & 0x20) != 0;
            bool ctrl = (GetAsyncKeyState(0x11) & 0x8000) != 0;
            bool shift = (GetAsyncKeyState(0x10) & 0x8000) != 0;
            bool front = GetForegroundWindow() == LauncherWindow;

            // Запасной путь, если другая программа уже заняла сочетание
            if (ctrl && shift)
            {
                int id = Array.IndexOf(hotkeyKeys, (uint)vk);
                if (id >= 0 && !hotkeyRegistered[id])
                {
                    if (wParam.ToInt64() == 0x100) RaiseHotkey(id);
                    return new IntPtr(1);
                }
            }

            bool block =
                vk == 0x5B || vk == 0x5C ||                      // Win
                (vk == 0x1B && ctrl) ||                          // Ctrl+Esc и Ctrl+Shift+Esc
                (front && !AllowSwitching && alt && (vk == 0x09 || vk == 0x1B || vk == 0x73));   // Alt+Tab, Alt+Esc, Alt+F4
            if (block && !ServiceMode) return new IntPtr(1);
        }
        return CallNextHookEx(hook, code, wParam, lParam);
    }

    private static void RaiseHotkey(int id)
    {
        if (id == 0) menuRequested = true;
        else if (id == 1) mixerRequested = true;
        else if (id == 2) adminRequested = true;
    }

    // Надёжный вывод окна на передний план: как при Alt+Tab, а не как при обычном запросе программы.
    public static void ForceForeground(IntPtr window)
    {
        if (window == IntPtr.Zero) return;
        if (IsIconic(window)) ShowWindow(window, 9);
        uint self = GetCurrentThreadId();
        uint ignored;
        uint other = GetWindowThreadProcessId(GetForegroundWindow(), out ignored);
        bool attached = other != 0 && other != self && AttachThreadInput(self, other, true);
        BringWindowToTop(window);
        SetForegroundWindow(window);
        if (attached) AttachThreadInput(self, other, false);
        if (GetForegroundWindow() != window)
        {
            // Последний способ: Windows разрешает смену окна сразу после нажатия клавиши Alt
            keybd_event(0x12, 0, 0, UIntPtr.Zero);
            keybd_event(0x12, 0, 2, UIntPtr.Zero);
            SetForegroundWindow(window);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr window);
    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);

    [StructLayout(LayoutKind.Sequential)]
    private struct MONITORINFO { public int Size; public RECT Monitor; public RECT Work; public uint Flags; }
    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll")]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);

    // Растягивает окно игры на весь монитор без рамки. 0: уже так или окно свёрнуто, 1: изменено, -1: Windows отказала.
    public static int ForceBorderless(IntPtr window)
    {
        if (!WindowExists(window) || IsIconic(window)) return 0;
        MONITORINFO info = new MONITORINFO();
        info.Size = Marshal.SizeOf(typeof(MONITORINFO));
        if (!GetMonitorInfo(MonitorFromWindow(window, 2), ref info)) return -1;     // 2 = ближайший монитор
        RECT rect;
        if (!GetWindowRect(window, out rect)) return -1;
        RECT m = info.Monitor;
        if (rect.Left == m.Left && rect.Top == m.Top && rect.Right == m.Right && rect.Bottom == m.Bottom) return 0;
        SetWindowLong(window, -16, GetWindowLong(window, -16) & ~(0x00C00000 | 0x00040000 | 0x00020000 | 0x00010000 | 0x00080000));   // заголовок, рамка, кнопки, меню
        SetWindowLong(window, -20, GetWindowLong(window, -20) & ~(0x00000001 | 0x00000100 | 0x00000200 | 0x00020000));                // края окна
        return SetWindowPos(window, IntPtr.Zero, m.Left, m.Top, m.Right - m.Left, m.Bottom - m.Top, 0x0074) ? 1 : -1;                 // FRAMECHANGED, SHOWWINDOW, NOZORDER, NOACTIVATE
    }

    public static bool WindowExists(IntPtr window) { return window != IntPtr.Zero && IsWindow(window); }

    // Большое окно: не меньше 40% экрана по ширине и высоте. Диалоги и консоль сюда не попадают.
    public static bool IsLargeWindow(IntPtr window)
    {
        RECT rect;
        if (!GetWindowRect(window, out rect)) return false;
        int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
        // Высота нужна для широких мониторов: окно 1920x1080 занимает меньше 40% ширины экрана 32:9
        return (width >= GetSystemMetrics(0) * 0.4 && height >= GetSystemMetrics(1) * 0.4) || height >= GetSystemMetrics(1) * 0.6;
    }

    // Ищет окно запущенной игры: большое, видимое и не принадлежащее служебным программам.
    public static IntPtr FindGameWindow(string[] ignoredProcesses)
    {
        IntPtr result = IntPtr.Zero;
        uint self = (uint)Process.GetCurrentProcess().Id;
        EnumWindows(delegate (IntPtr window, IntPtr parameter)
        {
            if (window == LauncherWindow || !IsWindowVisible(window) || IsIconic(window)) return true;
            if (GetWindow(window, 4) != IntPtr.Zero || !IsLargeWindow(window)) return true;
            int cloaked;
            if (DwmGetWindowAttribute(window, 14, out cloaked, 4) == 0 && cloaked != 0) return true;   // 14 = DWMWA_CLOAKED
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId == self) return true;
            string name = ProcessNameOf(window);
            if (name == "" || Array.IndexOf(ignoredProcesses, name) >= 0) return true;
            result = window;
            return false;
        }, IntPtr.Zero);
        return result;
    }

    // Ищет окно запущенной программы, которое могло открыться за лаунчером: видимое, с заголовком, не служебное.
    public static IntPtr FindAppWindow(string[] ignoredProcesses)
    {
        IntPtr result = IntPtr.Zero;
        uint self = (uint)Process.GetCurrentProcess().Id;
        EnumWindows(delegate (IntPtr window, IntPtr parameter)
        {
            if (window == LauncherWindow || !IsWindowVisible(window) || IsIconic(window)) return true;
            if (GetWindow(window, 4) != IntPtr.Zero || (GetWindowLong(window, -20) & 0x80) != 0) return true;   // владелец, служебное окно
            int cloaked;
            if (DwmGetWindowAttribute(window, 14, out cloaked, 4) == 0 && cloaked != 0) return true;
            StringBuilder title = new StringBuilder(8);
            if (GetWindowText(window, title, 8) == 0) return true;
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId == self) return true;
            string name = ProcessNameOf(window);
            if (name == "" || Array.IndexOf(ignoredProcesses, name) >= 0) return true;
            result = window;
            return false;
        }, IntPtr.Zero);
        return result;
    }

    // Окно Steam с выбором аккаунта или входом. Заставка Steam меньше и сюда не попадает.
    public static IntPtr FindSteamWindow()
    {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate (IntPtr window, IntPtr parameter)
        {
            if (!IsWindowVisible(window)) return true;
            RECT rect;
            if (!GetWindowRect(window, out rect)) return true;
            // Свёрнутое окно не считаем закрытым, хотя его размер уже не настоящий
            if (!IsIconic(window) && (rect.Right - rect.Left < 480 || rect.Bottom - rect.Top < 300)) return true;
            int cloaked;
            if (DwmGetWindowAttribute(window, 14, out cloaked, 4) == 0 && cloaked != 0) return true;
            string name = ProcessNameOf(window);
            if (name != "steam" && name != "steamwebhelper") return true;
            result = window;
            return false;
        }, IntPtr.Zero);
        return result;
    }

    // Скрытое окно программы, убранной в трей: без владельца, с заголовком, самое большое.
    public static IntPtr FindHiddenWindow(int[] processIds)
    {
        IntPtr result = IntPtr.Zero;
        long best = 0;
        EnumWindows(delegate (IntPtr window, IntPtr parameter)
        {
            if (IsWindowVisible(window)) return true;
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (Array.IndexOf(processIds, (int)processId) < 0) return true;
            if (GetWindow(window, 4) != IntPtr.Zero || (GetWindowLong(window, -20) & 0x80) != 0) return true;   // владелец, служебное окно
            StringBuilder title = new StringBuilder(8);
            if (GetWindowText(window, title, 8) == 0) return true;
            StringBuilder kind = new StringBuilder(64);
            GetClassName(window, kind, 64);
            if (kind.ToString().StartsWith("Chrome_WidgetWin")) return true;      // браузер держит скрытые служебные окна
            RECT rect;
            if (!GetWindowRect(window, out rect)) return true;
            long width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
            if (width < 300 || height < 200 || width * height <= best) return true;
            best = width * height;
            result = window;
            return true;
        }, IntPtr.Zero);
        return result;
    }

    // Возвращает скрытое окно на экран. false: Windows не дала это сделать, например программа запущена от администратора.
    public static bool ShowHiddenWindow(IntPtr window)
    {
        ShowWindow(window, 9);      // 9 = SW_RESTORE
        ShowWindow(window, 5);      // 5 = SW_SHOW
        if (!IsWindowVisible(window)) return false;
        ForceForeground(window);
        return true;
    }

    // Заголовок и размер окна для журнала
    public static string DescribeWindow(IntPtr window)
    {
        StringBuilder title = new StringBuilder(128);
        GetWindowText(window, title, 128);
        RECT rect;
        GetWindowRect(window, out rect);
        return ProcessNameOf(window) + ", \"" + title + "\", " + (rect.Right - rect.Left) + "x" + (rect.Bottom - rect.Top);
    }

    // Убирает окно лаунчера под все окна, активность при щелчке не отключает.
    public static void SendToBack()
    {
        if (LauncherWindow != IntPtr.Zero) SetWindowPos(LauncherWindow, new IntPtr(1), 0, 0, 0, 0, 0x0013);
    }

    public static int ProcessIdOf(IntPtr window)
    {
        uint processId;
        GetWindowThreadProcessId(window, out processId);
        return (int)processId;
    }

    public static void RequestClose(IntPtr window)
    {
        if (window != IntPtr.Zero) PostMessage(window, 0x10, IntPtr.Zero, IntPtr.Zero);   // 0x10 = WM_CLOSE
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetKeyboardLayout(uint thread);

    // Язык ввода активного окна: раскладка в Windows может быть своей у каждого окна
    public static string CurrentLanguage()
    {
        try
        {
            uint processId;
            uint thread = GetWindowThreadProcessId(GetForegroundWindow(), out processId);
            int language = (int)(GetKeyboardLayout(thread).ToInt64() & 0xFFFF);
            return new System.Globalization.CultureInfo(language).TwoLetterISOLanguageName.ToUpperInvariant();
        }
        catch (Exception) { return ""; }
    }

    public static string ProcessNameOf(IntPtr window)
    {
        uint processId;
        GetWindowThreadProcessId(window, out processId);
        try { return Process.GetProcessById((int)processId).ProcessName.ToLowerInvariant(); }
        catch (ArgumentException) { return ""; }
    }

    public static bool TakeAdminRequest()
    {
        bool requested = adminRequested;
        adminRequested = false;
        return requested;
    }

    public static bool TakeMixerRequest()
    {
        bool requested = mixerRequested;
        mixerRequested = false;
        return requested;
    }

    public static bool TakeMenuRequest()
    {
        bool requested = menuRequested;
        menuRequested = false;
        return requested;
    }

    public static IntPtr CurrentForeground() { return GetForegroundWindow(); }

    public static bool IsMinimized(IntPtr window) { return IsIconic(window); }

    public static void Minimize(IntPtr window) { ShowWindowAsync(window, 6); }   // 6 = SW_MINIMIZE, игра могла зависнуть

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder name, int size);

    // Сворачивает все обычные окна, кроме лаунчера и окна $keep: при запуске игры видно только то, что нужно.
    public static void MinimizeOtherWindows(IntPtr keep)
    {
        uint self = (uint)Process.GetCurrentProcess().Id;
        EnumWindows(delegate (IntPtr window, IntPtr parameter)
        {
            if (window == LauncherWindow || window == keep) return true;
            if (!IsWindowVisible(window) || IsIconic(window)) return true;
            if (GetWindow(window, 4) != IntPtr.Zero) return true;                     // 4 = GW_OWNER, диалоги свернутся с владельцем
            if ((GetWindowLong(window, -20) & 0x80) != 0) return true;                // 0x80 = служебное окно
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId == self) return true;
            StringBuilder title = new StringBuilder(8);
            if (GetWindowText(window, title, 8) == 0) return true;
            StringBuilder name = new StringBuilder(64);
            GetClassName(window, name, 64);
            string kind = name.ToString();
            if (kind == "Progman" || kind == "WorkerW" || kind == "Shell_TrayWnd" || kind == "Shell_SecondaryTrayWnd") return true;
            ShowWindowAsync(window, 6);
            return true;
        }, IntPtr.Zero);
    }

    // Закрывает главное окно Steam. Steam при этом продолжает работать в фоне.
    public static void CloseSteamMainWindow()
    {
        EnumWindows(delegate (IntPtr window, IntPtr parameter)
        {
            if (!IsWindowVisible(window)) return true;
            StringBuilder title = new StringBuilder(64);
            GetWindowText(window, title, 64);
            if (title.ToString() != "Steam") return true;
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            try
            {
                string name = Process.GetProcessById((int)processId).ProcessName.ToLowerInvariant();
                if (name == "steam" || name == "steamwebhelper") PostMessage(window, 0x10, IntPtr.Zero, IntPtr.Zero);   // 0x10 = WM_CLOSE
            }
            catch (ArgumentException) { }
            return true;
        }, IntPtr.Zero);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct JOYCAPS
    {
        public ushort wMid, wPid;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname;
        public uint xMin, xMax, yMin, yMax, zMin, zMax, numButtons, periodMin, periodMax, rMin, rMax, uMin, uMax, vMin, vMax, caps, maxAxes, numAxes, maxButtons;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szRegKey;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szOEMVxD;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct JOYINFOEX
    {
        public uint size, flags, x, y, z, r, u, v, buttons, buttonNumber, pov, reserved1, reserved2;
    }
    [DllImport("winmm.dll")]
    private static extern uint joyGetNumDevs();
    [DllImport("winmm.dll", CharSet = CharSet.Unicode, EntryPoint = "joyGetDevCapsW")]
    private static extern uint joyGetDevCaps(UIntPtr id, ref JOYCAPS caps, uint size);
    [DllImport("winmm.dll")]
    private static extern uint joyGetPosEx(uint id, ref JOYINFOEX info);

    // Номера подключённых устройств производителя. VID лежит в поле wMid.
    public static int[] FindJoysticks(int vendor)
    {
        System.Collections.Generic.List<int> found = new System.Collections.Generic.List<int>();
        uint count = joyGetNumDevs();
        for (uint id = 0; id < count && id < 32; id++)
        {
            JOYCAPS caps = new JOYCAPS();
            if (joyGetDevCaps(new UIntPtr(id), ref caps, (uint)Marshal.SizeOf(typeof(JOYCAPS))) != 0) continue;
            JOYINFOEX info = new JOYINFOEX();
            info.size = (uint)Marshal.SizeOf(typeof(JOYINFOEX));
            info.flags = 0xFF;
            if (joyGetPosEx(id, ref info) != 0) continue;     // записи в реестре без подключённого устройства
            if (caps.wMid == vendor) found.Add((int)id);
        }
        return found.ToArray();
    }

    // Все подключённые игровые устройства для журнала
    public static string DescribeJoysticks()
    {
        StringBuilder text = new StringBuilder();
        uint count = joyGetNumDevs();
        for (uint id = 0; id < count && id < 32; id++)
        {
            JOYCAPS caps = new JOYCAPS();
            if (joyGetDevCaps(new UIntPtr(id), ref caps, (uint)Marshal.SizeOf(typeof(JOYCAPS))) != 0) continue;
            JOYINFOEX info = new JOYINFOEX();
            info.size = (uint)Marshal.SizeOf(typeof(JOYINFOEX));
            info.flags = 0xFF;
            if (joyGetPosEx(id, ref info) != 0) continue;
            text.AppendFormat("#{0} {1:X4}:{2:X4} осей {3}; ", id, caps.wMid, caps.wPid, caps.numAxes);
        }
        return text.ToString();
    }

    // Значения осей X, Y, Z, R, U, V от 0 до 65535. null: устройство не отвечает.
    public static int[] ReadJoystick(int id)
    {
        JOYINFOEX info = new JOYINFOEX();
        info.size = (uint)Marshal.SizeOf(typeof(JOYINFOEX));
        info.flags = 0xFF;
        if (joyGetPosEx((uint)id, ref info) != 0) return null;
        return new int[] { (int)info.x, (int)info.y, (int)info.z, (int)info.r, (int)info.u, (int)info.v };
    }

    // Окно службы открывается за лаунчером, Windows не даёт ему выйти вперёд самому
    public static bool ActivateByTitle(string title)
    {
        IntPtr window = FindWindow(null, title);
        if (window == IntPtr.Zero) return false;
        ForceForeground(window);
        return true;
    }

    public static void ActivateWindow(IntPtr window)
    {
        if (window != IntPtr.Zero && window != LauncherWindow) ForceForeground(window);
    }

    // Скрывает или возвращает панель задач на всех мониторах.
    public static void SetTaskbarVisible(bool visible)
    {
        SetBarVisible(FindWindow("Shell_TrayWnd", null), visible);
        IntPtr bar = IntPtr.Zero;
        while ((bar = FindWindowEx(IntPtr.Zero, bar, "Shell_SecondaryTrayWnd", null)) != IntPtr.Zero)
            SetBarVisible(bar, visible);
    }

    private static void SetBarVisible(IntPtr bar, bool visible)
    {
        if (bar != IntPtr.Zero && IsWindowVisible(bar) != visible) ShowWindow(bar, visible ? 5 : 0);   // 5 = SW_SHOW, 0 = SW_HIDE
    }

    public static void BringToFront(IntPtr window)
    {
        ForceForeground(window);
    }

    // Пока идёт игра, окно лаунчера лежит под всеми окнами и не активируется по щелчку.
    // Диалоги и окна игр всегда остаются поверх него, а рабочий стол закрыт.
    public static void SetBackground(bool enabled)
    {
        if (LauncherWindow == IntPtr.Zero) return;
        const int GWL_EXSTYLE = -20;
        const int WS_EX_NOACTIVATE = 0x08000000;
        int style = GetWindowLong(LauncherWindow, GWL_EXSTYLE);
        if (enabled)
        {
            SetWindowLong(LauncherWindow, GWL_EXSTYLE, style | WS_EX_NOACTIVATE);
            SetWindowPos(LauncherWindow, new IntPtr(1), 0, 0, 0, 0, 0x0013);   // HWND_BOTTOM, без перемещения и активации
        }
        else
        {
            SetWindowLong(LauncherWindow, GWL_EXSTYLE, style & ~WS_EX_NOACTIVATE);
        }
    }

    // Запрещает всем завершать этот процесс. Диспетчер задач и taskkill получат отказ в доступе.
    public static bool ProtectProcess()
    {
        try
        {
            IntPtr self = GetCurrentProcess();
            uint needed;
            GetKernelObjectSecurity(self, 4, null, 0, out needed);
            byte[] current = new byte[needed];
            if (!GetKernelObjectSecurity(self, 4, current, needed, out needed)) return false;
            RawSecurityDescriptor descriptor = new RawSecurityDescriptor(current, 0);
            descriptor.DiscretionaryAcl.InsertAce(0, new CommonAce(AceFlags.None, AceQualifier.AccessDenied, 1,
                new SecurityIdentifier(WellKnownSidType.WorldSid, null), false, null));   // 1 = PROCESS_TERMINATE
            byte[] updated = new byte[descriptor.BinaryLength];
            descriptor.GetBinaryForm(updated, 0);
            return SetKernelObjectSecurity(self, 4, updated);
        }
        catch { return false; }
    }

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
                // При включённом UAC группа тоже есть в списке, поэтому её атрибуты не проверяем
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
}
'@

if (-not [SimraceNative]::ProtectProcess()) { Write-Log 'Не удалось включить защиту процесса' }

# Возвращает панель задач. Проводник перезапускается, потому что после скрытия панель
# может не появиться сама. На запущенные игры и программы это не влияет.
function Restore-Shell {
    [SimraceNative]::SetTaskbarVisible($true)
    $session = (Get-Process -Id $PID).SessionId
    Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })) {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe')
    }
    Write-Log 'Проводник перезапущен, панель задач возвращена'
}

# ---------- Сторож: поднимает окно заново, если процесс упал или был завершён ----------

if (-not $Child) {
    try {
        $arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`" -Child -ConfigPath `"$ConfigPath`"$(if ($Autostart) { ' -Boot' })"
        $restarts = New-Object System.Collections.ArrayList
        # Панель задач скрыта всё время работы лаунчера
        [SimraceNative]::SetTaskbarVisible($false)
        while ($true) {
            $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
            $null = $process.Handle      # без этого ExitCode будет пустым
            # Окно может зависнуть, не падая. Windows отвечает, реагирует ли окно на сообщения (ждёт до 5 секунд).
            $hung = 0
            while (-not $process.WaitForExit(5000)) {
                $responding = $true
                try {
                    $process.Refresh()
                    $responding = $process.Responding
                }
                catch { continue }      # процесс как раз завершился
                if ($responding) {
                    if ($hung -gt 0) { Write-Log "Окно снова отвечает после $($hung * 5) с" }
                    $hung = 0
                    continue
                }
                $hung++
                if ($hung -eq 1) { Write-Log 'Окно лаунчера не отвечает' }
                if ($hung -ge 6) {
                    Write-Log 'Окно не отвечает 30 секунд, перезапускаю'
                    # Защита процесса не мешает: права на завершение у сторожа есть с момента запуска окна
                    try { $process.Kill() }
                    catch { Write-Log "Зависшее окно не завершено: $_" }
                    $process.WaitForExit()
                    break
                }
            }
            Write-Log "Окно завершилось с кодом $($process.ExitCode)"
            if ($process.ExitCode -eq 0) { exit 0 }     # код 0 только у штатного выхода

            $now = Get-Date
            [void]$restarts.Add($now)
            if (@($restarts | Where-Object { ($now - $_).TotalSeconds -lt 60 }).Count -ge 5) {
                Write-Log 'Пять падений за минуту, перезапуск остановлен'
                Restore-Shell
                exit 1
            }
            Start-Sleep -Seconds 2
        }
    }
    catch {
        Write-Log "Ошибка сторожа: $_"
        exit 1
    }
    finally {
        # Запасной путь: панель не должна остаться скрытой при любом выходе сторожа
        [SimraceNative]::SetTaskbarVisible($true)
    }
}

# ---------- Окно ----------

$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\SimraceLauncher')
$owned = $false
try { $owned = $script:Mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $owned = $true }     # прошлое окно завершилось аварийно
if (-not $owned) { exit 0 }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ---------- Steam ----------

function Get-SteamRoot {
    $candidates = @()
    $hkcu = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
    if ($hkcu -and $hkcu.SteamPath) { $candidates += ($hkcu.SteamPath -replace '/', '\') }
    $hklm = Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue
    if ($hklm -and $hklm.InstallPath) { $candidates += $hklm.InstallPath }
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $path 'steam.exe')) { return $path }
    }
    return $null
}

function Get-SteamLibraries([string]$SteamRoot) {
    if (-not $SteamRoot) { return @() }
    $libraries = @($SteamRoot)
    $vdf = Join-Path $SteamRoot 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $text = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
        foreach ($match in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
            $libraries += ($match.Groups[1].Value -replace '\\\\', '\')
        }
    }
    return @($libraries | Sort-Object -Unique)
}

# Папка установленной игры Steam. Если игры нет на этом компьютере, вернётся $null.
function Get-SteamAppDir([string]$AppId) {
    if ($script:SteamDirs.ContainsKey($AppId)) { return $script:SteamDirs[$AppId] }
    $result = $null
    foreach ($library in $script:SteamLibraries) {
        $manifest = Join-Path $library "steamapps\appmanifest_$AppId.acf"
        if (-not (Test-Path -LiteralPath $manifest)) { continue }
        $text = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8
        $match = [regex]::Match($text, '"installdir"\s+"([^"]+)"')
        if ($match.Success) {
            $result = Join-Path $library ("steamapps\common\" + $match.Groups[1].Value)
            break
        }
    }
    $script:SteamDirs[$AppId] = $result
    return $result
}

function Get-SteamProcesses {
    return @(Get-Process -Name 'steam', 'steamwebhelper' -ErrorAction SilentlyContinue)
}

# Логин аккаунта, под которым Steam работает сейчас. Если вход не выполнен, вернётся $null.
function Get-SteamActiveAccount {
    $value = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam\ActiveProcess' -Name ActiveUser -ErrorAction SilentlyContinue
    if (-not $value -or -not $value.ActiveUser) { return $null }
    $activeId = [long][BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$value.ActiveUser), 0)

    $vdf = Join-Path $script:SteamRoot 'config\loginusers.vdf'
    if (-not (Test-Path -LiteralPath $vdf)) { return $null }
    $text = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
    foreach ($block in [regex]::Matches($text, '"(\d{17})"\s*\{([^}]*)\}')) {
        # В реестре хранятся младшие 32 бита SteamID64
        if (([long]$block.Groups[1].Value -band [long]4294967295) -eq $activeId) {
            $name = [regex]::Match($block.Groups[2].Value, '"AccountName"\s+"([^"]+)"')
            if ($name.Success) { return $name.Groups[1].Value }
        }
    }
    return $null
}

# Меняет поле в блоке аккаунта. Если поля нет, добавляет его.
function Set-VdfField([string]$Block, [string]$Name, [string]$Value) {
    $pattern = '(?i)("' + $Name + '"\s+)"[^"]*"'
    if ([regex]::IsMatch($Block, $pattern)) { return [regex]::Replace($Block, $pattern, ('${1}"' + $Value + '"')) }
    $closing = $Block.LastIndexOf('}')
    return $Block.Insert($closing, "`t`"$Name`"`t`t`"$Value`"`r`n`t")
}

# Делает аккаунт основным для следующего запуска Steam. Вход должен быть сохранён заранее.
function Set-SteamAccount([string]$Account) {
    Set-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name AutoLoginUser -Value $Account -Type String
    Set-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name RememberPassword -Value 1 -Type DWord
    # После аварийного закрытия Steam здесь мог остаться прежний аккаунт
    Set-ItemProperty -Path 'HKCU:\Software\Valve\Steam\ActiveProcess' -Name ActiveUser -Value 0 -Type DWord -ErrorAction SilentlyContinue

    $vdf = Join-Path $script:SteamRoot 'config\loginusers.vdf'
    try {
        $text = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
        $updated = [regex]::Replace($text, '"\d{17}"\s*\{[^}]*\}', {
            param($match)
            $block = $match.Value
            $isTarget = [regex]::IsMatch($block, '"AccountName"\s+"' + [regex]::Escape($Account) + '"', 'IgnoreCase')
            $recent = if ($isTarget) { '1' } else { '0' }
            $block = Set-VdfField $block 'MostRecent' $recent
            if ($isTarget) {
                foreach ($field in 'RememberPassword', 'AllowAutoLogin') { $block = Set-VdfField $block $field '1' }
                foreach ($field in 'WantsOfflineMode', 'SkipOfflineModeWarning') { $block = Set-VdfField $block $field '0' }
                $block = Set-VdfField $block 'Timestamp' ([string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
            }
            return $block
        })
        [System.IO.File]::WriteAllText($vdf, $updated, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { Write-Log "Не удалось изменить loginusers.vdf: $_" }
}

# Выполнен ли вход в Steam под любым аккаунтом.
function Test-SteamLoggedIn {
    $value = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam\ActiveProcess' -Name ActiveUser -ErrorAction SilentlyContinue
    return [bool]($value -and $value.ActiveUser)
}

# Убирает автовход, чтобы при следующем запуске Steam показал своё окно выбора аккаунта.
# Сохранённые входы при этом остаются.
function Clear-SteamAutoLogin {
    Set-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name AutoLoginUser -Value '' -Type String
    # После аварийного закрытия Steam здесь мог остаться прежний аккаунт
    Set-ItemProperty -Path 'HKCU:\Software\Valve\Steam\ActiveProcess' -Name ActiveUser -Value 0 -Type DWord -ErrorAction SilentlyContinue
    $vdf = Join-Path $script:SteamRoot 'config\loginusers.vdf'
    try {
        if (Test-Path -LiteralPath $vdf) {
            $text = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
            $updated = [regex]::Replace($text, '("MostRecent"\s+)"\d"', '$1"0"', 'IgnoreCase')
            [System.IO.File]::WriteAllText($vdf, $updated, (New-Object System.Text.UTF8Encoding($false)))
        }
    }
    catch { Write-Log "Не удалось изменить loginusers.vdf: $_" }
}

# Аккаунт для игры. Сначала ищем запись этого компьютера, затем общую запись "default".
function Get-AppAccount([string]$AppId) {
    $map = $script:Config.steamAccounts
    if (-not $map) { return $null }
    foreach ($scope in $env:COMPUTERNAME, 'default') {
        $section = $map.$scope
        if ($section -and $section.$AppId) { return [string]$section.$AppId }
    }
    return $null
}

# ---------- Поиск программ ----------

# Раскрывает %ПЕРЕМЕННЫЕ%, {steam:ID} и маски. Возвращает первый найденный файл или $null.
# Файлы рядом с программой, которые нельзя принимать за неё: удаление, обновление, отчёты об ошибках
$script:NotProgramNames = '(?i)unins|updat|crash|setup'

function Resolve-AppPath([string]$Path) {
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    foreach ($match in [regex]::Matches($expanded, '\{steam:(\d+)\}')) {
        $dir = Get-SteamAppDir $match.Groups[1].Value
        if (-not $dir) { return $null }
        $expanded = $expanded.Replace($match.Value, $dir)
    }
    $found = Get-Item -Path $expanded -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer -and $_.BaseName -notmatch $script:NotProgramNames } | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

# Все ярлыки: сначала рабочий стол текущего пользователя (C:\Users\<имя>\Desktop), затем своя папка shortcuts и общий рабочий стол.
function Get-AvailableShortcuts {
    if ($script:Shortcuts) { return $script:Shortcuts }
    $userDesktops = @((Join-Path $env:USERPROFILE 'Desktop'), [Environment]::GetFolderPath('Desktop')) | Where-Object { $_ } | Select-Object -Unique
    $folders = @($userDesktops) + @((Join-Path $script:Root 'shortcuts'), [Environment]::GetFolderPath('CommonDesktopDirectory'))
    $list = @()
    $shell = New-Object -ComObject WScript.Shell
    foreach ($folder in $folders) {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue) {
            if ($file.Extension -ne '.lnk' -and $file.Extension -ne '.url') { continue }
            if ($file.BaseName -like 'Настройки лаунчера*') { continue }
            $target = ''
            try {
                if ($file.Extension -eq '.lnk') { $target = $shell.CreateShortcut($file.FullName).TargetPath }
                else {
                    $line = Select-String -LiteralPath $file.FullName -Pattern '^URL=(.*)$' | Select-Object -First 1
                    if ($line) { $target = $line.Matches[0].Groups[1].Value }
                }
            }
            catch { Write-Log "Не прочитан ярлык $($file.FullName): $_" }
            # Ярлык, перенесённый с другого компьютера, может вести на файл, которого здесь нет
            if ($file.Extension -eq '.lnk' -and $target -and -not (Test-Path -LiteralPath $target)) {
                Write-Log "Пропущен ярлык на несуществующий файл: $($file.FullName) -> $target"
                continue
            }
            $targetName = if ($target -like '*.exe') { [IO.Path]::GetFileNameWithoutExtension($target) } else { '' }
            $list += [pscustomobject]@{ Path = $file.FullName; Name = $file.BaseName; Target = $target; TargetName = $targetName; OnUserDesktop = ($userDesktops -contains $folder) }
            Write-Log "Найден ярлык: $($file.FullName) -> $target"
        }
    }
    $script:Shortcuts = $list
    return $list
}

# Ищет ярлык для плитки. Рабочий стол пользователя важнее остальных папок.
# Внутри папок: сначала маски из apps.json (имя ярлыка или файл, на который он указывает), затем точное название плитки.
# Выделенные серверы в Steam не используются, поэтому ярлыки серверов к играм не привязываются.
function Find-AppShortcut($App) {
    $all = @(Get-AvailableShortcuts | Where-Object { "$($_.Name) $($_.TargetName)" -notmatch $script:NotProgramNames })
    if ([string]$App.id -notlike '*-extra') {
        $all = @($all | Where-Object { "$($_.Name) $($_.TargetName)" -notmatch '(?i)dedicated|server' })
    }
    foreach ($group in @(@($all | Where-Object { $_.OnUserDesktop }), @($all | Where-Object { -not $_.OnUserDesktop }))) {
        foreach ($mask in @($App.shortcut | Where-Object { $_ })) {
            $found = @($group) | Where-Object { $_.Name -like $mask -or ($_.TargetName -and $_.TargetName -like $mask) } | Select-Object -First 1
            if ($found) { return $found }
        }
        if (-not $App.requireShortcut) {
            $found = @($group) | Where-Object { $_.Name -eq $App.name } | Select-Object -First 1
            if ($found) { return $found }
        }
    }
    return $null
}

function Find-Cover($App) {
    foreach ($extension in 'jpg', 'jpeg', 'png') {
        $own = Join-Path $script:Root "images\$($App.id).$extension"
        if (Test-Path -LiteralPath $own) { return $own }
    }
    # Запасной вариант: обложка из локального кэша Steam
    $coverId = if ($App.steamAppId) { $App.steamAppId } else { $App.coverSteamAppId }
    if ($coverId -and $script:SteamRoot) {
        $cache = Join-Path $script:SteamRoot "appcache\librarycache\$coverId"
        if (Test-Path -LiteralPath $cache) {
            $file = Get-ChildItem -LiteralPath $cache -Recurse -Filter 'library_600x900*.jpg' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($file) { return $file.FullName }
        }
        $old = Join-Path $script:SteamRoot "appcache\librarycache\${coverId}_library_600x900.jpg"
        if (Test-Path -LiteralPath $old) { return $old }
    }
    return $null
}

# Порядок поиска: ярлык с рабочего стола, файл из paths, игра Steam.
# Если ничего не найдено, плитка на этом компьютере не показывается.
function Resolve-App($App) {
    if ($App.enabled -eq $false) { return $null }
    $watch = @($App.watch | Where-Object { $_ })
    $common = @{ Id = $App.id; Name = $App.name; Account = Get-AppAccount $App.id; Cover = Find-Cover $App; AskAccount = $App.askSteamAccount; ExitGrace = $App.exitGraceSeconds; Info = [string]$App.info; LaunchTimeout = $App.launchTimeoutSeconds; Extra = $null; ForceFullscreen = $App.forceFullscreen; Category = [string]$App.category; HostProcess = @($App.hostProcess | Where-Object { $_ }) }
    if ($App.extra) {
        try { $common.Extra = Resolve-App $App.extra }
        catch { Write-Log "$($App.name): ошибка дополнительной кнопки: $_" }
        if (-not $common.Extra) { Write-Log "$($App.name): не найдена программа для кнопки «$($App.extra.name)»" }
    }

    $shortcut = Find-AppShortcut $App
    if ($shortcut) {
        # Ярлык может вести на steam.exe: Steam и служебные программы процессами игры не считаем
        if ($shortcut.TargetName -and $script:NotGameProcesses -notcontains $shortcut.TargetName.ToLowerInvariant()) {
            $watch += $shortcut.TargetName
            # Content Manager могут запускать файлом с другим именем: такую программу тоже считаем оболочкой игры
            if (@($common.HostProcess).Count -gt 0) { $common.HostProcess = @($common.HostProcess) + $shortcut.TargetName }
        }
        Write-Log "$($App.name): запуск через ярлык $($shortcut.Path)"
        return [pscustomobject]($common + @{ Kind = 'shortcut'; Exe = $shortcut.Path; Args = $null; SteamAppId = $App.steamAppId; Watch = @($watch | Sort-Object -Unique) })
    }
    if ($App.shortcut) { Write-Log "$($App.name): подходящий ярлык не найден" }
    foreach ($path in @($App.paths | Where-Object { $_ })) {
        $exe = Resolve-AppPath $path
        if ($exe) {
            Write-Log "$($App.name): запуск файла $exe"
            $watch = @($watch + [IO.Path]::GetFileNameWithoutExtension($exe) | Sort-Object -Unique)
            return [pscustomobject]($common + @{ Kind = 'exe'; Exe = $exe; Args = $App.args; SteamAppId = $App.steamAppId; Watch = $watch })
        }
    }
    # Программа, которую нельзя заменить прямым запуском игры (Assetto Corsa только через Content Manager)
    if ($App.requireShortcut) {
        if ($App.steamAppId -and -not (Get-SteamAppDir ([string]$App.steamAppId))) { return $null }
        Write-Log "$($App.name): не найден ярлык или файл, прямой запуск запрещён"
        return [pscustomobject]($common + @{ Kind = 'missing'; Exe = $null; Args = $null; SteamAppId = $App.steamAppId; Watch = $watch })
    }
    if ($App.steamAppId -and $script:SteamExe -and (Get-SteamAppDir ([string]$App.steamAppId))) {
        Write-Log "$($App.name): запуск напрямую через Steam"
        return [pscustomobject]($common + @{ Kind = 'steam'; Exe = $script:SteamExe; Args = $null; SteamAppId = [string]$App.steamAppId; Watch = $watch })
    }
    return $null
}

# ---------- Запуск и отслеживание сессии ----------

# Экран ожидания: без кнопок в центре. Надпись для отмены появится в углу через 20 секунд, для администратора.
function Show-Waiting([string]$Title, [string]$Text, [string]$CornerText) {
    $TxtOverlayTitle.Text = $Title
    $TxtOverlayText.Text = $Text
    $TxtOverlayText.Visibility = 'Visible'
    $WaitSpinner.Visibility = 'Visible'
    $OverlayLine.Visibility = 'Collapsed'
    $BtnOverlay.Visibility = 'Collapsed'
    $BtnOverlayCorner.Content = $CornerText
    $BtnOverlayCorner.Visibility = 'Collapsed'
    $script:WaitCornerAt = (Get-Date).AddSeconds(20)
    $Overlay.Visibility = 'Visible'
    [System.Windows.Input.Keyboard]::ClearFocus()
}

function Show-Overlay([string]$Title, [string]$Text, [string]$ButtonText) {
    $WaitSpinner.Visibility = 'Collapsed'
    $OverlayLine.Visibility = 'Visible'
    $BtnOverlay.Visibility = 'Visible'
    $BtnOverlayCorner.Visibility = 'Collapsed'
    $TxtOverlayTitle.Text = $Title
    $TxtOverlayText.Text = $Text
    $TxtOverlayText.Visibility = 'Visible'
    $BtnOverlay.Content = $ButtonText
    $Overlay.Visibility = 'Visible'
    [void]$BtnOverlay.Focus()
}

function Restore-LauncherWindow {
    if ($script:ServiceMode) { return }     # лаунчер свернул администратор: не выскакиваем поверх его работы
    [SimraceNative]::SetBackground($false)
    # Краткий Topmost поднимает окно поверх Steam, Windows не всегда отдаёт фокус без него
    $Window.Topmost = $true
    [SimraceNative]::ForceForeground([SimraceNative]::LauncherWindow)
    $Window.Topmost = $false
    if ($script:LastTile -and $Overlay.Visibility -ne 'Visible') { [void]$script:LastTile.Focus() }
}

function Stop-Session {
    Hide-GameBar
    $script:Session = $null
    Start-LedAmbient
    $Overlay.Visibility = 'Collapsed'
    Restore-LauncherWindow
}

function Stop-SessionWithError([string]$Title, [string]$Text) {
    Hide-GameBar
    $script:Session = $null
    Start-LedAmbient
    Show-Overlay $Title $Text 'Закрыть'
    Restore-LauncherWindow
}

function Set-SessionStage([string]$Stage) {
    $script:Session.Stage = $Stage
    $script:Session.StageStart = Get-Date
}

# Запускает ярлык или файл. Для файла возвращает процесс.
function Start-AppTarget($App) {
    if ($App.Kind -eq 'shortcut') {
        # Как двойной щелчок: рабочую папку и параметры задаёт сам ярлык
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $App.Exe
        $info.UseShellExecute = $true
        [void][System.Diagnostics.Process]::Start($info)
        return $null
    }
    $start = @{ FilePath = $App.Exe; WorkingDirectory = (Split-Path -Parent $App.Exe); PassThru = $true }
    if ($App.Args) { $start.ArgumentList = @($App.Args) }
    return (Start-Process @start)
}

# Значки кнопок верхней панели
$script:ToolIcons = @{
    volume     = '<Path Data="M3,9 H7 L12,5 V19 L7,15 H3 Z" Fill="#C82F03"/><Path Data="M15.5,9 A4,4 0 0 1 15.5,15 M18,6.5 A8,8 0 0 1 18,17.5" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>'
    headphones = '<Path Data="M3.5,15 V12 A8.5,8.5 0 0 1 20.5,12 V15" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Rectangle Canvas.Left="2" Canvas.Top="13.5" Width="5.5" Height="8" RadiusX="1.8" RadiusY="1.8" Fill="#C82F03"/><Rectangle Canvas.Left="16.5" Canvas.Top="13.5" Width="5.5" Height="8" RadiusX="1.8" RadiusY="1.8" Fill="#C82F03"/>'
    home       = '<Path Data="M3,12 L12,4 L21,12 M6,10 V20 H18 V10" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>'
    close      = '<Ellipse Canvas.Left="2.5" Canvas.Top="2.5" Width="19" Height="19" Stroke="#E2450F" StrokeThickness="2"/><Path Data="M8.5,8.5 L15.5,15.5 M15.5,8.5 L8.5,15.5" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>'
    globe      = '<Ellipse Canvas.Left="2.5" Canvas.Top="2.5" Width="19" Height="19" Stroke="White" StrokeThickness="2"/><Path Data="M3,12 H21 M12,3 C15,6 16,9 16,12 C16,15 15,18 12,21 C9,18 8,15 8,12 C8,9 9,6 12,3" Stroke="#C82F03" StrokeThickness="2"/>'
    gear       = '<Path Data="M12,2 V5 M12,19 V22 M2,12 H5 M19,12 H22 M4.9,4.9 L7,7 M17,17 L19.1,19.1 M4.9,19.1 L7,17 M17,7 L19.1,4.9" Stroke="White" StrokeThickness="2.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/><Ellipse Canvas.Left="5.5" Canvas.Top="5.5" Width="13" Height="13" Stroke="White" StrokeThickness="2"/><Ellipse Canvas.Left="9.5" Canvas.Top="9.5" Width="5" Height="5" Fill="#C82F03"/>'
    shield     = '<Path Data="M12,2.5 L20,5.5 V11 C20,16 16.5,19.8 12,21.5 C7.5,19.8 4,16 4,11 V5.5 Z" Stroke="White" StrokeThickness="2" StrokeLineJoin="Round"/><Path Data="M8.5,11.5 L11,14 L15.5,9" Stroke="#C82F03" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>'
    lan        = '<Path Data="M12,8 V13 M5,17 V13 H19 V17" Stroke="White" StrokeThickness="2" StrokeLineJoin="Round"/><Rectangle Canvas.Left="8.5" Canvas.Top="2.5" Width="7" Height="6" RadiusX="1.2" RadiusY="1.2" Fill="#C82F03"/><Rectangle Canvas.Left="1.5" Canvas.Top="16" Width="7" Height="6" RadiusX="1.2" RadiusY="1.2" Fill="#C82F03"/><Rectangle Canvas.Left="15.5" Canvas.Top="16" Width="7" Height="6" RadiusX="1.2" RadiusY="1.2" Fill="#C82F03"/>'
    wheel      = '<Ellipse Canvas.Left="2.5" Canvas.Top="2.5" Width="19" Height="19" Stroke="White" StrokeThickness="2"/><Ellipse Canvas.Left="9" Canvas.Top="9" Width="6" Height="6" Fill="#C82F03"/><Path Data="M3,11 H9.5 M14.5,11 H21 M12,15 V21" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>'
}

# Кнопка в оверлее поверх игры
function New-PanelButton([string]$Text, [string]$Icon, $Tag, [scriptblock]$OnClick) {
    $button = New-Object System.Windows.Controls.Button
    $button.Style = $MixerWindow.FindResource('PanelButton')
    $button.Tag = $Tag
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Orientation = 'Horizontal'
    $iconXaml = $script:ToolIcons[$Icon]
    if (-not $iconXaml) { $iconXaml = $script:ToolIcons['wheel'] }
    $canvas = [Windows.Markup.XamlReader]::Parse('<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="24" Height="24" VerticalAlignment="Center">' + $iconXaml + '</Canvas>')
    [void]$panel.Children.Add($canvas)
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.VerticalAlignment = 'Center'
    $label.Margin = New-Object System.Windows.Thickness(9, 0, 0, 0)
    [void]$panel.Children.Add($label)
    $button.Content = $panel
    $button.Add_Click($OnClick)
    [void]$PanelTools.Children.Add($button)
    return $button
}

function New-ToolButton([string]$Text, [string]$Icon, $Tag, [scriptblock]$OnClick, [switch]$IconOnly) {
    $button = New-Object System.Windows.Controls.Button
    $button.Style = $Window.FindResource('ToolButton')
    $button.Tag = $Tag
    $button.Margin = New-Object System.Windows.Thickness(0, 0, 14, 0)
    $button.ToolTip = $Text

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Orientation = 'Horizontal'
    $iconXaml = $script:ToolIcons[$Icon]
    if (-not $iconXaml) { $iconXaml = $script:ToolIcons['wheel'] }
    $canvas = [Windows.Markup.XamlReader]::Parse('<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="24" Height="24" VerticalAlignment="Center">' + $iconXaml + '</Canvas>')
    [void]$panel.Children.Add($canvas)
    if (-not $IconOnly) {
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = $Text
        $label.VerticalAlignment = 'Center'
        $label.Margin = New-Object System.Windows.Thickness(12, 0, 4, 0)
        [void]$panel.Children.Add($label)
        [void]$script:ToolLabels.Add($label)
    }
    $button.Content = $panel

    # Запоминаем активное окно до нажатия: щелчок сделает активным сам лаунчер
    $button.Add_MouseEnter({ $script:ForegroundBeforeClick = [SimraceNative]::CurrentForeground() })
    $button.Add_Click($OnClick)
    [void]$HeaderTools.Children.Add($button)
}

# Сервисные окна запускаются с правами администратора: Windows сама запросит пароль.
function Start-AdminScript([string]$FileName) {
    Stop-BootGuard
    $path = Join-Path $script:Root $FileName
    if (-not (Test-Path -LiteralPath $path)) {
        Show-Overlay 'Нет файла обслуживания' "В папке лаунчера не найден $FileName." 'Закрыть'
        return
    }
    try {
        [void](Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -WindowStyle Hidden `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$path`"")
        Write-Log "Открыто сервисное окно: $FileName"
    }
    catch { Write-Log "Сервисное окно не открыто: $_" }     # в том числе отмена запроса пароля
}

# Кнопка VPN или локальной сети в статус-баре. Лампа показывает, работает ли подключение.
function New-StatusLink($Entry, $Utility) {
    $button = New-Object System.Windows.Controls.Button
    $button.Style = $Window.FindResource('StatusButton')
    $button.Tag = $Utility
    $button.ToolTip = [string]$Entry.title
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Orientation = 'Horizontal'
    $iconXaml = $script:ToolIcons[[string]$Entry.icon]
    if (-not $iconXaml) { $iconXaml = $script:ToolIcons['wheel'] }
    [void]$panel.Children.Add([Windows.Markup.XamlReader]::Parse('<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="24" Height="24" VerticalAlignment="Center">' + $iconXaml + '</Canvas>'))
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = [string]$Entry.name
    $label.VerticalAlignment = 'Center'
    $label.Margin = New-Object System.Windows.Thickness(8, 0, 8, 0)
    [void]$panel.Children.Add($label)
    $lamp = New-Object System.Windows.Shapes.Ellipse
    $lamp.Width = 10
    $lamp.Height = 10
    $lamp.VerticalAlignment = 'Center'
    $lamp.Fill = New-DeviceBrush '#55585C'
    [void]$panel.Children.Add($lamp)
    $button.Content = $panel
    $button.Add_MouseEnter({ $script:ForegroundBeforeClick = [SimraceNative]::CurrentForeground() })
    $button.Add_Click({
        param($sender, $e)
        Start-Utility $sender.Tag
    })
    [void]$StatusLinks.Children.Add($button)
    $script:StatusLamps[[string]$Entry.id] = $lamp
}

# Сеть проверяется в фоне раз в несколько секунд и только пока лаунчер на экране
function Start-NetStatusCheck {
    if ($script:NetAsync -or (Get-Date) -lt $script:NetNext) { return }
    if ($script:Session -and [SimraceNative]::CurrentForeground() -ne [SimraceNative]::LauncherWindow) { return }
    $script:NetPs = [powershell]::Create()
    [void]$script:NetPs.AddScript(@'
$up = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
    $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' -and $_.NetworkInterfaceType -ne 'Tunnel' })
$virtual = '(?i)radmin|karing|sing-?box|sing-?tun|wintun|\btun\b|\btap\b|vpn|virtual|hyper-v|vmware|vbox|wsl|bluetooth|wireguard|clash'
$real = @($up | Where-Object { "$($_.Name) $($_.Description)" -notmatch $virtual -and @($_.GetIPProperties().GatewayAddresses).Count -gt 0 })
$kind = 'none'
if (@($real | Where-Object { $_.NetworkInterfaceType -eq 'Wireless80211' }).Count -gt 0) { $kind = 'wifi' }
if (@($real | Where-Object { $_.NetworkInterfaceType -ne 'Wireless80211' }).Count -gt 0) { $kind = 'ethernet' }
$internet = $kind -ne 'none'
try {
    $manager = [Activator]::CreateInstance([Type]::GetTypeFromCLSID([Guid]'DCB00C01-570F-4A9B-8D69-199FDBA5723B'))
    $internet = [bool]$manager.IsConnectedToInternet
}
catch { }
$radmin = @($up | Where-Object { "$($_.Name) $($_.Description)" -match '(?i)radmin' }).Count -gt 0
$karingRunning = [bool](Get-Process -Name 'karing', 'karingService' -ErrorAction SilentlyContinue)
$tunnel = @($up | Where-Object { "$($_.Name) $($_.Description)" -match '(?i)karing|sing-?box|sing-?tun|wintun|\btun\b' }).Count -gt 0
$proxy = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue).ProxyEnable -eq 1
$karing = if ($karingRunning -and ($tunnel -or $proxy)) { 'on' } elseif ($karingRunning) { 'idle' } else { 'off' }
"$kind|$internet|$(if ($radmin) { 'on' } else { 'off' })|$karing"
'@)
    $script:NetAsync = $script:NetPs.BeginInvoke()
}

function Update-NetStatusCheck {
    if (-not $script:NetAsync) { Start-NetStatusCheck; return }
    if (-not $script:NetAsync.IsCompleted) { return }
    $result = ''
    try { $result = [string](@($script:NetPs.EndInvoke($script:NetAsync)) | Select-Object -Last 1) }
    catch { Write-Log "Сеть не проверена: $_" }
    $script:NetPs.Dispose()
    $script:NetAsync = $null
    $script:NetNext = (Get-Date).AddSeconds(4)
    $parts = $result -split '\|'
    if ($parts.Count -lt 4) { return }

    switch ($parts[0]) {
        'ethernet' { $data = 'M3,4 H21 V15 H3 Z M8,20 H16 M12,15 V20'; $name = 'Подключено по кабелю' }
        'wifi' { $data = 'M2,9 C8,3 16,3 22,9 M5.5,13 C9.5,9.5 14.5,9.5 18.5,13 M9,16.5 C10.8,15 13.2,15 15,16.5 M12,20 L12,20'; $name = 'Подключено по Wi-Fi' }
        default { $data = 'M4,4 L20,20 M20,4 L4,20'; $name = 'Нет подключения' }
    }
    $IconNet.Data = [System.Windows.Media.Geometry]::Parse($data)
    $hasInternet = $parts[1] -eq 'True'
    $IconNet.Stroke = New-DeviceBrush $(if ($parts[0] -eq 'none') { '#E5301A' } elseif ($hasInternet) { '#FFFFFF' } else { '#E9C62A' })
    $NetBox.ToolTip = $(if ($parts[0] -ne 'none' -and -not $hasInternet) { "$name, но интернета нет" } else { $name })

    $colors = @{ on = '#37C552'; idle = '#A2A6AB'; off = '#E5301A' }
    if ($script:StatusLamps['radmin']) { $script:StatusLamps['radmin'].Fill = New-DeviceBrush $colors[$parts[2]] }
    if ($script:StatusLamps['karing']) { $script:StatusLamps['karing'].Fill = New-DeviceBrush $colors[$parts[3]] }
}

# Лампа защиты в меню: зелёная включена, красная выключена, серая состояние неизвестно. Пароль не нужен, проверка идёт в фоне.
function Start-UwfStatusCheck {
    if ($script:UwfAsync) { return }
    $script:UwfPs = [powershell]::Create()
    [void]$script:UwfPs.AddScript(@'
try {
    $filter = Get-CimInstance -Namespace 'root\standardcimv2\embedded' -ClassName UWF_Filter -ErrorAction Stop
    if ($filter.CurrentEnabled) { 'ON' } else { 'OFF' }
    return
}
catch { }
$exe = Join-Path $env:SystemRoot 'System32\uwfmgr.exe'
if (Test-Path -LiteralPath $exe) { & $exe get-config 2>&1 | Out-String }
'@)
    $script:UwfAsync = $script:UwfPs.BeginInvoke()
}

function Update-UwfStatusCheck {
    if (-not $script:UwfAsync -or -not $script:UwfAsync.IsCompleted) { return }
    $text = ''
    try { $text = (@($script:UwfPs.EndInvoke($script:UwfAsync)) -join "`n") }
    catch { Write-Log "Состояние UWF не прочитано: $_" }
    $script:UwfPs.Dispose()
    $script:UwfAsync = $null
    if ($script:LockKnown) { return }      # служба уже сообщила точное состояние

    $state = $text.Trim()
    if ($state -ne 'ON' -and $state -ne 'OFF') {
        # Первая строка о фильтре в выводе uwfmgr относится к текущему сеансу
        $line = ($text -split "`r?`n") | Where-Object { $_ -match '(?i)filter state|состояние фильтра' } | Select-Object -First 1
        if ($line -match '(?i)\b(off|disabled)\b|выкл') { $state = 'OFF' }
        elseif ($line -match '(?i)\b(on|enabled)\b|вкл') { $state = 'ON' }
        else { Write-Log "Не распознано состояние UWF: $($text.Substring(0, [Math]::Min(300, $text.Length)))" }
    }
    Set-UwfDisplay $state
}

# Лампа и подпись защиты в панели. ON, OFF или пустое значение, если состояние неизвестно.
function Set-UwfDisplay([string]$state) {
    $LampUwf.Fill = New-DeviceBrush $(if ($state -eq 'ON') { '#37C552' } elseif ($state -eq 'OFF') { '#E5301A' } else { '#55585C' })
    $TxtUwfState.Text = $(if ($state -eq 'ON') { 'Защита UWF включена' } elseif ($state -eq 'OFF') { 'Защита UWF выключена' } else { 'Состояние защиты неизвестно' })
    $script:UwfOn = $(if ($state -eq 'ON') { $true } elseif ($state -eq 'OFF') { $false } else { $null })
    $TxtAdminUwf.Text = $(if ($script:UwfOn -eq $false) { 'Заблокировать ПК' } else { 'Разблокировать ПК' })
    # На кнопке показан результат действия, в статус-панели текущее состояние
    $closedLock = 'M8,11 V7.5 A4,4 0 0 1 16,7.5 V11'
    $openLock = 'M8,11 V7.5 A4,4 0 0 1 15.6,5.8'
    $IconAdminUwf.Data = [System.Windows.Media.Geometry]::Parse($(if ($script:UwfOn -eq $false) { $closedLock } else { $openLock }))
    $IconLock.Data = [System.Windows.Media.Geometry]::Parse($(if ($script:UwfOn -eq $false) { $openLock } else { $closedLock }))
    $LampLock.Fill = $LampUwf.Fill
    $LockBox.ToolTip = $TxtUwfState.Text
}

# Программа рядом с играми: первое нажатие показывает её окно, второе сворачивает.
function Start-Utility($Utility) {
    Stop-BootGuard      # человек сам открывает программу: не сворачиваем её
    try {
        $running = @()
        if (@($Utility.Watch).Count -gt 0) { $running = @(Get-Process -Name $Utility.Watch -ErrorAction SilentlyContinue) }
        $appProcess = $running | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
        if ($appProcess) {
            $handle = $appProcess.MainWindowHandle
            if (-not [SimraceNative]::IsMinimized($handle) -and $handle -eq $script:ForegroundBeforeClick) {
                [SimraceNative]::Minimize($handle)
                # В игре возвращаемся в игру, иначе в лаунчер
                if ($script:Session -and $script:GameWindow -ne [IntPtr]::Zero) { [SimraceNative]::ActivateWindow($script:GameWindow) }
                else { [void]$Window.Activate() }
            }
            else { [SimraceNative]::BringToFront($handle) }
            return
        }
        # VPN или LAN убраны в трей: процесс работает, а окно скрыто. Повторный запуск такое окно часто не открывает.
        # У других программ, например Pit House, скрытым бывает служебное окно, поэтому их просто запускаем снова.
        if ($Utility.Tray -and $running.Count -gt 0) {
            $hidden = [SimraceNative]::FindHiddenWindow([int[]]@($running | ForEach-Object { $_.Id }))
            if ($hidden -ne [IntPtr]::Zero -and [SimraceNative]::ShowHiddenWindow($hidden)) {
                Write-Log "$($Utility.Name): окно показано из трея: $([SimraceNative]::DescribeWindow($hidden))"
                return
            }
            Write-Log "$($Utility.Name): процессов $($running.Count), окно не показано, запускаю файл ещё раз"
        }
        if (-not $Utility.Exe) {
            $Utility.Exe = $running | Where-Object { $_.Path } | Select-Object -First 1 -ExpandProperty Path
            if (-not $Utility.Exe) { throw 'файл программы не найден' }
        }
        [void](Start-AppTarget $Utility)
        Write-Log "Запуск: $($Utility.Name): $($Utility.Exe)"
    }
    catch {
        Write-Log "Ошибка запуска $($Utility.Name): $_"
        Show-Overlay "$($Utility.Name) не запустился" 'Позови администратора клуба.' 'Закрыть'
    }
}

function Invoke-AppLaunch {
    $session = $script:Session
    $app = $session.App
    try {
        if ($app.Kind -eq 'steam') {
            [void](Start-Process -FilePath $app.Exe -ArgumentList @('-applaunch', $app.SteamAppId))
        }
        else {
            $session.Process = Start-AppTarget $app
        }
        Set-SessionStage 'running'
        $TxtOverlayTitle.Text = "Запускается $($app.Name)"
        $TxtOverlayText.Visibility = 'Collapsed'
        Write-Log "Запуск: $($app.Name) [$($app.Kind)]"
    }
    catch {
        Write-Log "Ошибка запуска $($app.Name): $_"
        Stop-SessionWithError "$($app.Name) не запустилась" 'Позови администратора клуба.'
    }
}

# Отмена запуска: экран ожидания закрывается, и игра не остаётся работать за лаунчером.
function Stop-Launch {
    $session = $script:Session
    if (-not $session -or $session.Stage -eq 'closing-game') {
        Stop-Session
        return
    }
    Write-Log "Запуск отменён: $($session.App.Name), этап $($session.Stage)"
    if ($session.Stage -eq 'running') {
        # Steam мог получить команду запуска, а окно игры появляется позже: следим за ней ещё минуту
        $script:CancelledLaunch = @{ Session = $session; Until = (Get-Date).AddSeconds(60) }
        Stop-CurrentGame
        return
    }
    # Игра ещё не запускалась
    Stop-UnusedSteam
    Stop-Session
}

# Steam без выполненного входа закрываем: иначе его окно останется за лаунчером.
function Stop-UnusedSteam {
    if (Test-SteamLoggedIn) { return }
    Get-SteamProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
}

# Отменённая игра всё же запустилась: закрываем её. Выбор новой игры снимает это наблюдение.
function Update-CancelledLaunch {
    $cancelled = $script:CancelledLaunch
    if (-not $cancelled -or $script:Session) { return }
    if ((Get-Date) -gt $cancelled.Until) {
        $script:CancelledLaunch = $null
        return
    }
    foreach ($process in @(Get-GameProcesses $cancelled.Session)) {
        Write-Log "Закрываю отменённый запуск: $($process.ProcessName)"
        & taskkill.exe /F /T /PID $process.Id | Out-Null
    }
}

# Окно входа Steam закрыли, не войдя. Пока идёт вход, окна могут сменять друг друга, поэтому ждём несколько секунд подряд.
function Test-SteamPickerClosed($Session) {
    if ((Get-SteamProcesses).Count -eq 0) {
        $Session.SteamGone++
        return ($Session.SteamGone -ge 6)
    }
    $Session.SteamGone = 0
    $found = [SimraceNative]::FindSteamWindow()
    if ($found -ne [IntPtr]::Zero) {
        if (-not $Session.PickerSeen) {
            $Session.PickerSeen = $true
            Write-Log "Окно входа Steam: $([SimraceNative]::DescribeWindow($found))"
            [SimraceNative]::ForceForeground($found)
        }
        $Session.PickerGone = 0
        return $false
    }
    if (-not $Session.PickerSeen) { return $false }
    $Session.PickerGone++
    return ($Session.PickerGone -ge 8)
}

function Start-App($App, [bool]$ChooseAccount = $false) {
    $script:CancelledLaunch = $null
    $Account = $App.Account
    $script:GameWindow = [IntPtr]::Zero
    $script:Session = @{ App = $App; Account = $Account; ChooseAccount = $ChooseAccount; Process = $null; Stage = 'running'; StageStart = Get-Date; Seen = $false; Misses = 0; ExeNames = $null; GamePid = 0; Forced = $false; GameUp = $false; GoneTicks = 0; FsWindow = [IntPtr]::Zero; FsTries = 0; FsOff = $false; BarShown = $false; HostUntil = [datetime]::MinValue; AskedInSteam = $false; PickerSeen = $false; PickerGone = 0; SteamGone = 0 }
    Show-Waiting "Запускается $($App.Name)" 'Подожди немного.' 'Отменить запуск'
    Stop-BootGuard
    # Лаунчер уходит под все окна, поэтому сначала сворачиваем посторонние: Mumble, Проводник и другие
    [SimraceNative]::MinimizeOtherWindows([IntPtr]::Zero)
    [SimraceNative]::SetBackground($true)

    if ($ChooseAccount) {
        Write-Log "Выбор аккаунта Steam для $($App.Name)"
        $TxtOverlayTitle.Text = 'Открываю выбор аккаунта'
        $TxtOverlayText.Text = 'Steam перезапускается. Это может занять до минуты.'
        Set-SessionStage 'closing-steam'
        if ((Get-SteamProcesses).Count -gt 0) {
            try { [void](Start-Process -FilePath $script:SteamExe -ArgumentList '-shutdown') }
            catch { Write-Log "Команда закрытия Steam не сработала: $_" }
        }
        return
    }

    # Аккаунт уже активен или не задан: запускаем сразу
    if (-not $Account -or -not $script:SteamExe -or (Get-SteamActiveAccount) -eq $Account) {
        Invoke-AppLaunch
        return
    }
    Write-Log "Смена аккаунта Steam для $($App.Name): $Account"
    $TxtOverlayText.Text = 'Переключаю аккаунт Steam. Обычно это занимает меньше минуты.'
    Set-SessionStage 'closing-steam'
    if ((Get-SteamProcesses).Count -gt 0) {
        try { [void](Start-Process -FilePath $script:SteamExe -ArgumentList '-shutdown') }
        catch { Write-Log "Команда закрытия Steam не сработала: $_" }
    }
}

function Test-SessionRunning {
    $session = $script:Session
    if ($session.Process -and -not $session.Process.HasExited) { return $true }
    $steam = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name RunningAppID -ErrorAction SilentlyContinue
    if ($steam -and $steam.RunningAppID -ne 0) { return $true }
    $watch = @($session.App.Watch)
    if ($watch.Count -gt 0 -and (Get-Process -Name $watch -ErrorAction SilentlyContinue)) { return $true }
    return $false
}

# Окно программы-оболочки игры, например Content Manager
function Get-HostWindow($Session) {
    $hosts = @($Session.App.HostProcess | Where-Object { $_ })
    if ($hosts.Count -eq 0) { return [IntPtr]::Zero }
    $process = Get-Process -Name $hosts -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
    if ($process) { return $process.MainWindowHandle }
    return [IntPtr]::Zero
}

# Долго запускающаяся программа открывается за активным лаунчером: Windows не даёт ей выйти вперёд.
# Пока лаунчер активен сам по себе, а не потому что его открыли, выводим такое окно на передний план.
function Show-WindowFromBehind($Session) {
    if ([SimraceNative]::CurrentForeground() -ne [SimraceNative]::LauncherWindow -or $AdminPanel.Visibility -eq 'Visible') { return }
    if (-not $Session.BarShown) { $handle = [SimraceNative]::FindAppWindow([string[]]$script:ShellProcesses) }
    elseif ((Get-Date) -lt $Session.HostUntil) { $handle = Get-HostWindow $Session }
    else { return }
    if ($handle -eq [IntPtr]::Zero) { return }
    Write-Log "Окно было за лаунчером, вывожу вперёд: $([SimraceNative]::ProcessNameOf($handle))"
    [SimraceNative]::SendToBack()
    [SimraceNative]::ForceForeground($handle)
}

# Окно самой игры. Content Manager и подобные программы окном игры не считаются.
function Find-SessionGameWindow($Session) {
    $ignored = @($script:NotGameProcesses) + @($Session.App.HostProcess | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
    return [SimraceNative]::FindGameWindow([string[]]$ignored)
}

# Держит окно игры на весь монитор. Если игра упорно возвращает свой размер, после нескольких попыток лаунчер отступает.
function Update-GameFullscreen($Session) {
    if ($Session.FsOff -or $Session.FsWindow -eq [IntPtr]::Zero) { return }
    if ($script:Config.forceFullscreen -eq $false -or $Session.App.ForceFullscreen -eq $false) { return }
    $result = [SimraceNative]::ForceBorderless($Session.FsWindow)
    if ($result -eq 0) { return }
    if ($result -lt 0) {
        $Session.FsOff = $true
        Write-Log "$($Session.App.Name): окно не растянуто на весь экран, возможно, игра запущена от администратора"
        return
    }
    $Session.FsTries++
    Write-Log "$($Session.App.Name): окно растянуто на весь экран, попытка $($Session.FsTries)"
    if ($Session.FsTries -ge 6) {
        $Session.FsOff = $true
        Write-Log "$($Session.App.Name): игра возвращает свой размер окна, лаунчер больше его не меняет"
    }
}

# Вызывается таймером раз в секунду. Этапы не блокируют окно.
function Update-Session {
    $session = $script:Session
    if (-not $session) { return }
    $elapsed = ((Get-Date) - $session.StageStart).TotalSeconds

    if ($session.Stage -eq 'running' -or $session.Stage -eq 'waiting-login') { Show-WindowFromBehind $session }
    if ($WaitSpinner.Visibility -eq 'Visible' -and $BtnOverlayCorner.Visibility -ne 'Visible' -and (Get-Date) -gt $script:WaitCornerAt) { $BtnOverlayCorner.Visibility = 'Visible' }

    switch ($session.Stage) {
        'closing-game' {
            $left = @(Get-GameProcesses $session)
            if ($left.Count -eq 0) {
                Write-Log 'Игра закрыта'
                Stop-Session
                return
            }
            if ($elapsed -ge 4) {
                foreach ($process in $left) { & taskkill.exe /F /T /PID $process.Id | Out-Null }
                if (-not $session.Forced) { Write-Log "Принудительное закрытие: $(($left | ForEach-Object { $_.ProcessName }) -join ', ')" }
                $session.Forced = $true
            }
            if ($elapsed -gt 12) {
                Write-Log "Не закрылись (возможно, запущены с правами администратора): $(($left | ForEach-Object { $_.ProcessName }) -join ', ')"
                Stop-SessionWithError "$($session.App.Name) не закрылась" 'Перезагрузи компьютер или позови администратора клуба.'
            }
        }
        'closing-steam' {
            $alive = (Get-SteamProcesses).Count -gt 0
            if ($alive -and $elapsed -lt 25) { return }
            if ($alive) { Get-SteamProcesses | Stop-Process -Force -ErrorAction SilentlyContinue }
            try {
                if ($session.ChooseAccount) {
                    Clear-SteamAutoLogin
                    # -silent: окно выбора аккаунта появится, а главное окно после входа нет
                    [void](Start-Process -FilePath $script:SteamExe -ArgumentList '-silent')
                    $TxtOverlayTitle.Text = 'Выбери аккаунт в окне Steam'
                    $TxtOverlayText.Text = "После входа $($session.App.Name) запустится сама."
                    Set-SessionStage 'waiting-login'
                    return
                }
                Set-SteamAccount $session.Account
                [void](Start-Process -FilePath $script:SteamExe -ArgumentList '-silent')
                Set-SessionStage 'waiting-login'
            }
            catch {
                Write-Log "Ошибка смены аккаунта: $_"
                Stop-SessionWithError 'Аккаунт Steam не переключился' 'Позови администратора клуба.'
            }
        }
        'waiting-login' {
            if ($session.ChooseAccount) {
                if (Test-SteamLoggedIn) { Invoke-AppLaunch }
                elseif (Test-SteamPickerClosed $session) {
                    Write-Log 'Окно выбора аккаунта закрыто без входа'
                    Stop-Launch
                }
                elseif ($elapsed -gt 300) {
                    Write-Log 'Аккаунт Steam не выбран за 5 минут'
                    Stop-UnusedSteam
                    Stop-SessionWithError 'Аккаунт не выбран' 'Выбери игру ещё раз. Если окно Steam не появляется, позови администратора клуба.'
                }
                return
            }
            if ((Get-SteamActiveAccount) -eq $session.Account) {
                Invoke-AppLaunch
            }
            elseif ($elapsed -gt 20) {
                # Steam не вошёл сам: остаётся его окно выбора аккаунта
                if (-not $session.AskedInSteam) {
                    $session.AskedInSteam = $true
                    Write-Log "Steam не вошёл в $($session.Account) автоматически"
                    $TxtOverlayTitle.Text = 'Выбери аккаунт в окне Steam'
                    $TxtOverlayText.Text = "Нужен аккаунт $($session.Account). После входа $($session.App.Name) запустится сама."
                }
                if (Test-SteamLoggedIn) {
                    Write-Log "Вход выполнен в другой аккаунт: $(Get-SteamActiveAccount)"
                    Invoke-AppLaunch
                }
                elseif (Test-SteamPickerClosed $session) {
                    Write-Log 'Окно выбора аккаунта закрыто без входа'
                    Stop-Launch
                }
                elseif ($elapsed -gt 300) {
                    Write-Log "Steam не вошёл в аккаунт $($session.Account) за 5 минут"
                    Stop-UnusedSteam
                    Stop-SessionWithError 'Steam не вошёл в аккаунт' 'Нужен повторный вход. Позови администратора клуба.'
                }
            }
        }
        'running' {
            # Steam иногда сам открывает главное окно при запуске игры
            if ($elapsed -lt 30) { [SimraceNative]::CloseSteamMainWindow() }

            # Появилось окно самой игры. Диалоги и консоль сюда не считаются: пока их не закроют, лаунчер неактивен,
            # поэтому фокус не падает на него, а окно игры сразу выводится на передний план.
            if (-not $session.GameUp) {
                $found = Find-SessionGameWindow $session
                if ($found -ne [IntPtr]::Zero) {
                    $session.GameUp = $true
                    $script:GameWindow = $found
                    $session.FsWindow = $found
                    $session.BarShown = $true
                    $session.GamePid = [SimraceNative]::ProcessIdOf($found)
                    Write-Log "Окно игры: $([SimraceNative]::ProcessNameOf($found))"
                    Show-GameBar
                    [SimraceNative]::ForceForeground($found)
                }
                elseif (-not $session.BarShown) {
                    # Открыт Content Manager или игра в маленьком окне: экран ожидания больше не нужен
                    # Экран ожидания убираем, только когда окно появилось, иначе оно откроется за лаунчером
                    $hostWindow = Get-HostWindow $session
                    if ($hostWindow -ne [IntPtr]::Zero) {
                        $session.BarShown = $true
                        $session.HostUntil = (Get-Date).AddSeconds(10)     # заставка может смениться главным окном
                        Show-GameBar
                        [SimraceNative]::SendToBack()
                        [SimraceNative]::ForceForeground($hostWindow)
                    }
                    elseif ($session.Seen -and $elapsed -gt 90) {
                        $session.BarShown = $true
                        Show-GameBar
                    }
                }
            }
            else {
                # Окно игры закрылось (Alt+F4, выход из меню, вылет): сразу возвращаемся в лаунчер
                if ([SimraceNative]::WindowExists($script:GameWindow)) { $session.GoneTicks = 0 }
                else {
                    $session.GoneTicks++
                    if ($session.GoneTicks -ge 2) {
                        $next = Find-SessionGameWindow $session
                        $hosts = @($session.App.HostProcess | Where-Object { $_ })
                        if ($next -ne [IntPtr]::Zero) {
                            $script:GameWindow = $next
                            $session.FsWindow = $next
                            $session.GamePid = [SimraceNative]::ProcessIdOf($next)
                            $session.GoneTicks = 0
                        }
                        elseif ($hosts.Count -gt 0 -and (Get-Process -Name $hosts -ErrorAction SilentlyContinue)) {
                            # Content Manager и подобные остаются открытыми: сеанс идёт, пока их не закроют
                            $script:GameWindow = [IntPtr]::Zero
                            $session.FsWindow = [IntPtr]::Zero
                            $session.GameUp = $false
                            $session.GoneTicks = 0
                        }
                        else {
                            foreach ($process in @(Get-GameProcesses $session)) { & taskkill.exe /F /T /PID $process.Id | Out-Null }
                            Write-Log "Игра закрыта: $($session.App.Name)"
                            Stop-Session
                            return
                        }
                    }
                }
            }

            Update-GameFullscreen $session

            if (Test-SessionRunning) {
                $session.Seen = $true
                $session.Misses = 0
            }
            elseif ($session.Seen) {
                # Короткая пауза: лаунчер игры мог на мгновение смениться самой игрой. Проверка раз в секунду.
                $session.Misses++
                $grace = if ($session.App.ExitGrace) { [int]$session.App.ExitGrace } else { $script:ExitGrace }
                if ($session.Misses -ge $grace) { Stop-Session }
            }
            elseif ($elapsed -gt $(if ($session.App.LaunchTimeout) { [int]$session.App.LaunchTimeout } else { $script:LaunchTimeout })) {
                Stop-SessionWithError "$($session.App.Name) не запустилась" 'Попробуй ещё раз. Если не получится, позови администратора клуба.'
            }
        }
    }
}

# ---------- Сетка плиток ----------

# Раскладывает плитки по категориям в порядке из настроек. Плитки без категории идут последними, без подписи.
function Initialize-TileSections {
    $script:TileSections = New-Object System.Collections.ArrayList
    $used = @{}
    foreach ($category in @($script:Config.categories | Where-Object { $_ })) {
        $tiles = @($script:Tiles | Where-Object { $_.Tag.Category -eq $category.id })
        foreach ($tile in $tiles) { $used[$tile.Tag.Id] = $true }
        if ($tiles.Count -gt 0) { [void]$script:TileSections.Add([pscustomobject]@{ Name = [string]$category.name; Note = [string]$category.note; Tiles = $tiles; Panel = $null }) }
    }
    $rest = @($script:Tiles | Where-Object { -not $used[$_.Tag.Id] })
    if ($rest.Count -gt 0) { [void]$script:TileSections.Add([pscustomobject]@{ Name = ''; Note = ''; Tiles = $rest; Panel = $null }) }
    foreach ($section in $script:TileSections) { $section.Panel = New-TileSectionPanel $section }
}

# Подпись категории и ряд плиток. Плитки перекладываются сюда один раз и дальше меняют только размер.
function New-TileSectionPanel($Section) {
    $panel = New-Object System.Windows.Controls.StackPanel
    if ($Section.Name) {
        $title = New-Object System.Windows.Controls.DockPanel
        $title.Margin = New-Object System.Windows.Thickness(8, 0, 8, 6)
        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = $Section.Name
        $name.FontSize = 20
        $name.FontWeight = [System.Windows.FontWeights]::SemiBold
        [System.Windows.Controls.DockPanel]::SetDock($name, 'Left')
        [void]$title.Children.Add($name)
        if ($Section.Note) {
            $note = New-Object System.Windows.Controls.TextBlock
            $note.Text = $Section.Note
            $note.FontSize = 15
            $note.Foreground = $Window.FindResource('Muted')
            $note.VerticalAlignment = 'Bottom'
            $note.TextTrimming = 'CharacterEllipsis'
            $note.Margin = New-Object System.Windows.Thickness(12, 0, 0, 2)
            [void]$title.Children.Add($note)
        }
        [void]$panel.Children.Add($title)
        $line = New-Object System.Windows.Shapes.Rectangle
        $line.Height = 1
        $line.Fill = $Window.FindResource('Divider')
        $line.Margin = New-Object System.Windows.Thickness(8, 0, 8, 2)
        [void]$panel.Children.Add($line)
    }
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    foreach ($tile in $Section.Tiles) { [void]$row.Children.Add($tile.Parent) }
    [void]$panel.Children.Add($row)
    return $panel
}

# Перебирает варианты размещения категорий по строкам и выбирает тот, где плитки 2:3 самые крупные.
function Get-BestSectionLayout([double]$Width, [double]$Height, [double]$Gap, [double]$MaxTile, [double]$ExtraRow, [double]$LabelRow, [double]$SectionGap) {
    $count = $script:TileSections.Count
    $best = @{ Tile = 0.0; Lines = @() }
    for ($mask = 0; $mask -lt [Math]::Pow(2, $count - 1); $mask++) {
        $lines = New-Object System.Collections.ArrayList
        $current = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $count; $i++) {
            [void]$current.Add($i)
            if ($i -lt $count - 1 -and ($mask -band (1 -shl $i))) {
                [void]$lines.Add($current.ToArray())
                $current = New-Object System.Collections.ArrayList
            }
        }
        [void]$lines.Add($current.ToArray())

        $byHeight = (($Height / $lines.Count) - $LabelRow - $ExtraRow - $Gap) / 1.5
        $tile = [Math]::Min($MaxTile, $byHeight)
        foreach ($line in $lines) {
            $tiles = 0
            foreach ($index in $line) { $tiles += @($script:TileSections[$index].Tiles).Count }
            $byWidth = ($Width - $SectionGap * ($line.Count - 1) - $Gap * $tiles) / $tiles
            $tile = [Math]::Min($tile, $byWidth)
        }
        if ($tile -gt $best.Tile) { $best = @{ Tile = $tile; Lines = $lines.ToArray() } }
    }
    return $best
}

# Стрелки видны, только когда плитки не помещаются
function Update-ScrollArrows {
    $can = $TileScroller.ScrollableWidth -gt 1 -and $script:TimerState -ne 'idle'
    $BtnScrollLeft.Visibility = $(if ($can -and $TileScroller.HorizontalOffset -gt 1) { 'Visible' } else { 'Collapsed' })
    $BtnScrollRight.Visibility = $(if ($can -and $TileScroller.HorizontalOffset -lt $TileScroller.ScrollableWidth - 1) { 'Visible' } else { 'Collapsed' })
}

function Move-TileScroll([int]$Direction) {
    $TileScroller.ScrollToHorizontalOffset($TileScroller.HorizontalOffset + $Direction * $TileScroller.ViewportWidth * 0.7)
}

function Update-TileLayout {
    $width = $TilesHost.ActualWidth
    $height = $TilesHost.ActualHeight
    if ($script:Tiles.Count -eq 0 -or $width -le 0 -or $height -le 0 -or $script:TileSections.Count -eq 0) { return }
    $gap = 16
    $labelRow = if (@($script:TileSections | Where-Object { $_.Name }).Count -gt 0) { 40 } else { 0 }
    $layout = Get-BestSectionLayout $width $height $gap 420 0 $labelRow 40
    # Плитки стали бы слишком мелкими: один ряд в полный рост, остальное листается
    $minTile = if ($script:Config.minTileWidth) { [double]$script:Config.minTileWidth } else { 220 }
    if ($layout.Tile -lt $minTile) {
        $allSections = @(0..($script:TileSections.Count - 1))
        $layout = @{ Tile = [Math]::Min(420, ($height - $labelRow - $gap) / 1.5); Lines = @(, $allSections) }
    }
    $tileWidth = [Math]::Floor($layout.Tile)
    $key = "$tileWidth|$(($layout.Lines | ForEach-Object { $_ -join ',' }) -join ';')"
    if ($key -eq $script:LayoutKey) { return }
    $script:LayoutKey = $key

    foreach ($tile in $script:Tiles) {
        $tile.Width = $tileWidth
        $tile.Height = [Math]::Floor($tileWidth * 1.5)
        $tile.Parent.Width = $tileWidth
        $tile.Parent.Margin = New-Object System.Windows.Thickness(($gap / 2), ($gap / 2), ($gap / 2), ($gap / 2))
    }
    foreach ($row in $RowsPanel.Children) { $row.Children.Clear() }
    $RowsPanel.Children.Clear()
    foreach ($line in $layout.Lines) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.HorizontalAlignment = 'Center'
        $first = $true
        foreach ($index in $line) {
            $panel = $script:TileSections[$index].Panel
            $panel.Margin = New-Object System.Windows.Thickness($(if ($first) { 0 } else { 40 }), 0, 0, 0)
            # Подпись категории не должна раздвигать ряд шире его плиток
            $panel.Width = @($script:TileSections[$index].Tiles).Count * ($tileWidth + $gap)
            $panel.VerticalAlignment = 'Top'
            [void]$row.Children.Add($panel)
            $first = $false
        }
        [void]$RowsPanel.Children.Add($row)
    }
}

function New-CoverImage([string]$Path, [int]$DecodeWidth = 600) {
    try {
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.UriSource = New-Object System.Uri($Path)
        if ($DecodeWidth -gt 0) { $bitmap.DecodePixelWidth = $DecodeWidth }   # экономим память на обложках
        $bitmap.CacheOption = 'OnLoad'
        $bitmap.EndInit()
        $bitmap.Freeze()
        $image = New-Object System.Windows.Controls.Image
        $image.Source = $bitmap
        $image.Stretch = 'UniformToFill'
        return $image
    }
    catch {
        Write-Log "Не прочитана картинка ${Path}: $_"
        return $null
    }
}

# Показывает файл из папки лаунчера в элементе Image. Нет файла: элемент останется пустым.
function Set-ImageFile($Control, [string]$Name, [int]$DecodeWidth = 0) {
    $path = Join-Path $script:Root $Name
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Log "Нет файла оформления: $Name"
        return $false
    }
    $image = New-CoverImage $path $DecodeWidth
    if (-not $image) { return $false }
    $Control.Source = $image.Source
    return $true
}

# Подгоняет нижний блок под экран: на 32:9 он занимает меньшую долю ширины, на 16:9 меньшую высоту.
function Update-Proportions {
    $width = $Window.ActualWidth
    $height = $Window.ActualHeight
    if ($width -le 0 -or $height -le 0) { return }
    $wide = ($width / $height) -ge 2.4
    $bottom = [Math]::Round($height * $(if ($wide) { 0.24 } else { 0.19 }))
    $BottomRow.Height = New-Object System.Windows.GridLength($bottom)
    $DashHost.Height = $bottom
    $DashHost.Width = $bottom * 1520 / 500
    $TxtSelected.FontSize = $(if ($wide) { 42 } else { 34 })
    # На узком экране у кнопок остаются только значки
    foreach ($label in $script:ToolLabels) { $label.Visibility = $(if ($wide) { 'Visible' } else { 'Collapsed' }) }
    # На узком экране мини-дашборду нет места рядом с адресами
    $AxesCard.Visibility = $(if ($wide -and $script:Config.showAxes -ne $false) { 'Visible' } else { 'Collapsed' })
    Update-FeatureWidth
}

# ---------- Подключение устройств ----------

# Скрытое окно получает от Windows сообщение о подключении и отключении USB-устройств.
# Если создать его не удалось, устройства проверяются по таймеру, как раньше.
function Start-DeviceWatch {
    $script:DeviceWatch = $null
    try {
        if (-not ('SimraceDeviceWatch' -as [type])) {
            Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
public class SimraceDeviceWatch : System.Windows.Forms.NativeWindow
{
    public static volatile bool Changed = true;
    public SimraceDeviceWatch()
    {
        System.Windows.Forms.CreateParams parameters = new System.Windows.Forms.CreateParams();
        parameters.Caption = "SimraceDeviceWatch";
        CreateHandle(parameters);
    }
    protected override void WndProc(ref System.Windows.Forms.Message message)
    {
        if (message.Msg == 0x219) Changed = true;      // WM_DEVICECHANGE
        base.WndProc(ref message);
    }
}
'@
        }
        $script:DeviceWatch = New-Object SimraceDeviceWatch
    }
    catch { Write-Log "Слежение за подключением устройств недоступно, проверка по таймеру: $_" }
}

# ---------- Оси руля и педалей ----------

# Привязка из apps.json: "0:X" значит устройство MOZA номер 0, ось X.
function Initialize-Axes {
    $script:AxisMap = @{}
    foreach ($name in 'wheel', 'throttle', 'brake', 'clutch') {
        $match = [regex]::Match([string]$script:Config.axes.$name, '^(\d+):([XYZRUVxyzruv])$')
        if ($match.Success) { $script:AxisMap[$name] = @([int]$match.Groups[1].Value, 'XYZRUV'.IndexOf($match.Groups[2].Value.ToUpperInvariant())) }
    }
    $script:ClutchAuto = [string]$script:Config.axes.clutch -eq '0:auto'
    try { Write-Log "Игровые устройства: $([SimraceNative]::DescribeJoysticks())" }
    catch { Write-Log "Игровые устройства не прочитаны: $_" }
}

function Get-AxisValue([string]$Name, $Readings) {
    $map = $script:AxisMap[$Name]
    if (-not $map -or $map[0] -ge $Readings.Count -or $map[1] -lt 0) { return -1 }
    return $Readings[$map[0]][$map[1]]
}

# Сцепление сидит на незанятой оси: привязываем ту из них, которая первой сдвинется от положения покоя
function Find-ClutchAxis($Readings) {
    if (-not $script:ClutchAuto -or $script:AxisMap['clutch']) { return }
    $used = @($script:AxisMap.Values | ForEach-Object { $_[1] })
    $values = $Readings[0]
    if (-not $script:ClutchRest) {
        $script:ClutchRest = @($values)
        return
    }
    foreach ($axis in 1..5) {
        if ($used -contains $axis) { continue }
        if ([Math]::Abs($values[$axis] - $script:ClutchRest[$axis]) -gt 8000) {
            $script:AxisMap['clutch'] = @(0, $axis)
            $script:AxisInvert['clutch'] = $script:ClutchRest[$axis] -gt 32767
            Write-Log "Сцепление привязано к оси $('XYZRUV'[$axis])"
            return
        }
    }
}

# Педаль в покое может стоять как на нуле, так и на максимуме: определяем это по первому чтению
function Set-PedalBar($Bar, [string]$Name, $Readings) {
    $value = Get-AxisValue $Name $Readings
    if ($value -lt 0) {
        $Bar.Height = 0
        return
    }
    if (-not $script:AxisInvert.ContainsKey($Name)) { $script:AxisInvert[$Name] = $value -gt 32767 }
    $part = $value / 65535.0
    if ($script:AxisInvert[$Name]) { $part = 1 - $part }
    $Bar.Height = [Math]::Round($part * 72)
}

# Обновляется, только пока лаунчер на экране: в игре оси не читаем
function Update-Axes {
    if ($AxesCard.Visibility -ne 'Visible' -or [SimraceNative]::CurrentForeground() -ne [SimraceNative]::LauncherWindow) { return }
    $readings = New-Object System.Collections.ArrayList
    foreach ($id in $script:AxisDevices) {
        $values = [SimraceNative]::ReadJoystick($id)
        if ($null -eq $values) {
            $readings.Clear()
            $script:AxisDevices = @()
            $script:AxisInvert = @{}
            $script:ClutchRest = $null
            break
        }
        [void]$readings.Add($values)
    }
    if ($readings.Count -eq 0) {
        if ((Get-Date) -ge $script:AxisNextScan) {
            $script:AxisNextScan = (Get-Date).AddSeconds(3)
            $script:AxisDevices = @([SimraceNative]::FindJoysticks(0x346E))
        }
        $AxesCard.Opacity = 0.35
        $BarThrottle.Height = 0
        $BarBrake.Height = 0
        $BarClutch.Height = 0
        $BarWheel.Width = 0
        $TxtAxesRaw.Text = 'База MOZA не найдена'
        return
    }
    $AxesCard.Opacity = 1
    Find-ClutchAxis $readings

    $wheel = Get-AxisValue 'wheel' $readings
    if ($wheel -ge 0) {
        $shift = ($wheel - 32767.5) / 32767.5 * 98
        $BarWheel.Width = [Math]::Abs($shift)
        [System.Windows.Controls.Canvas]::SetLeft($BarWheel, 98 + [Math]::Min($shift, 0))
    }
    Set-PedalBar $BarThrottle 'throttle' $readings
    Set-PedalBar $BarBrake 'brake' $readings
    Set-PedalBar $BarClutch 'clutch' $readings

    # Подсказка при наведении: сырые значения нужны, чтобы привязать оси
    $script:AxisTick++
    if ($script:AxisTick % 6 -eq 0) {
        $lines = for ($i = 0; $i -lt $readings.Count; $i++) {
            $v = $readings[$i]
            "Устройство ${i}:  X $($v[0])   Y $($v[1])   Z $($v[2])   R $($v[3])   U $($v[4])   V $($v[5])"
        }
        $TxtAxesRaw.Text = ($lines -join "`n")
    }
}

# ---------- Интересные факты ----------

# Факты лежат в facts.txt, по одному на строку. Нет файла или фактов: блока просто нет на экране.
function Initialize-Facts {
    $path = Join-Path $script:Root 'facts.txt'
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $script:Facts = @(Get-Content -LiteralPath $path -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    }
    catch { Write-Log "Не прочитан файл фактов: $_" }
    if ($script:Facts.Count -eq 0) { return }
    $script:FactFadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation
    $script:FactFadeOut.To = 0
    $script:FactFadeOut.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds(400)
    $script:FactFadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation
    $script:FactFadeIn.To = 1
    $script:FactFadeIn.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds(400)
    Set-NextFact
}

# Показываем факты в случайном порядке и без повторов, пока не покажем все
function Set-NextFact {
    if ($script:FactIndex -ge $script:FactDeck.Count) {
        $script:FactDeck = @($script:Facts | Sort-Object { Get-Random })
        $script:FactIndex = 0
    }
    $TxtFact.Text = $script:FactDeck[$script:FactIndex]
    $script:FactIndex++
    $script:FactNextAt = (Get-Date).AddSeconds(25)
}

# Вызывается таймером раз в полсекунды: текст гаснет и на следующем шаге появляется новый
function Update-Fact {
    if ($script:Facts.Count -lt 2) { return }
    if ($script:FactFading) {
        $script:FactFading = $false
        Set-NextFact
        $TxtFact.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $script:FactFadeIn)
    }
    elseif ((Get-Date) -ge $script:FactNextAt) {
        $script:FactFading = $true
        $TxtFact.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $script:FactFadeOut)
    }
}

# Блок занимает место между логотипом и центральным блоком. На узком экране он скрыт.
function Update-FactLayout {
    if ($script:Facts.Count -eq 0) { return }
    $left = $LogoHost.ActualWidth + 28
    $featureLeft = ($Window.ActualWidth - 112 - $FeatureBox.ActualWidth) / 2
    $room = $featureLeft - 28 - $left
    if ($room -lt 400) {
        $FactBox.Visibility = 'Collapsed'
        return
    }
    $FactBox.Margin = New-Object System.Windows.Thickness($left, 0, 0, 0)
    $FactBox.Width = [Math]::Min(520, $room)
    $FactBox.Visibility = 'Visible'
}

# Блок по центру экрана не должен заходить на логотип и кнопки
function Update-FeatureWidth {
    $half = $Window.ActualWidth / 2 - 56 - [Math]::Max($LogoHost.ActualWidth, $ToolsPanel.ActualWidth) - 32
    if ($half -gt 0) { $FeatureBox.MaxWidth = $half * 2 }
}

# ---------- Таймер сеанса ----------

function Get-SessionElapsed {
    if ($script:TimerState -eq 'running') { return $script:TimerAccum + ((Get-Date) - $script:TimerResume) }
    return $script:TimerAccum
}

function Format-Elapsed([TimeSpan]$Time) {
    return ('{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($Time.TotalHours), $Time.Minutes, $Time.Seconds)
}

function Update-TimerDisplay {
    if ($script:TimerState -eq 'idle') {
        $TxtDashTimer.Text = '--:--:--'
        $TxtDashStart.Text = '--:--'
        $TxtDashState.Text = 'IDLE'
        $TxtDashLap.Text = '0'
        if ($MixerWindow) { $TxtPanelSession.Text = 'Сеанс не начат' }
        return
    }
    $time = Get-SessionElapsed
    $elapsed = Format-Elapsed $time
    $started = $script:TimerStart.ToString('HH:mm')
    $TxtDashTimer.Text = $elapsed
    $TxtDashStart.Text = $started
    $TxtDashState.Text = $(if ($script:TimerState -eq 'paused') { 'PAUSE' } else { 'RUN' })
    $TxtDashLap.Text = [string][int][Math]::Floor($time.TotalHours)     # один час это один круг
    $TxtStripTime.Text = $elapsed
    $TxtStripStart.Text = $started
    if ($MixerWindow) { $TxtPanelSession.Text = "Сеанс $elapsed" + $(if ($script:TimerState -eq 'paused') { ', пауза' } else { '' }) }
    if ($script:EndArmedUntil -ne [datetime]::MinValue -and (Get-Date) -gt $script:EndArmedUntil) {
        $script:EndArmedUntil = [datetime]::MinValue
        $BtnEndSession.Content = 'Завершить'
    }
}

# Без начатого сеанса плитки неактивны и в центре большая кнопка
function Update-TimerLayout {
    $idle = $script:TimerState -eq 'idle'
    $SessionStart.Visibility = $(if ($idle) { 'Visible' } else { 'Collapsed' })
    $SessionFields.Visibility = $(if ($idle) { 'Collapsed' } else { 'Visible' })
    $RowsPanel.IsEnabled = -not $idle
    $RowsPanel.Opacity = $(if ($idle) { 0.25 } else { 1 })
    Update-ScrollArrows
    $IconPause.Data = [System.Windows.Media.Geometry]::Parse($(if ($script:TimerState -eq 'paused') { 'M8,5 L18,12 L8,19 Z' } else { 'M8,5 V19 M16,5 V19' }))
    $BtnPause.ToolTip = $(if ($script:TimerState -eq 'paused') { 'Продолжить' } else { 'Пауза' })
    Update-TimerDisplay
    if ($idle) { [void]$BtnStartSession.Focus() }
}

function Start-ClubSession {
    $script:TimerStart = Get-Date
    $script:TimerResume = $script:TimerStart
    $script:TimerAccum = [TimeSpan]::Zero
    $script:TimerState = 'running'
    Write-Log "Сеанс начат: $($script:TimerStart.ToString('HH:mm:ss'))"
    Update-TimerLayout
    if ($script:LastTile) { [void]$script:LastTile.Focus() }
}

function Switch-ClubSessionPause {
    if ($script:TimerState -eq 'running') {
        $script:TimerAccum = Get-SessionElapsed
        $script:TimerState = 'paused'
    }
    elseif ($script:TimerState -eq 'paused') {
        $script:TimerResume = Get-Date
        $script:TimerState = 'running'
    }
    Update-TimerLayout
}

# Завершение в два нажатия, чтобы не нажать случайно. Запущенная игра закрывается.
function Stop-ClubSession {
    if ($script:EndArmedUntil -eq [datetime]::MinValue) {
        $script:EndArmedUntil = (Get-Date).AddSeconds(4)
        $BtnEndSession.Content = 'Точно?'
        return
    }
    $script:EndArmedUntil = [datetime]::MinValue
    $BtnEndSession.Content = 'Завершить'
    $total = Format-Elapsed (Get-SessionElapsed)
    $TxtLastSession.Text = "Прошлый сеанс: $total, начат в $($script:TimerStart.ToString('HH:mm'))"
    Write-Log "Сеанс завершён: $total"
    $script:TimerState = 'idle'
    $script:TimerAccum = [TimeSpan]::Zero
    if ($script:Session) { Stop-CurrentGame }
    Update-TimerLayout
}

# ---------- Проверка оборудования ----------

function New-DeviceBrush([string]$Color) {
    return New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($Color))
}

# Строит индикаторы на приборке. Подключён: зелёный, не найден: красный.
function Initialize-Devices {
    $script:DeviceSlots = New-Object System.Collections.ArrayList
    $index = 0
    foreach ($device in @($script:Config.devices | Where-Object { $_ })) {
        if ($index -ge 3) { break }
        $border = New-Object System.Windows.Controls.Border
        $border.Width = 110
        $border.Height = 46
        $border.CornerRadius = New-Object System.Windows.CornerRadius(6)
        $border.BorderThickness = New-Object System.Windows.Thickness(2)
        $border.BorderBrush = New-DeviceBrush '#47565B'
        $border.Background = New-DeviceBrush '#090B0C'
        $grid = New-Object System.Windows.Controls.Grid
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = [string]$device.name
        $label.FontFamily = $script:DashFont
        $label.FontSize = 19
        $label.Foreground = New-DeviceBrush '#E0E2E2'
        $label.VerticalAlignment = 'Center'
        $label.Margin = New-Object System.Windows.Thickness(10, 0, 0, 0)
        $lamp = New-Object System.Windows.Shapes.Ellipse
        $lamp.Width = 14
        $lamp.Height = 14
        $lamp.Fill = New-DeviceBrush '#3A3D41'
        $lamp.HorizontalAlignment = 'Right'
        $lamp.VerticalAlignment = 'Center'
        $lamp.Margin = New-Object System.Windows.Thickness(0, 0, 9, 0)
        [void]$grid.Children.Add($label)
        [void]$grid.Children.Add($lamp)
        $border.Child = $grid
        [System.Windows.Controls.Canvas]::SetLeft($border, 110)
        [System.Windows.Controls.Canvas]::SetTop($border, 196 + $index * 58)
        [void]$DashLive.Children.Add($border)
        [void]$script:DeviceSlots.Add([pscustomobject]@{ Match = [string]$device.match; Lamp = $lamp })
        $index++
    }
}

# Опрос идёт в фоне, чтобы окно не подвисало. На время игры не выполняется.
function Update-Devices {
    if ($script:DeviceSlots.Count -eq 0) { return }
    if ($script:DeviceAsync) {
        if (-not $script:DeviceAsync.IsCompleted) { return }
        $lines = @($script:DevicePs.EndInvoke($script:DeviceAsync) | ForEach-Object { [string]$_ })
        $script:DevicePs.Dispose()
        $script:DeviceAsync = $null
        $power = $null
        foreach ($slot in $script:DeviceSlots) {
            $present = @($lines | Where-Object { $_ -match $slot.Match }).Count -gt 0
            $slot.Lamp.Fill = New-DeviceBrush $(if ($present) { '#37C552' } else { '#E5301A' })
            if ($null -eq $power) { $power = $present }     # первое устройство в списке это база
        }
        if ($null -ne $power) { Set-DashPower $power }
        # Со слежением за подключением хватает редкой контрольной проверки
        $seconds = if ($script:DeviceWatch) { 15 } elseif ($script:Config.deviceCheckSeconds) { [double]$script:Config.deviceCheckSeconds } else { 2 }
        $script:DeviceNext = (Get-Date).AddSeconds($seconds)
        return
    }
    if ($script:DeviceWatch -and [SimraceDeviceWatch]::Changed) {
        [SimraceDeviceWatch]::Changed = $false
        # Устройство подключили или отключили: проверяем через секунду, когда Windows его настроит
        $soon = (Get-Date).AddSeconds(1)
        if ($soon -lt $script:DeviceNext) { $script:DeviceNext = $soon }
    }
    if ($script:Session -or (Get-Date) -lt $script:DeviceNext) { return }
    $script:DevicePs = [powershell]::Create()
    [void]$script:DevicePs.AddScript('Get-CimInstance Win32_PnPEntity -Filter "(DeviceID LIKE ''USB%'' OR DeviceID LIKE ''HID%'') AND Status = ''OK''" | ForEach-Object { $_.DeviceID + " " + $_.Name }')
    $script:DeviceAsync = $script:DevicePs.BeginInvoke()
}

# ---------- Лампы приборки ----------

function New-LedBrush([string]$Inner, [string]$Middle, [string]$Outer) {
    $brush = New-Object System.Windows.Media.RadialGradientBrush
    $brush.GradientOrigin = New-Object System.Windows.Point(0.5, 0.42)
    $stops = @(@($Inner, 0.0), @($Middle, 0.5), @($Outer, 1.0))
    foreach ($stop in $stops) {
        $color = [System.Windows.Media.ColorConverter]::ConvertFromString($stop[0])
        $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop($color, [double]$stop[1])))
    }
    return $brush
}

function Add-Led([double]$X, [double]$Y, [double]$Size, $Colors) {
    $glow = New-Object System.Windows.Shapes.Ellipse
    $glow.Width = $Size * 2.1
    $glow.Height = $Size * 2.1
    $glowBrush = New-Object System.Windows.Media.RadialGradientBrush
    $glowColor = [System.Windows.Media.ColorConverter]::ConvertFromString($Colors[3])
    $clear = [System.Windows.Media.Color]::FromArgb(0, $glowColor.R, $glowColor.G, $glowColor.B)
    $glowBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop($glowColor, 0.3)))
    $glowBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop($clear, 1.0)))
    $glow.Fill = $glowBrush
    [System.Windows.Controls.Canvas]::SetLeft($glow, $X - $glow.Width / 2)
    [System.Windows.Controls.Canvas]::SetTop($glow, $Y - $glow.Height / 2)

    $lamp = New-Object System.Windows.Shapes.Ellipse
    $lamp.Width = $Size
    $lamp.Height = $Size
    $lamp.Fill = New-LedBrush $Colors[0] $Colors[1] $Colors[2]
    [System.Windows.Controls.Canvas]::SetLeft($lamp, $X - $Size / 2)
    [System.Windows.Controls.Canvas]::SetTop($lamp, $Y - $Size / 2)

    [void]$LedCanvas.Children.Add($glow)
    [void]$LedCanvas.Children.Add($lamp)
    return ,@($glow, $lamp)
}

# Лампы лежат над картинкой приборки: сверху 3 зелёных, 3 жёлтых, 3 красных, 3 жёлтых, 3 зелёных, по бокам оранжевые.
function Initialize-Leds {
    $script:Leds = New-Object System.Collections.ArrayList
    $script:SideLeds = New-Object System.Collections.ArrayList
    $script:AmbientOn = $false
    $green = @('#C9F5C0', '#37C552', '#15602A', '#6637C552')
    $yellow = @('#FFF2B0', '#E9C62A', '#7D6607', '#66E9C62A')
    $red = @('#FFB6A2', '#E5301A', '#7C1304', '#66E5301A')
    $orange = @('#FFD2B3', '#EE6A22', '#7F2F07', '#66EE6A22')
    $pattern = @($green, $green, $green, $yellow, $yellow, $yellow, $red, $red, $red, $yellow, $yellow, $yellow, $green, $green, $green)
    for ($i = 0; $i -lt 15; $i++) { [void]$script:Leds.Add((Add-Led (368 + $i * 56) 42 26 $pattern[$i])) }
    foreach ($y in 180, 232, 284, 336) {
        foreach ($x in 55, 1465) { [void]$script:SideLeds.Add((Add-Led $x $y 24 $orange)) }
    }
}

# Плавное перемигивание ламп, пока лаунчер на экране. На время игры выключается.
function New-LedAnimation([double]$Low, [double]$Seconds, [double]$Delay) {
    $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
    $animation.From = 1.0
    $animation.To = $Low
    $animation.Duration = New-Object System.Windows.Duration([TimeSpan]::FromSeconds($Seconds))
    $animation.BeginTime = [TimeSpan]::FromSeconds($Delay)
    $animation.AutoReverse = $true
    $animation.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $ease = New-Object System.Windows.Media.Animation.SineEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut
    $animation.EasingFunction = $ease
    return $animation
}

function Start-LedAmbient {
    if ($script:AmbientOn -or $script:Session -or $script:Sweeping -or -not $script:DashOn) { return }
    $script:AmbientOn = $true
    Set-LedCount 15
    Set-SideLedOpacity 1
    $property = [System.Windows.UIElement]::OpacityProperty
    for ($i = 0; $i -lt $script:Leds.Count; $i++) {
        # Волна от центра к краям
        $delay = [Math]::Abs($i - 7) * 0.22
        $script:Leds[$i][0].BeginAnimation($property, (New-LedAnimation 0.15 1.8 $delay))
        $script:Leds[$i][1].BeginAnimation($property, (New-LedAnimation 0.3 1.8 $delay))
    }
    for ($i = 0; $i -lt $script:SideLeds.Count; $i++) {
        $delay = [Math]::Floor($i / 2) * 0.5
        $script:SideLeds[$i][0].BeginAnimation($property, (New-LedAnimation 0.15 2.6 $delay))
        $script:SideLeds[$i][1].BeginAnimation($property, (New-LedAnimation 0.35 2.6 $delay))
    }
}

function Stop-LedAmbient {
    if (-not $script:AmbientOn) { return }
    $script:AmbientOn = $false
    $property = [System.Windows.UIElement]::OpacityProperty
    foreach ($led in @($script:Leds) + @($script:SideLeds)) {
        $led[0].BeginAnimation($property, $null)
        $led[1].BeginAnimation($property, $null)
    }
}

# Питание приборки следует за базой: база выключена, экран погашен и лампы серые.
function Set-SideLedOpacity([double]$Value) {
    foreach ($led in $script:SideLeds) {
        $led[0].Opacity = $Value
        $led[1].Opacity = $Value
    }
}

function Initialize-DashPower {
    # Без настроенных устройств приборка всегда включена
    $script:DashOn = $script:DeviceSlots.Count -eq 0
    $DashOffImage.Opacity = $(if ($script:DashOn) { 0 } else { 1 })
    if (-not $script:DashOn) {
        Set-LedCount 0
        Set-SideLedOpacity 0
    }
}

function Set-DashPower([bool]$On) {
    if ($script:DashOn -eq $On) { return }
    $script:DashOn = $On
    Write-Log "Приборка: $(if ($On) { 'база включена' } else { 'база выключена' })"
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fade.To = $(if ($On) { 0.0 } else { 1.0 })
    $fade.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(700))
    $DashOffImage.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    if ($On) {
        Set-SideLedOpacity 1
        if (-not $script:Session) { Start-LedSweep $null }
        else { Set-LedCount 15 }
        return
    }
    Stop-LedAmbient
    if ($script:Sweeping -and -not $script:SweepApp) {
        $script:SweepTimer.Stop()
        $script:Sweeping = $false
    }
    Set-LedCount 0
    Set-SideLedOpacity 0
}

# Включает первые $Count ламп, остальные гасит.
function Set-LedCount([int]$Count) {
    for ($i = 0; $i -lt $script:Leds.Count; $i++) {
        $opacity = if ($i -lt $Count) { 1.0 } else { 0.0 }
        $script:Leds[$i][0].Opacity = $opacity
        $script:Leds[$i][1].Opacity = $opacity
    }
}

# Лампы загораются от краёв к центру и гаснут от центра к краям, затем запускается выбранная игра. Без игры анимация просто показывается.
# Длительность считается по часам, поэтому занятый компьютер не растягивает запуск игры.
function Start-LedSweep($App) {
    # Приборка выключена: анимации нет, игра запускается сразу
    if (-not $script:DashOn) {
        if ($App) { Open-App $App }
        return
    }
    Stop-LedAmbient
    $script:SweepApp = $App
    $script:Sweeping = $true
    Set-LedCount 0
    $script:SweepClock = [System.Diagnostics.Stopwatch]::StartNew()
    $script:SweepTimer.Start()
}

function Update-LedSweep {
    $elapsed = $script:SweepClock.ElapsedMilliseconds
    $step = [int][Math]::Floor($elapsed / 70)
    for ($i = 0; $i -lt $script:Leds.Count; $i++) {
        $distance = [Math]::Abs($i - 7)                             # 0 в центре, 7 у края
        $lit = $step -ge (7 - $distance) -and $step -lt (8 + $distance)
        $value = $(if ($lit) { 1.0 } else { 0.0 })
        $script:Leds[$i][0].Opacity = $value
        $script:Leds[$i][1].Opacity = $value
    }
    if ($elapsed -lt 1400) { return }                                # короткая пауза, затем лампы горят
    $script:SweepTimer.Stop()
    $script:Sweeping = $false
    $app = $script:SweepApp
    $script:SweepApp = $null
    Set-LedCount 15
    if ($app) { Open-App $app }
    else { Start-LedAmbient }
}

# Что происходит после анимации: сразу открывается выбор аккаунта Steam или запускается игра.
function Open-App($App, [bool]$NoticeSeen = $false) {
    if ($App.Kind -eq 'missing') {
        Show-Overlay "$($App.Name) не настроена" 'Не найден ярлык для запуска на рабочем столе. Позови администратора клуба.' 'Закрыть'
        Start-LedAmbient
        return
    }
    # Предупреждение категории: кнопка «ОК» закрывает окно, и запуск продолжается
    if (-not $NoticeSeen) {
        $category = @($script:Config.categories | Where-Object { $_ -and $_.id -eq $App.Category }) | Select-Object -First 1
        if ($category -and $category.notice) {
            $script:NoticeApp = $App
            $TxtNoticeGame.Text = $App.Name
            $TxtNoticeText.Text = [string]$category.notice
            $NoticePanel.Visibility = 'Visible'
            [void]$BtnNoticeOk.Focus()
            return
        }
    }
    if ($script:Config.askSteamAccount -and $App.AskAccount -ne $false -and $script:SteamExe) { Start-App $App $true }
    else { Start-App $App }
}

function Show-GameInfo($App) {
    $TxtInfoTitle.Text = $App.Name
    $TxtInfoText.Text = $App.Info
    $InfoPanel.Visibility = 'Visible'
    [void]$BtnInfoOk.Focus()
}

function Hide-GameInfo {
    $InfoPanel.Visibility = 'Collapsed'
    if ($script:LastTile) { [void]$script:LastTile.Focus() }
}

function New-Tile($App) {
    $button = New-Object System.Windows.Controls.Button
    $button.Style = $Window.FindResource('TileButton')
    $button.Tag = $App

    $content = $null
    if ($App.Cover) { $content = New-CoverImage $App.Cover }
    if (-not $content) {
        # Нет обложки: плитка с названием
        $content = New-Object System.Windows.Controls.TextBlock
        $content.Text = $App.Name
        $content.TextWrapping = 'Wrap'
        $content.TextAlignment = 'Center'
        $content.HorizontalAlignment = 'Center'
        $content.VerticalAlignment = 'Center'
        $content.Margin = New-Object System.Windows.Thickness(20)
        $content.FontSize = 26
        $content.FontWeight = [System.Windows.FontWeights]::SemiBold
        $content.Foreground = [System.Windows.Media.Brushes]::White
    }
    # Значок «i» в углу плитки: описание игры простыми словами
    if ($App.Info) {
        $holder = New-Object System.Windows.Controls.Grid
        [void]$holder.Children.Add($content)
        $info = New-Object System.Windows.Controls.Button
        $info.Style = $Window.FindResource('InfoBadge')
        $info.Tag = $App
        $info.ToolTip = 'Об игре'
        $info.Add_Click({
            param($sender, $e)
            $e.Handled = $true
            Show-GameInfo $sender.Tag
        })
        [void]$holder.Children.Add($info)
        $content = $holder
    }
    $button.Content = $content

    $select = {
        param($sender, $e)
        $script:LastTile = $sender
        $TxtSelected.Text = $sender.Tag.Name
        $TxtHint.Text = 'Нажми, чтобы запустить'
        if ($sender.Tag.Extra) { $TxtHint.Text += ". Правая кнопка мыши: $($sender.Tag.Extra.Name)" }
        $script:ForegroundBeforeClick = [SimraceNative]::CurrentForeground()
    }
    $button.Add_MouseEnter($select)
    $button.Add_GotKeyboardFocus($select)
    $button.Add_Click({
        param($sender, $e)
        if ($script:Session -or $script:Sweeping) { return }
        Start-LedSweep $sender.Tag
    })
    # Плитка и необязательная кнопка под ней, например «Запустить сервер»
    $item = New-Object System.Windows.Controls.StackPanel
    [void]$item.Children.Add($button)
    # Правая кнопка мыши: дополнительное действие плитки, например запуск сервера
    if ($App.Extra) {
        $button.Add_MouseRightButtonUp({
            param($sender, $e)
            $e.Handled = $true
            if (-not $script:Session -and -not $script:Sweeping) { Start-Utility $sender.Tag.Extra }
        })
    }
    return $button
}

# ---------- Микшер громкости ----------

# Отдельный Add-Type: если код звука не соберётся, лаунчер продолжит работать без микшера.
function Initialize-Audio {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class SimraceAudio
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] private class MMDeviceEnumerator { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int context, IntPtr parameters, [MarshalAs(UnmanagedType.IUnknown)] out object result);
        [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int Item(int index, out IMMDevice device);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropertyKey { public Guid Format; public int Id; }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropVariant { public ushort Type; public ushort R1; public ushort R2; public ushort R3; public IntPtr Value; public IntPtr Extra; }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        int NotImpl1();
        int NotImpl2();
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
    }

    // Выбор устройства по умолчанию в Windows не имеет официального API. Этот интерфейс недокументирован,
    // но его используют системные и сторонние переключатели звука. Сбой обрабатывается в вызывающем коде.
    [ComImport, Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")] private class PolicyConfigClient { }

    [ComImport, Guid("F8679F50-850A-41CF-9C72-430F290290C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPolicyConfig
    {
        int NotImpl1(); int NotImpl2(); int NotImpl3(); int NotImpl4(); int NotImpl5();
        int NotImpl6(); int NotImpl7(); int NotImpl8(); int NotImpl9(); int NotImpl10();
        [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
    }

    // Активные устройства вывода в виде строк: id, табуляция, название
    public static string[] GetOutputs()
    {
        IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        IMMDeviceCollection devices;
        Marshal.ThrowExceptionForHR(enumerator.EnumAudioEndpoints(0, 1, out devices));   // вывод, только активные
        int count;
        Marshal.ThrowExceptionForHR(devices.GetCount(out count));
        List<string> result = new List<string>();
        for (int i = 0; i < count; i++)
        {
            IMMDevice device;
            if (devices.Item(i, out device) != 0) continue;
            string id;
            if (device.GetId(out id) != 0) continue;
            string name = id;
            IPropertyStore store;
            if (device.OpenPropertyStore(0, out store) == 0)
            {
                PropertyKey key = new PropertyKey();
                key.Format = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0");   // PKEY_Device_FriendlyName
                key.Id = 14;
                PropVariant value;
                if (store.GetValue(ref key, out value) == 0 && value.Value != IntPtr.Zero) name = Marshal.PtrToStringUni(value.Value);
            }
            result.Add(id + "\t" + name);
        }
        return result.ToArray();
    }

    public static string GetDefaultOutput()
    {
        string id;
        Marshal.ThrowExceptionForHR(Speakers().GetId(out id));
        return id;
    }

    public static void SetDefaultOutput(string id)
    {
        IPolicyConfig config = (IPolicyConfig)new PolicyConfigClient();
        for (int role = 0; role < 3; role++) Marshal.ThrowExceptionForHR(config.SetDefaultEndpoint(id, role));
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioEndpointVolume
    {
        int NotImpl1();
        int NotImpl2();
        int NotImpl3();
        int NotImpl4();
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid context);
        int NotImpl5();
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionManager2
    {
        int NotImpl1();
        int NotImpl2();
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessions);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionEnumerator
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, [MarshalAs(UnmanagedType.IUnknown)] out object session);
    }

    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionControl2
    {
        int NotImpl1(); int NotImpl2(); int NotImpl3(); int NotImpl4(); int NotImpl5();
        int NotImpl6(); int NotImpl7(); int NotImpl8(); int NotImpl9();
        int NotImpl10(); int NotImpl11();
        [PreserveSig] int GetProcessId(out uint processId);
        [PreserveSig] int IsSystemSoundsSession();
    }

    [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISimpleAudioVolume
    {
        [PreserveSig] int SetMasterVolume(float level, ref Guid context);
        [PreserveSig] int GetMasterVolume(out float level);
    }

    private static IMMDevice Speakers()
    {
        IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        IMMDevice device;
        Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0, 1, out device));   // вывод, мультимедиа
        return device;
    }

    private static object Activate(Guid iid)
    {
        object result;
        Marshal.ThrowExceptionForHR(Speakers().Activate(ref iid, 23, IntPtr.Zero, out result));   // 23 = CLSCTX_ALL
        return result;
    }

    public static float GetSystem()
    {
        IAudioEndpointVolume volume = (IAudioEndpointVolume)Activate(typeof(IAudioEndpointVolume).GUID);
        float level;
        Marshal.ThrowExceptionForHR(volume.GetMasterVolumeLevelScalar(out level));
        return level;
    }

    public static void SetSystem(float level)
    {
        IAudioEndpointVolume volume = (IAudioEndpointVolume)Activate(typeof(IAudioEndpointVolume).GUID);
        Guid context = Guid.Empty;
        Marshal.ThrowExceptionForHR(volume.SetMasterVolumeLevelScalar(level, ref context));
    }

    // Группы: "mumble" это Mumble, "browser" это Edge, "game" это все остальные программы, кроме Steam и системных звуков.
    private static List<ISimpleAudioVolume> Group(string group)
    {
        List<ISimpleAudioVolume> result = new List<ISimpleAudioVolume>();
        IAudioSessionManager2 manager = (IAudioSessionManager2)Activate(typeof(IAudioSessionManager2).GUID);
        IAudioSessionEnumerator sessions;
        Marshal.ThrowExceptionForHR(manager.GetSessionEnumerator(out sessions));
        int count;
        Marshal.ThrowExceptionForHR(sessions.GetCount(out count));
        for (int i = 0; i < count; i++)
        {
            object session;
            if (sessions.GetSession(i, out session) != 0) continue;
            IAudioSessionControl2 control = session as IAudioSessionControl2;
            ISimpleAudioVolume volume = session as ISimpleAudioVolume;
            if (control == null || volume == null) continue;
            if (control.IsSystemSoundsSession() == 0) continue;     // 0 = системные звуки

            string name = "";
            uint processId;
            if (control.GetProcessId(out processId) == 0)
            {
                try { name = Process.GetProcessById((int)processId).ProcessName.ToLowerInvariant(); }
                catch (ArgumentException) { continue; }
            }
            bool isMumble = name == "mumble";
            bool isSteam = name == "steam" || name == "steamwebhelper";
            bool isBrowser = name == "msedge";
            bool match = group == "mumble" ? isMumble : group == "browser" ? isBrowser : (!isMumble && !isSteam && !isBrowser);
            if (match) result.Add(volume);
        }
        return result;
    }

    // Возвращает -1, если программа сейчас не издаёт звук и громкость узнать нельзя.
    public static float GetGroup(string group)
    {
        foreach (ISimpleAudioVolume volume in Group(group))
        {
            float level;
            if (volume.GetMasterVolume(out level) == 0) return level;
        }
        return -1f;
    }

    public static void SetGroup(string group, float level)
    {
        Guid context = Guid.Empty;
        foreach (ISimpleAudioVolume volume in Group(group)) volume.SetMasterVolume(level, ref context);
    }
}
'@
        return $true
    }
    catch {
        Write-Log "Микшер отключён, код звука не собрался: $_"
        return $false
    }
}

function Set-MixerSlider($Slider, $Label, [double]$Level) {
    $Slider.Value = [Math]::Round($Level * 100)
    $Label.Text = "$([int]$Slider.Value)%"
}

# Список устройств вывода. Текущее выделено цветом.
function Update-OutputList {
    $OutputList.Children.Clear()
    $current = [SimraceAudio]::GetDefaultOutput()
    foreach ($line in [SimraceAudio]::GetOutputs()) {
        $parts = $line -split "`t", 2
        $button = New-Object System.Windows.Controls.Button
        $button.Style = $MixerWindow.FindResource('PanelButton')
        $button.Tag = $parts[0]
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = $parts[1]
        $label.TextTrimming = 'CharacterEllipsis'
        if ($parts[0] -eq $current) { $label.Foreground = $MixerWindow.FindResource('Accent') }
        $button.Content = $label
        $button.Add_Click({
            param($sender, $e)
            try {
                [SimraceAudio]::SetDefaultOutput([string]$sender.Tag)
                Write-Log "Вывод звука изменён: $($sender.Content.Text)"
                Update-OutputList
                $script:MixerLoading = $true
                Set-MixerSlider $SliderSystem $TxtSystem ([SimraceAudio]::GetSystem())
            }
            catch { Write-Log "Не изменён вывод звука: $_" }
            finally { $script:MixerLoading = $false }
        })
        [void]$OutputList.Children.Add($button)
    }
}

# Отдельное маленькое окно поверх всего: игра под ним продолжает работать.
function Switch-MixerWindow {
    if ($MixerWindow.IsVisible) {
        Hide-MixerWindow $true
        return
    }
    # Щелчок по кнопке сначала закрыл окно через потерю фокуса: второй раз не открываем
    if (((Get-Date) - $script:MixerHiddenAt).TotalMilliseconds -lt 300) { return }
    $script:MixerPrevious = [SimraceNative]::CurrentForeground()
    $script:PanelQuit.Visibility = $(if ($script:Session) { 'Visible' } else { 'Collapsed' })
    Update-TimerDisplay
    $script:MixerLoading = $true
    try {
        if (-not $script:AudioReady) { throw 'звук недоступен' }
        Update-OutputList
        Set-MixerSlider $SliderSystem $TxtSystem ([SimraceAudio]::GetSystem())
        # Если программа сейчас молчит, показываем выбранное ранее значение: оно применится, когда звук появится
        $game = [SimraceAudio]::GetGroup('game')
        if ($game -lt 0) { $game = if ($null -ne $script:GameLevel) { $script:GameLevel } else { 1 } }
        Set-MixerSlider $SliderGame $TxtGame $game
        $mumble = [SimraceAudio]::GetGroup('mumble')
        if ($mumble -lt 0) { $mumble = if ($null -ne $script:MumbleLevel) { $script:MumbleLevel } else { 1 } }
        Set-MixerSlider $SliderMumble $TxtMumble $mumble
        $browser = [SimraceAudio]::GetGroup('browser')
        if ($browser -lt 0) { $browser = if ($null -ne $script:BrowserLevel) { $script:BrowserLevel } else { 1 } }
        Set-MixerSlider $SliderBrowser $TxtBrowser $browser
    }
    catch { Write-Log "Не прочитана громкость: $_" }
    finally { $script:MixerLoading = $false }
    $MixerWindow.Left = [System.Windows.SystemParameters]::PrimaryScreenWidth - $MixerWindow.Width - 56
    $MixerWindow.Top = 156      # ниже панели сеанса
    $MixerWindow.Show()
    [SimraceNative]::ForceForeground((New-Object System.Windows.Interop.WindowInteropHelper($MixerWindow)).Handle)
}

function Hide-MixerWindow([bool]$ReturnFocus) {
    if (-not $MixerWindow.IsVisible) { return }
    $MixerWindow.Hide()
    $script:MixerHiddenAt = Get-Date
    if ($ReturnFocus) { [SimraceNative]::ActivateWindow($script:MixerPrevious) }
}

# Игра или Mumble могут запуститься позже: их новые звуковые потоки получают выбранную громкость
function Update-MixerLevels {
    if (-not $script:AudioReady) { return }
    if ($null -ne $script:GameLevel) { [SimraceAudio]::SetGroup('game', [float]$script:GameLevel) }
    if ($null -ne $script:MumbleLevel) { [SimraceAudio]::SetGroup('mumble', [float]$script:MumbleLevel) }
    if ($null -ne $script:BrowserLevel) { [SimraceAudio]::SetGroup('browser', [float]$script:BrowserLevel) }
}

# ---------- Переключение между игрой и лаунчером ----------

# Как только игра запустилась, экран ожидания больше не нужен: в лаунчере видны кнопки и панель игры.
function Show-GameBar {
    $SheenHost.Visibility = 'Collapsed'
    $TxtGameRunning.Text = $script:Session.App.Name
    $ImgRunning.Source = $null
    if ($script:Session.App.Cover) {
        $coverImage = New-CoverImage $script:Session.App.Cover 240
        if ($coverImage) { $ImgRunning.Source = $coverImage.Source }
    }
    $Overlay.Visibility = 'Collapsed'
    $SelectedInfo.Visibility = 'Collapsed'
    $GameBar.Visibility = 'Visible'
    $TilesHost.IsEnabled = $false
    $TilesHost.Opacity = 0.35
    [SimraceNative]::SetBackground($false)      # теперь окно можно активировать, в том числе через Alt+Tab
    [SimraceNative]::AllowSwitching = $true
}

function Hide-GameBar {
    $SheenHost.Visibility = 'Visible'
    $GameBar.Visibility = 'Collapsed'
    $SelectedInfo.Visibility = 'Visible'
    $TilesHost.IsEnabled = $true
    $TilesHost.Opacity = 1
    [SimraceNative]::AllowSwitching = $false
}

# После включения компьютера Steam, Mumble и другие программы стартуют за лаунчером:
# он держится поверх всего, а их окна сразу сворачиваются. Выбор игры завершает этот режим.
function Start-BootGuard {
    $script:BootUntil = (Get-Date).AddSeconds(60)
    $Window.Topmost = $true
}

function Update-BootGuard {
    if ($script:BootUntil -eq [datetime]::MinValue) { return }
    if ((Get-Date) -ge $script:BootUntil) {
        Stop-BootGuard
        return
    }
    [SimraceNative]::MinimizeOtherWindows([IntPtr]::Zero)
}

function Stop-BootGuard {
    if ($script:BootUntil -eq [datetime]::MinValue) { return }
    $script:BootUntil = [datetime]::MinValue
    $Window.Topmost = $false
}

# Запоминает окно игры: куда возвращаться. Лаунчер, Steam и кнопочные программы окном игры не считаются.
function Update-GameWindow {
    if (-not $script:Session) { return }
    $current = [SimraceNative]::CurrentForeground()
    if ($current -eq [IntPtr]::Zero -or $current -eq [SimraceNative]::LauncherWindow) { return }
    if ($current -eq $script:GameWindow) { return }
    $name = [SimraceNative]::ProcessNameOf($current)
    if ($name -and $script:NotGameProcesses -notcontains $name -and [SimraceNative]::IsLargeWindow($current)) {
        $script:GameWindow = $current
        $script:Session.GamePid = [SimraceNative]::ProcessIdOf($current)
    }
}

# Выводит лаунчер на экран. Игру сворачиваем, как при Alt+Tab, иначе она может остаться поверх.
function Show-Launcher {
    Update-GameWindow
    if ($script:Session -and $script:GameWindow -ne [IntPtr]::Zero -and [SimraceNative]::CurrentForeground() -eq $script:GameWindow) {
        [SimraceNative]::Minimize($script:GameWindow)
    }
    Restore-LauncherWindow
    if ($GameBar.Visibility -eq 'Visible') { [void]$BtnResumeGame.Focus() }
}

function Resume-Game {
    $target = $script:GameWindow
    # Игра закрыта, а Content Manager или другая программа запуска ещё открыта: возвращаемся в неё
    if (-not [SimraceNative]::WindowExists($target) -and $script:Session) {
        $found = Find-SessionGameWindow $script:Session
        $target = $(if ($found -ne [IntPtr]::Zero) { $found } else { Get-HostWindow $script:Session })
        if ($found -ne [IntPtr]::Zero) { $script:GameWindow = $found }
    }
    if (-not [SimraceNative]::WindowExists($target)) {
        Write-Log 'Вернуться в игру: окно игры не найдено'
        return
    }
    [SimraceNative]::MinimizeOtherWindows($target)
    [SimraceNative]::SendToBack()
    [SimraceNative]::ForceForeground($target)
}

# Команда «В лаунчер». Пока Steam ждёт выбора аккаунта, возвращаться можно только к плиткам: запуск отменяется.
function Exit-ToLauncher {
    if ($script:ServiceMode) {
        Exit-ServiceMode
        return
    }
    $session = $script:Session
    if ($session -and ($session.Stage -eq 'closing-steam' -or $session.Stage -eq 'waiting-login')) {
        Stop-Launch
        return
    }
    Show-Launcher
}

# Ctrl+Shift+End: из игры в лаунчер и обратно
function Switch-GameAndLauncher {
    if ($AdminPanel.Visibility -eq 'Visible') { return }
    $inLauncher = [SimraceNative]::CurrentForeground() -eq [SimraceNative]::LauncherWindow
    if ($inLauncher -and $GameBar.Visibility -eq 'Visible') { Resume-Game }
    else { Exit-ToLauncher }
}

# Все процессы текущей игры: окно игры, список watch и программы из её папки Steam.
function Get-GameProcesses($Session) {
    $app = $Session.App
    if ($null -eq $Session.ExeNames) {
        $names = @($app.Watch | Where-Object { $_ })
        if ($app.SteamAppId) {
            $folder = Get-SteamAppDir ([string]$app.SteamAppId)
            if ($folder) {
                $names += @(Get-ChildItem -LiteralPath $folder -Recurse -Filter '*.exe' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
            }
        }
        $Session.ExeNames = @($names | Sort-Object -Unique)
        Write-Log "Закрытие $($app.Name): ищу процессы: $($Session.ExeNames -join ', ')"
    }
    $found = @()
    if ($Session.ExeNames.Count -gt 0) { $found += @(Get-Process -Name $Session.ExeNames -ErrorAction SilentlyContinue) }
    if ($Session.GamePid) { $found += @(Get-Process -Id $Session.GamePid -ErrorAction SilentlyContinue) }
    return @($found | Where-Object { $_.Id -ne $PID } | Sort-Object -Property Id -Unique)
}

# Сначала просим игру закрыться, через несколько секунд завершаем принудительно. Шаги выполняет Update-Session.
function Stop-CurrentGame {
    $session = $script:Session
    if (-not $session) { return }
    if ($session.Stage -eq 'closing-steam' -or $session.Stage -eq 'waiting-login') {
        Stop-Launch
        return
    }
    Write-Log "Закрываю игру: $($session.App.Name)"
    [SimraceNative]::RequestClose($script:GameWindow)
    Set-SessionStage 'closing-game'
    $session.Forced = $false
    Show-Waiting "Закрываю $($session.App.Name)" 'Это займёт несколько секунд.' 'Вернуться к выбору игры'
}

# ---------- Выход для сотрудника ----------

# Имя администратора: из настроек, иначе первая включённая учётная запись группы администраторов.
# Администратор по имени компьютера: SIMRACE-5 -> admin5. Исключение: на SIMRACE-14 просто admin.
function Get-AdminByComputerName {
    $match = [regex]::Match($env:COMPUTERNAME, '(\d+)$')
    if (-not $match.Success) { return '' }
    $number = [int]$match.Value
    return $(if ($number -eq 14) { 'admin' } else { "admin$number" })
}

function Get-DefaultAdminName {
    $byName = Get-AdminByComputerName
    if ($byName) {
        try { if (Get-LocalUser -Name $byName -ErrorAction Stop) { return $byName } }
        catch { }
    }
    if ($script:Config.adminUser) { return [string]$script:Config.adminUser }
    try {
        $accounts = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | Where-Object { $_.ObjectClass -eq 'User' -and $_.PrincipalSource -eq 'Local' } | ForEach-Object {
            Get-LocalUser -SID $_.SID -ErrorAction SilentlyContinue
        } | Where-Object { $_.Enabled })
        $preferred = $accounts | Where-Object { $_.SID.Value -notlike '*-500' } | Select-Object -First 1
        if (-not $preferred) { $preferred = $accounts | Select-Object -First 1 }
        if ($preferred) { return [string]$preferred.Name }
    }
    catch { Write-Log "Не получен список администраторов: $_" }
    return ''
}

# Показывает текущий язык в статус-баре и рядом с паролем
function Update-LayoutLabel {
    $language = [SimraceNative]::CurrentLanguage()
    if (-not $language) { return }
    if ($BtnStatusLang.Content -ne $language) { $BtnStatusLang.Content = $language }
    if ($BtnLayout.Content -ne $language) { $BtnLayout.Content = $language }
}

function Switch-KeyboardLayout {
    $manager = [System.Windows.Input.InputLanguageManager]::Current
    $languages = @($manager.AvailableInputLanguages)
    if ($languages.Count -lt 2) { return }
    $index = [array]::IndexOf($languages, $manager.CurrentInputLanguage)
    $manager.CurrentInputLanguage = $languages[($index + 1) % $languages.Count]
    Update-LayoutLabel
    if ($AdminPanel.Visibility -eq 'Visible') { [void]$PasswordInput.Focus() }
}

# Запрос к службе лаунчера. $null: служба не запущена.
function Invoke-Agent([hashtable]$Request, [int]$ConnectMs = 1000) {
    $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'SimraceAgent', [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $client.Connect($ConnectMs)
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $writer = New-Object System.IO.StreamWriter($client, $encoding, 4096, $true)
        $writer.AutoFlush = $true
        $reader = New-Object System.IO.StreamReader($client, $encoding, $false, 4096, $true)
        $writer.WriteLine(($Request | ConvertTo-Json -Compress))
        $line = $reader.ReadLine()
        if ($line) { return ($line | ConvertFrom-Json) }
        return $null
    }
    catch { return $null }
    finally { $client.Dispose() }
}

function Set-AdminPage([string]$Page) {
    $AdminLogin.Visibility = $(if ($Page -eq 'login') { 'Visible' } else { 'Collapsed' })
    $AdminMenu.Visibility = $(if ($Page -eq 'menu') { 'Visible' } else { 'Collapsed' })
    $AdminConfirm.Visibility = $(if ($Page -eq 'confirm') { 'Visible' } else { 'Collapsed' })
    $script:AdminLastUse = Get-Date
}

function Show-AdminPanel {
    if ($script:ServiceMode) { Exit-ServiceMode }
    Show-Launcher
    if (-not $AdminUserInput.Text) { $AdminUserInput.Text = Get-DefaultAdminName }
    Update-LayoutLabel
    $PasswordInput.Clear()
    $TxtAdminError.Visibility = 'Collapsed'
    $script:AdminToken = $null
    Start-UwfStatusCheck
    Set-AdminPage 'login'
    $AdminPanel.Visibility = 'Visible'
    if ($AdminUserInput.Text) { [void]$PasswordInput.Focus() } else { [void]$AdminUserInput.Focus() }
}

function Hide-AdminPanel {
    $PasswordInput.Clear()
    if ($script:AdminToken) { [void](Invoke-Agent @{ action = 'logout' }) }
    $script:AdminToken = $null
    $AdminPanel.Visibility = 'Collapsed'
    # Панель открыта во время запуска: окно Steam или игры снова должно быть поверх лаунчера
    if ($script:Session -and -not $script:Session.BarShown) { [SimraceNative]::SetBackground($true) }
    # Панель открыта во время игры: возвращаем игру на передний план
    if ($GameBar.Visibility -eq 'Visible') { [void]$BtnResumeGame.Focus() }
    elseif ($script:LastTile) { [void]$script:LastTile.Focus() }
}

# Лаунчер свёрнут для работы администратора: видны панель задач и рабочий стол, клавиши Windows работают.
# Вернуть его можно кнопкой на панели задач или сочетанием Ctrl+Shift+End. Перезагрузка тоже вернёт его.
function Enter-ServiceMode {
    Write-Log 'Лаунчер свёрнут'
    Hide-AdminPanel
    Hide-MixerWindow $false
    Stop-BootGuard
    $script:ServiceMode = $true
    [SimraceNative]::ServiceMode = $true
    [SimraceNative]::SetBackground($false)
    Restore-Shell       # панель задач надёжно возвращается только после перезапуска Проводника
    $Window.WindowState = 'Minimized'
}

function Exit-ServiceMode {
    $script:ServiceMode = $false
    [SimraceNative]::ServiceMode = $false
    Write-Log 'Лаунчер развёрнут'
    [SimraceNative]::SetTaskbarVisible($false)
    $Window.WindowState = 'Maximized'
    Restore-LauncherWindow
}

# Пароль вводится один раз. Если службы нет, пароль проверяет сам лаунчер, а действиям с защитой UWF нужна служба.
function Submit-AdminLogin {
    $user = $AdminUserInput.Text.Trim()
    $allowed = $false
    $token = $null
    if ($user) {
        $response = Invoke-Agent @{ action = 'auth'; user = $user; password = $PasswordInput.Password }
        if ($response) {
            $allowed = [bool]$response.ok
            $token = $response.token
        }
        else {
            Write-Log 'Служба лаунчера не отвечает, пароль проверяет лаунчер'
            try { $allowed = [SimraceNative]::IsAdminPassword($user, $PasswordInput.Password) }
            catch { Write-Log "Ошибка проверки пароля: $_" }
        }
    }
    $PasswordInput.Clear()
    if (-not $allowed) {
        Write-Log "Неверный пароль администратора: $user"
        $TxtAdminError.Visibility = 'Visible'
        [void]$PasswordInput.Focus()
        return
    }
    Write-Log "Панель администратора открыта: $user"
    $script:AdminToken = $token
    $status = Invoke-Agent @{ action = 'status' }
    $TxtAdminNote.Text = $(if ($status) { "Версия лаунчера: $($status.version)" } else { 'Служба лаунчера не запущена: обновление и блокировка недоступны. Обнови лаунчер командой на этом компьютере.' })
    $TxtAdminNote.Foreground = $Window.FindResource('Muted')
    # Служба видит защиту надёжнее, чем гостевая учётная запись
    if ($status) { Set-UwfDisplay $(if ($status.uwfNow) { 'ON' } else { 'OFF' }) }
    Set-AdminPage 'menu'
}

function Show-AdminNote([string]$Text) {
    $TxtAdminNote.Text = $Text
    $TxtAdminNote.Foreground = $Window.FindResource('Accent')
    Set-AdminPage 'menu'
}

# Подтверждение действия с перезагрузкой. Пароль повторно не спрашиваем.
function Show-AdminConfirm([string]$Action, [string]$Title, [string]$Text, [string]$Button) {
    if (-not $script:AdminToken) {
        Show-AdminNote 'Служба лаунчера не запущена. Обнови лаунчер командой на этом компьютере.'
        return
    }
    if ($script:Session) { $Text = "$Text Запущенная игра закроется." }
    $script:AdminPending = $Action
    $TxtConfirmTitle.Text = $Title
    $TxtConfirmText.Text = $Text
    $BtnConfirmOk.Content = $Button
    Set-AdminPage 'confirm'
}

function Request-AdminUpdate {
    if (-not $script:AdminToken) {
        Show-AdminNote 'Служба лаунчера не запущена. Обнови лаунчер командой на этом компьютере.'
        return
    }
    $check = Invoke-Agent @{ action = 'check'; token = $script:AdminToken }
    $versions = ''
    if ($check -and $check.ok) {
        if (-not $check.latest) { $versions = "Установлена версия $($check.installed). Версию на GitHub проверить не удалось." }
        elseif ($check.latest -eq $check.installed) { $versions = "Установлена последняя версия: $($check.installed)." }
        else { $versions = "Установлена $($check.installed), доступна $($check.latest)." }
    }
    $plan = $(if ($script:UwfOn -eq $false) { 'Лаунчер обновится сейчас, затем спросит, заблокировать ли ПК.' } else { 'Защита UWF отключится, компьютер перезагрузится и обновит лаунчер. Затем лаунчер спросит, заблокировать ли ПК.' })
    Show-AdminConfirm 'update' 'Обновить лаунчер' ("$versions $plan".Trim()) 'Обновить'
}

function Request-AdminUwf {
    if ($script:UwfOn -eq $false) {
        # Как в UWF-Panel: без диска Z: не будет файла подкачки
        $text = $(if (Test-Path -LiteralPath 'Z:\') { 'Защита UWF включится, компьютер перезагрузится. Изменения после этого будут сбрасываться при каждой перезагрузке.' }
                  else { 'Диск Z: не найден. Без него не будет файла подкачки, и некоторые игры не запустятся. Всё равно включить защиту? Компьютер перезагрузится.' })
        Show-AdminConfirm 'uwf-on' 'Заблокировать ПК' $text 'Заблокировать'
    }
    else { Show-AdminConfirm 'uwf-off' 'Разблокировать ПК' 'Защита UWF выключится, компьютер перезагрузится. Пока она выключена, изменения сохраняются.' 'Разблокировать' }
}

# Выполняет подтверждённое действие
function Invoke-AdminPending {
    $request = switch ($script:AdminPending) {
        'update' { @{ action = 'update'; token = $script:AdminToken } }
        'uwf-on' { @{ action = 'uwf'; token = $script:AdminToken; enable = $true } }
        'uwf-off' { @{ action = 'uwf'; token = $script:AdminToken; enable = $false } }
        'reboot' { @{ action = 'reboot'; token = $script:AdminToken } }
        'shutdown' { @{ action = 'shutdown'; token = $script:AdminToken } }
    }
    $response = Invoke-Agent $request 3000
    if (-not $response -or -not $response.ok) {
        Show-AdminNote $(if ($response) { [string]$response.error } else { 'Служба лаунчера не ответила.' })
        return
    }
    $script:AdminToken = $null
    $AdminPanel.Visibility = 'Collapsed'
    if ($script:AdminPending -eq 'shutdown') { Show-Waiting 'Компьютер выключается' 'Подожди немного.' '' }
    elseif ($response.reboot) { Show-Waiting 'Компьютер перезагружается' 'Подожди немного.' '' }
    else { $script:AgentPollUntil = (Get-Date).AddMinutes(3) }
}

# Настройки и окно UWF открывает служба, без повторного пароля. Если службы нет, Windows спросит пароль сама.
function Open-AdminWindow([string]$FileName, [string]$Title) {
    if ($script:AdminToken) {
        $response = Invoke-Agent @{ action = 'open'; token = $script:AdminToken; file = $FileName }
        if ($response -and $response.ok) {
            $script:BringTitle = $Title
            $script:BringUntil = (Get-Date).AddSeconds(15)
            return
        }
        Write-Log "Служба не открыла окно: $(if ($response) { $response.error } else { 'нет ответа' })"
    }
    Start-AdminScript $FileName
}

# Диспетчер задач запрещён гостю, поэтому его открывает служба после входа в панель
function Open-TaskManager {
    if ($script:AdminToken) {
        $response = Invoke-Agent @{ action = 'open'; token = $script:AdminToken; file = 'taskmgr' }
        if ($response -and $response.ok) {
            $script:BringTitle = 'Диспетчер задач|Task Manager'
            $script:BringUntil = (Get-Date).AddSeconds(15)
            return
        }
        Show-AdminNote $(if ($response) { "$($response.error) Если служба ещё старая, перезагрузи ПК." } else { 'Служба лаунчера не ответила.' })
        return
    }
    try { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\Taskmgr.exe') -Verb RunAs }
    catch { Write-Log "Диспетчер задач не запущен: $_" }
}

# Настройки сохранены и администратор попросил перезапуск. Во время игры ждём её окончания.
function Test-RestartRequest {
    if ($script:Session) { return }
    $file = Get-Item -LiteralPath $script:RestartFile -ErrorAction SilentlyContinue
    if (-not $file -or $file.LastWriteTime -le $script:StartedAt) { return }
    Write-Log 'Перезапуск по запросу из настроек'
    Close-Launcher 2
}

# Закрытие или перезапуск самого лаунчера
function Close-Launcher([int]$Code) {
    Write-Log "$(if ($Code -eq 2) { 'Перезапуск' } else { 'Закрытие' }) лаунчера"
    # Код 2 говорит сторожу запустить лаунчер заново
    $script:ExitCode = $Code
    $script:AllowClose = $true
    $Window.Close()
}

# ---------- Опрос службы в фоне: окно не ждёт её ответа ----------

function Start-AgentPoller {
    $script:AgentShared = [hashtable]::Synchronized(@{ Status = $null; Overlay = $null; Stop = $false; Busy = $false })
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($Shared)
        $encoding = New-Object System.Text.UTF8Encoding($false)
        function Send-Line([string]$Line) {
            $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'SimraceAgent', [System.IO.Pipes.PipeDirection]::InOut)
            try {
                $client.Connect(500)
                $writer = New-Object System.IO.StreamWriter($client, $encoding, 4096, $true)
                $writer.AutoFlush = $true
                $reader = New-Object System.IO.StreamReader($client, $encoding, $false, 4096, $true)
                $writer.WriteLine($Line)
                return $reader.ReadLine()
            }
            catch { return $null }
            finally { $client.Dispose() }
        }
        $tick = 0
        while (-not $Shared.Stop) {
            $Shared.Status = Send-Line $(if ($Shared.Busy) { '{"action":"status","session":true}' } else { '{"action":"status","session":false}' })
            if ($tick % 5 -eq 0) { $Shared.Overlay = Send-Line '{"action":"overlay"}' }
            $tick++
            Start-Sleep -Seconds 2
        }
    }).AddArgument($script:AgentShared)
    $script:AgentPoller = $ps
    [void]$ps.BeginInvoke()
}

# Последний ответ службы. $null: служба не запущена или ещё не ответила.
function Get-AgentShared([string]$Key) {
    if (-not $script:AgentShared) { return $null }
    $line = $script:AgentShared[$Key]
    if (-not $line) { return $null }
    try { return ($line | ConvertFrom-Json) } catch { return $null }
}

# Замок на главном экране. Защита меняется только с перезагрузкой, поэтому достаточно узнать состояние один раз.
function Update-LockStatus {
    if ($script:LockKnown) { return }
    $status = Get-AgentShared 'Status'
    if ($status) {
        $script:LockKnown = $true
        Set-UwfDisplay $(if ($status.uwfNow) { 'ON' } else { 'OFF' })
    }
    elseif (-not $script:LockTried) {
        # Служба может запуститься позже лаунчера. Пока её нет, смотрим сами.
        $script:LockTried = $true
        Start-UwfStatusCheck
    }
}

# Заполненность оверлея UWF. Значения готовит служба, поэтому окно не подвисает на запросе к Windows.
# Меню состояния у замка: защита, оверлей и файл подкачки
function Update-SystemMenu($Data) {
    $TxtSysUwf.Text = $TxtUwfState.Text
    $LampSysUwf.Fill = $LampUwf.Fill
    if (-not $Data -or -not $Data.ok) {
        $TxtSysOverlay.Text = 'Служба лаунчера не отвечает'
        $BarSysOverlay.Width = 0
        $TxtSysPage.Text = 'Нет данных'
        $LampSysPage.Fill = New-DeviceBrush '#55585C'
        return
    }
    $total = [double]$Data.usedMb + [double]$Data.freeMb
    if (-not $Data.enabled -or $total -le 0) {
        $TxtSysOverlay.Text = 'Не используется: защита выключена'
        $BarSysOverlay.Width = 0
    }
    else {
        $part = [double]$Data.usedMb / $total
        $BarSysOverlay.Width = [Math]::Round(278 * [Math]::Min(1, $part))
        $BarSysOverlay.Fill = New-DeviceBrush $(if ($part -ge 0.9) { '#E5301A' } elseif ($part -ge 0.75) { '#FFB020' } else { '#37C552' })
        $TxtSysOverlay.Text = 'Занято {0:0.0} из {1:0} ГБ, свободно {2:0.0} ГБ' -f ($Data.usedMb / 1024), ($total / 1024), ($Data.freeMb / 1024)
    }
    # Нормально: файл подкачки работает и лежит на диске Z:
    $pages = @($Data.pages | Where-Object { $_ } | ForEach-Object {
        $parts = ([string]$_).Split('|')
        [pscustomobject]@{ Name = $parts[0]; Mb = [double]$parts[1] }
    } | Where-Object { $_.Mb -gt 0 })
    if ($pages.Count -eq 0) {
        $TxtSysPage.Text = 'Не работает'
        $LampSysPage.Fill = New-DeviceBrush '#E5301A'
        return
    }
    $TxtSysPage.Text = (@($pages | ForEach-Object { '{0}  {1:0.0} ГБ' -f $_.Name.Substring(0, 2), ($_.Mb / 1024) }) -join ', ')
    $onZ = @($pages | Where-Object { $_.Name -like 'Z:*' }).Count -gt 0
    $LampSysPage.Fill = New-DeviceBrush $(if ($onZ) { '#37C552' } else { '#FFB020' })
    if (-not $onZ) { $TxtSysPage.Text += ' (не на диске Z:)' }
}

function Update-OverlayGauge {
    $data = Get-AgentShared 'Overlay'
    Update-SystemMenu $data
    if (-not $data -or -not $data.ok -or -not $data.enabled) {
        $OverlayStrip.Visibility = 'Collapsed'
        return
    }
    $used = [double]$data.usedMb
    $free = [double]$data.freeMb
    $total = $used + $free
    if ($total -le 0) {
        $OverlayStrip.Visibility = 'Collapsed'
        return
    }
    $part = $used / $total
    $BarOverlay.Width = [Math]::Round(160 * [Math]::Min(1, $part))
    $BarOverlay.Fill = New-DeviceBrush $(if ($part -ge 0.9) { '#E5301A' } elseif ($part -ge 0.75) { '#FFB020' } else { '#37C552' })
    $TxtOverlayFree.Text = '{0:0.0} ГБ свободно из {1:0} ГБ' -f ($free / 1024), ($total / 1024)
    $TxtOverlayFree.Foreground = New-DeviceBrush $(if ($part -ge 0.9) { '#FF6A55' } else { '#FFFFFF' })
    $OverlayStrip.Visibility = 'Visible'
}

# Щелчок по замку открывает меню. Повторный щелчок закрывает: меню само закрылось при нажатии, не открываем его снова.
function Switch-SystemMenu {
    if (((Get-Date) - $script:SystemMenuClosedAt).TotalMilliseconds -lt 300) { return }
    Update-SystemMenu (Get-AgentShared 'Overlay')
    $SystemMenu.IsOpen = $true
}

# Индикатор Caps Lock рядом с раскладкой
function Update-CapsLamp {
    if ($AdminPanel.Visibility -ne 'Visible') { return }
    $LampCaps.Visibility = $(if ([System.Windows.Input.Keyboard]::IsKeyToggled('CapsLock')) { 'Visible' } else { 'Hidden' })
}

# Раз в несколько секунд спрашиваем службу, идёт ли обновление. После загрузки служба может запуститься позже лаунчера.
function Update-AgentStatus {
    if ((Get-Date) -gt $script:AgentPollUntil) { return }
    $status = Get-AgentShared 'Status'
    if (-not $status) { return }
    if ($status.state -eq 'updating') {
        $script:AgentPollUntil = (Get-Date).AddMinutes(3)
        if ($Overlay.Visibility -ne 'Visible' -or $TxtOverlayTitle.Text -ne 'Обновление лаунчера') { Show-Waiting 'Обновление лаунчера' 'Не выключай компьютер. Это займёт пару минут.' '' }
    }
    elseif ($status.state -eq 'await-decision') {
        $script:AgentPollUntil = [datetime]::MinValue
        $Overlay.Visibility = 'Collapsed'
        $TxtDecisionText.Text = [string]$status.message
        # Неудачу видно сразу, а не только по мелкой строке
        $TxtDecisionText.Foreground = $Window.FindResource($(if ($status.updateOk -eq $false) { 'Accent' } else { 'Muted' }))
        $TxtDecisionText.FontWeight = $(if ($status.updateOk -eq $false) { [System.Windows.FontWeights]::SemiBold } else { [System.Windows.FontWeights]::Normal })
        $DecisionPanel.Visibility = 'Visible'
        [void]$BtnDecideLock.Focus()
    }
}

# Ответ на вопрос после обновления
function Submit-Decision([bool]$Lock) {
    $DecisionPanel.Visibility = 'Collapsed'
    $response = Invoke-Agent @{ action = 'decide'; lock = $Lock } 3000
    if ($response -and $response.reboot) {
        Show-Waiting 'Компьютер перезагружается' 'Подожди немного.' ''
        return
    }
    if ($Lock -and (-not $response -or -not $response.ok)) {
        Show-Overlay 'Защиту включить не удалось' $(if ($response) { [string]$response.error } else { 'Служба лаунчера не ответила.' }) 'Закрыть'
        return
    }
    Close-Launcher 2     # новая версия лаунчера начинает работать после перезапуска
}

# ---------- Интерфейс ----------

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SIMRACE" WindowStyle="None" ResizeMode="NoResize" WindowState="Maximized"
        ShowInTaskbar="True" Background="#0E0F11" Foreground="White"
        FontFamily="Segoe UI Variable Display, Segoe UI" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#E2450F"/>
    <SolidColorBrush x:Key="LogoColor" Color="#C82F03"/>
    <SolidColorBrush x:Key="Muted" Color="#A2A6AB"/>
    <SolidColorBrush x:Key="Soft" Color="#B4B8BC"/>
    <SolidColorBrush x:Key="Graphite" Color="#D61F2124"/>
    <SolidColorBrush x:Key="Line" Color="#34373B"/>
    <SolidColorBrush x:Key="Divider" Color="#33FFFFFF"/>

    <Style x:Key="TileButton" TargetType="Button">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid x:Name="TileRoot" Background="{StaticResource Graphite}" ClipToBounds="True" RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
              <ContentPresenter x:Name="Cover" Opacity="0.82"/>
              <Border x:Name="Frame" BorderThickness="3" BorderBrush="Transparent"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Cover" Property="Opacity" Value="1"/>
                <Setter TargetName="Frame" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="TileRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1.035" Duration="0:0:0.12"/>
                      <DoubleAnimation Storyboard.TargetName="TileRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1.035" Duration="0:0:0.12"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="TileRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.16"/>
                      <DoubleAnimation Storyboard.TargetName="TileRoot" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.16"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Cover" Property="Opacity" Value="1"/>
                <Setter TargetName="Frame" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Cover" Property="Opacity" Value="0.6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ActionButton" TargetType="Button">
      <Setter Property="FontSize" Value="20"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="#1F2124" BorderBrush="{StaticResource Line}" BorderThickness="2" Padding="32,14">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ExtraButton" TargetType="Button">
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="#D61F2124" BorderBrush="{StaticResource LogoColor}" BorderThickness="2" Height="46">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="MenuItemButton" TargetType="Button">
      <Setter Property="FontSize" Value="18"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="Transparent" CornerRadius="10" Padding="16,11">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="#2C2E32"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Box" Property="Background" Value="#2C2E32"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="MenuIconButton" TargetType="Button">
      <Setter Property="Height" Value="52"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="Transparent" CornerRadius="10">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="#2C2E32"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Box" Property="Background" Value="#2C2E32"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="AdminTile" TargetType="Button">
      <Setter Property="FontSize" Value="18"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="5"/>
      <Setter Property="MinHeight" Value="62"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="#1C1E21" BorderBrush="#2E3135" BorderThickness="1" CornerRadius="14" Padding="18,8">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="Background" Value="#26282C"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Box" Property="Background" Value="#303338"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="AdminPrimary" TargetType="Button">
      <Setter Property="FontSize" Value="18"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="#D23F0D" CornerRadius="12" Padding="30,13">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="#E8501B"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Box" Property="Background" Value="#E8501B"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Box" Property="Background" Value="#B8350A"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="AdminGhost" TargetType="Button">
      <Setter Property="FontSize" Value="18"/>
      <Setter Property="Padding" Value="30,12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="Transparent" BorderBrush="#3A3D42" BorderThickness="1" CornerRadius="12" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="#26282C"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="AdminInputBox" TargetType="Border">
      <Setter Property="Background" Value="#1C1E21"/>
      <Setter Property="BorderBrush" Value="#2E3135"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="8,4"/>
    </Style>

    <Style x:Key="AdminGroup" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#7C8085"/>
      <Setter Property="Margin" Value="0,18,0,5"/>
    </Style>

    <Style x:Key="ScrollArrow" TargetType="Button">
      <Setter Property="Width" Value="58"/>
      <Setter Property="Height" Value="58"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="FontSize" Value="36"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="#E6181A1C" BorderBrush="#33FFFFFF" BorderThickness="1" CornerRadius="29">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,0,0,6"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="StatusButton" TargetType="Button">
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="Transparent" CornerRadius="12" Padding="10,6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="#2C2E32"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Запасной выход для администратора: маленькая надпись в углу, не похожая на кнопку -->
    <Style x:Key="CornerLink" TargetType="Button">
      <Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="VerticalAlignment" Value="Bottom"/>
      <Setter Property="Margin" Value="0,0,56,28"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Foreground" Value="#6C6F73"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="Transparent" Padding="6">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#A2A6AB"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="InfoBadge" TargetType="Button">
      <Setter Property="Margin" Value="0,10,10,0"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Pill" Background="#C70D0E10" BorderBrush="#59FFFFFF" BorderThickness="1" CornerRadius="15" Padding="8,5,13,5">
              <StackPanel Orientation="Horizontal">
                <Grid Width="18" Height="18" VerticalAlignment="Center">
                  <Ellipse x:Name="Ring" Stroke="#E2450F" StrokeThickness="1.6"/>
                  <TextBlock Text="i" FontSize="12" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Grid>
                <TextBlock Text="Об игре" FontSize="14" FontWeight="SemiBold" Foreground="White" VerticalAlignment="Center" Margin="7,0,0,1"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Pill" Property="Background" Value="#E2450F"/>
                <Setter TargetName="Pill" Property="BorderBrush" Value="#E2450F"/>
                <Setter TargetName="Ring" Property="Stroke" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="StartButton" TargetType="Button">
      <Setter Property="FontSize" Value="28"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="#C82F03" CornerRadius="14" Padding="40,18">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Background" Value="#E2450F"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Box" Property="Background" Value="#E2450F"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Box" Property="Background" Value="#A92702"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ToolButton" TargetType="Button">
      <Setter Property="FontSize" Value="18"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="#B3121315" BorderBrush="{StaticResource LogoColor}" BorderThickness="2" CornerRadius="18" Padding="14,9,14,9">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="Box" Property="Background" Value="#E61F2124"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="FeatureIcon" TargetType="Path">
      <Setter Property="Stroke" Value="{StaticResource Accent}"/>
      <Setter Property="StrokeThickness" Value="1.7"/>
      <Setter Property="StrokeStartLineCap" Value="Round"/>
      <Setter Property="StrokeEndLineCap" Value="Round"/>
      <Setter Property="StrokeLineJoin" Value="Round"/>
    </Style>
    <Style x:Key="FeatureTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="22"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Margin" Value="0,0,0,3"/>
    </Style>
    <Style x:Key="FeatureText" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="LineHeight" Value="19"/>
      <Setter Property="Foreground" Value="{StaticResource Soft}"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Image x:Name="BackgroundImage" Stretch="UniformToFill" HorizontalAlignment="Center" VerticalAlignment="Center"/>

    <Grid Margin="56,30,56,0">
      <Grid.RowDefinitions>
        <RowDefinition Height="84"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition x:Name="BottomRow" Height="260"/>
      </Grid.RowDefinitions>

      <!-- Логотип и кнопки по краям, блок с направлениями точно по центру экрана -->
      <Grid Grid.Row="0">
        <Grid x:Name="LogoHost" HorizontalAlignment="Left" VerticalAlignment="Center">
          <Image x:Name="LogoImage" Stretch="Uniform" Height="54" HorizontalAlignment="Left"/>
          <TextBlock x:Name="LogoText" Text="SIMRACE" FontSize="30" FontWeight="SemiBold" VerticalAlignment="Center" Visibility="Collapsed"/>
        </Grid>

        <!-- Интересный факт: показывается, только если рядом с логотипом хватает места -->
        <Border x:Name="FactBox" HorizontalAlignment="Left" VerticalAlignment="Center" BorderBrush="{StaticResource Divider}" BorderThickness="1,0,0,0" Padding="18,0,0,0" Visibility="Collapsed">
          <StackPanel>
            <TextBlock Text="ИНТЕРЕСНЫЙ ФАКТ" FontSize="13" FontWeight="Bold" Foreground="{StaticResource Accent}" Margin="0,0,0,3"/>
            <TextBlock x:Name="TxtFact" FontSize="15" LineHeight="19" MaxHeight="57" Foreground="{StaticResource Soft}" TextWrapping="Wrap" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </Border>

        <Viewbox x:Name="FeatureBox" Stretch="Uniform" StretchDirection="DownOnly" HorizontalAlignment="Center" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <StackPanel Orientation="Horizontal" Margin="0,0,56,0">
              <Viewbox Width="50" Height="50" Margin="0,0,18,0" VerticalAlignment="Center"><Canvas Width="48" Height="48">
                <Path Style="{StaticResource FeatureIcon}" Data="M4,19 L24,10 L44,19 L24,28 Z M12,23 V33 C12,36 18,39 24,39 C30,39 36,36 36,33 V23 M44,19 V32 M45.6,34.5 A1.6,1.6 0 1 0 42.4,34.5 A1.6,1.6 0 1 0 45.6,34.5"/>
              </Canvas></Viewbox>
              <Border BorderBrush="{StaticResource Divider}" BorderThickness="1,0,0,0" Padding="18,0,0,0">
                <StackPanel>
                  <TextBlock Style="{StaticResource FeatureTitle}" Text="ОБУЧЕНИЕ"/>
                  <TextBlock Style="{StaticResource FeatureText}" Text="КОЛЬЦЕВЫЕ ГОНКИ&#10;И ДРИФТ С ИНСТРУКТОРОМ"/>
                </StackPanel>
              </Border>
            </StackPanel>
            <Border BorderBrush="{StaticResource Divider}" BorderThickness="1,0,0,0" Padding="56,0,56,0">
              <StackPanel Orientation="Horizontal">
                <Viewbox Width="50" Height="50" Margin="0,0,18,0" VerticalAlignment="Center"><Canvas Width="48" Height="48">
                  <Path Style="{StaticResource FeatureIcon}" Data="M14,7 H34 V19 C34,26 30,31 24,31 C18,31 14,26 14,19 Z M14,11 H6 C6,19 9,24 15,25 M34,11 H42 C42,19 39,24 33,25 M24,31 V38 M16,41 H32 M18,41 C18,39 20,38 24,38 C28,38 30,39 30,41"/>
                </Canvas></Viewbox>
                <Border BorderBrush="{StaticResource Divider}" BorderThickness="1,0,0,0" Padding="18,0,0,0">
                  <StackPanel>
                    <TextBlock Style="{StaticResource FeatureTitle}" Text="ТУРНИРЫ"/>
                    <TextBlock Style="{StaticResource FeatureText}" Text="РЕГУЛЯРНЫЕ ЧЕМПИОНАТЫ&#10;И ГОНОЧНОЕ СООБЩЕСТВО"/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </Border>
            <Border BorderBrush="{StaticResource Divider}" BorderThickness="1,0,0,0" Padding="56,0,0,0">
              <StackPanel Orientation="Horizontal">
                <Viewbox Width="50" Height="50" Margin="0,0,18,0" VerticalAlignment="Center"><Canvas Width="48" Height="48">
                  <Path Style="{StaticResource FeatureIcon}" Data="M30.5,15 A6.5,6.5 0 1 0 17.5,15 A6.5,6.5 0 1 0 30.5,15 M12,39 C12,31 17,26 24,26 C31,26 36,31 36,39 Z M14.5,20 A4.5,4.5 0 1 0 5.5,20 A4.5,4.5 0 1 0 14.5,20 M3,37 C3,31 6,28 11,28 M42.5,20 A4.5,4.5 0 1 0 33.5,20 A4.5,4.5 0 1 0 42.5,20 M45,37 C45,31 42,28 37,28"/>
                </Canvas></Viewbox>
                <Border BorderBrush="{StaticResource Divider}" BorderThickness="1,0,0,0" Padding="18,0,0,0">
                  <StackPanel>
                    <TextBlock Style="{StaticResource FeatureTitle}" Text="МЕРОПРИЯТИЯ"/>
                    <TextBlock Style="{StaticResource FeatureText}" Text="ДНИ РОЖДЕНИЯ, КОРПОРАТИВЫ&#10;И ЧАСТНЫЕ СОБЫТИЯ"/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </Border>
          </StackPanel>
        </Viewbox>

        <StackPanel x:Name="ToolsPanel" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <StackPanel x:Name="HeaderTools" Orientation="Horizontal"/>
        <Border x:Name="StatusStrip" Margin="10,0,0,0" VerticalAlignment="Center" Background="#B3121315" BorderBrush="#33FFFFFF" BorderThickness="1" CornerRadius="18" Padding="6">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="BtnStatusLang" Style="{StaticResource StatusButton}" FontSize="18" MinWidth="50" ToolTip="Язык ввода, нажми, чтобы сменить"/>
            <Border x:Name="NetBox" Visibility="Collapsed" Padding="8,0" VerticalAlignment="Center" Background="Transparent">
              <Canvas Width="24" Height="24">
                <Path x:Name="IconNet" Stroke="#6C6F73" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Data="M4,4 L20,20 M20,4 L4,20"/>
              </Canvas>
            </Border>
            <Rectangle Width="1" Height="24" Fill="{StaticResource Divider}" Margin="6,0"/>
            <StackPanel x:Name="StatusLinks" Orientation="Horizontal"/>
            <Rectangle Width="1" Height="24" Fill="{StaticResource Divider}" Margin="6,0"/>
            <StackPanel x:Name="LockBox" Orientation="Horizontal" VerticalAlignment="Center" Margin="8,0" Background="Transparent" Cursor="Hand" ToolTip="Состояние системы">
              <Canvas Width="24" Height="24" VerticalAlignment="Center">
                <Rectangle Canvas.Left="5" Canvas.Top="11" Width="14" Height="10" RadiusX="2.2" RadiusY="2.2" Fill="White"/>
                <Path x:Name="IconLock" Data="M8,11 V7.5 A4,4 0 0 1 16,7.5 V11" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
              </Canvas>
              <Ellipse x:Name="LampLock" Width="10" Height="10" Fill="#55585C" VerticalAlignment="Center" Margin="8,0,0,0"/>
              <Path Data="M0,0 L4.5,4.5 L9,0" Stroke="#A2A6AB" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" VerticalAlignment="Center" Margin="8,2,0,0"/>
            </StackPanel>
            <Popup x:Name="SystemMenu" PlacementTarget="{Binding ElementName=LockBox}" Placement="Bottom" HorizontalOffset="-250" VerticalOffset="14" StaysOpen="False" AllowsTransparency="True" PopupAnimation="Fade">
              <Border Width="320" Background="#F7141518" BorderBrush="#2E3135" BorderThickness="1" CornerRadius="14" Padding="20,16,20,18">
                <StackPanel>
                  <StackPanel Orientation="Horizontal" Margin="0,0,0,14">
                    <Ellipse x:Name="LampSysUwf" Width="10" Height="10" Fill="#55585C" VerticalAlignment="Center" Margin="0,0,10,0"/>
                    <TextBlock x:Name="TxtSysUwf" Text="Состояние защиты неизвестно" FontSize="16" FontWeight="SemiBold"/>
                  </StackPanel>
                  <TextBlock Text="OVERLAY" FontSize="12" FontWeight="SemiBold" Foreground="#7C8085" Margin="0,0,0,6"/>
                  <Border Height="8" Background="#26282C" CornerRadius="4" ClipToBounds="True">
                    <Rectangle x:Name="BarSysOverlay" Width="0" HorizontalAlignment="Left" Fill="#37C552" RadiusX="3" RadiusY="3"/>
                  </Border>
                  <TextBlock x:Name="TxtSysOverlay" Text="Нет данных" FontSize="15" Foreground="{StaticResource Soft}" Margin="0,6,0,14"/>
                  <TextBlock Text="ФАЙЛ ПОДКАЧКИ" FontSize="12" FontWeight="SemiBold" Foreground="#7C8085" Margin="0,0,0,6"/>
                  <StackPanel Orientation="Horizontal">
                    <Ellipse x:Name="LampSysPage" Width="10" Height="10" Fill="#55585C" VerticalAlignment="Center" Margin="0,0,10,0"/>
                    <TextBlock x:Name="TxtSysPage" Text="Нет данных" FontSize="15" Foreground="{StaticResource Soft}" TextWrapping="Wrap" MaxWidth="250"/>
                  </StackPanel>
                </StackPanel>
              </Border>
            </Popup>
          </StackPanel>
        </Border>
        </StackPanel>
      </Grid>

      <!-- Второй ряд: всё о текущем сеансе -->
      <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right">
        <Border x:Name="OverlayStrip" Visibility="Collapsed" Margin="0,0,10,0" Background="#B3121315" BorderBrush="#33FFFFFF" BorderThickness="1" CornerRadius="18" Padding="20,6">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="OVERLAY" FontSize="14" FontWeight="SemiBold" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="0,0,12,0"/>
            <Border Width="160" Height="10" Background="#26282C" CornerRadius="5" ClipToBounds="True" VerticalAlignment="Center">
              <Rectangle x:Name="BarOverlay" Width="0" HorizontalAlignment="Left" Fill="#37C552" RadiusX="3" RadiusY="3"/>
            </Border>
            <TextBlock x:Name="TxtOverlayFree" FontSize="18" FontWeight="SemiBold" VerticalAlignment="Center" Margin="12,0,0,0"/>
          </StackPanel>
        </Border>

        <Border x:Name="SessionStrip" Background="#B3121315" BorderBrush="#33FFFFFF" BorderThickness="1" CornerRadius="18" Padding="22,6,22,6">
          <StackPanel Orientation="Horizontal">
            <StackPanel x:Name="SessionFields" Orientation="Horizontal" Visibility="Collapsed">
              <TextBlock Text="Сеанс" FontSize="16" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <TextBlock x:Name="TxtStripTime" FontSize="24" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,20,0"/>
              <Rectangle Width="1" Height="24" Fill="{StaticResource Divider}" Margin="0,0,20,0"/>
              <TextBlock Text="Старт" FontSize="16" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <TextBlock x:Name="TxtStripStart" FontSize="24" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,20,0"/>
              <Button x:Name="BtnPause" MinWidth="58" Style="{StaticResource ToolButton}" Margin="0,0,8,0" ToolTip="Пауза">
                <Canvas Width="24" Height="24">
                  <Path x:Name="IconPause" Data="M8,5 V19 M16,5 V19" Stroke="White" Fill="White" StrokeThickness="3.2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                </Canvas>
              </Button>
              <Button x:Name="BtnEndSession" Content="Завершить" Style="{StaticResource ToolButton}" Margin="0,0,20,0"/>
              <Rectangle Width="1" Height="24" Fill="{StaticResource Divider}" Margin="0,0,20,0"/>
            </StackPanel>
            <TextBlock x:Name="TxtComputer" FontSize="20" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="0,0,16,0"/>
            <TextBlock x:Name="TxtClock" FontSize="24" FontWeight="SemiBold" VerticalAlignment="Center"/>
          </StackPanel>
        </Border>
      </StackPanel>

      <Grid x:Name="TilesHost" Grid.Row="2" Margin="0,10,0,10">
        <ScrollViewer x:Name="TileScroller" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden" Focusable="False">
          <StackPanel x:Name="RowsPanel" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </ScrollViewer>
        <Button x:Name="BtnScrollLeft" Content="‹" Style="{StaticResource ScrollArrow}" HorizontalAlignment="Left" Margin="6,0,0,0" Visibility="Collapsed"/>
        <Button x:Name="BtnScrollRight" Content="›" Style="{StaticResource ScrollArrow}" HorizontalAlignment="Right" Margin="0,0,6,0" Visibility="Collapsed"/>
        <Border x:Name="SessionStart" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed" Width="760"
                Background="#EB121315" BorderBrush="#33FFFFFF" BorderThickness="1" CornerRadius="18" Padding="56,38,56,38">
          <StackPanel>
            <TextBlock FontSize="36" FontWeight="SemiBold" TextAlignment="Center" LineHeight="48" Margin="0,0,0,30" Text="Добро пожаловать в SIMRACE!&#10;Удачи в гонке!">
              <TextBlock.Triggers>
                <EventTrigger RoutedEvent="FrameworkElement.Loaded">
                  <BeginStoryboard>
                    <Storyboard RepeatBehavior="Forever" AutoReverse="True">
                      <DoubleAnimation Storyboard.TargetProperty="Opacity" From="1" To="0.62" Duration="0:0:1.8">
                        <DoubleAnimation.EasingFunction><SineEase EasingMode="EaseInOut"/></DoubleAnimation.EasingFunction>
                      </DoubleAnimation>
                    </Storyboard>
                  </BeginStoryboard>
                </EventTrigger>
              </TextBlock.Triggers>
            </TextBlock>
            <Button x:Name="BtnStartSession" Content="Начать заезд" Style="{StaticResource StartButton}"/>
            <TextBlock x:Name="TxtLastSession" FontSize="18" Foreground="{StaticResource Muted}" HorizontalAlignment="Center" Margin="0,16,0,0"/>
          </StackPanel>
        </Border>
        <TextBlock x:Name="TxtEmpty" Visibility="Collapsed" FontSize="28" HorizontalAlignment="Center" VerticalAlignment="Center" TextAlignment="Center"
                   Text="На этом компьютере нет доступных игр. Позови администратора клуба."/>
      </Grid>

      <Grid Grid.Row="3">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <StackPanel Grid.Column="0" VerticalAlignment="Bottom" Margin="0,0,40,28">
        <Border x:Name="GameBar" Visibility="Collapsed" HorizontalAlignment="Left" Background="#D6181A1C" BorderBrush="#26FFFFFF" BorderThickness="1" CornerRadius="18" Padding="14,14,22,14">
          <Border.Effect><DropShadowEffect BlurRadius="34" ShadowDepth="0" Color="#E2450F" Opacity="0.2"/></Border.Effect>
          <StackPanel Orientation="Horizontal">
            <Border Width="84" Height="126" CornerRadius="10" Background="#26282B" Margin="0,0,20,0" ClipToBounds="True">
              <Image x:Name="ImgRunning" Stretch="UniformToFill"/>
            </Border>
            <StackPanel VerticalAlignment="Center">
              <StackPanel Orientation="Horizontal">
                <Ellipse Width="10" Height="10" Fill="#4CC96A" VerticalAlignment="Center" Margin="0,0,9,0">
                  <Ellipse.Triggers>
                    <EventTrigger RoutedEvent="FrameworkElement.Loaded">
                      <BeginStoryboard>
                        <Storyboard RepeatBehavior="Forever" AutoReverse="True">
                          <DoubleAnimation Storyboard.TargetProperty="Opacity" From="1" To="0.35" Duration="0:0:1.1"/>
                        </Storyboard>
                      </BeginStoryboard>
                    </EventTrigger>
                  </Ellipse.Triggers>
                </Ellipse>
                <TextBlock Text="Игра ждёт тебя" FontSize="17" Foreground="{StaticResource Soft}"/>
              </StackPanel>
              <TextBlock x:Name="TxtGameRunning" FontSize="30" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" MaxWidth="560" Margin="0,2,0,12"/>
              <StackPanel Orientation="Horizontal">
                <Button x:Name="BtnResumeGame" Content="Вернуться в игру" Style="{StaticResource StartButton}" FontSize="20" Margin="0,0,10,0"/>
                <Button x:Name="BtnQuitGame" Content="Закрыть игру" Style="{StaticResource ActionButton}" FontSize="17"/>
              </StackPanel>
            </StackPanel>
          </StackPanel>
        </Border>

        <StackPanel x:Name="SelectedInfo">
          <Rectangle Width="72" Height="3" Fill="{StaticResource Accent}" HorizontalAlignment="Left" Margin="0,0,0,14"/>
          <TextBlock x:Name="TxtSelected" Text="Выбери игру" FontSize="42" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
          <TextBlock x:Name="TxtHint" Text="Наведи курсор на обложку" FontSize="20" Foreground="{StaticResource Muted}"/>
        </StackPanel>
        <TextBlock Text="Свернуть игру: Ctrl+Shift+End" FontSize="15" Foreground="#7C8085" Margin="0,10,0,0"/>
        </StackPanel>

        <!-- Приборка: картинка и лампы поверх неё в одной системе координат -->
        <Viewbox x:Name="DashHost" Grid.Column="1" Stretch="Uniform" VerticalAlignment="Bottom">
          <Grid Width="1520" Height="500">
            <Image x:Name="DashImage" Stretch="Fill" RenderOptions.BitmapScalingMode="HighQuality"/>
            <Canvas x:Name="DashLive" IsHitTestVisible="False">
              <TextBlock x:Name="TxtDashTimer" Canvas.Left="920" Canvas.Top="226" Width="320" TextAlignment="Center" FontSize="48" Foreground="#E0E2E2" Text="--:--:--"/>
              <TextBlock x:Name="TxtDashStart" Canvas.Left="920" Canvas.Top="322" Width="158" TextAlignment="Center" FontSize="27" Foreground="#E0E2E2" Text="--:--"/>
              <TextBlock x:Name="TxtDashState" Canvas.Left="1082" Canvas.Top="322" Width="158" TextAlignment="Center" FontSize="27" Foreground="#E0E2E2" Text="IDLE"/>
              <TextBlock x:Name="TxtDashPosition" Canvas.Left="400" Canvas.Top="138" Width="180" TextAlignment="Right" FontSize="27" Foreground="#E0E2E2"/>
              <TextBlock x:Name="TxtDashLap" Canvas.Left="1004" Canvas.Top="138" Width="80" TextAlignment="Right" FontSize="27" Foreground="#E0E2E2" Text="0"/>
              <TextBlock x:Name="TxtDashText" Canvas.Left="90" Canvas.Top="405" Width="1340" TextAlignment="Center" FontSize="38">
                <TextBlock.Foreground>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="#D5552A" Offset="0.3"/>
                    <GradientStop Color="#EA7440" Offset="0.5"/>
                    <GradientStop Color="#D5552A" Offset="0.7"/>
                  </LinearGradientBrush>
                </TextBlock.Foreground>
              </TextBlock>
            </Canvas>
            <!-- База выключена: погасший экран с надписью MOZA RACING -->
            <Image x:Name="DashOffImage" Stretch="Fill" RenderOptions.BitmapScalingMode="HighQuality" IsHitTestVisible="False"/>
            <Canvas x:Name="LedCanvas" IsHitTestVisible="False"/>
            <!-- Лёгкий блик проходит по стеклу экрана раз в несколько секунд -->
            <Canvas x:Name="SheenHost" Margin="90,114,90,20" ClipToBounds="True" IsHitTestVisible="False">
              <Rectangle Width="230" Height="760" Canvas.Top="-200">
                <Rectangle.Fill>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="#00FFFFFF" Offset="0"/>
                    <GradientStop Color="#12FFFFFF" Offset="0.5"/>
                    <GradientStop Color="#00FFFFFF" Offset="1"/>
                  </LinearGradientBrush>
                </Rectangle.Fill>
                <Rectangle.RenderTransform>
                  <TransformGroup>
                    <SkewTransform AngleX="-22"/>
                    <TranslateTransform X="-500"/>
                  </TransformGroup>
                </Rectangle.RenderTransform>
                <Rectangle.Triggers>
                  <EventTrigger RoutedEvent="FrameworkElement.Loaded">
                    <BeginStoryboard>
                      <Storyboard RepeatBehavior="Forever" Duration="0:0:9">
                        <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[1].(TranslateTransform.X)" From="-500" To="1800" BeginTime="0:0:2" Duration="0:0:1.8">
                          <DoubleAnimation.EasingFunction><SineEase EasingMode="EaseInOut"/></DoubleAnimation.EasingFunction>
                        </DoubleAnimation>
                      </Storyboard>
                    </BeginStoryboard>
                  </EventTrigger>
                </Rectangle.Triggers>
              </Rectangle>
            </Canvas>
          </Grid>
        </Viewbox>

        <StackPanel Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="40,0,0,28">
          <!-- Оси руля и педалей -->
          <Border x:Name="AxesCard" Width="236" VerticalAlignment="Bottom" Margin="0,0,32,0" Background="#B3121315" BorderBrush="#33FFFFFF" BorderThickness="1" CornerRadius="18" Padding="18,14" ToolTipService.ShowDuration="600000">
            <Border.ToolTip>
              <ToolTip><TextBlock x:Name="TxtAxesRaw" FontSize="14" Text="Чтение осей..."/></ToolTip>
            </Border.ToolTip>
            <StackPanel>
              <TextBlock Text="РУЛЬ" FontSize="12" Foreground="#A2A6AB" Margin="0,0,0,6"/>
              <Canvas Width="196" Height="10" HorizontalAlignment="Left" Margin="0,0,0,14">
                <Rectangle Width="196" Height="10" RadiusX="5" RadiusY="5" Fill="#26282C"/>
                <Rectangle x:Name="BarWheel" Canvas.Left="98" Width="0" Height="10" RadiusX="3" RadiusY="3" Fill="{StaticResource Accent}"/>
                <Rectangle Canvas.Left="97" Canvas.Top="-2" Width="2" Height="14" Fill="#A2A6AB"/>
              </Canvas>
              <UniformGrid Columns="3">
                <StackPanel Margin="0,0,0,0">
                <Border Width="16" Height="72" Background="#26282C" CornerRadius="5" HorizontalAlignment="Center" ClipToBounds="True">
                  <Rectangle x:Name="BarClutch" Fill="#A2A6AB" Height="0" VerticalAlignment="Bottom" RadiusX="3" RadiusY="3"/>
                </Border>
                <TextBlock Text="СЦЕПЛ." FontSize="12" Foreground="#A2A6AB" HorizontalAlignment="Center" Margin="0,6,0,0"/>
              </StackPanel>
                <StackPanel Margin="0,0,0,0">
                <Border Width="16" Height="72" Background="#26282C" CornerRadius="5" HorizontalAlignment="Center" ClipToBounds="True">
                  <Rectangle x:Name="BarBrake" Fill="#E5301A" Height="0" VerticalAlignment="Bottom" RadiusX="3" RadiusY="3"/>
                </Border>
                <TextBlock Text="ТОРМОЗ" FontSize="12" Foreground="#A2A6AB" HorizontalAlignment="Center" Margin="0,6,0,0"/>
              </StackPanel>
                <StackPanel Margin="0,0,0,0">
                <Border Width="16" Height="72" Background="#26282C" CornerRadius="5" HorizontalAlignment="Center" ClipToBounds="True">
                  <Rectangle x:Name="BarThrottle" Fill="#37C552" Height="0" VerticalAlignment="Bottom" RadiusX="3" RadiusY="3"/>
                </Border>
                <TextBlock Text="ГАЗ" FontSize="12" Foreground="#A2A6AB" HorizontalAlignment="Center" Margin="0,6,0,0"/>
              </StackPanel>
              </UniformGrid>
            </StackPanel>
          </Border>
          <StackPanel VerticalAlignment="Bottom" Margin="0,0,32,0">
            <TextBlock Text="Большакова, 99А" FontSize="18" FontWeight="SemiBold" TextAlignment="Right"/>
            <TextBlock Text="14 кокпитов, круглосуточно" FontSize="15" Foreground="{StaticResource Muted}" TextAlignment="Right" Margin="0,0,0,12"/>
            <TextBlock Text="Чернышевского, 4А" FontSize="18" FontWeight="SemiBold" TextAlignment="Right"/>
            <TextBlock Text="8 кокпитов, 10:00–22:00" FontSize="15" Foreground="{StaticResource Muted}" TextAlignment="Right"/>
          </StackPanel>
          <StackPanel Width="126" Margin="0,0,18,0">
            <Image x:Name="QrTelegram" Width="92" Height="92" Margin="0,0,0,7"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
              <Viewbox Width="15" Height="15" Margin="0,0,6,0"><Canvas Width="24" Height="24">
                <Ellipse Width="24" Height="24" Fill="{StaticResource Accent}"/>
                <Path Fill="White" Data="M5.2,11.7 L17.6,6.9 C18.2,6.7 18.7,7 18.5,7.8 L16.4,17.7 C16.2,18.4 15.8,18.6 15.2,18.2 L12,15.8 L10.4,17.3 C10.2,17.5 10.1,17.6 9.7,17.6 L9.9,14.4 L15.8,9.1 C16.1,8.9 15.7,8.7 15.4,8.9 L8.1,13.5 L5,12.5 C4.3,12.3 4.3,11.8 5.2,11.7 Z"/>
              </Canvas></Viewbox>
              <TextBlock Text="@SimRace_Ural" FontSize="14" FontWeight="SemiBold"/>
            </StackPanel>
            <TextBlock Text="Новости и турниры" FontSize="13" Foreground="{StaticResource Muted}" TextAlignment="Center"/>
          </StackPanel>
          <StackPanel Width="126">
            <Image x:Name="QrSite" Width="92" Height="92" Margin="0,0,0,7"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
              <Viewbox Width="15" Height="15" Margin="0,0,6,0"><Canvas Width="24" Height="24">
                <Ellipse Canvas.Left="2" Canvas.Top="2" Width="20" Height="20" Stroke="{StaticResource Accent}" StrokeThickness="2"/>
                <Path Stroke="{StaticResource Accent}" StrokeThickness="2" Data="M2,12 H22 M12,2 C15,5 16,8.5 16,12 C16,15.5 15,19 12,22 C9,19 8,15.5 8,12 C8,8.5 9,5 12,2"/>
              </Canvas></Viewbox>
              <TextBlock Text="simrace.pro" FontSize="14" FontWeight="SemiBold"/>
            </StackPanel>
            <TextBlock Text="Бронирование" FontSize="13" Foreground="{StaticResource Muted}" TextAlignment="Center"/>
          </StackPanel>
        </StackPanel>
      </Grid>
    </Grid>

    <!-- Описание игры по значку «i» -->
    <Grid x:Name="InfoPanel" Visibility="Collapsed" Background="#B3090A0C">
      <Border HorizontalAlignment="Center" VerticalAlignment="Center" Width="780" Background="#F7181A1C" BorderBrush="#29FFFFFF" BorderThickness="1" CornerRadius="18" Padding="48,36,48,36">
        <Border.Effect><DropShadowEffect BlurRadius="44" ShadowDepth="0" Color="#E2450F" Opacity="0.16"/></Border.Effect>
        <StackPanel>
          <Rectangle Width="56" Height="3" Fill="{StaticResource Accent}" HorizontalAlignment="Left" Margin="0,0,0,18"/>
          <TextBlock x:Name="TxtInfoTitle" FontSize="34" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,0,0,16"/>
          <TextBlock x:Name="TxtInfoText" FontSize="22" LineHeight="32" Foreground="{StaticResource Soft}" TextWrapping="Wrap" Margin="0,0,0,30"/>
          <Button x:Name="BtnInfoOk" Content="Понятно" Style="{StaticResource StartButton}" FontSize="22" MinWidth="200" HorizontalAlignment="Left"/>
        </StackPanel>
      </Border>
    </Grid>

    <!-- Предупреждение перед запуском игры из категории PRO -->
    <Grid x:Name="NoticePanel" Visibility="Collapsed" Background="#9E090A0C">
      <Border HorizontalAlignment="Center" VerticalAlignment="Center" Width="640" Background="#F7181A1C" BorderBrush="#29FFFFFF" BorderThickness="1" CornerRadius="18" Padding="48,34,48,36">
        <Border.Effect><DropShadowEffect BlurRadius="44" ShadowDepth="0" Color="#E2450F" Opacity="0.16"/></Border.Effect>
        <StackPanel>
          <TextBlock x:Name="TxtNoticeGame" FontSize="18" Foreground="{StaticResource Muted}" TextAlignment="Center" Margin="0,0,0,6"/>
          <TextBlock x:Name="TxtNoticeText" FontSize="34" FontWeight="SemiBold" TextAlignment="Center" TextWrapping="Wrap" Margin="0,0,0,28"/>
          <Button x:Name="BtnNoticeOk" Content="ОК" Style="{StaticResource StartButton}" FontSize="22" MinWidth="200" HorizontalAlignment="Center"/>
        </StackPanel>
      </Border>
    </Grid>

    <Grid x:Name="Overlay" Visibility="Collapsed" Background="#F20E0F11">
      <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" MaxWidth="1000">
        <!-- Ожидание: вращающееся кольцо вместо кнопок, чтобы гость просто ждал -->
        <Canvas x:Name="WaitSpinner" Width="64" Height="64" HorizontalAlignment="Center" Margin="0,0,0,32" RenderTransformOrigin="0.5,0.5" Visibility="Collapsed">
          <Canvas.RenderTransform><RotateTransform/></Canvas.RenderTransform>
          <Canvas.Triggers>
            <EventTrigger RoutedEvent="FrameworkElement.Loaded">
              <BeginStoryboard>
                <Storyboard RepeatBehavior="Forever">
                  <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(RotateTransform.Angle)" From="0" To="360" Duration="0:0:1.2"/>
                </Storyboard>
              </BeginStoryboard>
            </EventTrigger>
          </Canvas.Triggers>
          <Ellipse Width="64" Height="64" Stroke="#26FFFFFF" StrokeThickness="4"/>
          <Path Data="M32,2 A30,30 0 0 1 62,32" Stroke="{StaticResource Accent}" StrokeThickness="4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
        </Canvas>
        <Rectangle x:Name="OverlayLine" Width="72" Height="3" Fill="{StaticResource Accent}" Margin="0,0,0,28"/>
        <TextBlock x:Name="TxtOverlayTitle" FontSize="48" FontWeight="SemiBold" TextAlignment="Center" TextWrapping="Wrap"/>
        <TextBlock x:Name="TxtOverlayText" FontSize="22" Foreground="{StaticResource Muted}" TextAlignment="Center" TextWrapping="Wrap" Margin="0,16,0,40"/>
        <Button x:Name="BtnOverlay" Style="{StaticResource ActionButton}" HorizontalAlignment="Center"/>
      </StackPanel>
      <Button x:Name="BtnOverlayCorner" Style="{StaticResource CornerLink}" Visibility="Collapsed"/>
    </Grid>

    <Grid x:Name="AdminPanel" Visibility="Collapsed" Background="#E60A0B0D">
      <Border HorizontalAlignment="Center" VerticalAlignment="Center" Width="820" Background="#FA141518" BorderBrush="#2A2D31" BorderThickness="1" CornerRadius="22" Padding="38,32,38,26">
        <Border.Effect><DropShadowEffect BlurRadius="46" ShadowDepth="0" Color="#E2450F" Opacity="0.13"/></Border.Effect>
        <StackPanel>
          <DockPanel Margin="0,0,0,6">
            <Border DockPanel.Dock="Right" VerticalAlignment="Center" Background="#1C1E21" BorderBrush="#2E3135" BorderThickness="1" CornerRadius="16" Padding="14,7">
              <StackPanel Orientation="Horizontal">
                <Ellipse x:Name="LampUwf" Width="10" Height="10" Fill="#55585C" VerticalAlignment="Center" Margin="0,0,9,0"/>
                <TextBlock x:Name="TxtUwfState" Text="Проверяю защиту UWF" FontSize="15" Foreground="{StaticResource Soft}"/>
              </StackPanel>
            </Border>
            <TextBlock x:Name="TxtAdminTitle" Text="Панель администратора" FontSize="30" FontWeight="SemiBold"/>
          </DockPanel>

          <StackPanel x:Name="AdminLogin" Margin="0,14,0,0">
            <TextBlock Text="Учётная запись администратора Windows" FontSize="16" Foreground="{StaticResource Muted}" Margin="0,0,0,8"/>
            <Border Style="{StaticResource AdminInputBox}" Margin="0,0,0,16">
              <TextBox x:Name="AdminUserInput" FontSize="24" Padding="4,4" Background="Transparent" Foreground="White" BorderThickness="0" CaretBrush="White"/>
            </Border>
            <TextBlock Text="Пароль" FontSize="16" Foreground="{StaticResource Muted}" Margin="0,0,0,8"/>
            <DockPanel>
              <Button x:Name="BtnLayout" DockPanel.Dock="Right" Style="{StaticResource AdminGhost}" Padding="0" Width="72" Margin="10,0,0,0" Focusable="False" ToolTip="Сменить раскладку"/>
              <Ellipse x:Name="LampCaps" DockPanel.Dock="Right" Width="12" Height="12" Margin="14,0,4,0" Fill="#FFB020" Visibility="Hidden" VerticalAlignment="Center" ToolTip="Включён Caps Lock">
                <Ellipse.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="0" Color="#FFB020" Opacity="0.9"/></Ellipse.Effect>
              </Ellipse>
              <Border Style="{StaticResource AdminInputBox}">
                <PasswordBox x:Name="PasswordInput" FontSize="24" Padding="4,4" Background="Transparent" Foreground="White" BorderThickness="0" CaretBrush="White"/>
              </Border>
            </DockPanel>
            <TextBlock x:Name="TxtAdminError" Text="Неверный пароль или это не администратор" FontSize="18" Foreground="{StaticResource Accent}" Margin="0,10,0,0" Visibility="Collapsed"/>
            <StackPanel Orientation="Horizontal" Margin="0,24,0,6">
              <Button x:Name="BtnAdminLogin" Content="Войти" Style="{StaticResource AdminPrimary}" Margin="0,0,10,0"/>
              <Button x:Name="BtnCancel" Content="Отмена" Style="{StaticResource AdminGhost}"/>
            </StackPanel>
          </StackPanel>

          <StackPanel x:Name="AdminMenu" Visibility="Collapsed">
            <TextBlock Text="ЗАЩИТА" Style="{StaticResource AdminGroup}"/>
            <UniformGrid Columns="2" Margin="-5,0">
              <Button x:Name="BtnAdminUwf" Style="{StaticResource AdminTile}"><StackPanel Orientation="Horizontal"><Canvas Width="24" Height="24" VerticalAlignment="Center"><Rectangle Canvas.Left="5" Canvas.Top="11" Width="14" Height="10" RadiusX="2.2" RadiusY="2.2" Fill="#E2450F"/><Path x:Name="IconAdminUwf" Data="M8,11 V7.5 A4,4 0 0 1 15.6,5.8" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Canvas><TextBlock x:Name="TxtAdminUwf" Text="Разблокировать ПК" VerticalAlignment="Center" Margin="14,0,0,0"/></StackPanel></Button>
              <Button x:Name="BtnAdminUwfPanel" Style="{StaticResource AdminTile}"><StackPanel Orientation="Horizontal"><Canvas Width="24" Height="24" VerticalAlignment="Center"><Path Data="M12,2.5 L20,5.5 V11 C20,16 16.5,19.8 12,21.5 C7.5,19.8 4,16 4,11 V5.5 Z" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/><Path Data="M8.5,11.5 L11,14 L15.5,9" Stroke="#E2450F" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Canvas><TextBlock Text="Настройки UWF" VerticalAlignment="Center" Margin="14,0,0,0"/></StackPanel></Button>
            </UniformGrid>

            <TextBlock Text="ЛАУНЧЕР" Style="{StaticResource AdminGroup}"/>
            <Grid Margin="-5,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="92"/>
                <ColumnDefinition Width="92"/>
                <ColumnDefinition Width="92"/>
                <ColumnDefinition Width="92"/>
              </Grid.ColumnDefinitions>
              <Button x:Name="BtnAdminSettings" Grid.Column="0" Style="{StaticResource AdminTile}"><StackPanel Orientation="Horizontal"><Canvas Width="24" Height="24" VerticalAlignment="Center"><Path Data="M4,7 H20 M4,17 H20" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/><Ellipse Canvas.Left="12" Canvas.Top="4" Width="6" Height="6" Fill="#1C1E21" Stroke="#E2450F" StrokeThickness="2"/><Ellipse Canvas.Left="6" Canvas.Top="14" Width="6" Height="6" Fill="#1C1E21" Stroke="#E2450F" StrokeThickness="2"/></Canvas><TextBlock Text="Настройки лаунчера" VerticalAlignment="Center" Margin="14,0,0,0"/></StackPanel></Button>
              <Button x:Name="BtnMinimizeLauncher" Grid.Column="1" Style="{StaticResource AdminTile}" HorizontalContentAlignment="Center" ToolTip="Свернуть лаунчер"><StackPanel><Canvas Width="24" Height="24" HorizontalAlignment="Center"><Path Data="M5,19 H19" Stroke="White" StrokeThickness="2.4" StrokeStartLineCap="Round"/></Canvas><TextBlock Text="Свернуть" FontSize="12" FontWeight="Normal" Foreground="#A2A6AB" HorizontalAlignment="Center" Margin="0,4,0,0"/></StackPanel></Button>
              <Button x:Name="BtnRestartLauncher" Grid.Column="2" Style="{StaticResource AdminTile}" HorizontalContentAlignment="Center" ToolTip="Перезапустить лаунчер"><StackPanel><Canvas Width="24" Height="24" HorizontalAlignment="Center"><Path Data="M19.5,12 A7.5,7.5 0 1 1 17.3,6.7" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/><Path Data="M17.6,2.6 V7 H13.2" Stroke="#E2450F" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Canvas><TextBlock Text="Перезапуск" FontSize="12" FontWeight="Normal" Foreground="#A2A6AB" HorizontalAlignment="Center" Margin="0,4,0,0"/></StackPanel></Button>
              <Button x:Name="BtnAdminUpdate" Grid.Column="3" Style="{StaticResource AdminTile}" HorizontalContentAlignment="Center" ToolTip="Обновить лаунчер"><StackPanel><Canvas Width="24" Height="24" HorizontalAlignment="Center"><Path Data="M12,4 V14 M7.5,10 L12,14.5 L16.5,10" Stroke="#E2450F" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/><Path Data="M5,20 H19" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Canvas><TextBlock Text="Обновить" FontSize="12" FontWeight="Normal" Foreground="#A2A6AB" HorizontalAlignment="Center" Margin="0,4,0,0"/></StackPanel></Button>
              <Button x:Name="BtnExit" Grid.Column="4" Style="{StaticResource AdminTile}" HorizontalContentAlignment="Center" ToolTip="Закрыть лаунчер"><StackPanel><Canvas Width="24" Height="24" HorizontalAlignment="Center"><Ellipse Canvas.Left="2.5" Canvas.Top="2.5" Width="19" Height="19" Stroke="#E2450F" StrokeThickness="2"/><Path Data="M8.5,8.5 L15.5,15.5 M15.5,8.5 L8.5,15.5" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Canvas><TextBlock Text="Закрыть" FontSize="12" FontWeight="Normal" Foreground="#A2A6AB" HorizontalAlignment="Center" Margin="0,4,0,0"/></StackPanel></Button>
            </Grid>

            <Button x:Name="BtnAdminFleet" Style="{StaticResource AdminTile}" Margin="0,10,0,0" Visibility="Collapsed"><StackPanel Orientation="Horizontal"><Canvas Width="24" Height="24" VerticalAlignment="Center"><Rectangle Canvas.Left="2" Canvas.Top="4" Width="8" Height="7" RadiusX="1.5" RadiusY="1.5" Stroke="White" StrokeThickness="2"/><Rectangle Canvas.Left="14" Canvas.Top="4" Width="8" Height="7" RadiusX="1.5" RadiusY="1.5" Stroke="White" StrokeThickness="2"/><Rectangle Canvas.Left="2" Canvas.Top="14" Width="8" Height="7" RadiusX="1.5" RadiusY="1.5" Stroke="White" StrokeThickness="2"/><Rectangle Canvas.Left="14" Canvas.Top="14" Width="8" Height="7" RadiusX="1.5" RadiusY="1.5" Stroke="#E2450F" StrokeThickness="2"/></Canvas><TextBlock Text="Кокпиты клуба: состояние и обновление" VerticalAlignment="Center" Margin="12,0,0,0"/></StackPanel></Button>

            <TextBlock Text="КОМПЬЮТЕР" Style="{StaticResource AdminGroup}"/>
            <UniformGrid Columns="3" Margin="-5,0">
              <Button x:Name="BtnAdminTaskMgr" Style="{StaticResource AdminTile}"><StackPanel Orientation="Horizontal"><Canvas Width="24" Height="24" VerticalAlignment="Center"><Rectangle Canvas.Left="3" Canvas.Top="4" Width="18" Height="16" RadiusX="3" RadiusY="3" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/><Path Data="M6,13 H9 L11,9 L13,16 L15,13 H18" Stroke="#E2450F" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Canvas><TextBlock Text="Диспетчер задач" VerticalAlignment="Center" Margin="12,0,0,0"/></StackPanel></Button>
              <Button x:Name="BtnAdminShutdown" Style="{StaticResource AdminTile}"><StackPanel Orientation="Horizontal"><Canvas Width="24" Height="24" VerticalAlignment="Center"><Path Data="M12,3 V11" Stroke="#E2450F" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/><Path Data="M6.8,6.8 A8,8 0 1 0 17.2,6.8" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Canvas><TextBlock Text="Выключить ПК" VerticalAlignment="Center" Margin="14,0,0,0"/></StackPanel></Button>
              <Button x:Name="BtnAdminReboot" Style="{StaticResource AdminTile}"><StackPanel Orientation="Horizontal"><Canvas Width="24" Height="24" VerticalAlignment="Center"><Path Data="M19.5,12 A7.5,7.5 0 1 1 17.3,6.7" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/><Path Data="M17.6,2.6 V7 H13.2" Stroke="#E2450F" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Canvas><TextBlock Text="Перезагрузить ПК" VerticalAlignment="Center" Margin="14,0,0,0"/></StackPanel></Button>
            </UniformGrid>

            <DockPanel Margin="0,20,0,0">
              <Button x:Name="BtnAdminClose" DockPanel.Dock="Right" Content="Выйти из панели" Style="{StaticResource CornerLink}" Margin="16,0,-6,0" VerticalAlignment="Center" FontSize="16"/>
              <TextBlock x:Name="TxtAdminNote" FontSize="15" Foreground="{StaticResource Muted}" TextWrapping="Wrap" VerticalAlignment="Center"/>
            </DockPanel>
          </StackPanel>

          <StackPanel x:Name="AdminConfirm" Visibility="Collapsed" Margin="0,14,0,0">
            <TextBlock x:Name="TxtConfirmTitle" FontSize="24" FontWeight="SemiBold" Margin="0,0,0,10"/>
            <TextBlock x:Name="TxtConfirmText" FontSize="18" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,0,0,24"/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
              <Button x:Name="BtnConfirmOk" Style="{StaticResource AdminPrimary}" Margin="0,0,10,0"/>
              <Button x:Name="BtnConfirmCancel" Content="Назад" Style="{StaticResource AdminGhost}"/>
            </StackPanel>
          </StackPanel>
        </StackPanel>
      </Border>
    </Grid>

    <!-- Вопрос после обновления -->
    <Grid x:Name="DecisionPanel" Visibility="Collapsed" Background="#F20E0F11">
      <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" Width="760">
        <Rectangle Width="72" Height="3" Fill="{StaticResource Accent}" HorizontalAlignment="Left" Margin="0,0,0,24"/>
        <TextBlock Text="Заблокировать компьютер?" FontSize="36" FontWeight="SemiBold" Margin="0,0,0,12"/>
        <TextBlock x:Name="TxtDecisionText" FontSize="20" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,0,0,8"/>
        <TextBlock Text="Заблокировать: включится защита UWF, компьютер перезагрузится и будет готов для гостей. Оставить: защита останется выключенной." FontSize="20" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,0,0,28"/>
        <StackPanel Orientation="Horizontal">
          <Button x:Name="BtnDecideLock" Content="Заблокировать" Style="{StaticResource AdminPrimary}" Margin="0,0,10,0"/>
          <Button x:Name="BtnDecideKeep" Content="Оставить как есть" Style="{StaticResource AdminGhost}"/>
        </StackPanel>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@

[xml]$mixerXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Громкость" WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        ShowInTaskbar="False" Topmost="True" Width="380" SizeToContent="Height" Foreground="White"
        FontFamily="Segoe UI Variable Display, Segoe UI" UseLayoutRounding="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#E2450F"/>
    <SolidColorBrush x:Key="Line" Color="#3E4145"/>
    <Style x:Key="PanelButton" TargetType="Button">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="4"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="#26282B" BorderBrush="#3E4145" BorderThickness="1" CornerRadius="12" Padding="10,9">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#E2450F"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#E2450F"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="MixerSlider" TargetType="Slider">
      <Setter Property="Minimum" Value="0"/>
      <Setter Property="Maximum" Value="100"/>
      <Setter Property="IsMoveToPointEnabled" Value="True"/>
      <Setter Property="SmallChange" Value="1"/>
      <Setter Property="LargeChange" Value="5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Track x:Name="PART_Track" Height="36">
              <Track.DecreaseRepeatButton>
                <RepeatButton Command="{x:Static Slider.DecreaseLarge}" Focusable="False">
                  <RepeatButton.Template>
                    <ControlTemplate TargetType="RepeatButton">
                      <Border Background="Transparent"><Border Height="6" VerticalAlignment="Center" Background="{StaticResource Accent}"/></Border>
                    </ControlTemplate>
                  </RepeatButton.Template>
                </RepeatButton>
              </Track.DecreaseRepeatButton>
              <Track.IncreaseRepeatButton>
                <RepeatButton Command="{x:Static Slider.IncreaseLarge}" Focusable="False">
                  <RepeatButton.Template>
                    <ControlTemplate TargetType="RepeatButton">
                      <Border Background="Transparent"><Border Height="6" VerticalAlignment="Center" Background="{StaticResource Line}"/></Border>
                    </ControlTemplate>
                  </RepeatButton.Template>
                </RepeatButton>
              </Track.IncreaseRepeatButton>
              <Track.Thumb>
                <Thumb Width="24" Height="24">
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb"><Ellipse Fill="White"/></ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

  </Window.Resources>
  <Border Background="#F51A1B1E" BorderBrush="#3E4145" BorderThickness="1" CornerRadius="18" Padding="22,18,22,10">
    <StackPanel>
      <TextBlock x:Name="TxtPanelSession" FontSize="15" Foreground="#A2A6AB" Margin="0,0,0,12"/>
      <TextBlock Text="Вывод звука" FontSize="17" FontWeight="SemiBold" Margin="0,0,0,4"/>
      <StackPanel x:Name="OutputList" Margin="-4,0,-4,10"/>
      <Grid Margin="0,0,0,0">
        <TextBlock Text="Система" FontSize="17" FontWeight="SemiBold"/>
        <TextBlock x:Name="TxtSystem" Text="100%" FontSize="17" Foreground="#A2A6AB" HorizontalAlignment="Right"/>
      </Grid>
      <Slider x:Name="SliderSystem" Style="{StaticResource MixerSlider}" Margin="0,0,0,10"/>
      <Grid Margin="0,0,0,0">
        <TextBlock Text="Игра" FontSize="17" FontWeight="SemiBold"/>
        <TextBlock x:Name="TxtGame" Text="100%" FontSize="17" Foreground="#A2A6AB" HorizontalAlignment="Right"/>
      </Grid>
      <Slider x:Name="SliderGame" Style="{StaticResource MixerSlider}" Margin="0,0,0,10"/>
      <Grid Margin="0,0,0,0">
        <TextBlock Text="Mumble" FontSize="17" FontWeight="SemiBold"/>
        <TextBlock x:Name="TxtMumble" Text="100%" FontSize="17" Foreground="#A2A6AB" HorizontalAlignment="Right"/>
      </Grid>
      <Slider x:Name="SliderMumble" Style="{StaticResource MixerSlider}" Margin="0,0,0,10"/>
      <Grid Margin="0,0,0,0">
        <TextBlock Text="Браузер" FontSize="17" FontWeight="SemiBold"/>
        <TextBlock x:Name="TxtBrowser" Text="100%" FontSize="17" Foreground="#A2A6AB" HorizontalAlignment="Right"/>
      </Grid>
      <Slider x:Name="SliderBrowser" Style="{StaticResource MixerSlider}" Margin="0,0,0,12"/>
      <UniformGrid x:Name="PanelTools" Columns="2" Margin="-4,0,-4,6"/>
    </StackPanel>
  </Border>
</Window>
'@

try {
    $script:Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:LaunchTimeout = if ($script:Config.launchTimeoutSeconds) { [int]$script:Config.launchTimeoutSeconds } else { 180 }
    $script:ExitGrace = if ($script:Config.exitGraceSeconds) { [int]$script:Config.exitGraceSeconds } else { 2 }

    $script:SteamDirs = @{}
    $script:SteamRoot = Get-SteamRoot
    $script:SteamExe = if ($script:SteamRoot) { Join-Path $script:SteamRoot 'steam.exe' } else { $null }
    $script:SteamLibraries = Get-SteamLibraries $script:SteamRoot

    $script:ExitCode = 0
    $script:StartedAt = Get-Date
    $script:RestartFile = Join-Path $script:Root 'restart-request.txt'
    $script:WaitCornerAt = [datetime]::MaxValue
    $script:StatusLamps = @{}
    $script:NetAsync = $null
    $script:NetPs = $null
    $script:NetNext = [datetime]::MinValue
    $script:Facts = @()
    $script:FactDeck = @()
    $script:FactIndex = 0
    $script:FactFading = $false
    $script:FactNextAt = [datetime]::MaxValue
    $script:CancelledLaunch = $null
    $script:ServiceMode = $false
    $script:UwfAsync = $null
    $script:UwfPs = $null
    $script:NoticeApp = $null
    $script:DeviceWatch = $null
    $script:AgentShared = $null
    $script:SystemMenuClosedAt = [datetime]::MinValue
    $script:AxisDevices = @()
    $script:AxisInvert = @{}
    $script:AxisNextScan = [datetime]::MinValue
    $script:AxisTick = 0
    $script:ClutchAuto = $false
    $script:ClutchRest = $null
    $script:LockKnown = $false
    $script:LockTried = $false
    $script:AdminToken = $null
    $script:AdminPending = ''
    $script:AdminLastUse = [datetime]::MinValue
    $script:UwfOn = $null
    $script:BringTitle = ''
    $script:BringUntil = [datetime]::MinValue
    $script:AgentPollUntil = (Get-Date).AddMinutes(3)
    $script:Session = $null
    $script:TimerState = $(if ($script:Config.requireSession -eq $false) { 'running' } else { 'idle' })
    $script:TimerStart = Get-Date
    $script:TimerResume = $script:TimerStart
    $script:TimerAccum = [TimeSpan]::Zero
    $script:EndArmedUntil = [datetime]::MinValue
    $script:DeviceAsync = $null
    $script:DevicePs = $null
    $script:DeviceNext = [datetime]::MinValue
    $script:LastTile = $null
    $script:Shortcuts = $null
    $script:Sweeping = $false
    $script:SweepApp = $null
    $script:SweepClock = $null
    $script:GameLevel = $null
    $script:MumbleLevel = $null
    $script:BrowserLevel = $null
    $script:MixerLoading = $false
    $script:MixerPrevious = [IntPtr]::Zero
    $script:MixerHiddenAt = [datetime]::MinValue
    $script:BootUntil = [datetime]::MinValue
    $script:GameWindow = [IntPtr]::Zero
    $script:ForegroundBeforeClick = [IntPtr]::Zero
    $script:ToolLabels = New-Object System.Collections.ArrayList
    $script:ShellProcesses = @('explorer', 'powershell', 'shellexperiencehost', 'searchhost', 'startmenuexperiencehost', 'applicationframehost', 'textinputhost', 'systemsettings', 'lockapp', 'consent', 'nvidia overlay', 'nvcontainer')
    $script:NotGameProcesses = @('steam', 'steamwebhelper', 'explorer', 'powershell', 'conhost', 'cmd', 'windowsterminal', 'shellexperiencehost', 'searchhost', 'startmenuexperiencehost', 'applicationframehost', 'textinputhost', 'systemsettings', 'lockapp', 'consent', 'content manager', 'content manager safe', 'contentmanager', 'eadesktop', 'eabackgroundservice', 'easteamproxy', 'beammp-launcher', 'werfault', 'crashreportclient', 'steamerrorreporter', 'nvidia overlay', 'nvcontainer')
    $script:AudioReady = Initialize-Audio
    $script:AllowClose = $false
    $script:LayoutKey = ''
    $script:Tiles = New-Object System.Collections.ArrayList

    $Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    foreach ($name in 'BackgroundImage', 'BottomRow', 'FactBox', 'TxtFact', 'LogoHost', 'LogoImage', 'LogoText', 'FeatureBox', 'ToolsPanel',
                      'HeaderTools', 'TxtComputer', 'TxtClock', 'TilesHost', 'TileScroller', 'BtnScrollLeft', 'BtnScrollRight', 'RowsPanel', 'TxtEmpty', 'TxtSelected', 'TxtHint',
                      'DashHost', 'DashImage', 'LedCanvas', 'QrTelegram', 'QrSite',
                      'Overlay', 'WaitSpinner', 'OverlayLine', 'BtnOverlayCorner', 'TxtOverlayTitle', 'TxtOverlayText', 'BtnOverlay', 'AdminPanel', 'AdminUserInput', 'PasswordInput',
                      'TxtAdminError', 'BtnExit', 'BtnCancel', 'TxtAdminTitle', 'BtnMinimizeLauncher', 'TxtUwfState', 'AdminLogin', 'AdminMenu', 'AdminConfirm', 'BtnAdminLogin', 'BtnAdminUpdate', 'BtnAdminUwf', 'BtnAdminSettings', 'BtnAdminUwfPanel', 'BtnAdminReboot', 'TxtAdminNote', 'BtnAdminClose', 'TxtConfirmTitle', 'TxtConfirmText', 'BtnConfirmOk', 'BtnConfirmCancel', 'DecisionPanel', 'TxtDecisionText', 'BtnDecideLock', 'BtnDecideKeep',
                      'DashOffImage', 'DashLive', 'SheenHost', 'TxtDashTimer', 'TxtDashStart', 'TxtDashState', 'TxtDashText', 'TxtDashPosition', 'TxtDashLap', 'SessionStrip', 'TxtStripTime', 'TxtStripStart', 'BtnPause', 'BtnEndSession',
                      'SessionStart', 'BtnStartSession', 'TxtLastSession', 'StatusStrip', 'BtnStatusLang', 'NetBox', 'IconNet', 'StatusLinks', 'LampUwf', 'AxesCard', 'BarWheel', 'BarThrottle', 'BarBrake', 'BarClutch', 'TxtAxesRaw', 'SessionFields', 'BtnAdminShutdown', 'OverlayStrip', 'BarOverlay', 'TxtOverlayFree', 'BtnRestartLauncher', 'BtnAdminTaskMgr', 'BtnAdminFleet', 'IconPause', 'LockBox', 'IconLock', 'LampLock', 'LampCaps', 'TxtAdminUwf', 'IconAdminUwf', 'ImgRunning', 'SystemMenu', 'LampSysUwf', 'TxtSysUwf', 'BarSysOverlay', 'TxtSysOverlay', 'LampSysPage', 'TxtSysPage', 'InfoPanel', 'TxtInfoTitle', 'TxtInfoText', 'BtnInfoOk', 'NoticePanel', 'TxtNoticeGame', 'TxtNoticeText', 'BtnNoticeOk', 'BtnLayout', 'GameBar', 'SelectedInfo', 'TxtGameRunning', 'BtnResumeGame', 'BtnQuitGame') {
        Set-Variable -Name $name -Value $Window.FindName($name) -Scope Script
    }

    # Логотип вырезан из фирменной обоины без перерисовки. Если файла нет, выводим название текстом.
    if (-not (Set-ImageFile $LogoImage 'logo.png' 600)) { $LogoText.Visibility = 'Visible' }
    Initialize-Facts
    Initialize-Axes
    Start-AgentPoller
    Start-DeviceWatch
    [void](Set-ImageFile $BackgroundImage 'background.jpg')
    [void](Set-ImageFile $DashImage 'dash.png')
    [void](Set-ImageFile $DashOffImage 'dash-off.png')
    [void](Set-ImageFile $QrTelegram 'qr-telegram.png')
    [void](Set-ImageFile $QrSite 'qr-site.png')
    Initialize-Leds

    # Шрифты приборки лежат в папке лаунчера, устанавливать их не нужно
    $fontsUri = New-Object System.Uri((Join-Path $script:Root 'fonts') + '\')
    $script:DashFont = New-Object System.Windows.Media.FontFamily($fontsUri, './#Barlow Medium')
    # Race Position: номер компьютера из имени, например simrace-2 это 2
    $number = [regex]::Match($env:COMPUTERNAME, '(\d+)$')
    $TxtDashPosition.Text = $(if ($number.Success) { [string][int]$number.Value } else { '-' })
    foreach ($item in $TxtDashTimer, $TxtDashStart, $TxtDashState, $TxtDashPosition, $TxtDashLap) { $item.FontFamily = $script:DashFont }
    $TxtDashText.FontFamily = New-Object System.Windows.Media.FontFamily($fontsUri, './#Michroma')
    $TxtDashText.Text = $(if ($script:Config.dashText) { [string]$script:Config.dashText } else { 'READY TO RACE' })
    Initialize-Devices
    Initialize-DashPower

    $TxtComputer.Text = $env:COMPUTERNAME
    $TxtClock.Text = (Get-Date).ToString('HH:mm')

    foreach ($entry in @($script:Config.apps)) {
        try {
            $app = Resolve-App $entry
            if ($app) {
                [void]$script:Tiles.Add((New-Tile $app))
                # Программа сервера и подобные окном игры не считаются
                if ($app.Extra) {
                    $script:NotGameProcesses += @($app.Extra.Watch | ForEach-Object { ([string]$_).ToLowerInvariant() })
                    $script:ShellProcesses += @($app.Extra.Watch | ForEach-Object { ([string]$_).ToLowerInvariant() })
                }
            }
            else { Write-Log "Скрыта плитка (не найдена на этом ПК или выключена): $($entry.name)" }
        }
        catch { Write-Log "Ошибка в записи $($entry.name): $_" }
    }
    if ($script:Tiles.Count -eq 0) { $TxtEmpty.Visibility = 'Visible' }
    Initialize-TileSections

    $TilesHost.Add_SizeChanged({ Update-TileLayout })
    $TileScroller.Add_ScrollChanged({ Update-ScrollArrows })
    $BtnScrollLeft.Add_Click({ Move-TileScroll -1 })
    $BtnScrollRight.Add_Click({ Move-TileScroll 1 })
    $TileScroller.Add_PreviewMouseWheel({
        param($sender, $e)
        if ($TileScroller.ScrollableWidth -gt 0) {
            $TileScroller.ScrollToHorizontalOffset($TileScroller.HorizontalOffset - $e.Delta)
            $e.Handled = $true
        }
    })
    $Window.Add_SizeChanged({ Update-Proportions })
    $ToolsPanel.Add_SizeChanged({ Update-FeatureWidth })
    $FeatureBox.Add_SizeChanged({ Update-FactLayout })
    $LogoHost.Add_SizeChanged({ Update-FactLayout })

    $script:SweepTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:SweepTimer.Interval = [TimeSpan]::FromMilliseconds(25)
    $script:SweepTimer.Add_Tick({
        try { Update-LedSweep }
        catch {
            Write-Log "Ошибка анимации: $_"
            $script:SweepTimer.Stop()
            $script:Sweeping = $false
        }
    })

    $MixerWindow = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $mixerXaml))
    foreach ($name in 'OutputList', 'PanelTools', 'TxtPanelSession', 'SliderSystem', 'SliderGame', 'SliderMumble', 'SliderBrowser', 'TxtSystem', 'TxtGame', 'TxtMumble', 'TxtBrowser') {
        Set-Variable -Name $name -Value $MixerWindow.FindName($name) -Scope Script
    }
    $MixerWindow.Add_Deactivated({ Hide-MixerWindow $false })
    $MixerWindow.Add_KeyDown({
        param($sender, $e)
        if ($e.Key -eq 'Escape') { Hide-MixerWindow $true }
    })
    foreach ($entry in @($script:Config.utilities | Where-Object { $_ })) {
        try {
            $utility = Resolve-App $entry
            if (-not $utility) {
                Write-Log "Не найдена программа: $($entry.name)"
                if ($entry.place -ne 'status') { continue }
                # Программа в трее могла поставиться в другую папку: кнопку оставляем, путь возьмём у запущенного процесса
                $utility = [pscustomobject]@{ Name = $entry.name; Kind = 'exe'; Exe = $null; Args = $null; Watch = @($entry.watch | Where-Object { $_ }) }
            }
            $utility | Add-Member -NotePropertyName Tray -NotePropertyValue ($entry.place -eq 'status') -Force
            $script:NotGameProcesses += @($utility.Watch | ForEach-Object { ([string]$_).ToLowerInvariant() })
            $script:ShellProcesses += @($utility.Watch | ForEach-Object { ([string]$_).ToLowerInvariant() })
            if ($entry.place -eq 'status') { New-StatusLink $entry $utility }
            else { New-ToolButton $entry.name $entry.icon $utility { param($sender, $e) Start-Utility $sender.Tag } }
            [void](New-PanelButton $entry.name $entry.icon $utility {
                param($sender, $e)
                Hide-MixerWindow $false
                $script:ForegroundBeforeClick = $script:MixerPrevious
                Start-Utility $sender.Tag
            })
            # Голосовой чат стоит чуть отдельно от остальных кнопок
            if ($entry.gapAfter) {
                $HeaderTools.Children[$HeaderTools.Children.Count - 1].Margin = New-Object System.Windows.Thickness(0, 0, [double]$entry.gapAfter, 0)
            }
            if ($entry.autostart) { Start-Utility $utility }
        }
        catch { Write-Log "Ошибка в записи $($entry.name): $_" }
    }

    New-ToolButton 'Громкость' 'volume' $null { Switch-MixerWindow }

    [void](New-PanelButton 'В лаунчер' 'home' $null {
        Hide-MixerWindow $false
        Exit-ToLauncher
    })
    $script:PanelQuit = New-PanelButton 'Закрыть игру' 'close' $null {
        Hide-MixerWindow $false
        Stop-CurrentGame
    }

    # Шестерёнка стоит отдельно, справа от часов
    New-ToolButton 'Панель администратора' 'gear' $null { Show-AdminPanel } -IconOnly
    $gear = $HeaderTools.Children[$HeaderTools.Children.Count - 1]
    $HeaderTools.Children.Remove($gear)
    $gear.Margin = New-Object System.Windows.Thickness(10, 0, 0, 0)
    [void]$ToolsPanel.Children.Add($gear)

    $BtnAdminLogin.Add_Click({ Submit-AdminLogin })
    $BtnRestartLauncher.Add_Click({ Close-Launcher 2 })
    $BtnAdminTaskMgr.Add_Click({ Open-TaskManager })
    $BtnAdminFleet.Add_Click({ Open-AdminWindow 'Fleet.ps1' 'Кокпиты SIMRACE' })
    # Управление кокпитами клуба есть только на администраторском компьютере SIMRACE-14
    if ($env:COMPUTERNAME -match '(?i)-14$') { $BtnAdminFleet.Visibility = 'Visible' }
    $BtnAdminUpdate.Add_Click({ Request-AdminUpdate })
    $BtnAdminUwf.Add_Click({ Request-AdminUwf })
    $BtnAdminShutdown.Add_Click({ Show-AdminConfirm 'shutdown' 'Выключить ПК' 'Компьютер выключится. Включить его обратно можно только кнопкой на корпусе.' 'Выключить' })
    $BtnAdminReboot.Add_Click({ Show-AdminConfirm 'reboot' 'Перезагрузить ПК' 'Компьютер перезагрузится.' 'Перезагрузить' })
    $BtnAdminSettings.Add_Click({ Open-AdminWindow 'LauncherSettings.ps1' 'Настройки лаунчера SIMRACE' })
    $BtnAdminUwfPanel.Add_Click({ Open-AdminWindow 'UwfPanel.ps1' 'Защита UWF' })
    $BtnMinimizeLauncher.Add_Click({ Enter-ServiceMode })
    $BtnExit.Add_Click({ Close-Launcher 0 })
    $BtnAdminClose.Add_Click({ Hide-AdminPanel })
    $BtnConfirmOk.Add_Click({ Invoke-AdminPending })
    $BtnConfirmCancel.Add_Click({ Set-AdminPage 'menu' })
    $BtnDecideLock.Add_Click({ Submit-Decision $true })
    $BtnDecideKeep.Add_Click({ Submit-Decision $false })
    $AdminPanel.Add_PreviewMouseDown({ $script:AdminLastUse = Get-Date })

    $BtnInfoOk.Add_Click({ Hide-GameInfo })
    $LockBox.Add_MouseLeftButtonUp({ Switch-SystemMenu })
    $SystemMenu.Add_Closed({ $script:SystemMenuClosedAt = Get-Date })
    # Щелчок мимо карточки тоже закрывает описание
    $InfoPanel.Add_MouseLeftButtonUp({
        param($sender, $e)
        if ($e.OriginalSource -eq $InfoPanel) { Hide-GameInfo }
    })
    $BtnNoticeOk.Add_Click({
        $NoticePanel.Visibility = 'Collapsed'
        $app = $script:NoticeApp
        $script:NoticeApp = $null
        if ($app) { Open-App $app $true }
    })

    $BtnStartSession.Add_Click({ Start-ClubSession })
    $BtnPause.Add_Click({ Switch-ClubSessionPause })
    $BtnEndSession.Add_Click({ Stop-ClubSession })

    $BtnResumeGame.Add_Click({ Resume-Game })
    $BtnQuitGame.Add_Click({ Stop-CurrentGame })
    $SliderSystem.Add_ValueChanged({
        $TxtSystem.Text = "$([int]$SliderSystem.Value)%"
        if ($script:MixerLoading) { return }
        try { [SimraceAudio]::SetSystem([float]($SliderSystem.Value / 100)) }
        catch { Write-Log "Не изменена громкость системы: $_" }
    })
    $SliderGame.Add_ValueChanged({
        $TxtGame.Text = "$([int]$SliderGame.Value)%"
        if ($script:MixerLoading) { return }
        $script:GameLevel = $SliderGame.Value / 100
        try { [SimraceAudio]::SetGroup('game', [float]$script:GameLevel) }
        catch { Write-Log "Не изменена громкость игры: $_" }
    })
    $SliderMumble.Add_ValueChanged({
        $TxtMumble.Text = "$([int]$SliderMumble.Value)%"
        if ($script:MixerLoading) { return }
        $script:MumbleLevel = $SliderMumble.Value / 100
        try { [SimraceAudio]::SetGroup('mumble', [float]$script:MumbleLevel) }
        catch { Write-Log "Не изменена громкость Mumble: $_" }
    })

    $SliderBrowser.Add_ValueChanged({
        $TxtBrowser.Text = "$([int]$SliderBrowser.Value)%"
        if ($script:MixerLoading) { return }
        $script:BrowserLevel = $SliderBrowser.Value / 100
        try { [SimraceAudio]::SetGroup('browser', [float]$script:BrowserLevel) }
        catch { Write-Log "Не изменена громкость браузера: $_" }
    })

    $BtnOverlay.Add_Click({
        # Сообщение могло появиться во время игры: закрываем только его, а наблюдение за игрой продолжается
        if ($script:Session) { $Overlay.Visibility = 'Collapsed' }
        else { Stop-Session }
    })
    $BtnOverlayCorner.Add_Click({ Stop-Launch })
    $BtnLayout.Add_Click({ Switch-KeyboardLayout })
    $BtnStatusLang.Add_Click({ Switch-KeyboardLayout })
    $BtnCancel.Add_Click({ Hide-AdminPanel })
    $PasswordInput.Add_KeyDown({
        param($sender, $e)
        if ($e.Key -eq 'Return') { Submit-AdminLogin; $e.Handled = $true }
    })

    # Лаунчер развернули кнопкой на панели задач
    $Window.Add_StateChanged({
        if ($script:ServiceMode -and $Window.WindowState -ne 'Minimized') { Exit-ServiceMode }
    })
    $Window.Add_Closing({
        param($sender, $e)
        if (-not $script:AllowClose) { $e.Cancel = $true }
    })
    $Window.Add_SourceInitialized({
        [SimraceNative]::LauncherWindow = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle
        if (-not [SimraceNative]::InstallKeyGuard()) { Write-Log 'Не удалось включить перехват клавиш' }
    })
    $Window.Add_Loaded({
        Update-Proportions
        Update-TileLayout
        if ($script:DashOn) { Start-LedSweep $null }
        Update-TimerLayout
        if ($Boot) { Start-BootGuard }
        if ($script:Tiles.Count -gt 0) {
            $script:LastTile = $script:Tiles[0]
            [void]$script:Tiles[0].Focus()
        }
    })

    $script:TickCount = 0
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $timer.Add_Tick({
        try {
            $TxtClock.Text = (Get-Date).ToString('HH:mm')
            $script:TickCount++
            Update-GameWindow
            Update-BootGuard
            Update-LayoutLabel
            Update-NetStatusCheck
            Update-TimerDisplay
            Update-Fact
            if ($script:TickCount % 20 -eq 1) { Update-OverlayGauge }
            if ($script:TickCount % 4 -eq 2) { Test-RestartRequest }
            # Для обновления по сети: служба дождётся конца сеанса и игры
            if ($script:AgentShared) { $script:AgentShared.Busy = [bool]($script:Session -or $script:TimerState -ne 'idle') }
            if ($script:TickCount % 6 -eq 0) {
                Update-AgentStatus
                Update-LockStatus
            }
            # Открытая панель закрывается сама, если ей не пользуются 10 минут
            if ($AdminPanel.Visibility -eq 'Visible' -and $AdminLogin.Visibility -ne 'Visible' -and ((Get-Date) - $script:AdminLastUse).TotalMinutes -ge 10) { Hide-AdminPanel }
            Update-Devices
            if ($script:TickCount % 2 -eq 0) {
                Update-Session
                Update-CancelledLaunch
            }
            if ($script:TickCount % 4 -eq 0) {
                # Проводник мог перезапуститься и вернуть панель
                if (-not $script:ServiceMode) { [SimraceNative]::SetTaskbarVisible($false) }
                Update-MixerLevels
            }
        }
        catch { Write-Log "Ошибка таймера: $_" }
    })
    $timer.Start()

    # Сочетания клавиш проверяем часто, чтобы переключение было сразу
    $hotkeyTimer = New-Object System.Windows.Threading.DispatcherTimer
    $hotkeyTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $hotkeyTimer.Add_Tick({
        try {
            Update-UwfStatusCheck
            Update-CapsLamp
            if ($script:BringTitle) {
                $shown = $false
                foreach ($title in $script:BringTitle -split '\|') { if ([SimraceNative]::ActivateByTitle($title)) { $shown = $true } }
                if ($shown -or (Get-Date) -gt $script:BringUntil) { $script:BringTitle = '' }
            }
            if ([SimraceNative]::TakeAdminRequest()) { Show-AdminPanel }
            if ([SimraceNative]::TakeMixerRequest()) { Switch-MixerWindow }
            if ([SimraceNative]::TakeMenuRequest()) { Switch-GameAndLauncher }
        }
        catch { Write-Log "Ошибка переключения: $_" }
    })
    $hotkeyTimer.Start()

    $script:AxesTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:AxesTimer.Interval = [TimeSpan]::FromMilliseconds(66)
    $script:AxesTimer.Add_Tick({
        try { Update-Axes }
        catch {
            # Чтение идёт 15 раз в секунду: при ошибке останавливаемся, чтобы не забивать журнал и не мешать лаунчеру
            Write-Log "Чтение осей остановлено: $_"
            $script:AxesTimer.Stop()
        }
    })
    $script:AxesTimer.Start()

    [void]$Window.ShowDialog()
    $timer.Stop()
    $hotkeyTimer.Stop()
    $script:AxesTimer.Stop()
    if ($script:AgentShared) { $script:AgentShared.Stop = $true }
    $script:SweepTimer.Stop()
    $MixerWindow.Close()
    if ($script:AllowClose -and $script:ExitCode -eq 0) { Restore-Shell }
}
catch {
    Write-Log "Критическая ошибка: $_"
    exit 1
}
finally {
    [SimraceNative]::RemoveKeyGuard()
    $script:Mutex.ReleaseMutex()
}

Write-Log "Окно закрывается, код $($script:ExitCode)"
# Фоновые проверки не должны задерживать завершение: сторож перезапускает окно, только когда процесс вышел
[Environment]::Exit([int]$script:ExitCode)
