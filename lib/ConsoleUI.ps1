# -*- coding: utf-8 -*-
# ConsoleUI.ps1 — Terminal UI rendering class
# Ported from https://github.com/upa/deadman (MIT License)
# Uses [System.Console] API, fully supports PowerShell 7+

# ============================================================
# Constants
# ============================================================

# Program name and version
$script:TITLE_PROGNAME = "Dead Man"
$script:TITLE_VERSION = "[ver 1.0.0-ps]"
# Number of vertical lines occupied by the title area
$script:TITLE_VERTIC_LENGTH = 4

# Arrow indicator
$script:ARROW = " > "
$script:REAR  = "   "

# Maximum column width limits
$script:MAX_HOSTNAME_LENGTH = 20
$script:MAX_ADDRESS_LENGTH = 40

# Default result history display length
$script:RESULT_STR_LENGTH = 10

# ============================================================
# ConsoleUI class — encapsulates terminal rendering logic
# ============================================================
class ConsoleUI {
    # Terminal dimensions
    [int]$Width
    [int]$Height

    # Column start positions and lengths
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

    # RTT bar chart scale (milliseconds)
    [int]$RttScale

    # Host information string
    [string]$HostInfo

    # Global step counter (for spinner animation)
    [int]$GlobalStep = 0

    # Original foreground and background colors (for restoration)
    hidden [System.ConsoleColor]$OrigFg
    hidden [System.ConsoleColor]$OrigBg

    # Constructor — initialize host info and terminal dimensions
    ConsoleUI([int]$rttScale) {
        $this.RttScale = $rttScale

        # Get hostname and IP, build host info string
        $hostname = [System.Net.Dns]::GetHostName()
        try {
            $ip = ([System.Net.Dns]::GetHostAddresses($hostname) |
                   Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                   Select-Object -First 1).IPAddressToString
            $this.HostInfo = "From: $hostname ($ip)"
        }
        catch {
            $this.HostInfo = "From: $hostname"
        }

        # Save original terminal colors
        $this.OrigFg = [System.Console]::ForegroundColor
        $this.OrigBg = [System.Console]::BackgroundColor

        # Initialize terminal
        $this.Reinit()
    }

    # Increment global step counter (for spinner animation)
    [void] IncrementStep() {
        $this.GlobalStep++
    }

    # Get host info string, optionally with spinner animation
    [string] GetHostInfo([bool]$withWheel) {
        if (-not $withWheel) {
            return $this.HostInfo
        }
        # Spinner animation characters: | / - \
        $wheelChars = @('|', '/', '-', '\')
        $wheel = $wheelChars[$this.GlobalStep % 4]
        return "$($this.HostInfo) $wheel"
    }

    # Reinitialize terminal screen (clear and reset cursor)
    [void] Reinit() {
        [System.Console]::Clear()
        [System.Console]::CursorVisible = $false
        $this.Width = [System.Console]::WindowWidth
        $this.Height = [System.Console]::WindowHeight
    }

    # Safely write a string at specified coordinates, preventing overflow beyond terminal bounds
    [void] WriteAt([int]$row, [int]$col, [string]$text) {
        if ($row -lt 0 -or $row -ge $this.Height) { return }
        if ($col -lt 0 -or $col -ge $this.Width) { return }

        # Truncate text exceeding screen width
        $maxLen = $this.Width - $col
        if ($text.Length -gt $maxLen) {
            $text = $text.Substring(0, [Math]::Max(0, $maxLen))
        }
        if ($text.Length -eq 0) { return }

        [System.Console]::SetCursorPosition($col, $row)
        [System.Console]::Write($text)
    }

    # Safely write a colored string at specified coordinates
    [void] WriteAt([int]$row, [int]$col, [string]$text, [System.ConsoleColor]$fg) {
        $prevFg = [System.Console]::ForegroundColor
        [System.Console]::ForegroundColor = $fg
        $this.WriteAt($row, $col, $text)
        [System.Console]::ForegroundColor = $prevFg
    }

    # Calculate column start positions and widths based on the target list
    # Aligned with the original CursesCtrl.update_info() logic
    [void] UpdateLayout([System.Collections.Generic.List[object]]$targets) {
        $this.Width = [System.Console]::WindowWidth
        $this.Height = [System.Console]::WindowHeight

        # Arrow column
        $this.StartArrow = 0
        $this.LengthArrow = $script:ARROW.Length

        # Hostname column — use the longest name among all targets
        $hlen = "HOSTNAME ".Length
        foreach ($t in $targets) {
            if ($t -is [Separator]) { continue }
            if ($t.Name.Length -gt $hlen) { $hlen = $t.Name.Length }
        }
        if ($hlen -gt $script:MAX_HOSTNAME_LENGTH) { $hlen = $script:MAX_HOSTNAME_LENGTH }
        $this.StartHostname = $this.StartArrow + $this.LengthArrow
        $this.LengthHostname = $hlen

        # Address column — use the longest address among all targets
        $alen = "ADDRESS ".Length
        foreach ($t in $targets) {
            if ($t -is [Separator]) { continue }
            if ($t.Address.Length -gt $alen) { $alen = $t.Address.Length }
        }
        if ($alen -gt $script:MAX_ADDRESS_LENGTH) {
            $alen = $script:MAX_ADDRESS_LENGTH
        }
        else {
            $alen += 5
        }
        $this.StartAddress = $this.StartHostname + $this.LengthHostname + 1
        $this.LengthAddress = $alen

        # Reference values column (LOSS RTT AVG SNT)
        $this.RefStart = $this.StartAddress + $this.LengthAddress + 1
        $this.RefLength = " LOSS  RTT  AVG  SNT".Length

        # Result bar chart column
        $this.ResStart = $this.RefStart + $this.RefLength + 2
        $this.ResLength = $this.Width - ($this.RefStart + $this.RefLength + 2)

        # If result column is too narrow, compress leftward to ensure at least 10 characters
        if ($this.ResLength -lt 10) {
            $rev = 10 - $this.ResLength + $script:ARROW.Length
            $this.RefStart -= $rev
            $this.ResStart -= $rev
            $this.ResLength = 10
        }

        # Update global result string length
        $script:RESULT_STR_LENGTH = $this.ResLength
    }

    # Draw title row (program name, host info, version, RTT scale description)
    [void] PrintTitle([bool]$withWheel) {
        # Center program name on the first row
        $spacelen = [int](($this.Width - $script:TITLE_PROGNAME.Length) / 2)
        $this.WriteAt(0, $spacelen, $script:TITLE_PROGNAME, [System.ConsoleColor]::White)

        # Host info on the second row (left side)
        $displayHostInfo = $this.GetHostInfo($withWheel)
        $this.WriteAt(1, $this.StartHostname, $displayHostInfo, [System.ConsoleColor]::White)

        # Version on the second row (right side)
        $versionCol = $this.Width - ($script:ARROW.Length + $script:TITLE_VERSION.Length)
        if ($versionCol -gt 0) {
            $this.WriteAt(1, $versionCol, $script:TITLE_VERSION, [System.ConsoleColor]::White)
        }

        # RTT scale description on the third row
        $scaleInfo = "RTT Scale $($this.RttScale)ms. Keys: (r)efresh (q)uit"
        $this.WriteAt(2, $script:ARROW.Length, $scaleInfo)
    }

    # Clear title area
    [void] EraseTitle() {
        $blank = ' ' * $this.Width
        for ($row = 0; $row -lt 3; $row++) {
            $this.WriteAt($row, 0, $blank)
        }
    }

    # Draw header reference row (HOSTNAME, ADDRESS, LOSS, RTT, AVG, SNT, RESULT)
    [void] PrintReference() {
        $linenum = $script:TITLE_VERTIC_LENGTH
        $this.WriteAt($linenum, $script:ARROW.Length, "HOSTNAME", [System.ConsoleColor]::White)
        $this.WriteAt($linenum, $this.StartAddress, "ADDRESS", [System.ConsoleColor]::White)

        $valuesStr = " LOSS  RTT  AVG  SNT  RESULT"
        $this.WriteAt($linenum, $this.RefStart, $valuesStr, [System.ConsoleColor]::White)
    }

    # Clear header reference row
    [void] EraseReference() {
        $linenum = $script:TITLE_VERTIC_LENGTH
        $this.WriteAt($linenum, 0, (' ' * $this.Width))
    }

    # Draw separator line
    [void] PrintSeparator([int]$number) {
        $linenum = $number + $script:TITLE_VERTIC_LENGTH
        $dashLen = $this.Width - $this.StartHostname - $script:ARROW.Length
        if ($dashLen -gt 0) {
            $this.WriteAt($linenum, $this.StartHostname, ('-' * $dashLen))
        }
    }

    # Draw a single ping target result row
    [void] PrintPingTarget([object]$target, [int]$number) {
        $linenum = $number + $script:TITLE_VERTIC_LENGTH

        # Choose color based on target state: alive=green, no response=red
        $lineColor = if ($target.State) {
            [System.ConsoleColor]::Green
        }
        else {
            [System.ConsoleColor]::Red
        }

        # Hostname
        $nameStr = $target.Name
        if ($nameStr.Length -gt $this.LengthHostname) {
            $nameStr = $nameStr.Substring(0, $this.LengthHostname)
        }
        $this.WriteAt($linenum, $this.StartHostname, $nameStr, $lineColor)

        # Address
        $addrStr = $target.Address
        if ($addrStr.Length -gt $this.LengthAddress) {
            $addrStr = $addrStr.Substring(0, $this.LengthAddress)
        }
        $this.WriteAt($linenum, $this.StartAddress, $addrStr, $lineColor)

        # Statistics: LOSS% RTT AVG SNT
        $valuesStr = ' {0,3:N0}% {1,4:N0} {2,4:N0} {3,4:N0}  ' -f @(
            [int]$target.LossRate,
            [int]$target.RTT,
            [int]$target.Average,
            $target.Sent
        )
        $this.WriteAt($linenum, $this.RefStart, $valuesStr, $lineColor)

        # Draw result bar chart
        $maxChars = [Math]::Min($target.ResultHistory.Count, $this.ResLength)
        for ($n = 0; $n -lt $maxChars; $n++) {
            $ch = $target.ResultHistory[$n]
            $col = $this.ResStart + $n
            if ($col -ge $this.Width) { break }

            if ($ch -eq 'X' -or $ch -eq 't' -or $ch -eq 's') {
                $this.WriteAt($linenum, $col, $ch, [System.ConsoleColor]::Red)
            }
            else {
                $this.WriteAt($linenum, $col, $ch, [System.ConsoleColor]::Green)
            }
        }

        # Clear trailing characters at end of line
        $rearCol = $this.Width - $script:REAR.Length
        if ($rearCol -gt 0) {
            $this.WriteAt($linenum, $rearCol, $script:REAR)
        }
    }

    # Draw arrow indicator (marks the currently pinged target)
    [void] PrintArrow([int]$number) {
        $linenum = $number + $script:TITLE_VERTIC_LENGTH
        $this.WriteAt($linenum, $this.StartArrow, $script:ARROW)
    }

    # Clear arrow indicator
    [void] EraseArrow([int]$number) {
        $linenum = $number + $script:TITLE_VERTIC_LENGTH
        $this.WriteAt($linenum, $this.StartArrow, (' ' * $script:ARROW.Length))
    }

    # Clear the content of a specified ping target row
    [void] ErasePingTarget([int]$number) {
        $linenum = $number + $script:TITLE_VERTIC_LENGTH
        $blank = ' ' * [Math]::Max(0, $this.Width - 2)
        $this.WriteAt($linenum, 2, $blank)
    }

    # Handle logging — append ping results to log file
    [void] WriteLog([string]$logDir, [object]$target) {
        if ([string]::IsNullOrEmpty($logDir)) { return }

        # Ensure log directory exists
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        # Build log file path (use target name as filename)
        $filePath = Join-Path $logDir $target.Name
        # Format: timestamp RTT average sent_count
        $logLine = "{0} {1} {2} {3}" -f @(
            (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'),
            $target.RTT,
            $target.Average,
            $target.Sent
        )
        # Append to file (UTF-8 encoding)
        Add-Content -LiteralPath $filePath -Value $logLine -Encoding UTF8
    }

    # Restore terminal settings (called on program exit)
    [void] Cleanup() {
        [System.Console]::ForegroundColor = $this.OrigFg
        [System.Console]::BackgroundColor = $this.OrigBg
        [System.Console]::CursorVisible = $true
        [System.Console]::Clear()
    }
}
