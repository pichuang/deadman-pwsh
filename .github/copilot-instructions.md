# Copilot Instructions — pingpongman

## Project Overview

A real-time ICMP/TCP/HTTP/HTTPS monitoring tool with an ASCII English terminal UI, built in PowerShell.
Ported from [upa/deadman](https://github.com/upa/deadman) (Python). Single-file architecture (`pingpongman.ps1`).

## Architecture

- **Single-file design**: All classes (`PingTarget`, `PingResult`, `ConsoleUI`, `Separator`), config parser (`Read-PingPongManConfig`), and main loop are in `pingpongman.ps1`
- **Dot-source guard**: `if ($MyInvocation.InvocationName -ne '.')` prevents main loop execution when tests dot-source the file
- **Runtime dependencies**: Built-in cmdlets and system .NET APIs only. No external executables, jobs, ThreadJob, compiled helper code or runtime modules. `Add-Type -AssemblyName System.Net.Http` loads a system assembly, not source code.
- **Configuration**: Editable embedded targets are the default; optional `-ConfigFile` uses the same strict parser. Unknown/unsupported options must error with source and line context.
- **Lifecycle**: Shared task polling for sequential/concurrent modes. Per-probe deadlines include DNS; retain at most one unfinished operation per target. No PowerShell callbacks on threads without runspaces.
- **Statistics**: Average successful RTTs only, clear failed RTT/TTL, bound latest-first history to 256.
- **Test framework**: Pester 5 (`Invoke-Pester ./tests/ -Output Detailed -ExcludeTag 'Network'`)

## PowerShell Compatibility

### Dual-version support (PS 5.1 + PS 7+)

This project must work on both **Windows PowerShell 5.1** and **PowerShell 7+**. Key differences:

| Feature | PowerShell 5.1 | PowerShell 7+ |
|---------|----------------|---------------|
| `Test-Connection` | `-ComputerName`, `.StatusCode`, `.ResponseTime` | `-TargetName`, `-TimeoutSeconds`, `-Ping`, `.Status`, `.Latency` |
| Platform detection | `$global:IsWindows` doesn't exist (always Windows) | `$global:IsWindows` available |
| Async I/O | System .NET tasks, polled on main thread | Same; no ThreadJob dependency |
| Ternary operator | Not supported — use `if/else` | `$x ? $a : $b` supported but DO NOT USE for compat |
| `??` / `?.` operators | Not supported | Supported but DO NOT USE for compat |

### Rules

- Prefer APIs shared by both runtimes; explicitly gate any version-specific code.
- Never use ternary (`? :`), null-coalescing (`??`), or null-conditional (`?.`) operators
- In CI workflow `run:` blocks using `shell: powershell`, avoid inline `if ($x) { $a } else { $b }` assignment — use separate `if/else` statements
- GitHub Actions `${{ matrix.os }}` expands to `windows-2022` which PS 5.1 interprets as arithmetic (`windows` minus `2022`). Pass via `env:` variable instead

## ASCII & Character Display

- Script, help and UI are ASCII English. Increasing RTT buckets use digits `1..8`; failure uses `X`.
- Do not change console encoding or require `chcp`, Unicode fonts or ANSI support.
- Up/Down scroll target rows, including separators; all targets remain monitored offscreen.
- UI layout/key calculations must be testable without console access; leave final row/column unused.
- Restore original changed console settings in `finally`. Unix cannot query cursor visibility, so leave it unchanged there.
- HTTP GET reads headers only, follows at most 5 redirects, and treats final 200..399 as success. Preserve normal TLS validation; never set global TLS/certificate policy.
- **CI workflow YAML**: Never use non-ASCII characters (em-dash `—`, etc.) in PowerShell `run:` blocks — PS 5.1 runners may corrupt UTF-8

## Target Platforms

| OS | PS 5.1 | PS 7+ | CI Runner |
|----|:------:|:-----:|-----------|
| Windows Server 2022 | ✅ | ✅ | `windows-2022` |
| Windows Server 2025 | ✅ | ✅ | `windows-2025` |
| Windows 10 / 11 | Target | OS-supported releases only | Manual console validation required |
| Windows Server 2012 / 2016 | WMF 5.1 / .NET 4.7.2+ prerequisites | OS-supported releases only | Manual console validation required |

Note: `windows-2019` runner was removed by GitHub. Use `windows-2022` and `windows-2025`.
CI runner coverage does not prove compatibility with the actual legacy OS or console host.

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
- Archive contains: `pingpongman.ps1`, `pingpongman.conf`, `README.md`, `README.zh-tw.md`, `LICENSE`
- Preserve upstream `upa/deadman` attribution and historical names in provenance/history; do not rewrite Git history or rename upstream links.

## Branch & PR Workflow

- **Default branch**: `main` (protected)
- **Development branch**: `develop`
- **Flow**: develop → PR → required CI passes → merge to main when authorized
- **Branch protection (main)**:
  - No required review for the current solo-development workflow; confirm live settings before merging
  - 4 required status checks (win-2022/2025 × PS 5.1/7)
  - No force push or branch deletion; conversation resolution required
- **CODEOWNERS**: `@pichuang` for all files
- **PR auto-assign**: `pr-assign.yml` sets assignee to `pichuang`, requests CODEOWNERS review (skips if author = owner)

### Development rules

- **All changes must be made on `develop` branch** — never commit directly to `main`
- Before starting any new work, always sync with the latest `main`:
  ```bash
  git checkout develop
  git fetch origin
  git merge origin/main
  ```
- After committing on local `develop`, push to `origin/develop`
- **After every successful push to `origin/develop`**, Copilot agents must automatically create a PR targeting `main` (if no open PR from `develop` → `main` already exists)
- The PR must pass all required CI checks before merging to `main`; honor any review requirements if live protection settings change
- Copilot agents must verify the current branch is `develop` (not `main`) before making any code changes
- App-managed worktree sessions stay on their dedicated branch; do not switch or edit the primary checkout. An explicitly authorized delivery may fast-forward `origin/develop` from the worktree without force-pushing. Open PRs only when requested; never merge without explicit authorization and satisfying current branch protections.

## OpenSSF Scorecard

Target: maximize score on [scorecard.dev](https://scorecard.dev/viewer/?uri=github.com/pichuang/pingpongman).

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
- Test viewport/key calculations directly without a console. Use controlled loopback HTTP/TLS services and deterministic task completions, not public internet targets.
- Real ICMP tests require `Network` because permissions/firewalls vary. Never replace a meaningful assertion with a skip after a failed result.
- Run locally: `pwsh -NoProfile -Command "Invoke-Pester ./tests/ -Output Detailed -ExcludeTag 'Network'"`

## Key Files

| File | Purpose |
|------|---------|
| `pingpongman.ps1` | Self-contained program with embedded targets |
| `pingpongman.conf` | Example config (tab/space delimited) |
| `SECURITY.md` | Vulnerability reporting policy |
| `LICENSE` | MIT License |
| `.github/CODEOWNERS` | `* @pichuang` |
| `.github/dependabot.yml` | Weekly github-actions updates |
| `.github/pull_request_template.md` | PR checklist |
