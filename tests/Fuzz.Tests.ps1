BeforeAll { . "$PSScriptRoot/../deadman.ps1" }

Describe 'Fuzz: strict configuration and bounded state' -Tag Fuzz {
    It 'parses 1000 deterministic valid targets without losing rows' {
        $random = [Random]::new(42)
        $lines = 1..1000 | ForEach-Object {
            "host$_ 10.$($random.Next(0,256)).$($random.Next(0,256)).$($random.Next(1,255))"
        }
        $targets = Read-DeadmanConfig -Text ($lines -join "`n")
        $targets.Count | Should -Be 1000
    }
    It 'rejects generated unknown options rather than silently accepting them' {
        $random = [Random]::new(123)
        1..100 | ForEach-Object {
            $option = "unknown$($random.Next())=value"
            { Read-DeadmanConfig -Text "host localhost $option" } | Should -Throw '*Unsupported option*'
        }
    }
    It 'rejects control and non-ASCII input before console or log rendering' {
        foreach ($code in @(0, 1, 27, 31, 127, 233, 0x4e2d)) {
            $text = "host$([char]$code) localhost"
            { Read-DeadmanConfig -Text $text } | Should -Throw '*ASCII*'
        }
    }
    It 'bounds history and loss statistics after many mixed results' {
        $target = [PingTarget]::new('test', 'localhost')
        1..2000 | ForEach-Object {
            $success = ($_ % 2 -eq 0)
            $result = [PingResult]::new()
            $result.Success = $success
            if ($success) { $result.RTT = 20 }
            $target.ConsumeResult($result)
        }
        $target.ResultHistory.Count | Should -Be 256
        $target.Average | Should -Be 20
        $target.LossRate | Should -Be 50
        ($target.ResultHistory -join '') | Should -Match '^(3X)+$'
    }
    It 'clamps arbitrary viewport offsets and dimensions' {
        $ui = [ConsoleUI]::new()
        $random = [Random]::new(99)
        1..100 | ForEach-Object {
            $rows = $random.Next(0, 1000)
            $ui.Offset = $random.Next(-1000, 2000)
            $ui.SetSize($random.Next(1, 200), $random.Next(1, 100), $rows)
            $ui.Offset | Should -BeGreaterOrEqual 0
            $ui.Offset | Should -BeLessOrEqual ([Math]::Max(0, $rows - $ui.Capacity))
        }
    }
}
