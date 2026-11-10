#Requires -Version 5.1
<#
  Веб-панель SIMRACE: окно «Кокпиты» в браузере. Работает только на SIMRACE-14, от имени SYSTEM, с загрузки компьютера.
  Открывается с ноутбука или планшета в сети клуба: http://SIMRACE-14:8014
  Вход по паролю администратора SIMRACE-14. Команды кокпитам уходят с адреса SIMRACE-14, как из окна «Кокпиты».
#>
$ErrorActionPreference = 'Stop'

$script:WebPort = 8014
$script:AgentPort = 47615
$script:Names = @(1..14 | ForEach-Object { "SIMRACE-$_" })
$script:VersionUrl = 'https://raw.githubusercontent.com/velizhaninv/simrace_launcher/main/version.txt'
$script:AdminUser = $(if ($env:COMPUTERNAME -match '(?i)-14$') { 'admin' } else { 'admin' + [regex]::Match($env:COMPUTERNAME, '(\d+)$').Value })

$logFolder = if (Test-Path -LiteralPath 'Z:\') { 'Z:\SIMRACE\Logs' } else { Join-Path $env:ProgramData 'SIMRACE\Logs' }
New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
$script:LogFile = Join-Path $logFolder "$env:COMPUTERNAME-web.log"
function Write-Log([string]$Text) {
    try { Add-Content -LiteralPath $script:LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text" -Encoding UTF8 } catch { }
}

# Проверка пароля администратора: та же, что в службе лаунчера
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security.Principal;

public static class SimraceWebNative
{
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LogonUser(string user, string domain, string password, int type, int provider, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr buffer, int length, out int needed);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public static bool IsAdminPassword(string user, string password)
    {
        IntPtr token;
        if (!LogonUser(user, ".", password, 2, 0, out token)) return false;
        IntPtr buffer = IntPtr.Zero;
        try
        {
            int needed;
            GetTokenInformation(token, 2, IntPtr.Zero, 0, out needed);
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
}
'@

# ---------- Опрос кокпитов: как в окне «Кокпиты» ----------

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

# Состояние кокпитов обновляется в фоне каждые 5 секунд, страница получает готовый ответ
$script:Cache = @{ Results = @{}; Latest = ''; At = $null }
$script:Background = $null
$script:NextPoll = [datetime]::MinValue
$script:NextVersion = [datetime]::MinValue

function Update-Cache {
    if ($script:Background -and $script:Background.Async.IsCompleted) {
        $job = $script:Background
        $script:Background = $null
        try {
            $output = @($job.Ps.EndInvoke($job.Async))[0]
            if ($output) {
                $script:Cache.Results = $output.Results
                if ($output.Latest) { $script:Cache.Latest = $output.Latest }
                $script:Cache.At = Get-Date
                Update-Macs $output.Results
            }
        }
        catch { Write-Log "Ошибка опроса: $_" }
        $job.Ps.Dispose()
    }
    if ($script:Background -or (Get-Date) -lt $script:NextPoll) { return }
    $script:NextPoll = (Get-Date).AddSeconds(5)
    $versionUrl = ''
    if ((Get-Date) -ge $script:NextVersion) {
        $versionUrl = $script:VersionUrl
        $script:NextVersion = (Get-Date).AddMinutes(5)
    }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:QueryScript).AddArgument($script:Names).AddArgument($script:AgentPort).AddArgument('{"action":"status"}').AddArgument($versionUrl).AddArgument(@{})
    $script:Background = @{ Ps = $ps; Async = $ps.BeginInvoke() }
}

# ---------- Включение по сети: адреса общие с окном «Кокпиты» ----------

$script:MacFile = $(if (Test-Path -LiteralPath 'Z:\') { 'Z:\SIMRACE\fleet-macs.json' } else { Join-Path $env:ProgramData 'SIMRACE\fleet-macs.json' })

function Get-Macs {
    $macs = @{}
    try {
        if (Test-Path -LiteralPath $script:MacFile) {
            $saved = Get-Content -LiteralPath $script:MacFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($property in $saved.PSObject.Properties) { $macs[$property.Name] = @($property.Value) }
        }
    }
    catch { }
    return $macs
}

function Update-Macs($Results) {
    $macs = Get-Macs
    $changed = $false
    foreach ($name in $script:Names) {
        $answer = $Results[$name]
        if (-not $answer) { continue }
        try { $data = $answer | ConvertFrom-Json } catch { continue }
        $list = @($data.macs | Where-Object { $_ })
        if ($list.Count -gt 0 -and (@($macs[$name]) -join ',') -ne ($list -join ',')) {
            $macs[$name] = $list
            $changed = $true
        }
    }
    if ($changed) {
        try {
            $folder = Split-Path -Parent $script:MacFile
            if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
            Set-Content -LiteralPath $script:MacFile -Value ($macs | ConvertTo-Json -Compress) -Encoding UTF8
        }
        catch { }
    }
}

function Send-WakePacket([string]$Mac) {
    $bytes = [byte[]]@($Mac -split '[-:]' | ForEach-Object { [Convert]::ToByte($_, 16) })
    if ($bytes.Count -ne 6) { throw "Неверный MAC: $Mac" }
    $packet = [byte[]](@(0xFF) * 6 + (@($bytes) * 16))
    $targets = @('255.255.255.255')
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up' -or $nic.NetworkInterfaceType -eq 'Loopback') { continue }
        foreach ($address in $nic.GetIPProperties().UnicastAddresses) {
            if ($address.Address.AddressFamily -ne 'InterNetwork' -or -not $address.IPv4Mask) { continue }
            $ip = $address.Address.GetAddressBytes()
            $mask = $address.IPv4Mask.GetAddressBytes()
            $broadcast = for ($i = 0; $i -lt 4; $i++) { $ip[$i] -bor ($mask[$i] -bxor 255) }
            $targets += ($broadcast -join '.')
        }
    }
    $client = New-Object System.Net.Sockets.UdpClient
    try {
        $client.EnableBroadcast = $true
        foreach ($target in @($targets | Sort-Object -Unique)) {
            foreach ($port in 9, 7) { [void]$client.Send($packet, $packet.Length, $target, $port) }
        }
    }
    finally { $client.Close() }
}

# ---------- Вход ----------

$script:Tokens = @{}          # ключ сеанса → когда истекает
$script:Failures = @{}        # адрес → список неудачных попыток

function New-Token {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Test-Token($Request) {
    $cookie = $Request.Cookies['simrace_token']
    if (-not $cookie) { return $false }
    $until = $script:Tokens[$cookie.Value]
    if (-not $until -or (Get-Date) -gt $until) { return $false }
    $script:Tokens[$cookie.Value] = (Get-Date).AddHours(12)
    return $true
}

# Не больше 5 неудачных попыток за 5 минут с одного адреса
function Test-Throttle([string]$Ip) {
    $recent = @($script:Failures[$Ip] | Where-Object { $_ -gt (Get-Date).AddMinutes(-5) })
    $script:Failures[$Ip] = $recent
    return ($recent.Count -lt 5)
}

# ---------- Ответы ----------

function Send-Response($Context, [int]$Code, [string]$Type, [string]$Body, [hashtable]$Headers = @{}) {
    $response = $Context.Response
    $response.StatusCode = $Code
    $response.ContentType = $Type
    $response.Headers['Cache-Control'] = 'no-store'
    foreach ($key in $Headers.Keys) { $response.Headers[$key] = $Headers[$key] }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Close()
}

function Send-Json($Context, $Object, [int]$Code = 200, [hashtable]$Headers = @{}) {
    Send-Response $Context $Code 'application/json; charset=utf-8' ($Object | ConvertTo-Json -Compress -Depth 8) $Headers
}

function Read-Body($Request) {
    $reader = New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    $reader.Close()
    if (-not $text) { return $null }
    return ($text | ConvertFrom-Json)
}

# Команда выбранным кокпитам сразу, без фонового опроса. С адреса SIMRACE-14 кокпиты её примут.
function Invoke-CockpitCommand([string[]]$Names, [string]$Line, [hashtable]$Lines = @{}) {
    $output = & $script:QueryScript $Names $script:AgentPort $Line '' $Lines
    $result = @{}
    foreach ($name in $Names) {
        $answer = $output.Results[$name]
        $data = $null
        if ($answer) { try { $data = $answer | ConvertFrom-Json } catch { } }
        $result[$name] = $(if (-not $answer) { @{ ok = $false; error = 'не ответил' } } elseif ($data) { $data } else { @{ ok = $false; error = 'непонятный ответ' } })
    }
    $script:NextPoll = [datetime]::MinValue      # список обновится сразу после команды
    return $result
}

function Invoke-Api($Context, [string]$Path) {
    $request = $Context.Request
    $ip = $request.RemoteEndPoint.Address.ToString()
    if ($Path -eq '/api/login' -and $request.HttpMethod -eq 'POST') {
        if (-not (Test-Throttle $ip)) { return Send-Json $Context @{ ok = $false; error = 'Слишком много попыток. Подожди 5 минут.' } 429 }
        $body = Read-Body $request
        $password = [string]$body.password
        $allowed = $false
        try { $allowed = [SimraceWebNative]::IsAdminPassword($script:AdminUser, $password) } catch { }
        if (-not $allowed) {
            $script:Failures[$ip] = @($script:Failures[$ip]) + (Get-Date)
            Write-Log "Неверный пароль с $ip"
            return Send-Json $Context @{ ok = $false; error = 'Неверный пароль.' } 401
        }
        $token = New-Token
        $script:Tokens[$token] = (Get-Date).AddHours(12)
        Write-Log "Вход с $ip"
        return Send-Json $Context @{ ok = $true } 200 @{ 'Set-Cookie' = "simrace_token=$token; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200" }
    }
    if (-not (Test-Token $request)) { return Send-Json $Context @{ ok = $false; error = 'Нужен вход.' } 401 }
    # Изменяющие запросы только со страницы панели: чужой сайт не сможет поставить этот заголовок
    if ($request.HttpMethod -eq 'POST' -and $request.Headers['X-Simrace'] -ne '1') { return Send-Json $Context @{ ok = $false; error = 'Запрос отклонён.' } 403 }
    switch ($Path) {
        '/api/state' {
            $rows = @{}
            foreach ($name in $script:Names) {
                $answer = $script:Cache.Results[$name]
                $data = $null
                if ($answer) { try { $data = $answer | ConvertFrom-Json } catch { } }
                $rows[$name] = $data
            }
            $macs = Get-Macs
            return Send-Json $Context @{ ok = $true; latest = $script:Cache.Latest; at = $(if ($script:Cache.At) { $script:Cache.At.ToString('HH:mm:ss') } else { '' }); rows = $rows; wake = @($script:Names | Where-Object { @($macs[$_]).Count -gt 0 }) }
        }
        '/api/command' {
            $body = Read-Body $request
            $action = [string]$body.action
            if ('update', 'maintain', 'lock', 'unlock', 'reboot', 'shutdown' -notcontains $action) { return Send-Json $Context @{ ok = $false; error = 'Неизвестная команда.' } 400 }
            $names = @($body.names | Where-Object { $script:Names -contains $_ })
            if ($names.Count -eq 0) { return Send-Json $Context @{ ok = $false; error = 'Не выбраны кокпиты.' } 400 }
            $lines = @{}
            foreach ($name in @($body.force | Where-Object { $names -contains $_ })) { $lines[$name] = "{`"action`":`"$action`",`"force`":true}" }
            Write-Log "Команда $action с $ip`: $($names -join ', ')"
            return Send-Json $Context @{ ok = $true; results = (Invoke-CockpitCommand $names "{`"action`":`"$action`"}" $lines) }
        }
        '/api/volume' {
            $body = Read-Body $request
            $name = [string]$body.name
            if ($script:Names -notcontains $name) { return Send-Json $Context @{ ok = $false; error = 'Неизвестный кокпит.' } 400 }
            $command = [ordered]@{ action = 'volume' }
            foreach ($key in 'system', 'game', 'mumble') { if ($null -ne $body.$key) { $command[$key] = [int]$body.$key } }
            Write-Log "Громкость $name с $ip"
            return Send-Json $Context @{ ok = $true; results = (Invoke-CockpitCommand @($name) ($command | ConvertTo-Json -Compress)) }
        }
        '/api/wake' {
            $body = Read-Body $request
            $macs = Get-Macs
            $sent = @(); $unknown = @()
            foreach ($name in @($body.names | Where-Object { $script:Names -contains $_ })) {
                $list = @($macs[$name] | Where-Object { $_ })
                if ($list.Count -eq 0) { $unknown += $name; continue }
                try { foreach ($mac in $list) { Send-WakePacket $mac }; $sent += $name } catch { $unknown += $name }
            }
            Write-Log "Включение с $ip`: $($sent -join ', ')"
            return Send-Json $Context @{ ok = $true; sent = $sent; unknown = $unknown }
        }
        '/api/logout' {
            $cookie = $request.Cookies['simrace_token']
            if ($cookie) { $script:Tokens.Remove($cookie.Value) }
            return Send-Json $Context @{ ok = $true } 200 @{ 'Set-Cookie' = 'simrace_token=; Path=/; Max-Age=0' }
        }
        default { return Send-Json $Context @{ ok = $false; error = 'Нет такого адреса.' } 404 }
    }
}

# Страница лежит рядом: WebPanel.html
$script:PageFile = Join-Path $PSScriptRoot 'WebPanel.html'

function Invoke-Request($Context) {
    $path = $Context.Request.Url.AbsolutePath
    if ($path -like '/api/*') { return Invoke-Api $Context $path }
    if ($path -eq '/' -or $path -eq '/index.html') {
        $page = $(try { [System.IO.File]::ReadAllText($script:PageFile, [System.Text.Encoding]::UTF8) } catch { '<h1>Страница панели не найдена</h1>' })
        return Send-Response $Context 200 'text/html; charset=utf-8' $page @{ 'X-Frame-Options' = 'DENY' }
    }
    Send-Response $Context 404 'text/plain; charset=utf-8' 'Не найдено'
}

# ---------- Основной цикл ----------

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$($script:WebPort)/")
try { $listener.Start() }
catch {
    Write-Log "Веб-панель не запустилась на порту $($script:WebPort): $_"
    exit 1
}
Write-Log "Веб-панель запущена: http://$($env:COMPUTERNAME):$($script:WebPort)"
Update-Cache
while ($listener.IsListening) {
    $async = $listener.BeginGetContext($null, $null)
    while (-not $async.AsyncWaitHandle.WaitOne(500)) {
        try { Update-Cache } catch { Write-Log "Ошибка обновления: $_" }
    }
    $context = $null
    try { $context = $listener.EndGetContext($async) } catch { continue }
    try { Invoke-Request $context }
    catch {
        Write-Log "Ошибка запроса $($context.Request.Url.AbsolutePath): $_"
        try { Send-Json $context @{ ok = $false; error = 'Ошибка на SIMRACE-14.' } 500 } catch { }
    }
}
