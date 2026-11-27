[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester BeforeEach variables are consumed in It blocks.')]
param()

BeforeAll { . "$PSScriptRoot/../pingpongman.ps1" }

Describe 'Target statistics' {
    BeforeEach { $target = [PingTarget]::new('local', '127.0.0.1') }

    It 'uses successes, not sends, for average and clears failed RTT and TTL' {
        $target.ConsumeResult([PingResult]::new($true, [PingErrorCode]::Success, 10, 64))
        $failure = [PingResult]::new()
        $failure.Detail = 'Timeout'
        $target.ConsumeResult($failure)
        $target.Average | Should -Be 10
        $target.RTT | Should -Be 0
        $target.TTL | Should -Be 0
        $target.Detail | Should -Be 'Timeout'
        $target.ConsumeResult([PingResult]::new($true, [PingErrorCode]::Success, 30, 128))
        $target.Sent | Should -Be 3
        $target.Loss | Should -Be 1
        $target.Average | Should -Be 20
        [Math]::Round($target.LossRate, 2) | Should -Be 33.33
    }

    It 'stores bounded latest-first history' {
        $target.HistoryLimit = 3
        foreach ($rtt in @(0, 10, 20, 30)) {
            $target.ConsumeResult([PingResult]::new($true, [PingErrorCode]::Success, $rtt, 0))
        }
        ($target.ResultHistory -join '') | Should -Be '432'
        $target.ConsumeResult([PingResult]::new())
        ($target.ResultHistory -join '') | Should -Be 'X43'
        $target.Sent | Should -Be 5
    }

    It 'resets statistics without changing protocol or in-flight ownership' {
        $target.Protocol = 'tcp'
        $target.TcpPort = 443
        $target.Pending = [pscustomobject]@{ Done = $false }
        $pending = $target.Pending
        $target.ConsumeResult([PingResult]::new($true, [PingErrorCode]::Success, 30, 64))
        $target.ConsumeResult([PingResult]::new())
        $target.Refresh()
        $target.Sent | Should -Be 0
        $target.Loss | Should -Be 0
        $target.Average | Should -Be 0
        $target.RTT | Should -Be 0
        $target.ResultHistory.Count | Should -Be 0
        $target.Protocol | Should -Be 'tcp'
        $target.TcpPort | Should -Be 443
        [object]::ReferenceEquals($target.Pending, $pending) | Should -BeTrue
    }

    It 'maps exact bucket boundaries without overflow' {
        foreach ($case in @(
            @(0, '1'), @(9.99, '1'), @(10, '2'), @(20, '3'),
            @(30, '4'), @(40, '5'), @(50, '6'), @(60, '7'),
            @(69.99, '7'), @(70, '8'), @([double]::MaxValue, '8')
        )) {
            $result = [PingResult]::new($true, [PingErrorCode]::Success, $case[0], 0)
            $target.GetResultChar($result) | Should -Be $case[1]
        }
        $target.RttScale = 20
        $target.GetResultChar([PingResult]::new($true, [PingErrorCode]::Success, 20, 0)) | Should -Be '2'
        $target.GetResultChar([PingResult]::new()) | Should -Be 'X'
    }
}
