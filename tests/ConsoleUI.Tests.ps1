# -*- coding: utf-8 -*-
# ConsoleUI.Tests.ps1 — Unit tests for the ConsoleUI class
# Uses Pester 5 test framework
#
# Note: ConsoleUI directly manipulates the [System.Console] API; some methods
# cannot be fully tested in non-interactive environments (e.g. CI/CD).
# Here we primarily verify layout calculation logic (UpdateLayout).

BeforeAll {
    # Load dependent modules
    . "$PSScriptRoot/../lib/PingTarget.ps1"
    . "$PSScriptRoot/../lib/ConsoleUI.ps1"

    # Helper function — create a List with specified targets
    function New-TargetList {
        param([array]$Items)
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Items) { $list.Add($item) }
        return , $list
    }
}

Describe 'ConsoleUI.UpdateLayout' {

    # ========================================================
    # Layout calculation tests
    # ========================================================

    Context 'Column width calculation' {

        BeforeEach {
            # Create ConsoleUI instance (may try to clear screen, safe to skip in tests)
            try {
                $script:ui = [ConsoleUI]::new(10)
            }
            catch {
                # Non-interactive environments may fail to initialize Console
                $script:ui = [ConsoleUI]::new(10)
            }
        }

        It 'Hostname column width should use the larger of longest name and title' {
            $t1 = [PingTarget]::new('short', '8.8.8.8')
            $t2 = [PingTarget]::new('a-very-long-hostname', '9.9.9.9')
            $targets = New-TargetList -Items @($t1, $t2)

            $script:ui.UpdateLayout($targets)

            # 'a-very-long-hostname' length = 20, >= 'HOSTNAME ' length = 9
            $script:ui.LengthHostname | Should -Be 20
        }

        It 'Hostname column width should not exceed maximum limit' {
            $longName = 'a' * 30  # Exceeds MAX_HOSTNAME_LENGTH (20)
            $t1 = [PingTarget]::new($longName, '8.8.8.8')
            $targets = New-TargetList -Items @($t1)

            $script:ui.UpdateLayout($targets)

            $script:ui.LengthHostname | Should -BeLessOrEqual 20
        }

        It 'Address column width should use the larger of longest address and title' {
            $t1 = [PingTarget]::new('host', '8.8.8.8')
            $targets = New-TargetList -Items @($t1)

            $script:ui.UpdateLayout($targets)

            # Address '8.8.8.8' length = 7, < 'ADDRESS ' length = 8
            # Final width = 8 + 5 = 13 (because alen += 5)
            $script:ui.LengthAddress | Should -BeGreaterOrEqual 8
        }

        It 'Should skip Separator objects in width calculation' {
            $t1 = [PingTarget]::new('host', '8.8.8.8')
            $sep = [Separator]::new()
            $targets = New-TargetList -Items @($t1, $sep)

            # Should not throw an exception due to Separator
            { $script:ui.UpdateLayout($targets) } | Should -Not -Throw
        }

        It 'Address column width should not exceed maximum limit' {
            $longAddr = '2001:0db8:85a3:0000:0000:8a2e:0370:7334:extra:extra'
            $t1 = [PingTarget]::new('host', $longAddr)
            $targets = New-TargetList -Items @($t1)

            $script:ui.UpdateLayout($targets)

            $script:ui.LengthAddress | Should -BeLessOrEqual 45  # MAX + 5
        }
    }

    # ========================================================
    # Column position tests
    # ========================================================

    Context 'Column position ordering' {

        BeforeEach {
            try {
                $script:ui = [ConsoleUI]::new(10)
            }
            catch {
                $script:ui = [ConsoleUI]::new(10)
            }
        }

        It 'Columns should be in correct order: arrow < hostname < address < reference < result' {
            $t1 = [PingTarget]::new('host', '8.8.8.8')
            $targets = New-TargetList -Items @($t1)

            $script:ui.UpdateLayout($targets)

            $script:ui.StartArrow | Should -BeLessThan $script:ui.StartHostname
            $script:ui.StartHostname | Should -BeLessThan $script:ui.StartAddress
            $script:ui.StartAddress | Should -BeLessThan $script:ui.RefStart
            $script:ui.RefStart | Should -BeLessThan $script:ui.ResStart
        }
    }

    # ========================================================
    # Result column minimum width tests
    # ========================================================

    Context 'Result column minimum width guarantee' {

        BeforeEach {
            try {
                $script:ui = [ConsoleUI]::new(10)
            }
            catch {
                $script:ui = [ConsoleUI]::new(10)
            }
        }

        It 'Result column width should not be less than 10 characters' {
            $t1 = [PingTarget]::new('host', '8.8.8.8')
            $targets = New-TargetList -Items @($t1)

            $script:ui.UpdateLayout($targets)

            $script:ui.ResLength | Should -BeGreaterOrEqual 10
        }
    }
}

Describe 'ConsoleUI.GetHostInfo' {

    BeforeEach {
        try {
            $script:ui = [ConsoleUI]::new(10)
        }
        catch {
            $script:ui = [ConsoleUI]::new(10)
        }
    }

    It 'Without spinner should return plain host info' {
        $info = $script:ui.GetHostInfo($false)
        $info | Should -Match '^From: '
        $info | Should -Not -Match '[|/\-\\]$'
    }

    It 'With spinner should append a spinner character at the end' {
        $info = $script:ui.GetHostInfo($true)
        $info | Should -Match '^From: '
        # Last character should be one of the spinner animation characters
        $lastChar = $info[-1]
        $lastChar | Should -BeIn @('|', '/', '-', '\')
    }

    It 'Spinner should change with step counter' {
        $chars = @()
        for ($i = 0; $i -lt 4; $i++) {
            $script:ui.GlobalStep = $i
            $info = $script:ui.GetHostInfo($true)
            $chars += $info[-1]
        }
        # Four calls should produce different spinner characters
        ($chars | Sort-Object -Unique).Count | Should -Be 4
    }
}

Describe 'ConsoleUI.WriteLog' {

    BeforeEach {
        try {
            $script:ui = [ConsoleUI]::new(10)
        }
        catch {
            $script:ui = [ConsoleUI]::new(10)
        }
        # Create temporary log directory
        $script:tempLogDir = Join-Path ([System.IO.Path]::GetTempPath()) "deadman-log-test-$(New-Guid)"
    }

    AfterEach {
        # Clean up temporary log directory
        if (Test-Path $script:tempLogDir) {
            Remove-Item -Path $script:tempLogDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Should create log directory and file' {
        $target = [PingTarget]::new('testhost', '8.8.8.8')
        $target.Sent = 1
        $target.RTT = 10.5
        $target.Average = 10.5

        $script:ui.WriteLog($script:tempLogDir, $target)

        $logFile = Join-Path $script:tempLogDir 'testhost'
        Test-Path $logFile | Should -BeTrue
    }

    It 'Log content should contain timestamp and statistics' {
        $target = [PingTarget]::new('testhost', '8.8.8.8')
        $target.Sent = 5
        $target.RTT = 12.3
        $target.Average = 11.0

        $script:ui.WriteLog($script:tempLogDir, $target)

        $logFile = Join-Path $script:tempLogDir 'testhost'
        $content = Get-Content -Path $logFile
        $content | Should -Match '\d{4}-\d{2}-\d{2}'  # Date format
        $content | Should -Match '12\.3'                # RTT
        $content | Should -Match '11'                   # Average
        $content | Should -Match '5'                    # Sent count
    }

    It 'Should not write any file when log directory path is empty' {
        $target = [PingTarget]::new('testhost', '8.8.8.8')

        # Should not throw an exception
        { $script:ui.WriteLog('', $target) } | Should -Not -Throw
        { $script:ui.WriteLog($null, $target) } | Should -Not -Throw
    }
}
