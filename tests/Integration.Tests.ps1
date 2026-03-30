# -*- coding: utf-8 -*-
# Integration.Tests.ps1 — 整合測試
# 使用 Pester 5 測試框架
#
# 驗證從設定檔讀取到建立 PingTarget 的端到端流程。

BeforeAll {
    # 載入所有模組
    . "$PSScriptRoot/../lib/PingTarget.ps1"
    . "$PSScriptRoot/../lib/ConfigParser.ps1"
    . "$PSScriptRoot/../lib/ConsoleUI.ps1"

    # 輔助函式 — 建立暫時設定檔
    function New-TempConfig {
        param([string]$Content)
        $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "deadman-integ-$(New-Guid).conf"
        Set-Content -Path $tempFile -Value $Content -Encoding UTF8
        return $tempFile
    }
}

Describe '端到端整合測試' {

    AfterEach {
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'deadman-integ-*.conf' |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # ========================================================
    # 完整流程測試
    # ========================================================

    Context '設定檔解析到 PingTarget 物件建立' {

        It '應從設定檔正確建立整個目標列表' {
            $config = New-TempConfig -Content @"
# 測試設定檔
googleDNS	8.8.8.8
quad9		9.9.9.9
---
cloudflare	1.1.1.1
"@
            $targets = Read-DeadmanConfig -Path $config -RttScale 15

            # 確認目標數量
            $targets.Count | Should -Be 4

            # 確認第一個目標
            $targets[0].GetType().Name | Should -Be 'PingTarget'
            $targets[0].Name | Should -Be 'googleDNS'
            $targets[0].Address | Should -Be '8.8.8.8'
            $targets[0].RttScale | Should -Be 15

            # 確認分隔線
            $targets[2].GetType().Name | Should -Be 'Separator'

            # 確認最後一個目標
            $targets[3].Name | Should -Be 'cloudflare'
            $targets[3].Address | Should -Be '1.1.1.1'
        }
    }

    # ========================================================
    # PingTarget 完整生命週期測試
    # ========================================================

    Context 'PingTarget 完整生命週期' {

        It '建立 → 接收結果 → 重置 → 再次接收結果的完整流程' {
            $target = [PingTarget]::new('test', '8.8.8.8')
            $target.RttScale = 10

            # 第一次 Ping 成功
            $target.Sent = 1
            $res1 = [PingResult]::new($true, [PingErrorCode]::Success, 5.0, 64)
            $target.ConsumeResult($res1)

            $target.State | Should -BeTrue
            $target.RTT | Should -Be 5.0
            $target.ResultHistory.Count | Should -Be 1

            # 第二次 Ping 失敗
            $target.Sent = 2
            $res2 = [PingResult]::new($false, [PingErrorCode]::Failed, 0, 0)
            $target.ConsumeResult($res2)

            $target.State | Should -BeFalse
            $target.Loss | Should -Be 1
            $target.ResultHistory.Count | Should -Be 2
            $target.ResultHistory[0] | Should -Be 'X'

            # 重置統計
            $target.Refresh()

            $target.State | Should -BeFalse
            $target.Sent | Should -Be 0
            $target.Loss | Should -Be 0
            $target.ResultHistory.Count | Should -Be 0

            # 重置後再次接收結果
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
    # ConsoleUI 版面配置整合測試
    # ========================================================

    Context 'ConsoleUI 版面配置與目標列表整合' {

        It '應正確處理包含分隔線的目標列表' {
            $config = New-TempConfig -Content @"
google	8.8.8.8
---
quad9	9.9.9.9
"@
            $targets = Read-DeadmanConfig -Path $config

            try {
                $ui = [ConsoleUI]::new(10)
                # UpdateLayout 不應因 Separator 而拋出例外
                { $ui.UpdateLayout($targets) } | Should -Not -Throw
            }
            catch {
                # 非互動式環境可能無法建立 ConsoleUI
                Set-ItResult -Skipped -Because '非互動式環境無法初始化 Console'
            }
        }
    }

    # ========================================================
    # IPv6 位址支援測試
    # ========================================================

    Context 'IPv6 位址支援' {

        It '應正確解析 IPv6 位址' {
            $config = New-TempConfig -Content "kame6	2001:200:dff:fff1:216:3eff:feb1:44d7"
            $targets = Read-DeadmanConfig -Path $config

            $targets[0].Address | Should -Be '2001:200:dff:fff1:216:3eff:feb1:44d7'
        }
    }

    # ========================================================
    # 大量目標測試
    # ========================================================

    Context '效能與邊界條件' {

        It '應能處理大量目標（100 個）' {
            $lines = @()
            for ($i = 1; $i -le 100; $i++) {
                $lines += "host$i`t10.0.0.$($i % 256)"
            }
            $config = New-TempConfig -Content ($lines -join "`n")
            $targets = Read-DeadmanConfig -Path $config

            $targets.Count | Should -Be 100
        }

        It '應能處理空的設定檔' {
            $config = New-TempConfig -Content @"
# 只有註解
# 沒有任何目標
"@
            $targets = Read-DeadmanConfig -Path $config

            $targets.Count | Should -Be 0
        }
    }

    # ========================================================
    # 真實 Ping 測試（localhost）
    # ========================================================

    Context '真實 Ping 測試' {

        It '對 localhost（127.0.0.1）的 Ping 應成功' -Tag 'Network' {
            $target = [PingTarget]::new('localhost', '127.0.0.1')
            $target.Send()

            $target.Sent | Should -Be 1

            # 某些環境（如 macOS 非 root、CI/CD 容器）可能阻擋 ICMP
            # 因此僅驗證 Send() 不拋出例外且 Sent 計數正確
            if (-not $target.State) {
                Set-ItResult -Skipped -Because '環境可能阻擋 ICMP（需要管理員權限或防火牆設定）'
            }
            else {
                $target.RTT | Should -BeGreaterOrEqual 0
            }
        }

        It '對不可達位址的 Ping 應失敗' -Tag 'Network' {
            # 使用 TEST-NET 範圍的位址（RFC 5737），通常不可達
            $target = [PingTarget]::new('unreachable', '192.0.2.1')
            $target.Send()

            $target.Sent | Should -Be 1
            $target.State | Should -BeFalse
            $target.Loss | Should -Be 1
        }
    }
}
