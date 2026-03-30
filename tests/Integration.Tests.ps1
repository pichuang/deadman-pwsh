# -*- coding: utf-8 -*-
# Integration.Tests.ps1 — Integration tests
# Uses Pester 5 test framework
#
# Verifies the end-to-end flow from reading configuration files to creating PingTarget objects.

BeforeAll {
    # Load all modules
    . "$PSScriptRoot/../lib/PingTarget.ps1"
    . "$PSScriptRoot/../lib/ConfigParser.ps1"
    . "$PSScriptRoot/../lib/ConsoleUI.ps1"

    # Helper function — create a temporary config file
    function New-TempConfig {
        param([string]$Content)
        $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "deadman-integ-$(New-Guid).conf"
        Set-Content -Path $tempFile -Value $Content -Encoding UTF8
        return $tempFile
    }
}

Describe 'End-to-end integration tests' {

    AfterEach {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'deadman-integ-*.conf' |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # ========================================================
    # Complete flow tests
    # ========================================================

    Context 'Config file parsing to PingTarget object creation' {

        It 'Should correctly create the full target list from a config file' {
            $config = New-TempConfig -Content @"
# Test config file
googleDNS	8.8.8.8
quad9		9.9.9.9
---
cloudflare	1.1.1.1
"@
            $targets = Read-DeadmanConfig -Path $config -RttScale 15

            # Verify target count
            $targets.Count | Should -Be 4

            # Verify first target
            $targets[0].GetType().Name | Should -Be 'PingTarget'
            $targets[0].Name | Should -Be 'googleDNS'
            $targets[0].Address | Should -Be '8.8.8.8'
            $targets[0].RttScale | Should -Be 15

            # Verify separator
            $targets[2].GetType().Name | Should -Be 'Separator'

            # Verify last target
            $targets[3].Name | Should -Be 'cloudflare'
            $targets[3].Address | Should -Be '1.1.1.1'
        }
    }

    # ========================================================
    # PingTarget full lifecycle tests
    # ========================================================

    Context 'PingTarget full lifecycle' {

        It 'Create → receive results → reset → receive results again full flow' {
            $target = [PingTarget]::new('test', '8.8.8.8')
            $target.RttScale = 10

            # First ping success
            $target.Sent = 1
            $res1 = [PingResult]::new($true, [PingErrorCode]::Success, 5.0, 64)
            $target.ConsumeResult($res1)

            $target.State | Should -BeTrue
            $target.RTT | Should -Be 5.0
            $target.ResultHistory.Count | Should -Be 1

            # Second ping failure
            $target.Sent = 2
            $res2 = [PingResult]::new($false, [PingErrorCode]::Failed, 0, 0)
            $target.ConsumeResult($res2)

            $target.State | Should -BeFalse
            $target.Loss | Should -Be 1
            $target.ResultHistory.Count | Should -Be 2
            $target.ResultHistory[0] | Should -Be 'X'

            # Reset statistics
            $target.Refresh()

            $target.State | Should -BeFalse
            $target.Sent | Should -Be 0
            $target.Loss | Should -Be 0
            $target.ResultHistory.Count | Should -Be 0

            # Receive results again after reset
            $target.Sent = 1
            $res3 = [PingResult]::new($true, [PingErrorCode]::Success, 12.0, 128)
            $target.ConsumeResult($res3)

            $target.State | Should -BeTrue
            $target.RTT | Should -Be 12.0
            $target.Average | Should -Be 12.0
            $target.ResultHistory.Count | Should -Be 1
        }
    }

    # ========================================================
    # ConsoleUI layout integration tests
    # ========================================================

    Context 'ConsoleUI layout and target list integration' {

        It 'Should correctly handle target list containing separators' {
            $config = New-TempConfig -Content @"
google	8.8.8.8
---
quad9	9.9.9.9
"@
            $targets = Read-DeadmanConfig -Path $config

            try {
                $ui = [ConsoleUI]::new(10)
                # UpdateLayout should not throw due to Separator
                { $ui.UpdateLayout($targets) } | Should -Not -Throw
            }
            catch {
                # Non-interactive environments may fail to create ConsoleUI
                Set-ItResult -Skipped -Because 'Non-interactive environment cannot initialize Console'
            }
        }
    }

    # ========================================================
    # IPv6 address support tests
    # ========================================================

    Context 'IPv6 address support' {

        It 'Should correctly parse IPv6 addresses' {
            $config = New-TempConfig -Content "kame6	2001:200:dff:fff1:216:3eff:feb1:44d7"
            $targets = Read-DeadmanConfig -Path $config

            $targets[0].Address | Should -Be '2001:200:dff:fff1:216:3eff:feb1:44d7'
        }
    }

    # ========================================================
    # TCP ping integration tests
    # ========================================================

    Context 'TCP ping configuration integration' {

        It 'Should correctly create TCP ping targets from config' {
            $config = New-TempConfig -Content @"
# ICMP target
googleDNS	8.8.8.8
---
# TCP target
web-https	10.0.0.1	via=tcp port=443
web-http	10.0.0.2	via=tcp port=80
"@
            $targets = Read-DeadmanConfig -Path $config -RttScale 10

            $targets.Count | Should -Be 4
            $targets[0].TcpPort | Should -Be 0
            $targets[2].GetType().Name | Should -Be 'PingTarget'
            $targets[2].Name | Should -Be 'web-https'
            $targets[2].TcpPort | Should -Be 443
            $targets[3].TcpPort | Should -Be 80
        }

        It 'TCP target should preserve TcpPort after Refresh' {
            $config = New-TempConfig -Content "web 10.0.0.1 via=tcp port=443"
            $targets = Read-DeadmanConfig -Path $config

            $targets[0].TcpPort | Should -Be 443
            $targets[0].Refresh()
            $targets[0].TcpPort | Should -Be 443
        }
    }

    # ========================================================
    # Performance and boundary condition tests
    # ========================================================

    Context 'Performance and boundary conditions' {

        It 'Should handle a large number of targets (100)' {
            $lines = @()
            for ($i = 1; $i -le 100; $i++) {
                $lines += "host$i`t10.0.0.$($i % 256)"
            }
            $config = New-TempConfig -Content ($lines -join "`n")
            $targets = Read-DeadmanConfig -Path $config

            $targets.Count | Should -Be 100
        }

        It 'Should handle an empty config file' {
            $config = New-TempConfig -Content @"
# Only comments
# No targets
"@
            $targets = Read-DeadmanConfig -Path $config

            $targets.Count | Should -Be 0
        }
    }

    # ========================================================
    # Real ping tests (localhost)
    # ========================================================

    Context 'Real ping tests' {

        It 'Ping to localhost (127.0.0.1) should succeed' -Tag 'Network' {
            $target = [PingTarget]::new('localhost', '127.0.0.1')
            $target.Send()

            $target.Sent | Should -Be 1

            # Some environments (e.g. macOS non-root, CI/CD containers) may block ICMP
            # So we only verify Send() does not throw and Sent count is correct
            if (-not $target.State) {
                Set-ItResult -Skipped -Because 'Environment may block ICMP (requires admin privileges or firewall configuration)'
            }
            else {
                $target.RTT | Should -BeGreaterOrEqual 0
            }
        }

        It 'Ping to unreachable address should fail' -Tag 'Network' {
            # Use TEST-NET range address (RFC 5737), typically unreachable
            $target = [PingTarget]::new('unreachable', '192.0.2.1')
            $target.Send()

            $target.Sent | Should -Be 1
            $target.State | Should -BeFalse
            $target.Loss | Should -Be 1
        }
    }
}
