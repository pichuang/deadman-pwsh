#requires -Version 5.1
# pingpongman - PowerShell adaptation of https://github.com/upa/deadman.
#
# MIT License
#
# Copyright (c) 2018  Interop Tokyo ShowNet NOC team
# Copyright (c) 2024 Phil Huang (pichuang)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# Only this file is required. Edit EmbeddedConfig below to choose your targets.
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$ConfigFile,
    [Alias('s')][ValidateRange(1, 2147483647)][int]$Scale = 10,
    [Alias('a')][switch]$AsyncMode,
    [Alias('b')][switch]$BlinkArrow,
    [Alias('l')][string]$LogDir,
    [ValidateRange(0.01, 86400)][double]$Interval = 1,
    [ValidateRange(0.01, 86400)][double]$Timeout = 3,
    [Alias('h')][switch]$Help
)

$script:EmbeddedConfig = @'
# name       address                       options
localhost    127.0.0.1
---
blackair-icmp  ifconfig.blackair.io
blackair-tcp   ifconfig.blackair.io          via=tcp port=443
blackair-http  http://ifconfig.blackair.io/ via=http port=80
blackair-https https://ifconfig.blackair.io/ via=https port=443
blackair-https https://ifconfig.blackair.io/ip via=https port=443
---
# Intentional DNS failure: replace the reserved .invalid hostname to fix.
fail-dns     no-such-host.invalid
# Intentional wrong port: expect refusal/timeout unless a service uses port 81.
# Fix by using the service's actual port (443 for the successful TCP sample).
fail-port    ifconfig.blackair.io           via=tcp port=81
---
# web-tcp    localhost                     via=tcp port=443
# web-http   http://localhost/
# web-https  https://localhost/
'@

Add-Type -AssemblyName System.Net.Http -ErrorAction Stop

enum PingErrorCode { Success = 0; Failed = -1 }

class PingResult {
    [bool]$Success = $false
    [PingErrorCode]$ErrorCode = [PingErrorCode]::Failed
    [double]$RTT = 0
    [int]$TTL = 0
    [int]$StatusCode = 0
    [string]$Detail = 'Not probed'
    PingResult() {}
    PingResult([bool]$success, [PingErrorCode]$code, [double]$rtt, [int]$ttl) {
        $this.Success = $success
        $this.ErrorCode = $code
        $this.RTT = $rtt
        $this.TTL = $ttl
    }
}

class Separator {}

class PingTarget {
    [string]$Name
    [string]$LogName
    [string]$Address
    [string]$Protocol = 'icmp'
    [int]$TcpPort = 0
    [bool]$State = $false
    [int]$Sent = 0
    [int]$Loss = 0
    [double]$LossRate = 0
    [double]$RTT = 0
    [double]$Total = 0
    [double]$Average = 0
    [int]$TTL = 0
    [int]$StatusCode = 0
    [string]$Detail = 'Not probed'
    [int]$RttScale = 10
    [int]$HistoryLimit = 256
    [System.Collections.Generic.List[string]]$ResultHistory
    # One retained operation per target bounds uncancellable legacy DNS work.
    [object]$Pending

    PingTarget([string]$name, [string]$address) {
        $this.Name = $name
        $this.LogName = $name
        $this.Address = $address
        $this.ResultHistory = [System.Collections.Generic.List[string]]::new()
    }
    [string] GetResultChar([PingResult]$result) {
        if (-not $result.Success) { return 'X' }
        if ($this.RttScale -le 0) { throw 'RTT scale must be positive.' }
        if ($result.RTT -ge (7.0 * $this.RttScale)) { return '8' }
        $bucket = [int][Math]::Floor([Math]::Max(0.0, $result.RTT) / $this.RttScale)
        return [string]($bucket + 1)
    }
    [void] ConsumeResult([PingResult]$result) {
        $this.Sent++
        $this.State = $result.Success
        $this.StatusCode = $result.StatusCode
        $this.Detail = $result.Detail
        $this.RTT = 0
        $this.TTL = 0
        if ($result.Success) {
            $this.RTT = $result.RTT
            $this.TTL = $result.TTL
            $this.Total += $result.RTT
        } else {
            $this.Loss++
        }
        $successes = $this.Sent - $this.Loss
        if ($successes -gt 0) { $this.Average = $this.Total / $successes }
        $this.LossRate = 100.0 * $this.Loss / $this.Sent
        $this.ResultHistory.Insert(0, $this.GetResultChar($result))
        if ($this.HistoryLimit -lt 1) { throw 'History limit must be positive.' }
        if ($this.ResultHistory.Count -gt $this.HistoryLimit) {
            $this.ResultHistory.RemoveRange($this.HistoryLimit, $this.ResultHistory.Count - $this.HistoryLimit)
        }
    }
    [void] Refresh() {
        $this.State = $false
        $this.Sent = 0
        $this.Loss = 0
        $this.LossRate = 0
        $this.RTT = 0
        $this.Total = 0
        $this.Average = 0
        $this.TTL = 0
        $this.StatusCode = 0
        $this.Detail = 'Not probed'
        $this.ResultHistory.Clear()
    }
}

function Read-PingPongManConfig {
    [CmdletBinding(DefaultParameterSetName = 'File')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'File')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Text')][AllowEmptyString()][string]$Text,
        [ValidateRange(1, 2147483647)][int]$RttScale = 10
    )
    $source = 'EmbeddedConfig'
    if ($PSCmdlet.ParameterSetName -eq 'File') {
        $source = $Path
        $Text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    }
    $targets = [System.Collections.Generic.List[object]]::new()
    $names = @{}
    $lineNumber = 0
    foreach ($raw in ($Text -split '\r?\n')) {
        $lineNumber++
        $line = ($raw -replace ';\s*#.*$', '').Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $context = "${source}:${lineNumber}"
        if ($line -match '[^\x20-\x7e\t]') { throw "${context}: Use printable ASCII only." }
        if ($line -match '^-{3,}$') { $targets.Add([Separator]::new()); continue }
        $parts = $line -split '\s+'
        if ($parts.Count -lt 2) { throw "${context}: Expected name address [via=protocol] [port=number]." }
        $name = $parts[0]
        if ($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$' -or
            $name.EndsWith('.') -or $name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
            throw "${context}: Invalid target name '$name' (use a safe filename, 1..64 ASCII characters)."
        }
        $names[$name] = $true
        $options = @{}
        for ($index = 2; $index -lt $parts.Count; $index++) {
            $option = $parts[$index]
            if ($option -notmatch '^(via|port)=(.+)$') { throw "${context}: Unsupported option '$option'." }
            $key = $Matches[1].ToLowerInvariant()
            $value = $Matches[2]
            if ($options.ContainsKey($key)) { throw "${context}: Duplicate option '$key'." }
            $options[$key] = $value
        }
        $address = $parts[1]
        $protocol = 'icmp'
        if ($address -match '^https?://') { $protocol = ($address -split ':', 2)[0].ToLowerInvariant() }
        if ($options.ContainsKey('via')) { $protocol = $options.via.ToLowerInvariant() }
        if ($protocol -notin @('icmp', 'tcp', 'http', 'https')) {
            throw "${context}: Unsupported protocol '$protocol'."
        }
        $target = [PingTarget]::new($name, $address)
        $target.Protocol = $protocol
        $target.RttScale = $RttScale
        if ($protocol -in @('http', 'https')) {
            $uri = $null
            if ($address -match '\\' -or
                -not [Uri]::TryCreate($address, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -ne $protocol -or -not $uri.Host -or $uri.UserInfo -or
                $uri.Port -lt 1 -or $uri.Port -gt 65535 -or $address -notmatch '^https?://') {
                throw "${context}: Expected an absolute $protocol URL without credentials and with a valid port."
            }
            if ($options.ContainsKey('port')) {
                $port = 0
                if (-not [int]::TryParse($options.port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
                    throw "${context}: HTTP/HTTPS requires port=1..65535 when specified."
                }
                $authority = ($address -split '://', 2)[1] -split '[/?#]', 2
                if ($authority[0] -match ':\d+$' -and $uri.Port -ne $port) {
                    throw "${context}: port=$port conflicts with the explicit URL port $($uri.Port)."
                }
                if ($uri.Port -ne $port) {
                    $builder = [UriBuilder]::new($uri)
                    $builder.Port = $port
                    $target.Address = $builder.Uri.AbsoluteUri
                }
            }
        } else {
            $ip = $null
            $isIp = [System.Net.IPAddress]::TryParse($address, [ref]$ip)
            if (-not $isIp -and ($address -match '[:/\\]' -or
                [Uri]::CheckHostName($address) -ne [UriHostNameType]::Dns -or
                $address -match '^[\d.]+$')) {
                throw "${context}: Invalid hostname or IP address '$address'."
            }
            if ($protocol -eq 'tcp') {
                $port = 0
                if (-not $options.ContainsKey('port') -or -not [int]::TryParse($options.port, [ref]$port) -or
                    $port -lt 1 -or $port -gt 65535) { throw "${context}: TCP requires port=1..65535." }
                $target.TcpPort = $port
            } elseif ($options.ContainsKey('port')) {
                throw "${context}: port= requires TCP or an HTTP/HTTPS URL."
            }
        }
        $targets.Add($target)
    }
    if ($names.Count -eq 0) { throw "${source}: No monitoring targets configured." }
    # Reserve original names so a duplicate suffix cannot steal another row's log.
    $logNames = @{}
    foreach ($name in $names.Keys) { $logNames[$name] = $true }
    $seenNames = @{}
    foreach ($target in $targets) {
        if ($target -isnot [PingTarget]) { continue }
        $name = $target.Name
        if (-not $seenNames.ContainsKey($name)) { $seenNames[$name] = $true; continue }
        $suffix = 2
        do {
            $candidate = "$name-$suffix"
            $suffix++
        } while ($logNames.ContainsKey($candidate))
        $target.LogName = $candidate
        $logNames[$candidate] = $true
    }
    return ,$targets
}

function New-Probe {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Read-only network probe, no persistent target changes.')]
    param([PingTarget]$Target, [double]$TimeoutSeconds = 3)
    if ($null -ne $Target.Pending) {
        throw "Probe for '$($Target.Name)' is still finishing."
    }
    $entry = [pscustomobject]@{
        Target = $Target; Clock = [Diagnostics.Stopwatch]::StartNew()
        TimeoutMs = $TimeoutSeconds * 1000; Task = $null; Phase = 'dns'
        Client = $null; Request = $null; Cancellation = $null; Ping = $null
        Done = $false; Result = $null; Disposed = $false
        Addresses = @(); AddressIndex = 0
    }
    $Target.Pending = $entry
    try {
        if ($Target.Protocol -in @('http', 'https')) {
            $handler = [System.Net.Http.HttpClientHandler]::new()
            $handler.AllowAutoRedirect = $true
            $handler.MaxAutomaticRedirections = 5
            # Use only the platform's certificate validation and TLS defaults.
            $entry.Client = [System.Net.Http.HttpClient]::new($handler, $true)
            $entry.Client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
            $entry.Cancellation = [System.Threading.CancellationTokenSource]::new()
            $entry.Cancellation.CancelAfter([int][Math]::Ceiling($entry.TimeoutMs))
            $entry.Request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Target.Address)
            $entry.Phase = 'http'
            $entry.Task = $entry.Client.SendAsync($entry.Request,
                [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $entry.Cancellation.Token)
        } else {
            $entry.Task = [System.Net.Dns]::GetHostAddressesAsync($Target.Address)
        }
    } catch {
        Complete-Probe -Entry $entry -Detail $_.Exception.GetBaseException().Message
    }
    return $entry
}

function Close-ProbeResource {
    param($Entry)
    if ($Entry.Disposed) { return }
    if ($null -ne $Entry.Cancellation) { $Entry.Cancellation.Cancel() }
    foreach ($resource in @($Entry.Client, $Entry.Request, $Entry.Ping, $Entry.Cancellation)) {
        if ($null -ne $resource) { $resource.Dispose() }
    }
    $Entry.Disposed = $true
}

function Clear-ProbeTask {
    param($Entry)
    if ($null -ne $Entry.Task -and -not $Entry.Task.IsCompleted) { return $false }
    if ($null -ne $Entry.Task) {
        if ($Entry.Task.IsFaulted) { $null = $Entry.Task.Exception }
        elseif (-not $Entry.Task.IsCanceled -and $Entry.Phase -eq 'http') {
            $response = $Entry.Task.GetAwaiter().GetResult()
            if ($null -ne $response) { $response.Dispose() }
        }
    }
    if ([object]::ReferenceEquals($Entry.Target.Pending, $Entry)) { $Entry.Target.Pending = $null }
    return $true
}

function Complete-Probe {
    param($Entry, [string]$Detail, [bool]$Success = $false, [int]$StatusCode = 0, [int]$TTL = 0,
        [double]$Rtt = -1)
    if ($Entry.Done) { return }
    $Entry.Clock.Stop()
    $result = [PingResult]::new()
    $result.Success = $Success
    if ($Success) {
        $result.ErrorCode = [PingErrorCode]::Success
        $result.RTT = $Entry.Clock.Elapsed.TotalMilliseconds
        if ($Rtt -ge 0) { $result.RTT = $Rtt }
    }
    $result.Detail = $Detail
    $result.StatusCode = $StatusCode
    $result.TTL = $TTL
    $Entry.Result = $result
    $Entry.Done = $true
    Close-ProbeResource $Entry
    $null = Clear-ProbeTask $Entry
}

function Update-Probe {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Polls read-only network I/O.')]
    param($Entry)
    if ($Entry.Done) { $null = Clear-ProbeTask $Entry; return }
    if ($Entry.Clock.Elapsed.TotalMilliseconds -ge $Entry.TimeoutMs) {
        Complete-Probe $Entry -Detail 'Timeout'
        return
    }
    if ($null -eq $Entry.Task -or -not $Entry.Task.IsCompleted) { return }
    try {
        if ($Entry.Phase -eq 'tcp' -and ($Entry.Task.IsFaulted -or $Entry.Task.IsCanceled)) {
            $null = $Entry.Task.Exception
            $Entry.Client.Dispose()
            $Entry.Client = $null
            $Entry.AddressIndex++
            if ($Entry.AddressIndex -ge $Entry.Addresses.Count) {
                Complete-Probe $Entry -Detail 'TCP connection failed'
                return
            }
            $Entry.Phase = 'connect'
        } elseif ($Entry.Phase -eq 'dns') {
            $Entry.Addresses = @($Entry.Task.GetAwaiter().GetResult())
            if ($Entry.Addresses.Count -eq 0) { throw 'DNS returned no addresses.' }
            if ($Entry.Target.Protocol -eq 'icmp') {
                $Entry.Ping = [System.Net.NetworkInformation.Ping]::new()
                $Entry.Phase = 'icmp'
                $remaining = [int][Math]::Max(1, $Entry.TimeoutMs - $Entry.Clock.Elapsed.TotalMilliseconds)
                $Entry.Task = $Entry.Ping.SendPingAsync($Entry.Addresses[0], $remaining)
                return
            }
            $Entry.Phase = 'connect'
        } elseif ($Entry.Phase -eq 'http') {
            $response = $Entry.Task.GetAwaiter().GetResult()
            $status = [int]$response.StatusCode
            Complete-Probe $Entry -Detail "HTTP $status" -StatusCode $status -Success ($status -ge 200 -and $status -le 399)
            return
        } elseif ($Entry.Phase -eq 'icmp') {
            $reply = $Entry.Task.GetAwaiter().GetResult()
            $ttl = 0
            if ($null -ne $reply.Options) { $ttl = $reply.Options.Ttl }
            Complete-Probe $Entry -Detail $reply.Status.ToString() -TTL $ttl -Rtt $reply.RoundtripTime `
                -Success ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
            return
        } elseif ($Entry.Phase -eq 'tcp') {
            $null = $Entry.Task.GetAwaiter().GetResult()
            Complete-Probe $Entry -Detail 'Connected' -Success $true
            return
        }
        if ($Entry.Phase -eq 'connect') {
            $address = $Entry.Addresses[$Entry.AddressIndex]
            $Entry.Client = [System.Net.Sockets.TcpClient]::new($address.AddressFamily)
            $Entry.Phase = 'tcp'
            $Entry.Task = $Entry.Client.ConnectAsync($address, $Entry.Target.TcpPort)
        }
    } catch {
        Complete-Probe $Entry -Detail $_.Exception.GetBaseException().Message
    }
}

class ConsoleUI {
    [int]$Width = 80
    [int]$Height = 24
    [int]$Offset = 0
    [int]$Capacity = 19
    [bool]$Quit = $false
    [bool]$Reset = $false
    [int]$Step = 0

    [void] SetSize([int]$width, [int]$height, [int]$rowCount) {
        $this.Width = [Math]::Max(1, $width)
        $this.Height = [Math]::Max(1, $height)
        $this.Capacity = [Math]::Max(0, $height - 5)
        $this.Clamp($rowCount)
    }
    [void] Clamp([int]$rowCount) {
        $this.Offset = [Math]::Max(0, [Math]::Min($this.Offset, [Math]::Max(0, $rowCount - $this.Capacity)))
    }
    [void] HandleKey([ConsoleKeyInfo]$key, [int]$rowCount) {
        switch ($key.Key) {
            UpArrow { $this.Offset-- }
            DownArrow { $this.Offset++ }
            R { $this.Reset = $true }
            Q { $this.Quit = $true }
            C {
                if (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0) { $this.Quit = $true }
            }
        }
        $this.Clamp($rowCount)
    }
    [string] Fit([string]$text) {
        $text = $text -replace '[^\x20-\x7e]', '?'
        $length = [Math]::Max(0, $this.Width - 1)
        if ($text.Length -gt $length) { return $text.Substring(0, $length) }
        return $text.PadRight($length)
    }
    [string[]] Render([object[]]$targets, [int]$scale, [bool]$blink) {
        $this.Clamp($targets.Count)
        $lines = [System.Collections.Generic.List[string]]::new()
        if ($this.Height -lt 6) {
            $lines.Add($this.Fit('Window too short. Enlarge to 6 rows. Q quit'))
            while ($lines.Count -lt ($this.Height - 1)) { $lines.Add($this.Fit('')) }
            return $lines.ToArray()
        }
        $lines.Add($this.Fit('pingpongman - ICMP / TCP / HTTP / HTTPS'))
        $lines.Add($this.Fit("Up/Down scroll targets | R reset | Q/Ctrl+C quit | Scale ${scale}ms"))
        $first = 0
        if ($targets.Count -gt 0) { $first = $this.Offset + 1 }
        $last = [Math]::Min($targets.Count, $this.Offset + $this.Capacity)
        $lines.Add($this.Fit("Rows $first-$last/$($targets.Count) (includes separators); 1..8 RTT, X failure"))
        if ($this.Width -lt 60) {
            $lines.Add($this.Fit('NAME  LOSS% RTT/STATUS AVG SNT'))
        } elseif ($this.Width -ge 110) {
            $lines.Add($this.Fit('  NAME         ADDRESS                      PROTO LOSS% RTT/STATUS      AVG    SNT HISTORY'))
        } else {
            $lines.Add($this.Fit('  NAME         PROTO LOSS% RTT/STATUS      AVG    SNT HISTORY'))
        }
        for ($i = $this.Offset; $i -lt $last; $i++) {
            $target = $targets[$i]
            if ($target -is [Separator]) {
                $lines.Add($this.Fit(('-' * [Math]::Max(0, $this.Width - 1))))
                continue
            }
            $status = '-'
            if ($target.Sent -gt 0) {
                if ($target.State) { $status = '{0:F1}ms' -f $target.RTT }
                else { $status = $target.Detail }
                if ($target.StatusCode -gt 0) { $status = "$($target.StatusCode) $status" }
            }
            if ($status.Length -gt 12) { $status = $status.Substring(0, 12) }
            $marker = ' '
            if ($null -ne $target.Pending -and -not $target.Pending.Done -and
                (-not $blink -or $this.Step % 2 -eq 0)) { $marker = '>' }
            $name = $target.Name
            if ($name.Length -gt 12) { $name = $name.Substring(0, 12) }
            if ($this.Width -lt 60) {
                $text = '{0} {1:F0}% {2} {3:F1} {4} {5}' -f $name, $target.LossRate, $status, $target.Average, $target.Sent, ($target.ResultHistory -join '')
            } else {
                $text = '{0} {1,-12} {2,-5} {3,3:F0}% {4,-12} {5,6:F1} {6,6} {7}' -f `
                    $marker, $name, $target.Protocol, $target.LossRate, $status, $target.Average, $target.Sent, ($target.ResultHistory -join '')
                if ($this.Width -ge 110) {
                    $address = $target.Address
                    if ($address.Length -gt 28) { $address = $address.Substring(0, 28) }
                    $text = $text.Insert(15, $address.PadRight(28) + ' ')
                }
            }
            $lines.Add($this.Fit($text))
        }
        while ($lines.Count -lt ($this.Height - 1)) { $lines.Add($this.Fit('')) }
        return $lines.ToArray()
    }
}

function Write-ProbeLog {
    param([string]$Directory, [PingTarget]$Target)
    if (-not $Directory) { return }
    $null = New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop
    $record = [ordered]@{
        Time = [DateTimeOffset]::Now.ToString('o'); Name = $Target.Name; Address = $Target.Address
        Protocol = $Target.Protocol; Success = $Target.State; RTT = $Target.RTT
        Average = $Target.Average; Sent = $Target.Sent; Loss = $Target.Loss
        StatusCode = $Target.StatusCode; Detail = $Target.Detail
    }
    $record | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $Directory "$($Target.LogName).jsonl") -Encoding UTF8 -ErrorAction Stop
}

function New-MonitorState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates in-memory scheduler state only.')]
    param([object[]]$Targets, [bool]$Concurrent, [double]$IntervalSeconds = 1,
        [double]$TimeoutSeconds = 3, [string]$LogDirectory)
    return [pscustomobject]@{
        Targets = @($Targets | Where-Object { $_ -is [PingTarget] }); Concurrent = $Concurrent
        IntervalMs = $IntervalSeconds * 1000; TimeoutSeconds = $TimeoutSeconds; LogDirectory = $LogDirectory
        Active = [System.Collections.Generic.List[object]]::new()
        Queue = [System.Collections.Generic.Queue[object]]::new()
        Clock = [Diagnostics.Stopwatch]::StartNew(); NextRound = 0.0
    }
}

function Stop-MonitorProbe {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Disposes owned read-only probe operations.')]
    param($Monitor)
    foreach ($target in $Monitor.Targets) {
        if ($null -ne $target.Pending) {
            $entry = $target.Pending
            Complete-Probe $entry -Detail 'Stopped'
            $null = Clear-ProbeTask $entry
        }
    }
    $Monitor.Active.Clear()
    $Monitor.Queue.Clear()
}

function Invoke-MonitorTick {
    param($Monitor, [switch]$Reset)
    if ($Reset) {
        Stop-MonitorProbe $Monitor
        foreach ($target in $Monitor.Targets) { $target.Refresh() }
        $Monitor.NextRound = $Monitor.Clock.Elapsed.TotalMilliseconds
    }
    foreach ($target in $Monitor.Targets) {
        if ($null -ne $target.Pending -and $target.Pending.Done) { Update-Probe $target.Pending }
    }
    if ($Monitor.Active.Count -eq 0 -and $Monitor.Queue.Count -eq 0 -and
        $Monitor.Clock.Elapsed.TotalMilliseconds -ge $Monitor.NextRound) {
        $Monitor.NextRound = $Monitor.Clock.Elapsed.TotalMilliseconds + $Monitor.IntervalMs
        foreach ($target in $Monitor.Targets) { $Monitor.Queue.Enqueue($target) }
    }
    while ($Monitor.Queue.Count -gt 0 -and ($Monitor.Concurrent -or $Monitor.Active.Count -eq 0)) {
        $target = $Monitor.Queue.Dequeue()
        if ($null -ne $target.Pending) {
            $result = [PingResult]::new()
            $result.Detail = 'Previous probe still finishing'
            $target.ConsumeResult($result)
            Write-ProbeLog $Monitor.LogDirectory $target
            continue
        }
        $Monitor.Active.Add((New-Probe $target -TimeoutSeconds $Monitor.TimeoutSeconds))
    }
    for ($i = $Monitor.Active.Count - 1; $i -ge 0; $i--) {
        $entry = $Monitor.Active[$i]
        Update-Probe $entry
        if ($entry.Done) {
            $entry.Target.ConsumeResult($entry.Result)
            Write-ProbeLog $Monitor.LogDirectory $entry.Target
            $Monitor.Active.RemoveAt($i)
        }
    }
}

function Test-PingPongManConsole {
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected -or
        [Console]::WindowWidth -le 0 -or [Console]::WindowHeight -le 0) {
        throw 'pingpongman needs an interactive console. Run in powershell.exe or pwsh, not ISE or redirected input/output.'
    }
    try { $null = [Console]::KeyAvailable }
    catch { throw 'pingpongman needs an interactive console with keyboard input (not PowerShell ISE).' }
}

function Start-PingPongMan {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Interactive read-only monitoring loop.')]
    param([object[]]$Targets, [bool]$Concurrent, [double]$IntervalSeconds, [double]$TimeoutSeconds,
        [int]$RttScale, [string]$LogDirectory, [bool]$Blink)
    Test-PingPongManConsole
    $ui = [ConsoleUI]::new()
    $original = @{
        CursorVisible = $null; ControlC = [Console]::TreatControlCAsInput
        Left = [Console]::CursorLeft; Top = [Console]::CursorTop
    }
    # Unix cannot query cursor visibility; leave it unchanged there.
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $original.CursorVisible = [Console]::CursorVisible
    }
    $monitor = New-MonitorState $Targets -Concurrent $Concurrent -IntervalSeconds $IntervalSeconds `
        -TimeoutSeconds $TimeoutSeconds -LogDirectory $LogDirectory
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $nextDraw = 0.0
    try {
        if ($null -ne $original.CursorVisible) { [Console]::CursorVisible = $false }
        [Console]::TreatControlCAsInput = $true
        [Console]::Clear()
        while (-not $ui.Quit) {
            $ui.SetSize([Console]::WindowWidth, [Console]::WindowHeight, $Targets.Count)
            while ([Console]::KeyAvailable) { $ui.HandleKey([Console]::ReadKey($true), $Targets.Count) }
            if ($ui.Quit) { break }
            Invoke-MonitorTick $monitor -Reset:$ui.Reset
            $ui.Reset = $false
            if ($clock.Elapsed.TotalMilliseconds -ge $nextDraw) {
                $ui.Step++
                $lines = $ui.Render($Targets, $RttScale, $Blink)
                for ($row = 0; $row -lt $lines.Count; $row++) {
                    # A resize can race a frame; retry with fresh dimensions.
                    try {
                        [Console]::SetCursorPosition(0, $row)
                        [Console]::Write($lines[$row])
                    } catch [ArgumentOutOfRangeException] {
                        Write-Debug 'Console resized during rendering.'
                        break
                    }
                }
                $nextDraw = $clock.Elapsed.TotalMilliseconds + 100
            }
            Start-Sleep -Milliseconds 10
        }
    } finally {
        Stop-MonitorProbe $monitor
        [Console]::TreatControlCAsInput = $original.ControlC
        if ($null -ne $original.CursorVisible) { [Console]::CursorVisible = $original.CursorVisible }
        [Console]::Clear()
        [Console]::SetCursorPosition([Math]::Min($original.Left, [Console]::BufferWidth - 1),
            [Math]::Min($original.Top, [Console]::BufferHeight - 1))
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($ConfigFile -match '^--?(help|\?)$') { $Help = $true }
    if ($Help) {
        @'
pingpongman - single-file host monitor (PowerShell 5.1 / 7+)
Ported from https://github.com/upa/deadman (MIT).

Usage: .\pingpongman.ps1 [-ConfigFile path] [-AsyncMode] [-Scale 10]
                     [-Interval 1] [-Timeout 3] [-LogDir path] [-BlinkArrow]

No config file is needed: edit EmbeddedConfig in this script.
Config: name address [via=icmp|tcp|http|https] [port=1..65535]
TCP requires via=tcp port=number. HTTP/HTTPS require an absolute URL.
HTTP/HTTPS port= is optional; it must agree with an explicit URL port.
Display names may repeat; each row keeps independent statistics and logs.
Examples:
  loopback 127.0.0.1
  service  localhost via=tcp port=443
  website  https://example.com/health via=https port=443
  ---
Only ASCII names/UI are supported. # starts a full-line comment.
Use ; # for a trailing comment. Unknown/unsupported options are errors.

Up/Down: scroll target list. R: reset. Q/Ctrl+C: quit.
RTT history: 1..8 (floor(RTT / Scale) + 1, capped at 8), X failure.
HTTP GET: final 200..399 success; 400..599 failure. Headers only.
Redirect limit: 5. Normal TLS validation; no bypass or global TLS changes.
Interval: minimum round-start spacing; slow rounds do not overlap.
Timeout: per-probe deadline including DNS. Units are seconds.
No modules, external tools, jobs, or compiled helper code are required.
'@
    } else {
        $targets = $null
        if ($ConfigFile) { $targets = Read-PingPongManConfig -Path $ConfigFile -RttScale $Scale }
        else { $targets = Read-PingPongManConfig -Text $script:EmbeddedConfig -RttScale $Scale }
        Start-PingPongMan -Targets $targets.ToArray() -Concurrent $AsyncMode.IsPresent `
            -IntervalSeconds $Interval -TimeoutSeconds $Timeout -RttScale $Scale `
            -LogDirectory $LogDir -Blink $BlinkArrow.IsPresent
    }
}
