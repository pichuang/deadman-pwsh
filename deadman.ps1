#!/usr/bin/env pwsh
# -*- coding: utf-8 -*-
# deadman.ps1 — Main entry point
# Ported from https://github.com/upa/deadman (MIT License)
#
# deadman is a host monitoring tool using ICMP Ping.
# This version is fully implemented in PowerShell 7+ using the System.Console API for terminal UI.
#
# Usage:
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
    [string]$LogDir
)

# ============================================================
# Load modules
# ============================================================

# Get script directory
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# Default ConfigFile to deadman.conf in script directory
if ([string]::IsNullOrEmpty($ConfigFile)) {
    $ConfigFile = Join-Path $scriptRoot 'deadman.conf'
}

# Load libraries in order (class definitions must be loaded first)
. (Join-Path $scriptRoot 'lib' 'PingTarget.ps1')
. (Join-Path $scriptRoot 'lib' 'ConfigParser.ps1')
. (Join-Path $scriptRoot 'lib' 'ConsoleUI.ps1')

# ============================================================
# Validate environment
# ============================================================

# Ensure PowerShell version >= 7
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "deadman requires PowerShell 7 or later. Current version: $($PSVersionTable.PSVersion)"
    exit 1
}

# ============================================================
# Parse configuration file
# ============================================================

$targets = Read-DeadmanConfig -Path $ConfigFile -RttScale $Scale

if ($targets.Count -eq 0) {
    Write-Error "No valid targets found in configuration file: $ConfigFile"
    exit 1
}

# Warn if TCP ping targets exist on macOS/Linux (hping3 requires root)
$hasTcpTargets = $targets | Where-Object { $_ -isnot [Separator] -and $_.TcpPort -gt 0 }
if ($hasTcpTargets) {
    $isWin = $global:IsWindows -or ($null -eq $global:IsWindows -and [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows))
    if (-not $isWin) {
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
        [object]$UI,
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
        [object]$UI,
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
        [object]$UI,
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

        # Use PowerShell 7 parallel ping via ThreadJob
        $jobs = @()
        foreach ($t in $pingTargets) {
            if ($t.TcpPort -gt 0) {
                # TCP ping mode
                $job = Start-ThreadJob -ScriptBlock {
                    param($addr, $port, $isWin)
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
                } -ArgumentList $t.Address, $t.TcpPort, ($global:IsWindows -or ($null -eq $global:IsWindows -and [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)))
            }
            else {
                # ICMP ping mode
                $job = Start-ThreadJob -ScriptBlock {
                    param($addr)
                    try {
                        $reply = Test-Connection -TargetName $addr -Count 1 -TimeoutSeconds 1 -Ping -ErrorAction Stop
                        if ($reply.Status -eq 'Success') {
                            $ttl = -1
                            if ($null -ne $reply.Reply -and $null -ne $reply.Reply.Options) {
                                $ttl = [int]$reply.Reply.Options.Ttl
                            }
                            return @{ Success = $true; RTT = [double]$reply.Latency; TTL = $ttl }
                        }
                        return @{ Success = $false; RTT = 0; TTL = 0 }
                    }
                    catch {
                        return @{ Success = $false; RTT = 0; TTL = 0 }
                    }
                } -ArgumentList $t.Address
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
