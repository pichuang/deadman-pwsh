BeforeAll { . "$PSScriptRoot/../pingpongman.ps1" }

Describe 'Single-file startup and portability' {
    It 'loads embedded targets with only the script present and no encoding side effects' {
        $copy = Join-Path $TestDrive 'standalone.ps1'
        Copy-Item -LiteralPath "$PSScriptRoot/../pingpongman.ps1" -Destination $copy
        $shell = [PowerShell]::Create()
        try {
            $null = $shell.AddScript({
                param($Path)
                $encoding = [Console]::OutputEncoding.CodePage
                . $Path
                $targets = Read-PingPongManConfig -Text $script:EmbeddedConfig
                [pscustomobject]@{
                    Count = @($targets | Where-Object { $_ -is [PingTarget] }).Count
                    EncodingUnchanged = [Console]::OutputEncoding.CodePage -eq $encoding
                }
            }).AddArgument($copy)
            $result = $shell.Invoke()
            $shell.HadErrors | Should -BeFalse
            $result[0].Count | Should -BeGreaterThan 0
            $result[0].EncodingUnchanged | Should -BeTrue
        } finally { $shell.Dispose() }
        Test-Path (Join-Path $TestDrive 'pingpongman.conf') | Should -BeFalse
    }
    It 'starts with embedded configuration when ConfigFile is omitted' {
        Mock Start-PingPongMan {}
        & "$PSScriptRoot/../pingpongman.ps1"
        Should -Invoke Start-PingPongMan -Times 1 -Exactly -ParameterFilter {
            $Targets.Count -gt 0 -and $Targets[0].Address -eq '127.0.0.1' -and
            $IntervalSeconds -eq 1 -and $TimeoutSeconds -eq 3
        }
    }
    It 'shows ASCII help without initializing a console' {
        $text = & "$PSScriptRoot/../pingpongman.ps1" -Help | Out-String
        $text | Should -Match '^pingpongman - single-file'
        $text | Should -Match 'Usage: \.\\pingpongman\.ps1'
        $text | Should -Match 'https://github\.com/upa/deadman'
        $text | Should -Match 'HTTP / HTTPS|HTTP/HTTPS'
        $text | Should -Match 'Up/Down'
        $text | Should -Not -Match '[^\x00-\x7f]'
    }
    It 'validates configurable timing and scale before any network work' {
        { & "$PSScriptRoot/../pingpongman.ps1" -Scale 0 } | Should -Throw
        { & "$PSScriptRoot/../pingpongman.ps1" -Timeout 0 } | Should -Throw
        { & "$PSScriptRoot/../pingpongman.ps1" -Interval -1 } | Should -Throw
        { & "$PSScriptRoot/../pingpongman.ps1" -Timeout ([double]::NaN) } | Should -Throw
    }
    It 'rejects redirected/noninteractive console use clearly' {
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected -or [Console]::WindowWidth -le 0) {
            { Test-PingPongManConsole } | Should -Throw '*interactive console*'
        } else {
            Set-ItResult -Skipped -Because 'This check requires redirected input/output.'
        }
    }
    It 'is ASCII source with no PS7-only syntax or external runtime commands' {
        $source = Get-Content -LiteralPath "$PSScriptRoot/../pingpongman.ps1" -Raw
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
