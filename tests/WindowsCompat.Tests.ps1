BeforeAll { . "$PSScriptRoot/../pingpongman.ps1" }

Describe 'Single-file startup and portability' {
    It 'starts with only the script and uses its Setting targets (edited: <Edited>)' -TestCases @(
        @{ Edited = $false }
        @{ Edited = $true }
    ) {
        param($Edited)
        $directory = Join-Path $TestDrive "standalone-$Edited"
        $null = New-Item -ItemType Directory -Path $directory
        $copy = Join-Path $directory 'pingpongman.ps1'
        Copy-Item -LiteralPath "$PSScriptRoot/../pingpongman.ps1" -Destination $copy
        $expected = Read-PingPongManConfig -Path "$PSScriptRoot/../pingpongman.conf"
        if ($Edited) {
            $source = Get-Content -LiteralPath $copy -Raw
            $source = $source.Replace('localhost 127.0.0.1', 'edited-localhost 127.0.0.1')
            Set-Content -LiteralPath $copy -Value $source -Encoding UTF8
            $expected[0].Name = 'edited-localhost'
        }
        $expectedRows = @($expected | Where-Object { $_ -is [PingTarget] } | ForEach-Object {
            "$($_.Name)|$($_.Address)|$($_.Protocol)|$($_.TcpPort)"
        })
        $shell = [PowerShell]::Create()
        try {
            $null = $shell.AddScript({
                param($Path)
                $encoding = [Console]::OutputEncoding.CodePage
                function Get-TestStartup {
                    param($Targets, $Concurrent, $IntervalSeconds, $TimeoutSeconds, $RttScale, $LogDirectory, $Blink)
                    [pscustomobject]@{
                        Rows = @($Targets | Where-Object { $_.Name } | ForEach-Object {
                            "$($_.Name)|$($_.Address)|$($_.Protocol)|$($_.TcpPort)"
                        })
                        Concurrent = $Concurrent; Interval = $IntervalSeconds; Timeout = $TimeoutSeconds
                        Scale = $RttScale; LogDirectory = $LogDirectory; Blink = $Blink
                    }
                }
                # Alias precedence replaces only the console loop, not startup/config selection.
                Set-Alias -Name Start-PingPongMan -Value Get-TestStartup
                Set-Location -LiteralPath (Split-Path -Parent $Path)
                $startup = & $Path
                $startup | Add-Member -NotePropertyName EncodingUnchanged `
                    -NotePropertyValue ([Console]::OutputEncoding.CodePage -eq $encoding) -PassThru
            }).AddArgument($copy)
            $result = $shell.Invoke()
            $shell.HadErrors | Should -BeFalse
            $result.Count | Should -Be 1
            ($result[0].Rows -join "`n") | Should -Be ($expectedRows -join "`n")
            $result[0].Interval | Should -Be 1
            $result[0].Timeout | Should -Be 3
            $result[0].EncodingUnchanged | Should -BeTrue
        } finally { $shell.Dispose() }
        @(Get-ChildItem -LiteralPath $directory -Force).Count | Should -Be 1
        Test-Path (Join-Path $directory 'pingpongman.conf') | Should -BeFalse
    }
    It 'replaces embedded targets only when ConfigFile is explicitly provided' {
        $path = Join-Path $TestDrive 'selected.conf'
        Set-Content -LiteralPath $path -Value 'selected 127.0.0.2'
        Mock Start-PingPongMan {}
        & "$PSScriptRoot/../pingpongman.ps1" -ConfigFile $path
        Should -Invoke Start-PingPongMan -Times 1 -Exactly -ParameterFilter {
            $Targets.Count -eq 1 -and $Targets[0].Name -eq 'selected' -and $Targets[0].Address -eq '127.0.0.2' -and
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
