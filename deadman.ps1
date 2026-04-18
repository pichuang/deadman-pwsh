#!/usr/bin/env pwsh
# -*- coding: utf-8 -*-
# deadman.ps1 — Main entry point (single-file edition)
# Ported from https://github.com/upa/deadman (MIT License)
#
# deadman is a host monitoring tool using ICMP Ping and TCP Ping.
# This version is implemented in PowerShell 5.1+ using the System.Console API for terminal UI.
# Works best with PowerShell 7+ but is fully compatible with Windows PowerShell 5.1.
#
# Usage:
#   ./deadman.ps1
#   ./deadman.ps1 -ConfigFile deadman.conf
#   ./deadman.ps1 -ConfigFile deadman.conf -AsyncMode
#   ./deadman.ps1 -ConfigFile deadman.conf -Scale 20 -LogDir ./logs

[CmdletBinding()]
param(
    # Configuration file path (defaults to deadman.conf in script directory)
    [Parameter(Position = 0)]
    [string]$ConfigFile,

    # RTT bar chart scale (milliseconds), default 10ms
    [Alias('s')]
    [int]$Scale = 10,

    # Enable async ping mode (ping all targets simultaneously)
    [Alias('a')]
    [switch]$AsyncMode,

    # Blink arrow indicator in async mode
    [Alias('b')]
    [switch]$BlinkArrow,

    # Log directory path (optional, writes ping results to log files)
    [Alias('l')]
    [string]$LogDir,

    # Show usage help and exit
    [Alias('h')]
    [switch]$Help
)

# ============================================================
# Help message
# ============================================================

if ($Help) {
    @"
deadman.ps1 — Host monitoring tool using ICMP Ping and TCP Ping
Ported from https://github.com/upa/deadman (MIT License)

USAGE:
    ./deadman.ps1 [options]

OPTIONS:
    -ConfigFile <path>   Configuration file path (default: deadman.conf)
    -Scale, -s <int>     RTT bar chart scale in ms (default: 10)
    -AsyncMode, -a       Enable async ping mode (ping all targets simultaneously)
    -BlinkArrow, -b      Blink arrow indicator in async mode
    -LogDir, -l <path>   Log directory path (writes ping results to files)
    -Help, -h            Show this help message and exit

CONFIG FILE FORMAT:
    name    address    [options]
    ---                            (separator line)
    # comment                      (ignored)

    Supported options:
      source=<interface>           Specify source network interface
      via=tcp port=<number>        Use TCP SYN ping (Windows: tnc, macOS/Linux: hping3)

EXAMPLES:
    ./deadman.ps1
    ./deadman.ps1 -ConfigFile deadman.conf
    ./deadman.ps1 -ConfigFile deadman.conf -AsyncMode
    ./deadman.ps1 -ConfigFile deadman.conf -Scale 20 -LogDir ./logs
    sudo pwsh ./deadman.ps1 -a     # TCP ping on macOS/Linux requires root

INTERACTIVE KEYS:
    r    Reset all target statistics
    q    Quit the program

REQUIREMENTS:
    PowerShell 5.1 or later (PowerShell 7+ recommended for best experience)
    hping3 (macOS/Linux only, for TCP ping, requires sudo)
"@
    exit 0
}

# ============================================================
# Validate environment
# ============================================================

# Ensure PowerShell version >= 5.1
if ($PSVersionTable.PSVersion.Major -lt 5 -or
    ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
    Write-Error "deadman requires PowerShell 5.1 or later. Current version: $($PSVersionTable.PSVersion)"
    exit 1
}

# ============================================================
# Cross-version helper functions
# ============================================================

# Platform detection — PS 6+ has $IsWindows; PS 5.1 runs only on Windows
function Test-IsWindows {
    if ($null -ne $global:IsWindows) { return $global:IsWindows }
    # PowerShell 5.1 (Windows PowerShell) only runs on Windows
    return $true
}

# Detect whether the console supports Unicode block elements
# Returns $true if Windows Terminal, modern console, or non-Windows (most support Unicode)
function Test-UnicodeSupport {
    # Non-Windows platforms generally support Unicode
    if (-not (Test-IsWindows)) { return $true }
    # Windows Terminal sets WT_SESSION
    if ($env:WT_SESSION) { return $true }
    # VS Code integrated terminal
    if ($env:TERM_PROGRAM -eq 'vscode') { return $true }
    # Check if OutputEncoding is already UTF-8
    try {
        if ([Console]::OutputEncoding.WebName -eq 'utf-8') { return $true }
    } catch { }
    return $false
}

# Script-level flag for ASCII fallback mode
$script:UseAsciiChars = -not (Test-UnicodeSupport)

# Script-level flag for PowerShell version (class methods cannot access $PSVersionTable)
$script:PSMajorVersion = $PSVersionTable.PSVersion.Major

# Script-level flag for Windows platform (class methods cannot call script functions reliably)
$script:IsWindowsPlatform = Test-IsWindows

# Set console output encoding to UTF-8 on Windows for proper Unicode rendering
if (Test-IsWindows) {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
    } catch { }
}

# Show hint when falling back to ASCII mode
if ($script:UseAsciiChars -and $MyInvocation.InvocationName -ne '.') {
    Write-Host "[Info] Console does not fully support Unicode block characters." -ForegroundColor Yellow
    Write-Host "[Info] Using ASCII fallback mode for RTT bar chart." -ForegroundColor Yellow
    Write-Host "[Info] For best display, use Windows Terminal or run 'chcp 65001' first." -ForegroundColor Yellow
    Write-Host ""
}

# Get script directory
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# Default ConfigFile to deadman.conf in script directory
if ([string]::IsNullOrEmpty($ConfigFile)) {
    $ConfigFile = Join-Path $scriptRoot 'deadman.conf'
}

# ============================================================
# Class definitions — PingErrorCode, PingResult, Separator, PingTarget
# ============================================================

# Ping error code enumeration
enum PingErrorCode {
    # Ping succeeded
    Success = 0
    # Ping failed (timeout or no response)
    Failed = -1
}

# PingResult class — encapsulates a single ping result
class PingResult {
    [bool]$Success = $false
    [PingErrorCode]$ErrorCode = [PingErrorCode]::Failed
    [double]$RTT = 0.0
    [int]$TTL = 0

    PingResult() {}

    PingResult([bool]$success, [PingErrorCode]$errorCode, [double]$rtt, [int]$ttl) {
        $this.Success = $success
        $this.ErrorCode = $errorCode
        $this.RTT = $rtt
        $this.TTL = $ttl
    }
}

# Separator class — separator marker in configuration file
class Separator {}

# PingTarget class — encapsulates a single ping monitoring target
class PingTarget {
    [string]$Name
    [string]$Address
    [string]$Source
    [int]$TcpPort = 0
    [bool]$State = $false
    [int]$Loss = 0
    [double]$LossRate = 0.0
    [double]$RTT = 0
    [double]$Total = 0
    [double]$Average = 0
    [int]$Sent = 0
    [int]$TTL = 0
    [System.Collections.Generic.List[string]]$ResultHistory
    [int]$RttScale = 10

    PingTarget([string]$name, [string]$address) {
        $this.Name = $name
        $this.Address = $address
        $this.Source = $null
        $this.ResultHistory = [System.Collections.Generic.List[string]]::new()
    }

    PingTarget([string]$name, [string]$address, [string]$source) {
        $this.Name = $name
        $this.Address = $address
        $this.Source = $source
        $this.ResultHistory = [System.Collections.Generic.List[string]]::new()
    }

    # Execute a single ping (ICMP or TCP based on TcpPort)
    [void] Send() {
        if ($this.TcpPort -gt 0) {
            $this.SendTcp()
            return
        }

        $result = [PingResult]::new()
        try {
            if ($script:PSMajorVersion -ge 7) {
                # PowerShell 7+: use -TargetName, -TimeoutSeconds, -Ping
                $params = @{
                    TargetName     = $this.Address
                    Count          = 1
                    TimeoutSeconds = 1
                    Ping           = $true
                    ErrorAction    = 'Stop'
                }
                $reply = Test-Connection @params
                if ($reply.Status -eq 'Success') {
                    $result.Success = $true
                    $result.ErrorCode = [PingErrorCode]::Success
                    $result.RTT = [double]$reply.Latency
                    $result.TTL = if ($null -ne $reply.Reply -and $null -ne $reply.Reply.Options) {
                        [int]$reply.Reply.Options.Ttl
                    } else { -1 }
                }
            }
            else {
                # PowerShell 5.1: use -ComputerName, returns Win32_PingStatus
                $reply = Test-Connection -ComputerName $this.Address -Count 1 -ErrorAction Stop
                if ($reply.StatusCode -eq 0) {
                    $result.Success = $true
                    $result.ErrorCode = [PingErrorCode]::Success
                    $result.RTT = [double]$reply.ResponseTime
                    $result.TTL = if ($null -ne $reply.ResponseTimeToLive) {
                        [int]$reply.ResponseTimeToLive
                    } else { -1 }
                }
            }
        }
        catch {
            $result.Success = $false
            $result.ErrorCode = [PingErrorCode]::Failed
        }
        $this.Sent++
        $this.ConsumeResult($result)
    }

    # Execute a TCP ping (SYN check)
    # Windows: Test-NetConnection, macOS/Linux: hping3
    [void] SendTcp() {
        $result = [PingResult]::new()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            if ($script:IsWindowsPlatform) {
                $tnc = Test-NetConnection -ComputerName $this.Address -Port $this.TcpPort -WarningAction SilentlyContinue -ErrorAction Stop
                $sw.Stop()
                if ($tnc.TcpTestSucceeded) {
                    $result.Success = $true
                    $result.ErrorCode = [PingErrorCode]::Success
                    $result.RTT = [double]$sw.Elapsed.TotalMilliseconds
                    $result.TTL = -1
                }
            }
            else {
                $hpingOutput = & hping3 -S -p $this.TcpPort -c 1 $this.Address 2>&1
                $sw.Stop()
                $outputStr = $hpingOutput -join "`n"
                if ($outputStr -match 'flags=SA' -or $outputStr -match 'flags=S\.A') {
                    $result.Success = $true
                    $result.ErrorCode = [PingErrorCode]::Success
                    if ($outputStr -match 'rtt=([\d.]+)\s*ms') {
                        $result.RTT = [double]$Matches[1]
                    } else {
                        $result.RTT = [double]$sw.Elapsed.TotalMilliseconds
                    }
                    $result.TTL = -1
                    if ($outputStr -match 'ttl=(\d+)') {
                        $result.TTL = [int]$Matches[1]
                    }
                }
            }
        }
        catch {
            $sw.Stop()
            $result.Success = $false
            $result.ErrorCode = [PingErrorCode]::Failed
        }
        $this.Sent++
        $this.ConsumeResult($result)
    }

    # Consume ping result and update statistics
    [void] ConsumeResult([PingResult]$res) {
        if ($res.Success) {
            $this.State = $true
            $this.RTT = $res.RTT
            $this.Total += $res.RTT
            $this.Average = $this.Total / $this.Sent
            $this.TTL = $res.TTL
        }
        else {
            $this.Loss++
            $this.State = $false
        }
        $this.LossRate = [double]$this.Loss / [double]$this.Sent * 100.0
        $this.ResultHistory.Insert(0, $this.GetResultChar($res))
    }

    # Return bar chart character based on RTT
    # Uses Unicode block elements when supported, ASCII fallback otherwise
    [string] GetResultChar([PingResult]$res) {
        if ($res.ErrorCode -eq [PingErrorCode]::Failed) { return 'X' }
        $scale = $this.RttScale
        if ($script:UseAsciiChars) {
            # ASCII fallback for consoles without Unicode support
            if ($res.RTT -lt ($scale * 1)) { return '_' }
            if ($res.RTT -lt ($scale * 2)) { return '.' }
            if ($res.RTT -lt ($scale * 3)) { return 'o' }
            if ($res.RTT -lt ($scale * 4)) { return 'O' }
            if ($res.RTT -lt ($scale * 5)) { return '+' }
            if ($res.RTT -lt ($scale * 6)) { return '=' }
            if ($res.RTT -lt ($scale * 7)) { return '#' }
            return '@'
        }
        if ($res.RTT -lt ($scale * 1)) { return [char]0x2581 }
        if ($res.RTT -lt ($scale * 2)) { return [char]0x2582 }
        if ($res.RTT -lt ($scale * 3)) { return [char]0x2583 }
        if ($res.RTT -lt ($scale * 4)) { return [char]0x2584 }
        if ($res.RTT -lt ($scale * 5)) { return [char]0x2585 }
        if ($res.RTT -lt ($scale * 6)) { return [char]0x2586 }
        if ($res.RTT -lt ($scale * 7)) { return [char]0x2587 }
        return [char]0x2588
    }

    # Reset all statistics (preserve name, address, TcpPort)
    [void] Refresh() {
        $this.State = $false
        $this.Loss = 0
        $this.LossRate = 0.0
        $this.RTT = 0
        $this.Total = 0
        $this.Average = 0
        $this.Sent = 0
        $this.TTL = 0
        $this.ResultHistory.Clear()
    }

    [string] ToString() {
        $parts = @($this.Name, $this.Address)
        if ($this.Source) { $parts += $this.Source }
        if ($this.TcpPort -gt 0) { $parts += "tcp:$($this.TcpPort)" }
        return ($parts -join ':')
    }
}

# ============================================================
# Configuration file parser — Read-DeadmanConfig
# ============================================================

function Read-DeadmanConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [int]$RttScale = 10
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }

    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    $targets = [System.Collections.Generic.List[object]]::new()

    foreach ($rawLine in $lines) {
        $line = $rawLine -replace '\t', ' '
        $line = $line -replace '\s+', ' '
        $line = $line -replace '^\s*#.*', ''
        $line = $line -replace ';\s*#.*', ''
        $line = $line.Trim()

        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $parts = $line -split '\s+'
        $name = $parts[0]

        if ($name -match '^-+$') {
            $targets.Add([Separator]::new())
            continue
        }

        if ($parts.Count -lt 2) {
            Write-Warning "Invalid config line format, missing address field: $rawLine"
            continue
        }
        $address = $parts[1]

        $source = $null
        $via = $null
        $port = 0
        for ($i = 2; $i -lt $parts.Count; $i++) {
            $option = $parts[$i]
            if ($option -match '^(\w+)=(.+)$') {
                $key = $Matches[1]
                $value = $Matches[2]
                switch ($key) {
                    'source' { $source = $value }
                    'via'    { $via = $value }
                    'port'   { $port = [int]$value }
                    default  { <# Ignore unsupported options #> }
                }
            }
        }

        if ($source) {
            $target = [PingTarget]::new($name, $address, $source)
        } else {
            $target = [PingTarget]::new($name, $address)
        }
        $target.RttScale = $RttScale
        if ($via -eq 'tcp' -and $port -gt 0) {
            $target.TcpPort = $port
        }
        $targets.Add($target)
    }

    return , $targets
}

# ============================================================
# ConsoleUI class — terminal rendering
# ============================================================

$script:TITLE_PROGNAME = "Dead Man PWSH"
$script:TITLE_VERSION = "[ver 2026.03.31-ps]"
$script:TITLE_VERTIC_LENGTH = 4
$script:ARROW = " > "
$script:REAR  = "   "
$script:MAX_HOSTNAME_LENGTH = 20
$script:MAX_ADDRESS_LENGTH = 40
$script:RESULT_STR_LENGTH = 10

class ConsoleUI {
    [int]$Width
    [int]$Height
    [int]$StartArrow
    [int]$LengthArrow
    [int]$StartHostname
    [int]$LengthHostname
    [int]$StartAddress
    [int]$LengthAddress
    [int]$RefStart
    [int]$RefLength
    [int]$ResStart
    [int]$ResLength
    [int]$RttScale
    [string]$HostInfo
    [int]$GlobalStep = 0
    hidden [System.ConsoleColor]$OrigFg
    hidden [System.ConsoleColor]$OrigBg

    ConsoleUI([int]$rttScale) {
        $this.RttScale = $rttScale
        $hostname = [System.Net.Dns]::GetHostName()
        try {
            $ip = ([System.Net.Dns]::GetHostAddresses($hostname) |
                   Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                   Select-Object -First 1).IPAddressToString
            $this.HostInfo = "From: $hostname ($ip)"
        } catch {
            $this.HostInfo = "From: $hostname"
        }
        $this.OrigFg = [System.Console]::ForegroundColor
        $this.OrigBg = [System.Console]::BackgroundColor
        $this.Reinit()
    }

    [void] IncrementStep() { $this.GlobalStep++ }

    [string] GetHostInfo([bool]$withWheel) {
        if (-not $withWheel) { return $this.HostInfo }
        $wheelChars = @('|', '/', '-', '\')
        $wheel = $wheelChars[$this.GlobalStep % 4]
        return "$($this.HostInfo) $wheel"
    }

    [void] Reinit() {
        [System.Console]::Clear()
        [System.Console]::CursorVisible = $false
        $this.Width = [System.Console]::WindowWidth
        $this.Height = [System.Console]::WindowHeight
    }

    [void] WriteAt([int]$row, [int]$col, [string]$text) {
        if ($row -lt 0 -or $row -ge $this.Height) { return }
        if ($col -lt 0 -or $col -ge $this.Width) { return }
        $maxLen = $this.Width - $col
        if ($text.Length -gt $maxLen) { $text = $text.Substring(0, [Math]::Max(0, $maxLen)) }
        if ($text.Length -eq 0) { return }
        [System.Console]::SetCursorPosition($col, $row)
        [System.Console]::Write($text)
    }

    [void] WriteAt([int]$row, [int]$col, [string]$text, [System.ConsoleColor]$fg) {
        $prevFg = [System.Console]::ForegroundColor
        [System.Console]::ForegroundColor = $fg
        $this.WriteAt($row, $col, $text)
        [System.Console]::ForegroundColor = $prevFg
    }

    [void] UpdateLayout([System.Collections.Generic.List[object]]$targets) {
        $this.Width = [System.Console]::WindowWidth
        $this.Height = [System.Console]::WindowHeight
        $this.StartArrow = 0
        $this.LengthArrow = $script:ARROW.Length
        $hlen = "HOSTNAME ".Length
        foreach ($t in $targets) {
            if ($t -is [Separator]) { continue }
            if ($t.Name.Length -gt $hlen) { $hlen = $t.Name.Length }
        }
        if ($hlen -gt $script:MAX_HOSTNAME_LENGTH) { $hlen = $script:MAX_HOSTNAME_LENGTH }
        $this.StartHostname = $this.StartArrow + $this.LengthArrow
        $this.LengthHostname = $hlen
        $alen = "ADDRESS ".Length
        foreach ($t in $targets) {
            if ($t -is [Separator]) { continue }
            if ($t.Address.Length -gt $alen) { $alen = $t.Address.Length }
        }
        if ($alen -gt $script:MAX_ADDRESS_LENGTH) { $alen = $script:MAX_ADDRESS_LENGTH }
        else { $alen += 5 }
        $this.StartAddress = $this.StartHostname + $this.LengthHostname + 1
        $this.LengthAddress = $alen
        $this.RefStart = $this.StartAddress + $this.LengthAddress + 1
        $this.RefLength = " LOSS  RTT  AVG  SNT".Length
        $this.ResStart = $this.RefStart + $this.RefLength + 2
        $this.ResLength = $this.Width - ($this.RefStart + $this.RefLength + 2)
        if ($this.ResLength -lt 10) {
            $rev = 10 - $this.ResLength + $script:ARROW.Length
            $this.RefStart -= $rev
            $this.ResStart -= $rev
            $this.ResLength = 10
        }
        $script:RESULT_STR_LENGTH = $this.ResLength
    }

    [void] PrintTitle([bool]$withWheel) {
        $spacelen = [int](($this.Width - $script:TITLE_PROGNAME.Length) / 2)
        $this.WriteAt(0, $spacelen, $script:TITLE_PROGNAME, [System.ConsoleColor]::White)
        $displayHostInfo = $this.GetHostInfo($withWheel)
        $this.WriteAt(1, $this.StartHostname, $displayHostInfo, [System.ConsoleColor]::White)
        $versionCol = $this.Width - ($script:ARROW.Length + $script:TITLE_VERSION.Length)
        if ($versionCol -gt 0) {
            $this.WriteAt(1, $versionCol, $script:TITLE_VERSION, [System.ConsoleColor]::White)
        }
        $scaleInfo = "RTT Scale $($this.RttScale)ms. Keys: (r)efresh (q)uit"
        $this.WriteAt(2, $script:ARROW.Length, $scaleInfo)
    }

    [void] EraseTitle() {
        $blank = ' ' * $this.Width
        for ($row = 0; $row -lt 3; $row++) { $this.WriteAt($row, 0, $blank) }
    }

    [void] PrintReference() {
        $linenum = $script:TITLE_VERTIC_LENGTH
        $this.WriteAt($linenum, $script:ARROW.Length, "HOSTNAME", [System.ConsoleColor]::White)
        $this.WriteAt($linenum, $this.StartAddress, "ADDRESS", [System.ConsoleColor]::White)
        $this.WriteAt($linenum, $this.RefStart, " LOSS  RTT  AVG  SNT  RESULT", [System.ConsoleColor]::White)
    }

    [void] EraseReference() {
        $linenum = $script:TITLE_VERTIC_LENGTH
        $this.WriteAt($linenum, 0, (' ' * $this.Width))
    }

    [void] PrintSeparator([int]$number) {
        $linenum = $number + $script:TITLE_VERTIC_LENGTH
        $dashLen = $this.Width - $this.StartHostname - $script:ARROW.Length
        if ($dashLen -gt 0) { $this.WriteAt($linenum, $this.StartHostname, ('-' * $dashLen)) }
    }

    [void] PrintPingTarget([PingTarget]$target, [int]$number) {
        $linenum = $number + $script:TITLE_VERTIC_LENGTH
        $lineColor = if ($target.State) { [System.ConsoleColor]::Green } else { [System.ConsoleColor]::Red }
        $nameStr = $target.Name
        if ($nameStr.Length -gt $this.LengthHostname) { $nameStr = $nameStr.Substring(0, $this.LengthHostname) }
        $this.WriteAt($linenum, $this.StartHostname, $nameStr, $lineColor)
        $addrStr = $target.Address
        if ($addrStr.Length -gt $this.LengthAddress) { $addrStr = $addrStr.Substring(0, $this.LengthAddress) }
        $this.WriteAt($linenum, $this.StartAddress, $addrStr, $lineColor)
        $valuesStr = ' {0,3:N0}% {1,4:N0} {2,4:N0} {3,4:N0}  ' -f @(
            [int]$target.LossRate, [int]$target.RTT, [int]$target.Average, $target.Sent
        )
        $this.WriteAt($linenum, $this.RefStart, $valuesStr, $lineColor)
        $maxChars = [Math]::Min($target.ResultHistory.Count, $this.ResLength)
        for ($n = 0; $n -lt $maxChars; $n++) {
            $ch = $target.ResultHistory[$n]
            $col = $this.ResStart + $n
            if ($col -ge $this.Width) { break }
            if ($ch -eq 'X' -or $ch -eq 't' -or $ch -eq 's') {
                $this.WriteAt($linenum, $col, $ch, [System.ConsoleColor]::Red)
            } else {
                $this.WriteAt($linenum, $col, $ch, [System.ConsoleColor]::Green)
            }
        }
        $rearCol = $this.Width - $script:REAR.Length
        if ($rearCol -gt 0) { $this.WriteAt($linenum, $rearCol, $script:REAR) }
    }

    [void] PrintArrow([int]$number) {
        $linenum = $number + $script:TITLE_VERTIC_LENGTH
        $this.WriteAt($linenum, $this.StartArrow, $script:ARROW)
    }

    [void] EraseArrow([int]$number) {
        $linenum = $number + $script:TITLE_VERTIC_LENGTH
        $this.WriteAt($linenum, $this.StartArrow, (' ' * $script:ARROW.Length))
    }

    [void] ErasePingTarget([int]$number) {
        $linenum = $number + $script:TITLE_VERTIC_LENGTH
        $blank = ' ' * [Math]::Max(0, $this.Width - 2)
        $this.WriteAt($linenum, 2, $blank)
    }

    [void] WriteLog([string]$logDir, [PingTarget]$target) {
        if ([string]::IsNullOrEmpty($logDir)) { return }
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $filePath = Join-Path $logDir $target.Name
        $logLine = "{0} {1} {2} {3}" -f @(
            (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'),
            $target.RTT, $target.Average, $target.Sent
        )
        Add-Content -LiteralPath $filePath -Value $logLine -Encoding UTF8
    }

    [void] Cleanup() {
        [System.Console]::ForegroundColor = $this.OrigFg
        [System.Console]::BackgroundColor = $this.OrigBg
        [System.Console]::CursorVisible = $true
        [System.Console]::Clear()
    }
}

# ============================================================
# Main execution — only runs when script is executed directly
# (skipped when dot-sourced for testing)
# ============================================================

if ($MyInvocation.InvocationName -ne '.') {

$targets = Read-DeadmanConfig -Path $ConfigFile -RttScale $Scale

if ($targets.Count -eq 0) {
    Write-Error "No valid targets found in configuration file: $ConfigFile"
    exit 1
}

# Warn if TCP ping targets exist on macOS/Linux (hping3 requires root)
$hasTcpTargets = $targets | Where-Object { $_ -isnot [Separator] -and $_.TcpPort -gt 0 }
if ($hasTcpTargets) {
    if (-not (Test-IsWindows)) {
        $currentUser = & whoami 2>$null
        if ($currentUser -ne 'root') {
            Write-Warning "TCP ping targets detected. hping3 requires root privileges on macOS/Linux. Please run with: sudo pwsh $($MyInvocation.MyCommand.Path) $($MyInvocation.UnboundArguments -join ' ')"
        }
    }
}

# ============================================================
# Ping interval constants (seconds)
# ============================================================

# Interval between individual pings
$PING_INTERVAL = 0.05
# Wait interval after completing one round of all targets
$PING_ALLTARGET_INTERVAL = 1

# ============================================================
# Initialize UI
# ============================================================

$ui = [ConsoleUI]::new($Scale)
$ui.UpdateLayout($targets)
$ui.PrintTitle($false)
$ui.PrintReference()

# Draw initial screen (blank lines and separators)
for ($idx = 0; $idx -lt $targets.Count; $idx++) {
    $number = $idx + 1
    if ($targets[$idx] -is [Separator]) {
        $ui.PrintSeparator($number)
    }
    else {
        $ui.PrintPingTarget($targets[$idx], $number)
    }
}

# ============================================================
# Key handler function — non-blocking key read
# ============================================================

function Invoke-KeyHandler {
    param(
        [ConsoleUI]$UI,
        [System.Collections.Generic.List[object]]$Targets
    )

    # Check for key input (non-blocking)
    while ([System.Console]::KeyAvailable) {
        $keyInfo = [System.Console]::ReadKey($true)
        $key = $keyInfo.KeyChar

        switch ($key) {
            'r' {
                # Reset all target statistics
                for ($i = 0; $i -lt $Targets.Count; $i++) {
                    if ($Targets[$i] -is [Separator]) { continue }
                    $Targets[$i].Refresh()
                    $number = $i + 1
                    $UI.ErasePingTarget($number)
                    $UI.PrintPingTarget($Targets[$i], $number)
                }
            }
            'q' {
                # Quit program
                $UI.Cleanup()
                exit 0
            }
        }
    }
}

# ============================================================
# Sync mode main loop — ping targets one by one
# ============================================================

function Start-SyncMode {
    param(
        [ConsoleUI]$UI,
        [System.Collections.Generic.List[object]]$Targets,
        [string]$LogDirectory,
        [double]$PingInterval,
        [double]$AllTargetInterval
    )

    while ($true) {
        # Detect terminal size changes, redraw if necessary
        $newW = [System.Console]::WindowWidth
        $newH = [System.Console]::WindowHeight
        if ($newW -ne $UI.Width -or $newH -ne $UI.Height) {
            $UI.Reinit()
            $UI.UpdateLayout($Targets)
            $UI.PrintTitle($false)
            $UI.PrintReference()
            for ($i = 0; $i -lt $Targets.Count; $i++) {
                $number = $i + 1
                if ($Targets[$i] -is [Separator]) {
                    $UI.PrintSeparator($number)
                }
                else {
                    $UI.PrintPingTarget($Targets[$i], $number)
                }
            }
        }

        $UI.UpdateLayout($Targets)
        $UI.EraseTitle()
        $UI.PrintTitle($false)
        $UI.EraseReference()
        $UI.PrintReference()

        # Ping each target one by one
        for ($idx = 0; $idx -lt $Targets.Count; $idx++) {
            $number = $idx + 1
            if ($Targets[$idx] -is [Separator]) { continue }

            $target = $Targets[$idx]

            # Show arrow indicating the currently pinged target
            $UI.PrintArrow($number)

            # Execute ping
            $target.Send()

            # Update UI
            $UI.ErasePingTarget($number)
            $UI.PrintPingTarget($target, $number)

            # Write log
            if (-not [string]::IsNullOrEmpty($LogDirectory)) {
                $UI.WriteLog($LogDirectory, $target)
            }

            # Handle key input
            Invoke-KeyHandler -UI $UI -Targets $Targets

            # Brief wait before next target
            Start-Sleep -Milliseconds ([int]($PingInterval * 1000))

            # Clear arrow
            $UI.EraseArrow($number)
        }

        # After one round, show arrow at the last target and wait
        $lastIdx = $Targets.Count
        $UI.PrintArrow($lastIdx)
        Start-Sleep -Milliseconds ([int]($AllTargetInterval * 1000))
        $UI.EraseArrow($lastIdx)
        $UI.ErasePingTarget($lastIdx + 1)

        # Handle key input
        Invoke-KeyHandler -UI $UI -Targets $Targets
    }
}

# ============================================================
# Async mode main loop — ping all targets simultaneously
# ============================================================

function Start-AsyncMode {
    param(
        [ConsoleUI]$UI,
        [System.Collections.Generic.List[object]]$Targets,
        [string]$LogDirectory,
        [double]$AllTargetInterval,
        [bool]$BlinkArrowEnabled
    )

    while ($true) {
        # Detect terminal size changes
        $newW = [System.Console]::WindowWidth
        $newH = [System.Console]::WindowHeight
        if ($newW -ne $UI.Width -or $newH -ne $UI.Height) {
            $UI.Reinit()
            $UI.UpdateLayout($Targets)
            $UI.PrintTitle($true)
            $UI.PrintReference()
            for ($i = 0; $i -lt $Targets.Count; $i++) {
                $number = $i + 1
                if ($Targets[$i] -is [Separator]) {
                    $UI.PrintSeparator($number)
                }
                else {
                    $UI.PrintPingTarget($Targets[$i], $number)
                }
            }
        }

        $UI.UpdateLayout($Targets)
        $UI.IncrementStep()
        $UI.EraseTitle()
        $UI.PrintTitle($true)
        $UI.EraseReference()
        $UI.PrintReference()

        # Blink arrows (optional)
        if ($BlinkArrowEnabled) {
            for ($i = 0; $i -lt $Targets.Count; $i++) {
                if ($Targets[$i] -is [Separator]) { continue }
                $UI.PrintArrow($i + 1)
            }
        }

        # Record start time
        $start = [System.Diagnostics.Stopwatch]::StartNew()

        # Collect non-Separator targets for parallel ping
        $pingTargets = @()
        $pingIndices = @()
        for ($i = 0; $i -lt $Targets.Count; $i++) {
            if ($Targets[$i] -is [Separator]) { continue }
            $pingTargets += $Targets[$i]
            $pingIndices += $i
        }

        # Parallel ping using Start-ThreadJob (PS 7+) or Start-Job (PS 5.1)
        $jobs = @()
        $usePsVer7 = $PSVersionTable.PSVersion.Major -ge 7
        $isWinForJobs = Test-IsWindows

        # Define ScriptBlocks for job-based parallel ping
        $tcpPingBlock = {
            param($addr, $port, $isWin, $psVer)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                if ($isWin) {
                    $tnc = Test-NetConnection -ComputerName $addr -Port $port -WarningAction SilentlyContinue -ErrorAction Stop
                    $sw.Stop()
                    if ($tnc.TcpTestSucceeded) {
                        return @{ Success = $true; RTT = [double]$sw.Elapsed.TotalMilliseconds; TTL = -1 }
                    }
                    return @{ Success = $false; RTT = 0; TTL = 0 }
                }
                else {
                    $hpingOutput = & hping3 -S -p $port -c 1 $addr 2>&1
                    $sw.Stop()
                    $outputStr = $hpingOutput -join "`n"
                    if ($outputStr -match 'flags=SA' -or $outputStr -match 'flags=S\.A') {
                        $rtt = [double]$sw.Elapsed.TotalMilliseconds
                        $ttl = -1
                        if ($outputStr -match 'rtt=([\d.]+)\s*ms') { $rtt = [double]$Matches[1] }
                        if ($outputStr -match 'ttl=(\d+)') { $ttl = [int]$Matches[1] }
                        return @{ Success = $true; RTT = $rtt; TTL = $ttl }
                    }
                    return @{ Success = $false; RTT = 0; TTL = 0 }
                }
            }
            catch {
                $sw.Stop()
                return @{ Success = $false; RTT = 0; TTL = 0 }
            }
        }

        $icmpPingBlock = {
            param($addr, $psVer)
            try {
                if ($psVer -ge 7) {
                    $reply = Test-Connection -TargetName $addr -Count 1 -TimeoutSeconds 1 -Ping -ErrorAction Stop
                    if ($reply.Status -eq 'Success') {
                        $ttl = -1
                        if ($null -ne $reply.Reply -and $null -ne $reply.Reply.Options) {
                            $ttl = [int]$reply.Reply.Options.Ttl
                        }
                        return @{ Success = $true; RTT = [double]$reply.Latency; TTL = $ttl }
                    }
                }
                else {
                    $reply = Test-Connection -ComputerName $addr -Count 1 -ErrorAction Stop
                    if ($reply.StatusCode -eq 0) {
                        $ttl = -1
                        if ($null -ne $reply.ResponseTimeToLive) { $ttl = [int]$reply.ResponseTimeToLive }
                        return @{ Success = $true; RTT = [double]$reply.ResponseTime; TTL = $ttl }
                    }
                }
                return @{ Success = $false; RTT = 0; TTL = 0 }
            }
            catch {
                return @{ Success = $false; RTT = 0; TTL = 0 }
            }
        }

        foreach ($t in $pingTargets) {
            if ($t.TcpPort -gt 0) {
                if ($usePsVer7) {
                    $job = Start-ThreadJob -ScriptBlock $tcpPingBlock -ArgumentList $t.Address, $t.TcpPort, $isWinForJobs, $PSVersionTable.PSVersion.Major
                } else {
                    $job = Start-Job -ScriptBlock $tcpPingBlock -ArgumentList $t.Address, $t.TcpPort, $isWinForJobs, $PSVersionTable.PSVersion.Major
                }
            }
            else {
                if ($usePsVer7) {
                    $job = Start-ThreadJob -ScriptBlock $icmpPingBlock -ArgumentList $t.Address, $PSVersionTable.PSVersion.Major
                } else {
                    $job = Start-Job -ScriptBlock $icmpPingBlock -ArgumentList $t.Address, $PSVersionTable.PSVersion.Major
                }
            }
            $jobs += @{ Job = $job; Target = $t }
        }

        # Wait for all jobs to complete
        $allJobs = $jobs | ForEach-Object { $_.Job }
        $null = Wait-Job -Job $allJobs -Timeout 5

        # Collect results and update each target
        foreach ($entry in $jobs) {
            $result = Receive-Job -Job $entry.Job -ErrorAction SilentlyContinue
            Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue

            $t = $entry.Target
            $t.Sent++

            $pingResult = [PingResult]::new()
            if ($null -ne $result -and $result.Success) {
                $pingResult.Success = $true
                $pingResult.ErrorCode = [PingErrorCode]::Success
                $pingResult.RTT = $result.RTT
                $pingResult.TTL = $result.TTL
            }
            $t.ConsumeResult($pingResult)
        }

        $elapsed = $start.Elapsed.TotalSeconds

        # Update UI display for all targets
        for ($i = 0; $i -lt $Targets.Count; $i++) {
            $number = $i + 1
            if ($Targets[$i] -is [Separator]) { continue }

            $UI.ErasePingTarget($number)
            $UI.PrintPingTarget($Targets[$i], $number)

            if ($BlinkArrowEnabled) {
                $UI.EraseArrow($number)
            }

            # Write log
            if (-not [string]::IsNullOrEmpty($LogDirectory)) {
                $UI.WriteLog($LogDirectory, $Targets[$i])
            }
        }

        # Update spinner animation
        $UI.IncrementStep()
        $UI.EraseTitle()
        $UI.PrintTitle($true)

        # Wait at least AllTargetInterval seconds
        if ($elapsed -lt $AllTargetInterval) {
            Start-Sleep -Milliseconds ([int](($AllTargetInterval - $elapsed) * 1000))
        }

        Start-Sleep -Milliseconds ([int]($AllTargetInterval * 1000))

        # Handle key input
        Invoke-KeyHandler -UI $UI -Targets $Targets
    }
}

# ============================================================
# Main program startup
# ============================================================

try {
    if ($AsyncMode) {
        Start-AsyncMode -UI $ui -Targets $targets `
                        -LogDirectory $LogDir `
                        -AllTargetInterval $PING_ALLTARGET_INTERVAL `
                        -BlinkArrowEnabled $BlinkArrow.IsPresent
    }
    else {
        Start-SyncMode -UI $ui -Targets $targets `
                       -LogDirectory $LogDir `
                       -PingInterval $PING_INTERVAL `
                       -AllTargetInterval $PING_ALLTARGET_INTERVAL
    }
}
catch {
    # Catch Ctrl+C or other interrupts
    if ($ui) { $ui.Cleanup() }
    throw
}
finally {
    # Ensure terminal settings are restored
    if ($ui) { $ui.Cleanup() }
}

} # end main execution guard
