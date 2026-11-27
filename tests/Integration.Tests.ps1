[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester BeforeEach variables are consumed in It blocks.')]
param()

BeforeAll {
    . "$PSScriptRoot/../pingpongman.ps1"

    function Wait-TestProbe {
        param($Entry, [scriptblock]$Serve)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $Entry.Done -and $watch.Elapsed.TotalSeconds -lt 20) {
            if ($Serve) { & $Serve }
            Update-Probe $Entry
            Start-Sleep -Milliseconds 5
        }
        $Entry.Done | Should -BeTrue
    }

    function New-TestPending {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates deterministic in-memory test state.')]
        param([PingTarget]$Target, [string]$Phase = 'dns', [double]$TimeoutMs = 1000)
        $completion = [System.Threading.Tasks.TaskCompletionSource[object]]::new()
        $entry = [pscustomobject]@{
            Target = $Target; Clock = [Diagnostics.Stopwatch]::StartNew(); TimeoutMs = $TimeoutMs
            Task = $completion.Task; Phase = $Phase; Client = $null; Request = $null
            Cancellation = $null; Ping = $null; Done = $false; Result = $null
            Disposed = $false; Addresses = @(); AddressIndex = 0; Completion = $completion
        }
        $Target.Pending = $entry
        return $entry
    }
}

Describe 'Native asynchronous probe lifecycle' {
    BeforeEach {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $clients = [System.Collections.Generic.List[object]]::new()
    }
    AfterEach {
        foreach ($client in $clients) { $client.Dispose() }
        $listener.Stop()
    }
    It 'receives an IPv4 echo reply in an environment permitting ICMP' -Tag Network {
        $target = (Read-PingPongManConfig -Text 'loopback 127.0.0.1')[0]
        $entry = New-Probe $target
        Wait-TestProbe $entry
        $entry.Result.Success | Should -BeTrue
        $entry.Result.RTT | Should -BeGreaterOrEqual 0
    }
    It 'connects TCP over loopback and counts exactly once' {
        $target = (Read-PingPongManConfig -Text "local 127.0.0.1 via=tcp port=$port")[0]
        $entry = New-Probe $target
        Wait-TestProbe $entry
        $entry.Result.Success | Should -BeTrue
        $target.ConsumeResult($entry.Result)
        Update-Probe $entry
        $target.Sent | Should -Be 1
        $target.Pending | Should -BeNullOrEmpty
        $entry.Disposed | Should -BeTrue
    }
    It 'returns HTTP status after headers without waiting for the body: <Status>' -TestCases @(
        @{ Status = 200; Expected = $true }
        @{ Status = 302; Expected = $true }
        @{ Status = 404; Expected = $false }
        @{ Status = 503; Expected = $false }
    ) {
        param($Status, $Expected)
        $target = (Read-PingPongManConfig -Text "local http://127.0.0.1:$port/test")[0]
        $entry = New-Probe $target -TimeoutSeconds 2
        $accepted = $listener.AcceptTcpClientAsync()
        $request = [System.Text.StringBuilder]::new()
        $server = {
            if ($accepted.IsCompleted -and $clients.Count -eq 0) { $clients.Add($accepted.Result) }
            if ($clients.Count -gt 0) {
                $stream = $clients[0].GetStream()
                if ($stream.DataAvailable) {
                    $buffer = New-Object byte[] 4096
                    $count = $stream.Read($buffer, 0, $buffer.Length)
                    $null = $request.Append([Text.Encoding]::ASCII.GetString($buffer, 0, $count))
                    if ($request.ToString().Contains("`r`n`r`n")) {
                        # Intentionally omit the advertised response body.
                        $bytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $Status Test`r`nContent-Length: 100000`r`nConnection: close`r`n`r`n")
                        $stream.Write($bytes, 0, $bytes.Length)
                        $request.Clear() | Out-Null
                    }
                }
            }
        }
        Wait-TestProbe $entry $server
        $entry.Result.Success | Should -Be $Expected
        $entry.Result.StatusCode | Should -Be $Status
        $entry.Result.Detail | Should -Be "HTTP $Status"
        $entry.Clock.Elapsed.TotalSeconds | Should -BeLessThan 2
        $entry.Disposed | Should -BeTrue
        $target.Pending | Should -BeNullOrEmpty
    }
    It 'follows a redirect and measures through final headers' {
        $entry = New-Probe ((Read-PingPongManConfig -Text "local http://127.0.0.1:$port/start")[0]) -TimeoutSeconds 3
        $paths = [System.Collections.Generic.List[string]]::new()
        $server = {
            if ($listener.Pending()) {
                $client = $listener.AcceptTcpClient()
                $clients.Add($client)
            }
            foreach ($client in $clients) {
                $stream = $client.GetStream()
                if ($stream.DataAvailable) {
                    $buffer = New-Object byte[] 4096
                    $count = $stream.Read($buffer, 0, $buffer.Length)
                    $request = [Text.Encoding]::ASCII.GetString($buffer, 0, $count)
                    if ($request -match '^GET (/[^ ]*) ') {
                        $paths.Add($Matches[1])
                        if ($Matches[1] -eq '/start') {
                            $response = "HTTP/1.1 302 Found`r`nLocation: /final`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
                        } else {
                            Start-Sleep -Milliseconds 80
                            $response = "HTTP/1.1 204 No Content`r`nConnection: close`r`n`r`n"
                        }
                        $bytes = [Text.Encoding]::ASCII.GetBytes($response)
                        $stream.Write($bytes, 0, $bytes.Length)
                    }
                }
            }
        }
        Wait-TestProbe $entry $server
        $entry.Result.Success | Should -BeTrue
        $entry.Result.StatusCode | Should -Be 204
        $entry.Result.RTT | Should -BeGreaterOrEqual 80
        ($paths -join ',') | Should -Be '/start,/final'
    }
    It 'bounds redirect loops' {
        $entry = New-Probe ((Read-PingPongManConfig -Text "local http://127.0.0.1:$port/loop")[0]) -TimeoutSeconds 3
        $requests = [System.Collections.Generic.List[string]]::new()
        $server = {
            if ($listener.Pending()) { $clients.Add($listener.AcceptTcpClient()) }
            foreach ($client in $clients) {
                $stream = $client.GetStream()
                if ($stream.DataAvailable) {
                    $buffer = New-Object byte[] 4096
                    $count = $stream.Read($buffer, 0, $buffer.Length)
                    $requests.Add([Text.Encoding]::ASCII.GetString($buffer, 0, $count))
                    $bytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 302 Found`r`nLocation: /loop`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                    $stream.Write($bytes, 0, $bytes.Length)
                }
            }
        }
        Wait-TestProbe $entry $server
        $requests.Count | Should -BeLessOrEqual 6
        $requests.Count | Should -BeGreaterThan 1
        # Runtimes either return the final 302 or reject excessive redirects.
        if ($entry.Result.Success) { $entry.Result.StatusCode | Should -Be 302 }
        else { $entry.Result.Detail | Should -Not -BeNullOrEmpty }
    }
    It 'times out an HTTP server that sends no headers and disposes resources' {
        $target = (Read-PingPongManConfig -Text "local http://127.0.0.1:$port/")[0]
        $entry = New-Probe $target -TimeoutSeconds 0.15
        Wait-TestProbe $entry
        $entry.Result.Success | Should -BeFalse
        $entry.Clock.Elapsed.TotalMilliseconds | Should -BeLessThan 1500
        $entry.Disposed | Should -BeTrue
        if ($target.Pending) { Wait-TestProbe $entry; $null = Clear-ProbeTask $entry }
    }
    It 'rejects an untrusted HTTPS certificate without modifying global TLS policy' {
        $savedProtocol = [System.Net.ServicePointManager]::SecurityProtocol
        $savedCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        $rsa = $null
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new(2048)
        } else {
            $rsa = [System.Security.Cryptography.RSA]::Create()
            $rsa.KeySize = 2048
        }
        $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=localhost', $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $generated = $request.CreateSelfSigned([DateTimeOffset]::Now.AddMinutes(-1), [DateTimeOffset]::Now.AddMinutes(5))
        # Importing PFX gives Schannel an owned, accessible private key on Windows.
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $generated.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx),
            '', [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
        $generated.Dispose()
        $ssl = $null
        $authentication = $null
        try {
            $entry = New-Probe ((Read-PingPongManConfig -Text "local https://127.0.0.1:$port/")[0]) -TimeoutSeconds 15
            $server = {
                if ($listener.Pending() -and $clients.Count -eq 0) {
                    $clients.Add($listener.AcceptTcpClient())
                    $script:testSsl = [System.Net.Security.SslStream]::new($clients[0].GetStream(), $false)
                    $script:testAuthentication = $script:testSsl.AuthenticateAsServerAsync($certificate, $false,
                        [System.Security.Authentication.SslProtocols]::Tls12, $false)
                }
                if ($script:testAuthentication -and $script:testAuthentication.IsFaulted) {
                    $null = $script:testAuthentication.Exception
                    $script:testSsl.Dispose()
                }
            }
            Wait-TestProbe $entry $server
            $entry.Result.Success | Should -BeFalse
            $entry.Result.Detail | Should -Match 'certificate|SSL|TLS|trust|secure|authentication'
            [System.Net.ServicePointManager]::SecurityProtocol | Should -Be $savedProtocol
            [object]::ReferenceEquals([System.Net.ServicePointManager]::ServerCertificateValidationCallback, $savedCallback) | Should -BeTrue
        } finally {
            $ssl = $script:testSsl
            $authentication = $script:testAuthentication
            if ($ssl) { $ssl.Dispose() }
            if ($authentication -and $authentication.IsFaulted) { $null = $authentication.Exception }
            $certificate.Dispose()
            $rsa.Dispose()
            $script:testSsl = $null
            $script:testAuthentication = $null
        }
    }
}

Describe 'Independent completions and bounded cancellation' {
    It 'consumes ICMP replies and failure statuses with correct RTT and TTL' {
        foreach ($success in @($true, $false)) {
            $entry = New-TestPending ([PingTarget]::new('icmp', 'localhost')) -Phase icmp
            $status = [System.Net.NetworkInformation.IPStatus]::TimedOut
            if ($success) { $status = [System.Net.NetworkInformation.IPStatus]::Success }
            $entry.Completion.SetResult([pscustomobject]@{
                Status = $status; Options = [pscustomobject]@{ Ttl = 64 }; RoundtripTime = 23
            })
            Update-Probe $entry
            $entry.Result.Success | Should -Be $success
            if ($success) {
                $entry.Result.RTT | Should -Be 23
                $entry.Result.TTL | Should -Be 64
            } else {
                $entry.Result.Detail | Should -Be 'TimedOut'
                $entry.Result.RTT | Should -Be 0
            }
        }
    }
    It 'completes fast targets without waiting for unrelated slow ones' {
        $fast = New-TestPending ([PingTarget]::new('fast', 'localhost')) -Phase tcp
        $slow = New-TestPending ([PingTarget]::new('slow', 'localhost')) -TimeoutMs 100
        $fast.Completion.SetResult($null)
        Update-Probe $fast
        $fast.Result.Success | Should -BeTrue
        $duration = $fast.Result.RTT
        Wait-TestProbe $slow
        $slow.Result.Detail | Should -Be 'Timeout'
        $fast.Result.RTT | Should -Be $duration
        $fast.Clock.IsRunning | Should -BeFalse
        $slow.Done | Should -BeTrue
    }
    It 'retains at most one uncancellable DNS task per target until its late fault is observed' {
        $target = [PingTarget]::new('slow', 'localhost')
        $entry = New-TestPending $target -TimeoutMs 1
        Wait-TestProbe $entry
        $entry.Done | Should -BeTrue
        $entry.Result.Success | Should -BeFalse
        [object]::ReferenceEquals($target.Pending, $entry) | Should -BeTrue
        { New-Probe $target } | Should -Throw '*still finishing*'
        $entry.Completion.SetException([Exception]::new('late DNS failure'))
        Update-Probe $entry
        $target.Pending | Should -BeNullOrEmpty
        $entry.Result.Detail | Should -Be 'Timeout'
    }
    It 'disposes a late HTTP response after cancellation without a second result' {
        $target = [PingTarget]::new('late', 'http://localhost/')
        $entry = New-TestPending $target -Phase http -TimeoutMs 1
        Wait-TestProbe $entry
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::OK)
        $response.Content = [System.Net.Http.StringContent]::new('body')
        $entry.Completion.SetResult($response)
        Update-Probe $entry
        $target.Pending | Should -BeNullOrEmpty
        { $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() } | Should -Throw
        $entry.Result.Detail | Should -Be 'Timeout'
    }
    It 'retries another resolved TCP address after an individual connect failure' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $target = [PingTarget]::new('fallback', 'localhost')
            $target.Protocol = 'tcp'
            $target.TcpPort = $listener.LocalEndpoint.Port
            $entry = New-TestPending $target -Phase tcp
            $entry.Addresses = @([System.Net.IPAddress]::IPv6Loopback, [System.Net.IPAddress]::Loopback)
            $entry.Client = [System.Net.Sockets.TcpClient]::new()
            $entry.Completion.SetException([System.Net.Sockets.SocketException]::new())
            Update-Probe $entry
            Wait-TestProbe $entry
            $entry.Result.Success | Should -BeTrue
            $entry.AddressIndex | Should -Be 1
        } finally { $listener.Stop() }
    }
}

Describe 'Shared sequential and concurrent scheduler' {
    BeforeEach {
        Mock New-Probe {
            param($Target)
            New-TestPending $Target -Phase tcp
        }
        $targets = @(
            [PingTarget]::new('first', 'localhost'), [Separator]::new(),
            [PingTarget]::new('offscreen', 'localhost')
        )
    }
    It 'probes every target regardless of viewport in concurrent mode' {
        $ui = [ConsoleUI]::new()
        $ui.SetSize(80, 6, 3)
        $monitor = New-MonitorState $targets -Concurrent $true -IntervalSeconds 60
        Invoke-MonitorTick $monitor
        $monitor.Active.Count | Should -Be 2
        foreach ($entry in $monitor.Active) { $entry.Completion.SetResult($null) }
        Invoke-MonitorTick $monitor
        $targets[0].Sent | Should -Be 1
        $targets[2].Sent | Should -Be 1
        Invoke-MonitorTick $monitor
        Should -Invoke New-Probe -Times 2 -Exactly
    }
    It 'runs one target at a time in sequential mode' {
        $monitor = New-MonitorState $targets -Concurrent $false -IntervalSeconds 60
        Invoke-MonitorTick $monitor
        $monitor.Active.Count | Should -Be 1
        $monitor.Queue.Count | Should -Be 1
        $monitor.Active[0].Completion.SetResult($null)
        Invoke-MonitorTick $monitor
        Invoke-MonitorTick $monitor
        $monitor.Active[0].Target.Name | Should -Be 'offscreen'
        $monitor.Active[0].Completion.SetResult($null)
        Invoke-MonitorTick $monitor
        $targets[0].Sent | Should -Be 1
        $targets[2].Sent | Should -Be 1
    }
    It 'resets in-flight work without consuming old results or growing pending tasks' {
        $monitor = New-MonitorState $targets -Concurrent $true -IntervalSeconds 60
        Invoke-MonitorTick $monitor
        $old = @($monitor.Active.ToArray())
        Invoke-MonitorTick $monitor -Reset
        $monitor.Active.Count | Should -Be 0
        # A blocked, uncancellable operation gets a visible failure, never a new task.
        $targets[0].Sent | Should -Be 1
        $targets[0].Detail | Should -Be 'Previous probe still finishing'
        Should -Invoke New-Probe -Times 2 -Exactly
        foreach ($entry in $old) { $entry.Completion.SetResult($null) }
        Invoke-MonitorTick $monitor
        $targets[0].Pending | Should -BeNullOrEmpty
        $targets[0].State | Should -BeFalse
        Stop-MonitorProbe $monitor
    }
}

Describe 'Structured probe logs' {
    It 'records failure details and HTTP status in a safe per-target file' {
        $target = (Read-PingPongManConfig -Text 'web https://example.com/')[0]
        $result = [PingResult]::new()
        $result.StatusCode = 503
        $result.Detail = 'HTTP 503'
        $target.ConsumeResult($result)
        Write-ProbeLog $TestDrive $target
        $record = Get-Content -LiteralPath (Join-Path $TestDrive 'web.jsonl') | ConvertFrom-Json
        $record.Success | Should -BeFalse
        $record.StatusCode | Should -Be 503
        $record.Detail | Should -Be 'HTTP 503'
        $record.Sent | Should -Be 1
        $record.RTT | Should -Be 0
    }

    It 'surfaces logging failures' {
        $file = Join-Path $TestDrive 'not-a-directory'
        Set-Content -LiteralPath $file -Value 'test'
        { Write-ProbeLog $file ([PingTarget]::new('local', 'localhost')) } | Should -Throw
    }

}
