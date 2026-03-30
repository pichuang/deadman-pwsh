# -*- coding: utf-8 -*-
# ConfigParser.Tests.ps1 — Unit tests for configuration file parsing function
# Uses Pester 5 test framework

BeforeAll {
    # Load class and function definitions from the single-file script
    . "$PSScriptRoot/../deadman.ps1"

    # Helper function — create a temporary config file and return its path
    function New-TempConfig {
        param([string]$Content)
        $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "deadman-test-$(New-Guid).conf"
        Set-Content -Path $tempFile -Value $Content -Encoding UTF8
        return $tempFile
    }
}

Describe 'Read-DeadmanConfig' {

    AfterEach {
        # Clean up temporary config files
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'deadman-test-*.conf' |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # ========================================================
    # Basic functionality tests
    # ========================================================

    Context 'Basic line parsing' {

        It 'Should correctly parse name and address' {
            # Prepare: create a config file with two targets
            $config = New-TempConfig -Content @"
googleDNS   8.8.8.8
quad9       9.9.9.9
"@
            $result = Read-DeadmanConfig -Path $config

            # Verify: should return two PingTarget objects
            $result.Count | Should -Be 2
            $result[0].GetType().Name | Should -Be 'PingTarget'
            $result[0].Name | Should -Be 'googleDNS'
            $result[0].Address | Should -Be '8.8.8.8'
            $result[1].Name | Should -Be 'quad9'
            $result[1].Address | Should -Be '9.9.9.9'
        }

        It 'Should correctly handle tab-delimited lines' {
            $config = New-TempConfig -Content "google`t8.8.8.8"
            $result = Read-DeadmanConfig -Path $config

            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'google'
            $result[0].Address | Should -Be '8.8.8.8'
        }

        It 'Should correctly handle lines with multiple spaces' {
            $config = New-TempConfig -Content "google     8.8.8.8"
            $result = Read-DeadmanConfig -Path $config

            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'google'
            $result[0].Address | Should -Be '8.8.8.8'
        }
    }

    # ========================================================
    # Option parsing tests
    # ========================================================

    Context 'Option parsing' {

        It 'Should correctly parse the source option' {
            $config = New-TempConfig -Content "myhost 192.168.1.1 source=eth0"
            $result = Read-DeadmanConfig -Path $config

            $result[0].Source | Should -Be 'eth0'
        }

        It 'Should ignore unsupported options without errors' {
            # relay, os options are not used in this version but should not cause errors
            $config = New-TempConfig -Content "myhost 8.8.8.8 relay=10.0.0.1 os=Linux via=ssh"
            $result = Read-DeadmanConfig -Path $config

            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'myhost'
            $result[0].Address | Should -Be '8.8.8.8'
        }

        It 'Should correctly parse via=tcp and port options' {
            $config = New-TempConfig -Content "webhost 10.0.0.1 via=tcp port=443"
            $result = Read-DeadmanConfig -Path $config

            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'webhost'
            $result[0].Address | Should -Be '10.0.0.1'
            $result[0].TcpPort | Should -Be 443
        }

        It 'Should not set TcpPort when via is not tcp' {
            $config = New-TempConfig -Content "myhost 10.0.0.1 via=snmp port=161"
            $result = Read-DeadmanConfig -Path $config

            $result[0].TcpPort | Should -Be 0
        }

        It 'Should not set TcpPort when port is missing' {
            $config = New-TempConfig -Content "myhost 10.0.0.1 via=tcp"
            $result = Read-DeadmanConfig -Path $config

            $result[0].TcpPort | Should -Be 0
        }

        It 'Should parse via=tcp with source option together' {
            $config = New-TempConfig -Content "webhost 10.0.0.1 source=eth0 via=tcp port=80"
            $result = Read-DeadmanConfig -Path $config

            $result[0].Source | Should -Be 'eth0'
            $result[0].TcpPort | Should -Be 80
        }
    }

    # ========================================================
    # Comment and blank line tests
    # ========================================================

    Context 'Comment and blank line handling' {

        It 'Should ignore lines starting with #' {
            $config = New-TempConfig -Content @"
# This is a comment
googleDNS   8.8.8.8
# Another comment
"@
            $result = Read-DeadmanConfig -Path $config

            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'googleDNS'
        }

        It 'Should ignore empty lines' {
            $config = New-TempConfig -Content @"
googleDNS   8.8.8.8

quad9       9.9.9.9

"@
            $result = Read-DeadmanConfig -Path $config

            $result.Count | Should -Be 2
        }

        It 'Should ignore whitespace-only lines' {
            $config = New-TempConfig -Content "googleDNS   8.8.8.8`n   `n   "
            $result = Read-DeadmanConfig -Path $config

            $result.Count | Should -Be 1
        }
    }

    # ========================================================
    # Separator tests
    # ========================================================

    Context 'Separator handling' {

        It 'Should parse --- as a Separator object' {
            $config = New-TempConfig -Content @"
google  8.8.8.8
---
quad9   9.9.9.9
"@
            $result = Read-DeadmanConfig -Path $config

            $result.Count | Should -Be 3
            $result[0].GetType().Name | Should -Be 'PingTarget'
            $result[1].GetType().Name | Should -Be 'Separator'
            $result[2].GetType().Name | Should -Be 'PingTarget'
        }

        It 'Should support separators of different lengths' {
            $config = New-TempConfig -Content @"
google  8.8.8.8
-----
quad9   9.9.9.9
"@
            $result = Read-DeadmanConfig -Path $config

            $result[1].GetType().Name | Should -Be 'Separator'
        }
    }

    # ========================================================
    # RTT scale propagation tests
    # ========================================================

    Context 'RTT scale configuration' {

        It 'Should pass RttScale to each PingTarget' {
            $config = New-TempConfig -Content "google 8.8.8.8"
            $result = Read-DeadmanConfig -Path $config -RttScale 20

            $result[0].RttScale | Should -Be 20
        }

        It 'Default RttScale should be 10' {
            $config = New-TempConfig -Content "google 8.8.8.8"
            $result = Read-DeadmanConfig -Path $config

            $result[0].RttScale | Should -Be 10
        }
    }

    # ========================================================
    # Error handling tests
    # ========================================================

    Context 'Error handling' {

        It 'Should throw an exception when config file does not exist' {
            { Read-DeadmanConfig -Path '/nonexistent/path/deadman.conf' } |
                Should -Throw 'Configuration file not found*'
        }

        It 'Should produce a warning and skip lines missing the address field' {
            $config = New-TempConfig -Content @"
google
quad9   9.9.9.9
"@
            $result = Read-DeadmanConfig -Path $config -WarningAction SilentlyContinue

            # Only quad9 should be parsed successfully
            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'quad9'
        }
    }

    # ========================================================
    # Original config format compatibility tests
    # ========================================================

    Context 'Original config format compatibility' {

        It 'Should correctly parse a complete original format config file' {
            $config = New-TempConfig -Content @"
#
#	deadman config
#
googleDNS	8.8.8.8
quad9		9.9.9.9
mroot		202.12.27.33
---
kame6		2001:200:dff:fff1:216:3eff:feb1:44d7
"@
            $result = Read-DeadmanConfig -Path $config

            $result.Count | Should -Be 5
            $result[0].Name | Should -Be 'googleDNS'
            $result[0].Address | Should -Be '8.8.8.8'
            $result[3].GetType().Name | Should -Be 'Separator'
            $result[4].Name | Should -Be 'kame6'
            $result[4].Address | Should -Be '2001:200:dff:fff1:216:3eff:feb1:44d7'
        }
    }
}
