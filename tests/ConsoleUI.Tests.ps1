[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester BeforeEach variables are consumed in It blocks.')]
param()

BeforeAll { . "$PSScriptRoot/../deadman.ps1" }

Describe 'Target viewport without console access' {
    BeforeEach {
        $ui = [ConsoleUI]::new()
        $targets = @(
            [PingTarget]::new('first', '127.0.0.1'), [Separator]::new(),
            [PingTarget]::new('third', '127.0.0.3'), [PingTarget]::new('last', '127.0.0.4')
        )
    }
    It 'scrolls rows including separators while keeping headings fixed' {
        $ui.SetSize(80, 7, $targets.Count)
        $ui.Capacity | Should -Be 2
        $before = $ui.Render($targets, 10, $false)
        $before[4] | Should -Match 'first'
        $before[5] | Should -Match '^-+$'
        $ui.HandleKey([ConsoleKeyInfo]::new([char]0, [ConsoleKey]::DownArrow, $false, $false, $false), $targets.Count)
        $after = $ui.Render($targets, 10, $false)
        $after[0] | Should -Be $before[0]
        $after[3] | Should -Be $before[3]
        $after[2] | Should -Match 'Rows 2-3/4'
        $after[4] | Should -Match '^-+$'
        $after[5] | Should -Match 'third'
        $targets[0].Sent | Should -Be 0
    }
    It 'clamps on repeated keypresses, resize and shrinking target lists' {
        $ui.SetSize(80, 7, 4)
        $down = [ConsoleKeyInfo]::new([char]0, [ConsoleKey]::DownArrow, $false, $false, $false)
        $up = [ConsoleKeyInfo]::new([char]0, [ConsoleKey]::UpArrow, $false, $false, $false)
        1..10 | ForEach-Object { $ui.HandleKey($down, 4) }
        $ui.Offset | Should -Be 2
        $ui.SetSize(80, 8, 4)
        $ui.Offset | Should -Be 1
        $ui.Clamp(1)
        $ui.Offset | Should -Be 0
        1..10 | ForEach-Object { $ui.HandleKey($up, 4) }
        $ui.Offset | Should -Be 0
    }
    It 'clips narrow and short windows without touching the final column or row' {
        foreach ($size in @(@(1, 1), @(10, 4), @(40, 8), @(80, 24), @(120, 10))) {
            $ui.SetSize($size[0], $size[1], 4)
            $lines = $ui.Render($targets, 10, $false)
            $lines.Count | Should -BeLessOrEqual ([Math]::Max(1, $size[1] - 1))
            foreach ($line in $lines) {
                $line.Length | Should -BeLessOrEqual ($size[0] - 1)
                $line | Should -Not -Match '[^\x20-\x7e]'
            }
        }
        $ui.SetSize(80, 10, 4)
        ($ui.Render($targets, 10, $false))[-1].Trim() | Should -Be ''
    }
    It 'shows HTTP failure status instead of stale RTT and keeps newest history' {
        $target = $targets[0]
        $target.ConsumeResult([PingResult]::new($true, [PingErrorCode]::Success, 23, 0))
        $result = [PingResult]::new()
        $result.Detail = 'HTTP 503'
        $result.StatusCode = 503
        $target.ConsumeResult($result)
        $ui.SetSize(110, 10, 4)
        $line = ($ui.Render($targets, 10, $false))[4]
        $line | Should -Match '503'
        $line | Should -Match 'X3'
        $line | Should -Not -Match '23.0ms'
        $line | Should -Match '127.0.0.1'
    }
    It 'handles reset, quit and Ctrl+C using ConsoleKey, not arrow KeyChar' {
        $ui.HandleKey([ConsoleKeyInfo]::new('r', [ConsoleKey]::R, $false, $false, $false), 4)
        $ui.Reset | Should -BeTrue
        $ui.HandleKey([ConsoleKeyInfo]::new([char]3, [ConsoleKey]::C, $false, $false, $true), 4)
        $ui.Quit | Should -BeTrue
        $ui.Quit = $false
        $ui.HandleKey([ConsoleKeyInfo]::new('q', [ConsoleKey]::Q, $false, $false, $false), 4)
        $ui.Quit | Should -BeTrue
    }
}
