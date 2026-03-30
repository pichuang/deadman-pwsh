# -*- coding: utf-8 -*-
# PingTarget.ps1 — Ping result and target class definitions
# Ported from https://github.com/upa/deadman (MIT License)
# Fully supports PowerShell 7+

# ============================================================
# Constants
# ============================================================

# Ping error code enumeration
enum PingErrorCode {
    # Ping succeeded
    Success = 0
    # Ping failed (timeout or no response)
    Failed = -1
}

# ============================================================
# PingResult class — encapsulates a single ping result
# ============================================================
class PingResult {
    # Whether the ping succeeded
    [bool]$Success = $false
    # Error code
    [PingErrorCode]$ErrorCode = [PingErrorCode]::Failed
    # Round-trip time (milliseconds)
    [double]$RTT = 0.0
    # Time to live
    [int]$TTL = 0

    # Default constructor
    PingResult() {}

    # Parameterized constructor
    PingResult([bool]$success, [PingErrorCode]$errorCode, [double]$rtt, [int]$ttl) {
        $this.Success = $success
        $this.ErrorCode = $errorCode
        $this.RTT = $rtt
        $this.TTL = $ttl
    }
}

# ============================================================
# Separator class — separator marker in configuration file
# ============================================================
class Separator {
    # Separator requires no properties, serves only as a marker object
}

# ============================================================
# PingTarget class — encapsulates a single ping monitoring target
# ============================================================
class PingTarget {
    # Target name (for display)
    [string]$Name
    # Target address (IP or hostname)
    [string]$Address
    # Source interface (optional)
    [string]$Source
    # TCP port for TCP ping mode (0 = ICMP mode)
    [int]$TcpPort = 0
    # Current state (true = alive, false = no response)
    [bool]$State = $false
    # Cumulative loss count
    [int]$Loss = 0
    # Loss rate (percentage)
    [double]$LossRate = 0.0
    # Latest RTT (milliseconds)
    [double]$RTT = 0
    # RTT sum (for calculating average)
    [double]$Total = 0
    # Average RTT (milliseconds)
    [double]$Average = 0
    # Number of pings sent
    [int]$Sent = 0
    # Latest TTL
    [int]$TTL = 0
    # Result history (newest first, for drawing bar chart)
    [System.Collections.Generic.List[string]]$ResultHistory
    # RTT scale (milliseconds), used for bar chart character selection
    [int]$RttScale = 10

    # Constructor — initialize target name and address
    PingTarget([string]$name, [string]$address) {
        $this.Name = $name
        $this.Address = $address
        $this.Source = $null
        $this.ResultHistory = [System.Collections.Generic.List[string]]::new()
    }

    # Constructor — initialize target name, address, and source interface
    PingTarget([string]$name, [string]$address, [string]$source) {
        $this.Name = $name
        $this.Address = $address
        $this.Source = $source
        $this.ResultHistory = [System.Collections.Generic.List[string]]::new()
    }

    # Execute a single ping and update statistics
    # Uses ICMP (Test-Connection) or TCP ping based on TcpPort setting
    [void] Send() {
        if ($this.TcpPort -gt 0) {
            $this.SendTcp()
            return
        }

        $result = [PingResult]::new()

        try {
            # Build Test-Connection parameters
            $params = @{
                TargetName    = $this.Address
                Count         = 1
                TimeoutSeconds = 1
                Ping          = $true
                ErrorAction   = 'Stop'
            }

            $reply = Test-Connection @params

            if ($reply.Status -eq 'Success') {
                $result.Success = $true
                $result.ErrorCode = [PingErrorCode]::Success
                # Latency property is round-trip time (milliseconds)
                $result.RTT = [double]$reply.Latency
                $result.TTL = if ($null -ne $reply.Reply -and $null -ne $reply.Reply.Options) {
                    [int]$reply.Reply.Options.Ttl
                } else {
                    -1
                }
            }
        }
        catch {
            # Ping failed (timeout, host unreachable, etc.)
            $result.Success = $false
            $result.ErrorCode = [PingErrorCode]::Failed
        }

        $this.Sent++
        $this.ConsumeResult($result)
    }

    # Execute a TCP ping (SYN check) and update statistics
    # Windows: Test-NetConnection, macOS/Linux: hping3
    [void] SendTcp() {
        $result = [PingResult]::new()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            if ($global:IsWindows -or ($null -eq $global:IsWindows -and [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows))) {
                # Windows: use Test-NetConnection
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
                # macOS/Linux: use hping3
                $hpingOutput = & hping3 -S -p $this.TcpPort -c 1 $this.Address 2>&1
                $sw.Stop()
                $outputStr = $hpingOutput -join "`n"

                # Check for SYN-ACK response (flags=SA)
                if ($outputStr -match 'flags=SA' -or $outputStr -match 'flags=S\.A') {
                    $result.Success = $true
                    $result.ErrorCode = [PingErrorCode]::Success
                    # Parse RTT from hping3 output (e.g. "rtt=2.5 ms")
                    if ($outputStr -match 'rtt=([\d.]+)\s*ms') {
                        $result.RTT = [double]$Matches[1]
                    }
                    else {
                        $result.RTT = [double]$sw.Elapsed.TotalMilliseconds
                    }
                    $result.TTL = -1
                    # Parse TTL if available
                    if ($outputStr -match 'ttl=(\d+)') {
                        $result.TTL = [int]$Matches[1]
                    }
                }
            }
        }
        catch {
            # TCP ping failed
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
            # Ping succeeded — update RTT statistics
            $this.State = $true
            $this.RTT = $res.RTT
            $this.Total += $res.RTT
            $this.Average = $this.Total / $this.Sent
            $this.TTL = $res.TTL
        }
        else {
            # Ping failed — increment loss count
            $this.Loss++
            $this.State = $false
        }

        # Calculate loss rate
        $this.LossRate = [double]$this.Loss / [double]$this.Sent * 100.0

        # Insert result character at the front of history
        $this.ResultHistory.Insert(0, $this.GetResultChar($res))
    }

    # Return the corresponding Unicode bar chart character based on ping result
    # Higher RTT = taller bar; failure returns 'X'
    [string] GetResultChar([PingResult]$res) {
        if ($res.ErrorCode -eq [PingErrorCode]::Failed) {
            return 'X'
        }

        $scale = $this.RttScale
        if ($res.RTT -lt ($scale * 1)) { return [char]0x2581 }  # ▁
        if ($res.RTT -lt ($scale * 2)) { return [char]0x2582 }  # ▂
        if ($res.RTT -lt ($scale * 3)) { return [char]0x2583 }  # ▃
        if ($res.RTT -lt ($scale * 4)) { return [char]0x2584 }  # ▄
        if ($res.RTT -lt ($scale * 5)) { return [char]0x2585 }  # ▅
        if ($res.RTT -lt ($scale * 6)) { return [char]0x2586 }  # ▆
        if ($res.RTT -lt ($scale * 7)) { return [char]0x2587 }  # ▇

        return [char]0x2588  # █ (RTT >= scale * 7)
    }

    # Reset all statistics (preserve name and address)
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

    # String representation (for comparison and debugging)
    [string] ToString() {
        $parts = @($this.Name, $this.Address)
        if ($this.Source) { $parts += $this.Source }
        if ($this.TcpPort -gt 0) { $parts += "tcp:$($this.TcpPort)" }
        return ($parts -join ':')
    }
}
