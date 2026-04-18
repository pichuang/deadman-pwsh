# -*- coding: utf-8 -*-
# WindowsCompat.Tests.ps1 — Windows compatibility and cross-version tests
# Uses Pester 5 test framework
#
# Validates that deadman.ps1 works correctly on Windows with both
# PowerShell 5.1 and PowerShell 7+, including Unicode/ASCII fallback behavior.

BeforeAll {
    # Load class and function definitions from the single-file script
    . "$PSScriptRoot/../deadman.ps1"
}

Describe 'PowerShell version compatibility' {

    It 'Should be running PowerShell 5.1 or later' {
        $PSVersionTable.PSVersion.Major | Should -BeGreaterOrEqual 5
        if ($PSVersionTable.PSVersion.Major -eq 5) {
            $PSVersionTable.PSVersion.Minor | Should -BeGreaterOrEqual 1
        }
    }

    It 'Test-IsWindows function should exist' {
        Get-Command -Name Test-IsWindows -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'Test-IsWindows should return boolean' {
        (Test-IsWindows) | Should -BeOfType [bool]
    }

    It 'Test-UnicodeSupport function should exist' {
        Get-Command -Name Test-UnicodeSupport -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'Test-UnicodeSupport should return boolean' {
        (Test-UnicodeSupport) | Should -BeOfType [bool]
    }
}

Describe 'Platform detection' {

    Context 'Windows platform' -Tag 'WindowsOnly' {

        It 'Test-IsWindows should return $true on Windows' {
            if (-not (Test-IsWindows)) {
                Set-ItResult -Skipped -Because 'Not running on Windows'
            }
            Test-IsWindows | Should -BeTrue
        }

        It 'Test-NetConnection should be available on Windows' {
            if (-not (Test-IsWindows)) {
                Set-ItResult -Skipped -Because 'Not running on Windows'
            }
            Get-Command -Name Test-NetConnection -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Unicode block element characters' {

    Context 'Character validity' {

        It 'All Unicode block element code points should produce valid chars' {
            $codePoints = @(0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, 0x2588)
            foreach ($cp in $codePoints) {
                $ch = [char]$cp
                $ch | Should -Not -BeNullOrEmpty
                $ch.ToString().Length | Should -Be 1
            }
        }

        It 'Unicode block characters should be distinct from each other' {
            $chars = @(
                [char]0x2581, [char]0x2582, [char]0x2583, [char]0x2584,
                [char]0x2585, [char]0x2586, [char]0x2587, [char]0x2588
            )
            ($chars | Sort-Object -Unique).Count | Should -Be 8
        }
    }
}

Describe 'ASCII fallback characters' {

    Context 'GetResultChar with ASCII mode' {

        BeforeEach {
            $script:target = [PingTarget]::new('test', '8.8.8.8')
            $script:target.RttScale = 10
        }

        It 'Should return X on failure regardless of mode' {
            $savedMode = $script:UseAsciiChars
            try {
                $script:UseAsciiChars = $true
                $res = [PingResult]::new($false, [PingErrorCode]::Failed, 0, 0)
                $script:target.GetResultChar($res) | Should -Be 'X'
            } finally {
                $script:UseAsciiChars = $savedMode
            }
        }

        It 'ASCII mode should return single-character strings for all RTT ranges' {
            $savedMode = $script:UseAsciiChars
            try {
                $script:UseAsciiChars = $true
                $rttValues = @(5, 15, 25, 35, 45, 55, 65, 80)
                foreach ($rtt in $rttValues) {
                    $res = [PingResult]::new($true, [PingErrorCode]::Success, $rtt, 64)
                    $ch = $script:target.GetResultChar($res)
                    $ch.Length | Should -Be 1 -Because "RTT=$rtt should produce a single character"
                }
            } finally {
                $script:UseAsciiChars = $savedMode
            }
        }

        It 'ASCII fallback characters should be distinct for each RTT range' {
            $savedMode = $script:UseAsciiChars
            try {
                $script:UseAsciiChars = $true
                $chars = @()
                $rttValues = @(5, 15, 25, 35, 45, 55, 65, 80)
                foreach ($rtt in $rttValues) {
                    $res = [PingResult]::new($true, [PingErrorCode]::Success, $rtt, 64)
                    $chars += $script:target.GetResultChar($res)
                }
                ($chars | Sort-Object -Unique).Count | Should -Be 8
            } finally {
                $script:UseAsciiChars = $savedMode
            }
        }

        It 'ASCII fallback characters should all be printable ASCII (0x20-0x7E)' {
            $savedMode = $script:UseAsciiChars
            try {
                $script:UseAsciiChars = $true
                $rttValues = @(5, 15, 25, 35, 45, 55, 65, 80)
                foreach ($rtt in $rttValues) {
                    $res = [PingResult]::new($true, [PingErrorCode]::Success, $rtt, 64)
                    $ch = $script:target.GetResultChar($res)
                    $code = [int][char]$ch
                    $code | Should -BeGreaterOrEqual 0x20 -Because "RTT=$rtt char should be printable ASCII"
                    $code | Should -BeLessOrEqual 0x7E -Because "RTT=$rtt char should be printable ASCII"
                }
            } finally {
                $script:UseAsciiChars = $savedMode
            }
        }

        It 'Unicode mode should return Unicode block elements' {
            $savedMode = $script:UseAsciiChars
            try {
                $script:UseAsciiChars = $false
                $res = [PingResult]::new($true, [PingErrorCode]::Success, 5, 64)
                $ch = $script:target.GetResultChar($res)
                [int][char]$ch | Should -Be 0x2581
            } finally {
                $script:UseAsciiChars = $savedMode
            }
        }
    }
}

Describe 'Test-Connection compatibility' {

    It 'Test-Connection cmdlet should be available' {
        Get-Command -Name Test-Connection -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    Context 'Version-appropriate parameters' {

        It 'PS 7+ should support -TargetName parameter' {
            if ($PSVersionTable.PSVersion.Major -lt 7) {
                Set-ItResult -Skipped -Because 'PowerShell 7+ only'
            }
            $params = (Get-Command Test-Connection).Parameters
            $params.ContainsKey('TargetName') | Should -BeTrue
        }

        It 'PS 5.1 should support -ComputerName parameter' {
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                Set-ItResult -Skipped -Because 'PowerShell 5.1 only'
            }
            $params = (Get-Command Test-Connection).Parameters
            $params.ContainsKey('ComputerName') | Should -BeTrue
        }
    }
}

Describe 'Console encoding' {

    It 'Console OutputEncoding should be accessible' {
        { [Console]::OutputEncoding } | Should -Not -Throw
    }

    It 'On Windows, OutputEncoding should be set to UTF-8 after script load' {
        if (-not (Test-IsWindows)) {
            Set-ItResult -Skipped -Because 'Not running on Windows'
        }
        [Console]::OutputEncoding.WebName | Should -Be 'utf-8'
    }
}

Describe 'Class definitions compatibility' {

    It 'PingErrorCode enum should be defined' {
        { [PingErrorCode]::Success } | Should -Not -Throw
        { [PingErrorCode]::Failed } | Should -Not -Throw
    }

    It 'PingResult class should be constructable' {
        { [PingResult]::new() } | Should -Not -Throw
        { [PingResult]::new($true, [PingErrorCode]::Success, 10.0, 64) } | Should -Not -Throw
    }

    It 'PingTarget class should be constructable' {
        { [PingTarget]::new('test', '8.8.8.8') } | Should -Not -Throw
        { [PingTarget]::new('test', '8.8.8.8', 'eth0') } | Should -Not -Throw
    }

    It 'Separator class should be constructable' {
        { [Separator]::new() } | Should -Not -Throw
    }

    It 'Generic List should work for ResultHistory' {
        $target = [PingTarget]::new('test', '8.8.8.8')
        ($null -ne $target.ResultHistory) | Should -BeTrue
        $target.ResultHistory.GetType().Name | Should -Match 'List'
    }
}
