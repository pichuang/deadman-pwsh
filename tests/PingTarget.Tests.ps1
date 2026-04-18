# -*- coding: utf-8 -*-
# PingTarget.Tests.ps1 — Unit tests for PingTarget and PingResult classes
# Uses Pester 5 test framework

BeforeAll {
    # Load class and function definitions from the single-file script
    . "$PSScriptRoot/../deadman.ps1"
}

Describe 'PingResult class' {

    Context 'Constructor' {

        It 'Default constructor should initialize to failed state' {
            $result = [PingResult]::new()

            $result.Success | Should -BeFalse
            $result.ErrorCode | Should -Be ([PingErrorCode]::Failed)
            $result.RTT | Should -Be 0.0
            $result.TTL | Should -Be 0
        }

        It 'Parameterized constructor should correctly set all properties' {
            $result = [PingResult]::new($true, [PingErrorCode]::Success, 15.5, 64)

            $result.Success | Should -BeTrue
            $result.ErrorCode | Should -Be ([PingErrorCode]::Success)
            $result.RTT | Should -Be 15.5
            $result.TTL | Should -Be 64
        }
    }
}

Describe 'PingTarget class' {

    # ========================================================
    # Constructor tests
    # ========================================================

    Context 'Constructor' {

        It 'Two-parameter constructor should correctly initialize name and address' {
            $target = [PingTarget]::new('google', '8.8.8.8')

            $target.Name | Should -Be 'google'
            $target.Address | Should -Be '8.8.8.8'
            $target.Source | Should -BeNullOrEmpty
            $target.TcpPort | Should -Be 0
            $target.State | Should -BeFalse
            $target.Loss | Should -Be 0
            $target.LossRate | Should -Be 0.0
            $target.RTT | Should -Be 0
            $target.Average | Should -Be 0
            $target.Sent | Should -Be 0
            $target.TTL | Should -Be 0
            ($null -ne $target.ResultHistory) | Should -BeTrue
            $target.ResultHistory.Count | Should -Be 0
        }

        It 'Three-parameter constructor should correctly set source interface' {
            $target = [PingTarget]::new('myhost', '192.168.1.1', 'eth0')

            $target.Name | Should -Be 'myhost'
            $target.Address | Should -Be '192.168.1.1'
            $target.Source | Should -Be 'eth0'
        }

        It 'TcpPort should be settable after construction' {
            $target = [PingTarget]::new('webhost', '10.0.0.1')
            $target.TcpPort = 443

            $target.TcpPort | Should -Be 443
        }
    }

    # ========================================================
    # GetResultChar() tests
    # ========================================================

    Context 'GetResultChar method' {

        BeforeEach {
            $script:target = [PingTarget]::new('test', '8.8.8.8')
            $script:target.RttScale = 10
        }

        It 'Should return X on ping failure' {
            $res = [PingResult]::new($false, [PingErrorCode]::Failed, 0, 0)
            $script:target.GetResultChar($res) | Should -Be 'X'
        }

        It 'RTT < 1x scale should return ▁' {
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 5, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2581)
        }

        It 'RTT < 2x scale should return ▂' {
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 15, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2582)
        }

        It 'RTT < 3x scale should return ▃' {
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 25, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2583)
        }

        It 'RTT < 4x scale should return ▄' {
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 35, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2584)
        }

        It 'RTT < 5x scale should return ▅' {
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 45, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2585)
        }

        It 'RTT < 6x scale should return ▆' {
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 55, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2586)
        }

        It 'RTT < 7x scale should return ▇' {
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 65, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2587)
        }

        It 'RTT >= 7x scale should return █' {
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 80, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2588)
        }

        It 'Should correctly determine with custom RttScale' {
            $script:target.RttScale = 20
            # RTT 15 < 20*1, should return ▁
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 15, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2581)
        }
    }

    # ========================================================
    # ConsumeResult() tests
    # ========================================================

    Context 'ConsumeResult method' {

        BeforeEach {
            $script:target = [PingTarget]::new('test', '8.8.8.8')
            $script:target.Sent = 1  # Simulate one ping already sent
        }

        It 'Should correctly update statistics on ping success' {
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 10.0, 64)
            $script:target.ConsumeResult($res)

            $script:target.State | Should -BeTrue
            $script:target.RTT | Should -Be 10.0
            $script:target.Total | Should -Be 10.0
            $script:target.Average | Should -Be 10.0
            $script:target.TTL | Should -Be 64
            $script:target.Loss | Should -Be 0
            $script:target.LossRate | Should -Be 0.0
        }

        It 'Should increment loss count on ping failure' {
            $res = [PingResult]::new($false, [PingErrorCode]::Failed, 0, 0)
            $script:target.ConsumeResult($res)

            $script:target.State | Should -BeFalse
            $script:target.Loss | Should -Be 1
            $script:target.LossRate | Should -Be 100.0
        }

        It 'Should correctly calculate average after multiple pings' {
            # First ping success (RTT = 10ms)
            $res1 = [PingResult]::new($true, [PingErrorCode]::Success, 10.0, 64)
            $script:target.ConsumeResult($res1)

            # Second ping success (RTT = 20ms)
            $script:target.Sent = 2
            $res2 = [PingResult]::new($true, [PingErrorCode]::Success, 20.0, 64)
            $script:target.ConsumeResult($res2)

            $script:target.Total | Should -Be 30.0
            $script:target.Average | Should -Be 15.0
            $script:target.RTT | Should -Be 20.0  # Last RTT
        }

        It 'Results should be inserted at the front of history' {
            $res1 = [PingResult]::new($true, [PingErrorCode]::Success, 5.0, 64)
            $script:target.ConsumeResult($res1)

            $script:target.Sent = 2
            $res2 = [PingResult]::new($false, [PingErrorCode]::Failed, 0, 0)
            $script:target.ConsumeResult($res2)

            # Latest result (failure=X) should be at the front
            $script:target.ResultHistory[0] | Should -Be 'X'
            # Older result should be after
            $script:target.ResultHistory[1] | Should -Be ([char]0x2581)
        }

        It 'Loss rate should be correct with mixed success and failure' {
            # 1 success + 2 failures = 66.67% loss rate
            $res1 = [PingResult]::new($true, [PingErrorCode]::Success, 10.0, 64)
            $script:target.ConsumeResult($res1)

            $script:target.Sent = 2
            $res2 = [PingResult]::new($false, [PingErrorCode]::Failed, 0, 0)
            $script:target.ConsumeResult($res2)

            $script:target.Sent = 3
            $res3 = [PingResult]::new($false, [PingErrorCode]::Failed, 0, 0)
            $script:target.ConsumeResult($res3)

            $script:target.Loss | Should -Be 2
            # Loss rate = 2/3 * 100 ≈ 66.67
            [Math]::Round($script:target.LossRate, 2) | Should -Be 66.67
        }
    }

    # ========================================================
    # Refresh() tests
    # ========================================================

    Context 'Refresh method' {

        It 'Should reset all statistics' {
            $target = [PingTarget]::new('test', '8.8.8.8')
            # Simulate some accumulated data
            $target.State = $true
            $target.Loss = 5
            $target.LossRate = 50.0
            $target.RTT = 15.0
            $target.Total = 150.0
            $target.Average = 15.0
            $target.Sent = 10
            $target.TTL = 64
            $target.ResultHistory.Add('X')
            $target.ResultHistory.Add([string]([char]0x2581))

            # Execute reset
            $target.Refresh()

            # Verify all statistics are zeroed
            $target.State | Should -BeFalse
            $target.Loss | Should -Be 0
            $target.LossRate | Should -Be 0.0
            $target.RTT | Should -Be 0
            $target.Total | Should -Be 0
            $target.Average | Should -Be 0
            $target.Sent | Should -Be 0
            $target.TTL | Should -Be 0
            $target.ResultHistory.Count | Should -Be 0
        }

        It 'Name and address should remain unchanged after reset' {
            $target = [PingTarget]::new('google', '8.8.8.8')
            $target.Refresh()

            $target.Name | Should -Be 'google'
            $target.Address | Should -Be '8.8.8.8'
        }
    }

    # ========================================================
    # ToString() tests
    # ========================================================

    Context 'ToString method' {

        It 'Without source interface should return name:address' {
            $target = [PingTarget]::new('google', '8.8.8.8')
            $target.ToString() | Should -Be 'google:8.8.8.8'
        }

        It 'With source interface should return name:address:source' {
            $target = [PingTarget]::new('myhost', '192.168.1.1', 'eth0')
            $target.ToString() | Should -Be 'myhost:192.168.1.1:eth0'
        }

        It 'With TcpPort should include tcp:port in string' {
            $target = [PingTarget]::new('webhost', '10.0.0.1')
            $target.TcpPort = 443
            $target.ToString() | Should -Be 'webhost:10.0.0.1:tcp:443'
        }
    }

    # ========================================================
    # Send() method tests (using Mock)
    # ========================================================

    Context 'Send method' {

        It 'Sent count should increase after calling Send' {
            # Mock Test-Connection to return success
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                Mock Test-Connection {
                    return [PSCustomObject]@{
                        Status  = 'Success'
                        Latency = 10
                        Reply   = [PSCustomObject]@{
                            Options = [PSCustomObject]@{ Ttl = 64 }
                        }
                    }
                }
            } else {
                Mock Test-Connection {
                    return [PSCustomObject]@{
                        StatusCode          = 0
                        ResponseTime        = 10
                        ResponseTimeToLive  = 64
                    }
                }
            }

            $target = [PingTarget]::new('test', '127.0.0.1')
            $target.Send()

            $target.Sent | Should -Be 1
        }

        It 'Should update state to alive on ping success' {
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                Mock Test-Connection {
                    return [PSCustomObject]@{
                        Status  = 'Success'
                        Latency = 5
                        Reply   = [PSCustomObject]@{
                            Options = [PSCustomObject]@{ Ttl = 128 }
                        }
                    }
                }
            } else {
                Mock Test-Connection {
                    return [PSCustomObject]@{
                        StatusCode          = 0
                        ResponseTime        = 5
                        ResponseTimeToLive  = 128
                    }
                }
            }

            $target = [PingTarget]::new('test', '127.0.0.1')
            $target.Send()

            $target.State | Should -BeTrue
            $target.RTT | Should -Be 5
        }

        It 'Should update state to no response on ping failure' {
            Mock Test-Connection {
                throw "Ping failed"
            }

            $target = [PingTarget]::new('test', '192.0.2.1')
            $target.Send()

            $target.State | Should -BeFalse
            $target.Loss | Should -Be 1
        }

        It 'TCP ping target should call SendTcp instead of ICMP ping' {
            # When TcpPort > 0, Send() should delegate to SendTcp()
            # Mock Test-NetConnection for Windows or hping3 for others
            if (Test-IsWindows) {
                Mock Test-NetConnection {
                    return [PSCustomObject]@{ TcpTestSucceeded = $true }
                }
            }

            $target = [PingTarget]::new('webhost', '127.0.0.1')
            $target.TcpPort = 80

            # Send should not throw even if external commands are unavailable
            { $target.Send() } | Should -Not -Throw
            $target.Sent | Should -Be 1
        }

        It 'Refresh should preserve TcpPort' {
            $target = [PingTarget]::new('webhost', '10.0.0.1')
            $target.TcpPort = 443
            $target.State = $true
            $target.Sent = 5

            $target.Refresh()

            $target.TcpPort | Should -Be 443
            $target.Sent | Should -Be 0
            $target.State | Should -BeFalse
        }
    }
}

Describe 'Separator class' {

    It 'Should correctly create Separator object' {
        $sep = New-Object Separator
        $sep.GetType().Name | Should -Be 'Separator'
    }
}

Describe 'PingErrorCode enumeration' {

    It 'Success value should be 0' {
        [int][PingErrorCode]::Success | Should -Be 0
    }

    It 'Failed value should be -1' {
        [int][PingErrorCode]::Failed | Should -Be -1
    }
}
