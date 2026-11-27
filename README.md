# pingpongman

[![CI](https://github.com/pichuang/pingpongman/actions/workflows/ci.yml/badge.svg)](https://github.com/pichuang/pingpongman/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/pichuang/pingpongman/badge)](https://scorecard.dev/viewer/?uri=github.com/pichuang/pingpongman)

Real-time ICMP, TCP, HTTP and HTTPS monitoring in **one PowerShell file**.
Ported from [upa/deadman](https://github.com/upa/deadman), MIT licensed.
Uses built-in PowerShell commands and system .NET APIs only: no modules,
external executables, compiled helpers, jobs or third-party runtime dependencies.

[Traditional Chinese documentation](README.zh-tw.md)

## Quick start

Download and copy **only [pingpongman.ps1](pingpongman.ps1)** to the destination machine.
Open it in a text editor, search for **`Setting`**, and edit the target rows
inside `$script:EmbeddedConfig` immediately after the script parameters.
Save the same file, then run it in an interactive PowerShell console:

```powershell
.\pingpongman.ps1
.\pingpongman.ps1 -AsyncMode
.\pingpongman.ps1 -Interval 1 -Timeout 3 -Scale 20 -LogDir .\logs
.\pingpongman.ps1 -Help
```

**No `.conf` download is required.** The `Setting` block already includes all
targets and explanatory comments from the optional `pingpongman.conf` example,
including the Blackair and intentional failure examples.
Only if you prefer a separate file, `-ConfigFile .\pingpongman.conf` explicitly
replaces these embedded targets. No adjacent config file is loaded automatically.
Follow your organization's execution policy; no execution-policy changes are
required by the program.

## Requirements and Windows coverage

- Windows PowerShell **5.1** with **.NET Framework 4.7.2 or newer** (4.8 recommended),
  or a PowerShell **7+** release supported on your operating system.
- Interactive `powershell.exe` or `pwsh` console (legacy conhost, Windows Terminal,
  or VS Code terminal). PowerShell ISE and redirected input/output are unsupported
  and receive an explicit diagnostic.
- Working DNS, network routes, trusted HTTPS certificate roots and system TLS
  configuration. Firewalls and ICMP permissions can cause failed probes.
- No administrator privileges are required for ordinary TCP/HTTP probes.

| Environment | Coverage / prerequisites |
|---|---|
| Windows 10 / Windows 11 | Target consoles; manual console validation remains required |
| Windows Server 2016 | Ensure Windows PowerShell 5.1 and .NET prerequisites; manual validation required |
| Windows Server 2012 | Install WMF 5.1 and a supported .NET Framework first; manual validation required |
| Windows Server 2022 / 2025 | Automated Pester CI on Windows PowerShell 5.1 and PowerShell 7 |
| macOS / Linux with PowerShell 7 | Same .NET probe and console APIs; not proof of legacy Windows compatibility |

CI on Server 2022/2025 is **not** a substitute for testing the actual Windows
10/11/Server 2012/2016 machines and their console hosts. PowerShell 7 releases have
their own OS support boundaries; this project does not extend them. Old systems
also need appropriate patches, TLS settings and certificate roots for modern
HTTPS sites. There is no insecure TLS bypass.

### No garbled terminal characters

The script, help and UI are printable ASCII English. RTT history uses digits
`1..8`, not Unicode blocks. No `chcp`, font change, encoding mutation or ANSI
support is required. Console colors/encoding are left unchanged. Only console
cursor visibility (Windows) and Ctrl+C handling are changed while running,
then restored in `finally`.

## Targets

The embedded block and optional example config include `ifconfig.blackair.io`
as the representative successful endpoint for all four protocols:

```text
blackair-icmp  ifconfig.blackair.io
blackair-tcp   ifconfig.blackair.io          via=tcp port=443
blackair-http  http://ifconfig.blackair.io/ via=http port=80
blackair-https https://ifconfig.blackair.io/ via=https port=443
blackair-https https://ifconfig.blackair.io/ip via=https port=443
```

On November 27, 2026, the development environment received an ICMP echo reply,
connected to TCP port 443, and received final HTTP **200** responses over both
HTTP and HTTPS (including `/ip`) with normal certificate validation. Public endpoint availability
and your network's ICMP/TLS policies can differ; these examples are not a
guarantee of success or an automated test dependency.

### Intentional failure examples

The embedded and optional example configurations also enable these targets so
you can compare successful probes with runtime failures:

```text
fail-dns  no-such-host.invalid
fail-port ifconfig.blackair.io via=tcp port=81
```

| Target | Expected cause | How to fix |
|---|---|---|
| `fail-dns` | `.invalid` is reserved for invalid names; ordinary DNS resolution fails | Replace with a real hostname, such as `ifconfig.blackair.io`; check DNS configuration if a real name also fails |
| `fail-port` | Port 81 is intentionally different from the working TCP sample's port 443; a closed port refuses connections, while a firewall may cause a timeout | Use the actual service port, such as 443; check the listener, route and firewall |

The development environment observed a name-resolution error and a timeout,
respectively, on November 27, 2026. A public port is not guaranteed to stay closed;
if a service opens on port 81, that example can succeed. Failure detail depends
on the operating system and network. These targets show failures (`X`) without
preventing other targets from being monitored; remove/comment them after trying
the demo.

Runtime failures are different from **invalid configuration**. For example,
`bad-port localhost via=tcp port=70000` or `bad-url https:///` causes startup to
stop with a source/line error. Such parser-invalid examples are not enabled in
the sample configurations. Correct the port to 1..65535 or supply an absolute
HTTP/HTTPS URL before starting again.

### Configuration syntax

The embedded block and optional UTF-8 config file use the **same strict parser**.
Other syntax examples (replace endpoints for your environment):

```text
# name        address                         options
gateway       192.0.2.1
loopback-v6   ::1
dns           dns.example.com                  via=icmp
---
database      db.example.com                   via=tcp port=1433
health        http://localhost:8080/health
website       https://example.com/              via=https
```

- Space or tab delimited: `name address [via=protocol] [port=number]`.
- Names are display labels and may repeat: each row has independent probes,
  statistics and history, including the two `blackair-https` URLs above.
  Use 1..64 ASCII letters, digits, `_`, `-` or `.`, beginning with a letter/digit.
  Trailing dots, Windows device names and path characters are rejected so names
  are safe log filenames.
- ICMP is the default for hostnames and IPv4/IPv6 literals. TCP requires
  `via=tcp port=1..65535`. TCP is a full connect check, not a raw SYN probe.
- An absolute `http://` or `https://` URL selects HTTP/HTTPS automatically.
  An explicit `via=http`/`via=https` must match the URL scheme. Set HTTP ports
  in the URL or with `port=1..65535`. Without an explicit URL port, the option
  sets the request port; if both specify a port, they must agree, even when the
  URL explicitly uses its default port. Conflicts fail with source/line context.
  Paths, queries and fragments are preserved. IPv6 URLs use brackets, for
  example `http://[::1]:8080/`.
  Credentials embedded in URLs are rejected.
- `---` (three or more hyphens) adds a group separator, which counts as a
  viewport row. Blank lines and full-line `#` comments are ignored.
  `; # comment` is also supported after a target. URL `#fragment` is preserved.
- Unsupported SSH/relay, SNMP, source/interface, netns, VRF and unknown options
  **fail with source and line context**. Invalid ports/URLs, duplicate options,
  missing addresses and configurations without real targets also fail.
  This is intentionally stricter than the old parser; unsupported features
  no longer silently fall back to ICMP.

## Probes and timing

| Protocol | Success | Measured duration |
|---|---|---|
| ICMP | Echo reply with `Success` status | Reply's round-trip time |
| TCP | Connection established | DNS and TCP connect, including address retries |
| HTTP / HTTPS | **Final 200..399** response | GET through final response headers, including DNS, TCP, TLS and redirects |

HTTP uses `ResponseHeadersRead`: it does **not** download or wait for the full
response body. HTTP 400..599 is a failed probe with status shown in the UI/log.
Automatic redirects are limited to **5**. At the limit, runtimes may return a
final 3xx (successful by the stated status rule) or report a redirect error.
HTTPS uses ordinary platform certificate validation and TLS defaults; no global
certificate callbacks, global TLS changes or bypass switches are used.

Each probe has its own deadline (default **3 seconds**, including DNS). Completed
tasks are polled individually, never with `WaitAll`, so one slow target does not
inflate another's RTT. TCP/HTTP timing has the main-loop polling granularity
(normally about 10 ms; host load can add scheduling delay).

Default mode probes targets sequentially. `-AsyncMode` starts all targets in a
round concurrently. `-Interval` (default **1 second**) is the minimum spacing
between round starts, not an extra delay after a slow round. Rounds never overlap.
Both modes poll keyboard input and resize while probes are pending.

Some old .NET DNS operations cannot be promptly cancelled. On timeout/reset their
results are discarded, owned network resources are closed, and at most **one**
unfinished task is retained per target. That target reports
`Previous probe still finishing` rather than accumulating new work. Late faults
are observed and late HTTP responses disposed before retrying.

## Display and controls

| Key | Action |
|---|---|
| Up / Down | Scroll the **target list**, not RTT history |
| R | Cancel the current round and reset every target's statistics |
| Q / Ctrl+C | Stop probing, dispose owned resources and restore console state |

Headings and the visible row range remain fixed; all targets continue to be
probed even when offscreen. Separators scroll with the target list. Resizing
clamps the offset, clears stale rows and clips narrow screens. Address columns
are shown at 110+ columns; compact screens prioritize statistics. Very short
windows show an enlargement hint but still accept keys. Rendering leaves the
last column/row unused to avoid console auto-scroll.

`LOSS%` counts failed sends; `AVG` averages **successful** RTTs only; `SNT` counts
completed probes (including failures). Current RTT/TTL are cleared on failure,
and the failure detail or HTTP status replaces stale RTT. Pending probes show
`>`; `-BlinkArrow` blinks this marker.

History is newest first, bounded to the latest **256** results per target:
`min(8, floor(RTT / Scale) + 1)` for success, `X` for failure.
With `-Scale 10`, 0..<10 ms is `1`, 10..<20 is `2`, and 70+ is `8`.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-ConfigFile` | Embedded targets | Optional config file; also accepted positionally |
| `-Scale`, `-s` | 10 | Positive integer RTT bucket width in milliseconds |
| `-Interval` | 1 | Round-start interval, 0.01..86400 seconds |
| `-Timeout` | 3 | Per-probe deadline, 0.01..86400 seconds |
| `-AsyncMode`, `-a` | Off | Concurrent probes |
| `-BlinkArrow`, `-b` | Off | Blink pending probe markers |
| `-LogDir`, `-l` | None | Append per-target JSONL logs; duplicate labels get separate filenames |
| `-Help`, `-h` | Off | Show help (`--help` is also accepted) |

Each JSON log line contains a timestamp with UTC offset, target name/address,
protocol, success, RTT, average, sends, losses, HTTP status and failure detail.
The first occurrence of a name uses `<name>.jsonl`; duplicates get `-2`, `-3`,
etc. in configuration order, skipping names already used by any configured
label (case-insensitive). The two HTTPS samples therefore use
`blackair-https.jsonl` and `blackair-https-2.jsonl`, without mixing records.
Keep configuration order stable when appending across runs.
Log write failures stop monitoring with an error rather than silently losing
data. Logs can contain internal addresses/URLs; protect them appropriately.

## Development and verification

Pester and PSScriptAnalyzer are **development-only** dependencies:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester ./tests/ -Output Detailed -ExcludeTag Network
Invoke-ScriptAnalyzer ./pingpongman.ps1 -Severity Error,Warning -ExcludeRule PSAvoidUsingWriteHost
Invoke-ScriptAnalyzer ./pingpongman.ps1 -Settings @{
    IncludeRules = @('PSUseCompatibleSyntax')
    Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } }
}
```

Tests use deterministic task completions and controlled local TCP/HTTP/TLS
services, not public internet endpoints. Viewport/key tests need no real console.
The `Fuzz` tag covers generated parser and bounded-state cases. Real ICMP tests
are tagged `Network` because host permissions/firewalls vary.

Before delivery, manually check on the actual target Windows machines:
launch with only the script, each protocol including trusted/untrusted HTTPS,
Up/Down with more targets than rows, slow DNS/probes while scrolling, resize to
narrow/short windows, reset while busy, quit/Ctrl+C, and original console state.
Record the exact OS, PowerShell/.NET versions and console host; do not infer
this coverage from the CI runner names.

CI retains Windows Server 2022/2025 x PowerShell 5.1/7. Actions are SHA-pinned.
Development delivery uses `develop` -> PR to protected `main` and requires the
four configured Windows CI checks. A review is currently optional for solo
development; verify live protection settings before merging and never bypass them.
Release archives include the script, optional config/docs and MIT license.
Users need only the script, which includes the copyright and license notice.

## Provenance and change history

pingpongman is the PowerShell adaptation formerly named **deadman-pwsh**.
It is not a rename of the original Python project.

- **Original Python project:** [upa/deadman](https://github.com/upa/deadman),
  designed for Interop Tokyo ShowNet by the ShowNet NOC team. Its
  [commit history](https://github.com/upa/deadman/commits/master/) and
  [MIT license](https://github.com/upa/deadman/blob/master/LICENSE) remain upstream.
- **PowerShell adaptation:** began with
  [6c5286d](https://github.com/pichuang/pingpongman/commit/6c5286d) on 2026-03-30;
  [c8c0498](https://github.com/pichuang/pingpongman/commit/c8c0498) consolidated
  the program into one script on 2026-03-31.
- **Four-protocol rewrite:** [6120b68](https://github.com/pichuang/pingpongman/commit/6120b68)
  added HTTP/HTTPS, strict configuration, independent task deadlines, numeric
  ASCII history and target-list scrolling on 2026-11-27.
- **pingpongman rename:** the repository was renamed in place, retaining Git
  commit IDs, issues and pull requests. The runtime entry points are now
  `pingpongman.ps1` and optional `pingpongman.conf`; protocol behavior is unchanged.
  Historical commits and published release assets retain their original
  `deadman-pwsh` / `deadman.ps1` names rather than rewriting the past.

See this adaptation's [full history](https://github.com/pichuang/pingpongman/commits/main/).
Both the upstream copyright and existing PowerShell adaptation copyright are
preserved in [LICENSE](LICENSE) and in the distributable script.

## License and acknowledgements

[MIT License](LICENSE), with upstream attribution preserved.
Original Python design: [upa/deadman](https://github.com/upa/deadman) and the
Interop Tokyo ShowNet NOC team. See [SECURITY.md](SECURITY.md) for private
vulnerability reporting.
