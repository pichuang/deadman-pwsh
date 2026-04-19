# Copilot Instructions — deadman-pwsh

## Project Overview

A real-time host monitoring tool using ICMP/TCP Ping with a terminal UI, built in PowerShell.
Ported from [upa/deadman](https://github.com/upa/deadman) (Python). Single-file architecture (`deadman.ps1`).

## Architecture

- **Single-file design**: All classes (`PingTarget`, `PingResult`, `ConsoleUI`, `Separator`), config parser (`Read-DeadmanConfig`), and main loop are in `deadman.ps1`
- **Dot-source guard**: `if ($MyInvocation.InvocationName -ne '.')` prevents main loop execution when tests dot-source the file
- **Script-scope variables for class methods**: PowerShell class methods cannot access `$PSVersionTable` or call script functions directly. Use `$script:PSMajorVersion`, `$script:IsWindowsPlatform`, `$script:UseAsciiChars` instead
- **Test framework**: Pester 5 (`Invoke-Pester ./tests/ -Output Detailed -ExcludeTag 'Network'`)

## PowerShell Compatibility

### Dual-version support (PS 5.1 + PS 7+)

This project must work on both **Windows PowerShell 5.1** and **PowerShell 7+**. Key differences:

| Feature | PowerShell 5.1 | PowerShell 7+ |
|---------|----------------|---------------|
| `Test-Connection` | `-ComputerName`, `.StatusCode`, `.ResponseTime` | `-TargetName`, `-TimeoutSeconds`, `-Ping`, `.Status`, `.Latency` |
| Platform detection | `$global:IsWindows` doesn't exist (always Windows) | `$global:IsWindows` available |
| Async jobs | `Start-Job` (process-based, slower) | `Start-ThreadJob` (thread-based, faster) |
| Ternary operator | Not supported — use `if/else` | `$x ? $a : $b` supported but DO NOT USE for compat |
| `??` / `?.` operators | Not supported | Supported but DO NOT USE for compat |

### Rules

- Always branch on `$script:PSMajorVersion -ge 7` for version-specific code
- Never use ternary (`? :`), null-coalescing (`??`), or null-conditional (`?.`) operators
- In CI workflow `run:` blocks using `shell: powershell`, avoid inline `if ($x) { $a } else { $b }` assignment — use separate `if/else` statements
- GitHub Actions `${{ matrix.os }}` expands to `windows-2022` which PS 5.1 interprets as arithmetic (`windows` minus `2022`). Pass via `env:` variable instead

## Unicode & Character Display

- **Windows Terminal / VS Code**: Full Unicode block elements (▁▂▃▄▅▆▇█)
- **conhost / legacy console**: Auto-detect via `$env:WT_SESSION` and `[Console]::OutputEncoding`; falls back to ASCII (`_.:‐+=@#`)
- Detection function: `Test-UnicodeSupport` → sets `$script:UseAsciiChars`
- Always set `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` on Windows at startup
- **CI workflow YAML**: Never use non-ASCII characters (em-dash `—`, etc.) in PowerShell `run:` blocks — PS 5.1 runners may corrupt UTF-8

## Target Platforms

| OS | PS 5.1 | PS 7+ | CI Runner |
|----|:------:|:-----:|-----------|
| Windows Server 2022 | ✅ | ✅ | `windows-2022` |
| Windows Server 2025 | ✅ | ✅ | `windows-2025` |
| Windows 10 | ✅ | ✅ | Same kernel as Server 2019 |
| Windows 11 | ✅ | ✅ | Same kernel as Server 2022 |

Note: `windows-2019` runner was removed by GitHub. Use `windows-2022` and `windows-2025`.

## CI/CD Workflows

All GitHub Actions are **pinned by SHA hash** with version comment (e.g., `@de0fac2e...# v6`). Dependabot auto-updates via `.github/dependabot.yml`.

| Workflow | File | Trigger |
|----------|------|---------|
| CI | `ci.yml` | push main/develop, PR to main |
| SAST | `sast.yml` | push/PR to main, weekly (Wed) |
| Fuzzing | `fuzzing.yml` | push/PR to main, weekly (Fri) |
| Scorecard | `scorecard.yml` | push to main, weekly (Mon) |
| Release | `release.yml` | tag push `[0-9]*` |
| PR Assign | `pr-assign.yml` | PR open/reopen |

### CI structure

Two separate jobs (not matrix with `shell:`) because GitHub Actions `shell:` doesn't accept matrix variables:
- `test-pwsh`: `shell: pwsh` (PowerShell 7)
- `test-powershell`: `shell: powershell` (Windows PowerShell 5.1)

### Test report in CI

- JUnit XML output (`$config.TestResult.OutputFormat = 'JUnitXml'`)
- Job Summary: full test case table (Status/Suite/Name/Duration) + collapsible Skipped section
- `dorny/test-reporter` for Check Run reports
- Pass `matrix.os` via `env: MATRIX_OS` (not inline `${{ }}`) to avoid PS 5.1 parse errors

### Release workflow

- Tag format: `yyyymmdd` (e.g., `20260419`)
- Build → Provenance → Release (3 jobs)
- SLSA provenance via `actions/attest-build-provenance` → `.sigstore.json` attached as release asset
- Archive contains only: `deadman.ps1`, `deadman.conf`, `README.md`, `README.zh-tw.md`

## Branch & PR Workflow

- **Default branch**: `main` (protected)
- **Development branch**: `develop`
- **Flow**: develop → PR → CI passes → merge to main
- **Branch protection (main)**:
  - 1 required review (CODEOWNERS enforced)
  - 4 required status checks (win-2022/2025 × PS 5.1/7)
  - Dismiss stale reviews, no force push, conversation resolution required
- **CODEOWNERS**: `@pichuang` for all files
- **PR auto-assign**: `pr-assign.yml` sets assignee to `pichuang`, requests CODEOWNERS review (skips if author = owner)

## OpenSSF Scorecard

Target: maximize score on [scorecard.dev](https://scorecard.dev/viewer/?uri=github.com/pichuang/deadman-pwsh).

### Checks and status

| Check | Approach |
|-------|----------|
| License | MIT `LICENSE` file |
| Security-Policy | `SECURITY.md` with private vulnerability reporting |
| Pinned-Dependencies | All actions pinned by SHA |
| Dependency-Update-Tool | Dependabot for github-actions |
| Token-Permissions | Top-level `contents: read`, job-level scoping |
| CI-Tests | 4 CI checks on PRs |
| Branch-Protection | API-configured (see above) |
| SAST | CodeQL + PSScriptAnalyzer |
| Signed-Releases | SLSA provenance `.sigstore.json` in release assets |
| Packaging | Release workflow detected |
| Dangerous-Workflow | No `pull_request_target` with checkout |
| Fuzzing | Not achievable for PowerShell (Scorecard only recognizes OSS-Fuzz/ClusterFuzzLite) |
| CII-Best-Practices | Requires manual badge application |
| Code-Review | Requires external reviewer approval on PRs |

## Testing Conventions

- All test files in `tests/` directory, named `*.Tests.ps1`
- Tag `Network` for tests requiring real network access (excluded in CI)
- Tag `Fuzz` for fuzz/property-based tests
- Non-interactive console tests: use `BeforeAll` to detect console availability with `$script:canCreateConsole` flag, skip gracefully in CI
- Mock `Test-Connection` must handle both PS 5.1 and PS 7+ parameter signatures
- Run locally: `pwsh -NoProfile -Command "Invoke-Pester ./tests/ -Output Detailed -ExcludeTag 'Network'"`

## Key Files

| File | Purpose |
|------|---------|
| `deadman.ps1` | Main program (single-file, ~1000 lines) |
| `deadman.conf` | Example config (tab/space delimited) |
| `SECURITY.md` | Vulnerability reporting policy |
| `LICENSE` | MIT License |
| `.github/CODEOWNERS` | `* @pichuang` |
| `.github/dependabot.yml` | Weekly github-actions updates |
| `.github/pull_request_template.md` | PR checklist |
