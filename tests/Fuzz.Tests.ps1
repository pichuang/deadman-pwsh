# -*- coding: utf-8 -*-
# Fuzz testing for deadman.ps1 components
# Generates random/malicious inputs to test parser robustness

BeforeAll {
    . "$PSScriptRoot/../deadman.ps1"
}

Describe 'Fuzz: Read-DeadmanConfig parser' -Tag 'Fuzz' {

    BeforeAll {
        $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "deadman-fuzz-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
    }

    AfterAll {
        if ($script:tempDir -and (Test-Path $script:tempDir)) {
            Remove-Item -Path $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Should handle empty file without crashing' {
        $f = Join-Path $script:tempDir 'empty.conf'
        Set-Content -Path $f -Value '' -Encoding UTF8
        { Read-DeadmanConfig -Path $f } | Should -Not -Throw
    }

    It 'Should handle file with only comments' {
        $f = Join-Path $script:tempDir 'comments.conf'
        $lines = @('# comment1', '# comment2', '  # indented', '')
        Set-Content -Path $f -Value ($lines -join "`n") -Encoding UTF8
        { Read-DeadmanConfig -Path $f } | Should -Not -Throw
    }

    It 'Should handle file with only separators' {
        $f = Join-Path $script:tempDir 'separators.conf'
        $lines = @('---', '---', '---')
        Set-Content -Path $f -Value ($lines -join "`n") -Encoding UTF8
        { Read-DeadmanConfig -Path $f } | Should -Not -Throw
    }

    It 'Should handle extremely long hostnames without crashing' {
        $f = Join-Path $script:tempDir 'longname.conf'
        $longName = 'A' * 1000
        Set-Content -Path $f -Value "$longName 192.168.1.1" -Encoding UTF8
        { Read-DeadmanConfig -Path $f } | Should -Not -Throw
    }

    It 'Should handle extremely long addresses without crashing' {
        $f = Join-Path $script:tempDir 'longaddr.conf'
        $longAddr = '1' * 500
        Set-Content -Path $f -Value "host $longAddr" -Encoding UTF8
        { Read-DeadmanConfig -Path $f } | Should -Not -Throw
    }

    It 'Should handle special characters in hostname' {
        $f = Join-Path $script:tempDir 'special.conf'
        $lines = @(
            'host<script> 1.1.1.1',
            'host;rm -rf / 2.2.2.2',
            'host|whoami 3.3.3.3',
            'host`id` 4.4.4.4',
            'host$(calc) 5.5.5.5',
            'host&net user 6.6.6.6'
        )
        Set-Content -Path $f -Value ($lines -join "`n") -Encoding UTF8
        { Read-DeadmanConfig -Path $f } | Should -Not -Throw
    }

    It 'Should handle null bytes and control characters' {
        $f = Join-Path $script:tempDir 'nullbytes.conf'
        $content = "host1`0 1.1.1.1`nhost2 2.2.2.2"
        Set-Content -Path $f -Value $content -Encoding UTF8
        { Read-DeadmanConfig -Path $f } | Should -Not -Throw
    }

    It 'Should handle Unicode and emoji in hostnames' {
        $f = Join-Path $script:tempDir 'unicode.conf'
        $lines = @(
            "host-日本語 1.1.1.1",
            "host-émojis 2.2.2.2",
            "host-中文 3.3.3.3"
        )
        Set-Content -Path $f -Value ($lines -join "`n") -Encoding UTF8
        { Read-DeadmanConfig -Path $f } | Should -Not -Throw
    }

    It 'Should handle malformed option strings' {
        $f = Join-Path $script:tempDir 'badopts.conf'
        $lines = @(
            'host1 1.1.1.1 via=',
            'host2 2.2.2.2 port=abc',
            'host3 3.3.3.3 via=tcp port=-1',
            'host4 4.4.4.4 via=tcp port=99999',
            'host5 5.5.5.5 source=',
            'host6 6.6.6.6 =invalid',
            'host7 7.7.7.7 key=value=extra'
        )
        Set-Content -Path $f -Value ($lines -join "`n") -Encoding UTF8
        { Read-DeadmanConfig -Path $f } | Should -Not -Throw
    }

    It 'Should handle lines with excessive whitespace' {
        $f = Join-Path $script:tempDir 'whitespace.conf'
        $lines = @(
            ('  ' * 100 + 'host1 1.1.1.1'),
            ("host2`t`t`t`t`t`t`t`t`t`t2.2.2.2"),
            ('host3     ' + (' ' * 200) + '3.3.3.3')
        )
        Set-Content -Path $f -Value ($lines -join "`n") -Encoding UTF8
        { Read-DeadmanConfig -Path $f } | Should -Not -Throw
    }

    It 'Should handle 1000 random entries without crashing' {
        $f = Join-Path $script:tempDir 'bulk.conf'
        $random = [System.Random]::new(42)
        $lines = @()
        for ($i = 0; $i -lt 1000; $i++) {
            $name = "host$i"
            $addr = "$($random.Next(1,255)).$($random.Next(0,255)).$($random.Next(0,255)).$($random.Next(1,254))"
            $lines += "$name $addr"
        }
        Set-Content -Path $f -Value ($lines -join "`n") -Encoding UTF8
        $result = Read-DeadmanConfig -Path $f
        ($result | Where-Object { $_ -is [PingTarget] }).Count | Should -Be 1000
    }

    It 'Should handle path traversal attempts in options' {
        $f = Join-Path $script:tempDir 'traversal.conf'
        $lines = @(
            'host1 1.1.1.1 source=../../etc/passwd',
            'host2 2.2.2.2 source=..\..\windows\system32',
            'host3 3.3.3.3 source=/dev/null'
        )
        Set-Content -Path $f -Value ($lines -join "`n") -Encoding UTF8
        { Read-DeadmanConfig -Path $f } | Should -Not -Throw
    }
}

Describe 'Fuzz: PingTarget robustness' -Tag 'Fuzz' {

    It 'Should handle creation with empty strings' {
        { [PingTarget]::new('', '') } | Should -Not -Throw
    }

    It 'Should handle creation with very long strings' {
        $longStr = 'A' * 10000
        { [PingTarget]::new($longStr, $longStr) } | Should -Not -Throw
    }

    It 'Should handle GetResultChar with extreme RTT values' {
        $target = [PingTarget]::new('test', '1.1.1.1')
        $target.RttScale = 10

        # Extreme positive
        $res = [PingResult]::new()
        $res.Success = $true
        $res.ErrorCode = [PingErrorCode]::Success
        $res.RTT = [double]::MaxValue
        $res.TTL = 64
        { $target.GetResultChar($res) } | Should -Not -Throw

        # Zero RTT
        $res.RTT = 0
        { $target.GetResultChar($res) } | Should -Not -Throw

        # Negative RTT
        $res.RTT = -1
        { $target.GetResultChar($res) } | Should -Not -Throw
    }

    It 'Should handle ConsumeResult with zero Sent count edge case' {
        $target = [PingTarget]::new('test', '1.1.1.1')
        $res = [PingResult]::new()
        $res.Success = $true
        $res.ErrorCode = [PingErrorCode]::Success
        $res.RTT = 10
        $res.TTL = 64
        $target.Sent = 0
        { $target.ConsumeResult($res) } | Should -Not -Throw
    }

    It 'Should handle rapid Refresh cycles' {
        $target = [PingTarget]::new('test', '1.1.1.1')
        for ($i = 0; $i -lt 100; $i++) {
            $res = [PingResult]::new()
            $res.Success = ($i % 2 -eq 0)
            if ($res.Success) {
                $res.ErrorCode = [PingErrorCode]::Success
                $res.RTT = [double]($i * 5)
                $res.TTL = 64
            }
            $target.Sent++
            $target.ConsumeResult($res)
        }
        { $target.Refresh() } | Should -Not -Throw
        $target.Sent | Should -Be 0
        $target.Loss | Should -Be 0
    }

    It 'Should handle RttScale of zero without division by zero' {
        $target = [PingTarget]::new('test', '1.1.1.1')
        $target.RttScale = 0
        $res = [PingResult]::new()
        $res.Success = $true
        $res.ErrorCode = [PingErrorCode]::Success
        $res.RTT = 10
        $res.TTL = 64
        { $target.GetResultChar($res) } | Should -Not -Throw
    }

    It 'Should handle RttScale of negative value' {
        $target = [PingTarget]::new('test', '1.1.1.1')
        $target.RttScale = -10
        $res = [PingResult]::new()
        $res.Success = $true
        $res.ErrorCode = [PingErrorCode]::Success
        $res.RTT = 10
        $res.TTL = 64
        { $target.GetResultChar($res) } | Should -Not -Throw
    }
}

Describe 'Fuzz: Random config generation' -Tag 'Fuzz' {

    BeforeAll {
        $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "deadman-fuzz-rand-$(New-Guid)"
        New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
    }

    AfterAll {
        if ($script:tempDir -and (Test-Path $script:tempDir)) {
            Remove-Item -Path $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Should survive 100 random config files' {
        $random = [System.Random]::new(12345)
        $chars = 'abcdefghijklmnopqrstuvwxyz0123456789.-_/\:;#= '
        $crashed = 0

        for ($round = 0; $round -lt 100; $round++) {
            $f = Join-Path $script:tempDir "rand_$round.conf"
            $lineCount = $random.Next(1, 20)
            $lines = @()
            for ($l = 0; $l -lt $lineCount; $l++) {
                $len = $random.Next(0, 100)
                $line = ''
                for ($c = 0; $c -lt $len; $c++) {
                    $line += $chars[$random.Next(0, $chars.Length)]
                }
                $lines += $line
            }
            Set-Content -Path $f -Value ($lines -join "`n") -Encoding UTF8
            try {
                $null = Read-DeadmanConfig -Path $f -ErrorAction SilentlyContinue 3>$null
            }
            catch {
                $crashed++
            }
        }
        $crashed | Should -Be 0
    }
}
