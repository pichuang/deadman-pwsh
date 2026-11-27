BeforeAll { . "$PSScriptRoot/../deadman.ps1" }

Describe 'Strict configuration parser' {
    It 'shares one parser for embedded text and optional files' {
        $text = "# comment`nlocal`t127.0.0.1`n---`ntcp ::1 via=tcp port=443`nhttp http://localhost:8080/a?x=1#fragment`nhttps https://example.com/ via=https ; # note"
        $path = Join-Path $TestDrive 'targets.conf'
        Set-Content -LiteralPath $path -Value $text -Encoding UTF8
        $fromText = Read-DeadmanConfig -Text $text -RttScale 20
        $fromFile = Read-DeadmanConfig -Path $path -RttScale 20
        $fromText.Count | Should -Be 5
        $fromFile.Count | Should -Be 5
        ($fromText[1] -is [Separator]) | Should -BeTrue
        $fromFile[2].TcpPort | Should -Be 443
        $fromFile[2].Address | Should -Be '::1'
        $fromFile[3].Protocol | Should -Be 'http'
        $fromFile[3].Address | Should -Be 'http://localhost:8080/a?x=1#fragment'
        $fromFile[4].Protocol | Should -Be 'https'
        foreach ($target in $fromFile) {
            if ($target -is [PingTarget]) { $target.RttScale | Should -Be 20 }
        }
    }

    It 'keeps the existing ICMP and via=tcp syntax' {
        $targets = Read-DeadmanConfig -Text "dns 8.8.8.8`nv6 2001:db8::1`nservice localhost via=tcp port=65535"
        $targets[0].Protocol | Should -Be 'icmp'
        $targets[1].Address | Should -Be '2001:db8::1'
        $targets[2].TcpPort | Should -Be 65535
    }

    It 'rejects malformed or unsupported settings with source and line context: <Line>' -TestCases @(
        @{ Line = 'host' }
        @{ Line = 'host localhost source=eth0' }
        @{ Line = 'host localhost via=ssh' }
        @{ Line = 'host localhost via=snmp' }
        @{ Line = 'host localhost netns=ns' }
        @{ Line = 'host localhost vrf=blue' }
        @{ Line = 'host localhost relay=other' }
        @{ Line = 'host localhost via=tcp' }
        @{ Line = 'host localhost via=tcp port=0' }
        @{ Line = 'host localhost via=tcp port=65536' }
        @{ Line = 'host localhost via=tcp port=abc' }
        @{ Line = 'host localhost port=443' }
        @{ Line = 'host localhost via=tcp port=80 port=443' }
        @{ Line = 'host localhost via=' }
        @{ Line = 'host localhost garbage' }
        @{ Line = 'host https://example.com via=icmp' }
        @{ Line = 'host http://example.com via=https' }
        @{ Line = 'host example.com via=http' }
        @{ Line = 'host http://example.com:99999/' }
        @{ Line = 'host http://example.com:0/' }
        @{ Line = 'host http://user:password@example.com/' }
        @{ Line = 'host http://example.com/ port=80' }
        @{ Line = 'host https:///' }
        @{ Line = 'host ftp://example.com/' }
        @{ Line = 'host 999.1.1.1' }
        @{ Line = '../escape localhost' }
        @{ Line = 'NUL localhost' }
        @{ Line = 'COM1.log localhost' }
        @{ Line = 'host. localhost' }
    ) {
        param($Line)
        $text = "# header`n$Line"
        { Read-DeadmanConfig -Text $text } | Should -Throw '*EmbeddedConfig:2:*'
    }

    It 'rejects duplicates and configurations with no real targets' {
        { Read-DeadmanConfig -Text "same localhost`nSAME ::1" } | Should -Throw '*Duplicate target name*'
        foreach ($text in @('', '# comment', "---`n---")) {
            { Read-DeadmanConfig -Text $text } | Should -Throw '*No monitoring targets*'
        }
    }

    It 'reports external file context and missing files as errors' {
        $path = Join-Path $TestDrive 'bad.conf'
        Set-Content -LiteralPath $path -Value "# comment`nhost localhost via=ssh"
        { Read-DeadmanConfig -Path $path } | Should -Throw '*bad.conf:2:*'
        { Read-DeadmanConfig -Path (Join-Path $TestDrive 'missing.conf') } | Should -Throw
    }
}
