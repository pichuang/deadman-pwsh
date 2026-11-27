BeforeAll { . "$PSScriptRoot/../pingpongman.ps1" }

Describe 'Strict configuration parser' {
    It 'shares one parser for embedded text and optional files' {
        $text = "# comment`nlocal`t127.0.0.1`n---`ntcp ::1 via=tcp port=443`nhttp http://localhost:8080/a?x=1#fragment`nhttps https://example.com/ via=https ; # note"
        $path = Join-Path $TestDrive 'targets.conf'
        Set-Content -LiteralPath $path -Value $text -Encoding UTF8
        $fromText = Read-PingPongManConfig -Text $text -RttScale 20
        $fromFile = Read-PingPongManConfig -Path $path -RttScale 20
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
        $targets = Read-PingPongManConfig -Text "dns 8.8.8.8`nv6 2001:db8::1`nservice localhost via=tcp port=65535"
        $targets[0].Protocol | Should -Be 'icmp'
        $targets[1].Address | Should -Be '2001:db8::1'
        $targets[2].TcpPort | Should -Be 65535
    }

    It 'accepts the exact five-line Blackair configuration without renaming display names' {
        $text = @'
blackair-icmp  ifconfig.blackair.io
blackair-tcp   ifconfig.blackair.io          via=tcp port=443
blackair-http  http://ifconfig.blackair.io/ via=http port=80
blackair-https https://ifconfig.blackair.io/ via=https port=443
blackair-https https://ifconfig.blackair.io/ip via=https port=443
'@
        $targets = Read-PingPongManConfig -Text $text
        $targets.Count | Should -Be 5
        ($targets.Protocol -join ',') | Should -Be 'icmp,tcp,http,https,https'
        $targets[1].TcpPort | Should -Be 443
        $targets[3].Name | Should -Be 'blackair-https'
        $targets[4].Name | Should -Be 'blackair-https'
        $targets[3].Address | Should -Be 'https://ifconfig.blackair.io/'
        $targets[4].Address | Should -Be 'https://ifconfig.blackair.io/ip'
    }

    It 'applies HTTP port options without losing IPv6, escaped paths, query or fragment: <Url>' -TestCases @(
        @{ Url = 'http://example.com/a%2Fb?next=%2Fip#result'; Via = 'http'; Port = 8080; Expected = 'http://example.com:8080/a%2Fb?next=%2Fip#result' }
        @{ Url = 'https://[::1]/ip?q=a%2Bb'; Via = 'https'; Port = 8443; Expected = 'https://[::1]:8443/ip?q=a%2Bb' }
        @{ Url = 'http://[::1]:8080/ip'; Via = 'http'; Port = 8080; Expected = 'http://[::1]:8080/ip' }
        @{ Url = 'https://example.com:443/ip'; Via = 'https'; Port = 443; Expected = 'https://example.com:443/ip' }
    ) {
        param($Url, $Via, $Port, $Expected)
        $target = (Read-PingPongManConfig -Text "web $Url via=$Via port=$Port")[0]
        $actualUri = [Uri]$target.Address
        $expectedUri = [Uri]$Expected
        $actualUri.Scheme | Should -Be $expectedUri.Scheme
        $actualUri.Host | Should -Be $expectedUri.Host
        $actualUri.Port | Should -Be $Port
        $actualUri.PathAndQuery | Should -Be $expectedUri.PathAndQuery
        $actualUri.Fragment | Should -Be $expectedUri.Fragment
    }

    It 'keeps duplicate display names independent and avoids case-insensitive log filename collisions' {
        $targets = Read-PingPongManConfig -Text "same http://localhost/`nSAME http://localhost/ip`n---`nsame-2 ::1`nsame http://localhost/other"
        ($targets | Where-Object { $_ -is [PingTarget] }).Count | Should -Be 4
        $targets[0].LogName | Should -Be 'same'
        $targets[1].LogName | Should -Be 'SAME-3'
        $targets[3].LogName | Should -Be 'same-2'
        $targets[4].LogName | Should -Be 'same-4'
        $result = [PingResult]::new()
        $targets[1].ConsumeResult($result)
        $targets[1].Loss | Should -Be 1
        $targets[0].Sent | Should -Be 0
        $targets[4].ResultHistory.Count | Should -Be 0
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
        @{ Line = 'host http://example.com/ port=0' }
        @{ Line = 'host https://example.com/ port=65536' }
        @{ Line = 'host http://example.com/ port=abc' }
        @{ Line = 'host http://example.com:8080/ip port=80' }
        @{ Line = 'host http://example.com:80/ip port=8080' }
        @{ Line = 'host https://example.com:443/ip port=8443' }
        @{ Line = 'host https://[::1]:8443/ip port=443' }
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
        { Read-PingPongManConfig -Text $text } | Should -Throw '*EmbeddedConfig:2:*'
    }

    It 'rejects configurations with no real targets' {
        foreach ($text in @('', '# comment', "---`n---")) {
            { Read-PingPongManConfig -Text $text } | Should -Throw '*No monitoring targets*'
        }
    }

    It 'reports external file context and missing files as errors' {
        $path = Join-Path $TestDrive 'bad.conf'
        Set-Content -LiteralPath $path -Value "# comment`nhost localhost via=ssh"
        { Read-PingPongManConfig -Path $path } | Should -Throw '*bad.conf:2:*'
        { Read-PingPongManConfig -Path (Join-Path $TestDrive 'missing.conf') } | Should -Throw
    }
}
