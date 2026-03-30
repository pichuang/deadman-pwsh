# -*- coding: utf-8 -*-
# ConfigParser.ps1 — Configuration file parsing function
# Ported from https://github.com/upa/deadman (MIT License)
# Fully supports PowerShell 7+

# ============================================================
# Read-DeadmanConfig — Parse deadman configuration file
# ============================================================
# Configuration file format (compatible with original):
#   name    address    [key=value ...]
#   ---                              (separator)
#   # this is a comment               (ignored)
#
# Supported options:
#   source=interface   — specify source interface
#   via=tcp            — use TCP ping instead of ICMP
#   port=number        — TCP port for TCP ping (requires via=tcp)
#   os=operating_system — used by original, ignored in this version
#   relay=host         — used by original, ignored (SSH relay)
#   other key=value    — parsed but ignored, no error
# ============================================================

function Read-DeadmanConfig {
    [CmdletBinding()]
    param(
        # Configuration file path
        [Parameter(Mandatory)]
        [string]$Path,

        # RTT bar chart scale (milliseconds), passed to PingTarget objects
        [int]$RttScale = 10
    )

    # Verify configuration file exists
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }

    # Read all lines
    $lines = Get-Content -LiteralPath $Path -Encoding UTF8

    # Array to store parsed results
    $targets = [System.Collections.Generic.List[object]]::new()

    foreach ($rawLine in $lines) {
        # Replace tabs with spaces
        $line = $rawLine -replace '\t', ' '
        # Collapse multiple spaces
        $line = $line -replace '\s+', ' '
        # Remove comments (lines starting with #)
        $line = $line -replace '^\s*#.*', ''
        # Remove inline comments (starting with ; #)
        $line = $line -replace ';\s*#.*', ''
        # Trim leading and trailing whitespace
        $line = $line.Trim()

        # Skip empty lines
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        # Split fields by whitespace
        $parts = $line -split '\s+'
        $name = $parts[0]

        # Check if line is a separator (composed of hyphens, e.g. --- or -----)
        if ($name -match '^-+$') {
            $targets.Add([Separator]::new())
            continue
        }

        # Parse address (second field)
        if ($parts.Count -lt 2) {
            Write-Warning "Invalid config line format, missing address field: $rawLine"
            continue
        }
        $address = $parts[1]

        # Parse options (key=value pairs from third field onward)
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
                    # Other options (os, relay, community, user, key, etc.)
                    # Parsed but not used, maintaining compatibility with original config format
                    default { <# Ignore unsupported options #> }
                }
            }
        }

        # Create PingTarget object
        if ($source) {
            $target = [PingTarget]::new($name, $address, $source)
        }
        else {
            $target = [PingTarget]::new($name, $address)
        }

        # Set RTT scale
        $target.RttScale = $RttScale

        # Set TCP port if via=tcp is specified
        if ($via -eq 'tcp' -and $port -gt 0) {
            $target.TcpPort = $port
        }

        $targets.Add($target)
    }

    return , $targets
}
