BeforeAll { . "$PSScriptRoot/../deadman.ps1" }

Describe 'Single-file startup and portability' {
    It 'loads embedded targets with only the script present and no encoding side effects' {
        $copy = Join-Path $TestDrive 'standalone.ps1'
        Copy-Item -LiteralPath "$PSScriptRoot/../deadman.ps1" -Destination $copy
        $encoding = [Console]::OutputEncoding
        . $copy
        $targets = Read-DeadmanConfig -Text $script:EmbeddedConfig
        @($targets | Where-Object { $_ -is [PingTarget] }).Count | Should -BeGreaterThan 0
        [Console]::OutputEncoding.CodePage | Should -Be $encoding.CodePage
        Test-Path (Join-Path $TestDrive 'deadman.conf') | Should -BeFalse
    }
    It 'starts with embedded configuration when ConfigFile is omitted' {
        Mock Start-Deadman {}
        & "$PSScriptRoot/../deadman.ps1"
        Should -Invoke Start-Deadman -Times 1 -Exactly -ParameterFilter {
            $Targets.Count -gt 0 -and $Targets[0].Address -eq '127.0.0.1' -and
            $IntervalSeconds -eq 1 -and $TimeoutSeconds -eq 3
        }
    }
    It 'shows ASCII help without initializing a console' {
        $text = & "$PSScriptRoot/../deadman.ps1" -Help | Out-String
        $text | Should -Match 'HTTP / HTTPS|HTTP/HTTPS'
        $text | Should -Match 'Up/Down'
        $text | Should -Not -Match '[^\x00-\x7f]'
    }
    It 'validates configurable timing and scale before any network work' {
        { & "$PSScriptRoot/../deadman.ps1" -Scale 0 } | Should -Throw
        { & "$PSScriptRoot/../deadman.ps1" -Timeout 0 } | Should -Throw
        { & "$PSScriptRoot/../deadman.ps1" -Interval -1 } | Should -Throw
        { & "$PSScriptRoot/../deadman.ps1" -Timeout ([double]::NaN) } | Should -Throw
    }
    It 'rejects redirected/noninteractive console use clearly' {
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected -or [Console]::WindowWidth -le 0) {
            { Test-DeadmanConsole } | Should -Throw '*interactive console*'
        } else {
            Set-ItResult -Skipped -Because 'This check requires redirected input/output.'
        }
    }
    It 'is ASCII source with no PS7-only syntax or external runtime commands' {
        $source = Get-Content -LiteralPath "$PSScriptRoot/../deadman.ps1" -Raw
        $source | Should -Not -Match '[^\x00-\x7f]'
        $source | Should -Not -Match '\?\?|\?\.'
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $commands = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($command in $commands) {
            $command.GetCommandName() | Should -Not -BeIn @('Start-Job', 'Start-ThreadJob', 'python', 'ping', 'hping3', 'curl')
            if ($command.GetCommandName() -eq 'Add-Type') {
                $command.Extent.Text | Should -Match '-AssemblyName System.Net.Http'
            }
        }
    }
}
