# Dead Man (PowerShell Edition)

> Ported from [upa/deadman](https://github.com/upa/deadman) (MIT License)

deadman is a host monitoring tool using ICMP Ping and TCP Ping. It checks whether hosts are alive via ICMP Echo or TCP SYN and displays results in real-time through a terminal UI.

This version is fully implemented in **PowerShell 7+**, using the `System.Console` API for terminal rendering. Works on Windows, macOS, and Linux.

## Features

- 🔍 Real-time ping monitoring of multiple hosts
- 📊 Unicode bar chart display for RTT history (▁▂▃▄▅▆▇█)
- 🎨 Color-coded: green = alive, red = no response
- ⚡ Supports both sync (sequential) and async (parallel) ping modes
- � TCP ping support: `Test-NetConnection` on Windows, `hping3` on macOS/Linux
- �📁 Configuration file format fully compatible with the original
- 📝 Optional logging functionality
- 🔄 Key interaction: `r` to reset statistics, `q` to quit
- 📐 Automatic terminal size detection and redraw

## Prerequisites

- **PowerShell 7.0** or later
  - Windows: `winget install Microsoft.PowerShell`
  - macOS: `brew install powershell`
  - Linux: See [official installation guide](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux)
- Async mode requires the `ThreadJob` module (built-in with PowerShell 7)
- TCP ping on macOS/Linux requires [hping3](https://github.com/antirez/hping) (`brew install hping` / `apt install hping3`)
- TCP ping on macOS/Linux requires `sudo` (root privileges) to send raw packets: `sudo pwsh ./deadman.ps1 ...`
- TCP ping on Windows uses the built-in `Test-NetConnection` cmdlet

## Quick Start

```powershell
# Clone the project
git clone https://github.com/pichuang/deadman-pwsh.git
cd deadman-pwsh

# Start with default config file (sync mode)
./deadman.ps1 -ConfigFile deadman.conf

# Async mode (ping all targets simultaneously)
./deadman.ps1 -ConfigFile deadman.conf -AsyncMode

# Custom RTT scale at 20ms with logging enabled
./deadman.ps1 -ConfigFile deadman.conf -Scale 20 -LogDir ./logs
```

## Parameters

| Parameter | Alias | Type | Description |
|-----------|-------|------|-------------|
| `-ConfigFile` | | string | Configuration file path (required) |
| `-Scale` | `-s` | int | RTT bar chart scale, default 10 (milliseconds) |
| `-AsyncMode` | `-a` | switch | Enable async ping mode |
| `-BlinkArrow` | `-b` | switch | Blink arrow indicator in async mode |
| `-LogDir` | `-l` | string | Log directory path |

## Configuration File Format

The configuration file format is fully compatible with the [original deadman](https://github.com/upa/deadman):

```conf
#
# deadman configuration file
# Format: name    address    [options]
#

# === Basic targets ===
googleDNS       8.8.8.8
quad9           9.9.9.9

# === Separator (use --- or more hyphens) ===
---

# === IPv6 targets ===
googleDNS-v6    2001:4860:4860::8888

# === Specify source interface ===
local-eth0      192.168.1.1     source=eth0

# === TCP ping targets ===
web-https       10.0.0.1        via=tcp port=443
web-http        10.0.0.2        via=tcp port=80
```

### Supported Options

| Option | Description |
|--------|-------------|
| `source=interface` | Specify the source network interface for ping |
| `via=tcp` | Use TCP SYN ping instead of ICMP |
| `port=number` | TCP port number (requires `via=tcp`) |

> **Note**: The original advanced options such as SSH relay (`relay=`), SNMP (`via=snmp`), netns, and VRF are parsed but not used in this version. They will not produce errors.

## Key Bindings

| Key | Action |
|-----|--------|
| `r` | Reset all target statistics |
| `q` | Quit the program |

## Running Tests

Uses [Pester 5](https://pester.dev/) test framework:

```powershell
# Install Pester (if not already installed)
Install-Module -Name Pester -MinimumVersion 5.0 -Force -Scope CurrentUser

# Run all tests
Invoke-Pester ./tests/ -Output Detailed

# Run a specific test file
Invoke-Pester ./tests/ConfigParser.Tests.ps1 -Output Detailed

# Exclude tests requiring network access
Invoke-Pester ./tests/ -Output Detailed -ExcludeTag 'Network'
```

## Project Structure

```
deadman-pwsh/
├── deadman.ps1           # Main entry point (parameter parsing, main loop)
├── deadman.conf          # Example configuration file
├── lib/
│   ├── PingTarget.ps1    # PingTarget / PingResult class definitions
│   ├── ConfigParser.ps1  # Configuration file parsing function
│   └── ConsoleUI.ps1     # Terminal UI rendering class
├── tests/
│   ├── PingTarget.Tests.ps1    # PingTarget unit tests
│   ├── ConfigParser.Tests.ps1  # ConfigParser unit tests
│   ├── ConsoleUI.Tests.ps1     # ConsoleUI unit tests
│   └── Integration.Tests.ps1   # Integration tests
├── README.md             # English documentation
└── readme.zh-tw.md       # Chinese (Traditional) documentation
```

## Differences from Original

| Feature | Original (Python) | This Version (PowerShell) |
|---------|-------------------|---------------------------|
| Language | Python 3 + curses | PowerShell 7+ |
| UI Framework | curses | System.Console API |
| Ping Implementation | subprocess (ping command) | Test-Connection Cmdlet |
| Async | asyncio | ThreadJob / ForEach-Object -Parallel |
| SSH Relay | ✅ | ❌ (config compatible, but not used) |
| SNMP Ping | ✅ | ❌ |
| RouterOS API | ✅ | ❌ |
| netns / VRF | ✅ | ❌ |
| TCP Ping (hping3) | ✅ | ✅ (Windows: tnc, macOS/Linux: hping3) |
| SIGHUP Reload | ✅ | ❌ (SIGHUP not supported on Windows) |

## License

MIT License — same as the original

## Acknowledgements

- [upa/deadman](https://github.com/upa/deadman) — Original Python version
- Original design and implementation: Interop Tokyo ShowNet NOC team
