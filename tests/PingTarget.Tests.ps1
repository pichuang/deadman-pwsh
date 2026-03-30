# -*- coding: utf-8 -*-
# PingTarget.Tests.ps1 — PingTarget 與 PingResult 類別的單元測試
# 使用 Pester 5 測試框架

BeforeAll {
    # 載入類別定義
    . "$PSScriptRoot/../lib/PingTarget.ps1"
}

Describe 'PingResult 類別' {

    Context '建構子' {

        It '預設建構子應初始化為失敗狀態' {
            $result = [PingResult]::new()

            $result.Success | Should -BeFalse
            $result.ErrorCode | Should -Be ([PingErrorCode]::Failed)
            $result.RTT | Should -Be 0.0
            $result.TTL | Should -Be 0
        }

        It '帶參數建構子應正確設定所有屬性' {
            $result = [PingResult]::new($true, [PingErrorCode]::Success, 15.5, 64)

            $result.Success | Should -BeTrue
            $result.ErrorCode | Should -Be ([PingErrorCode]::Success)
            $result.RTT | Should -Be 15.5
            $result.TTL | Should -Be 64
        }
    }
}

Describe 'PingTarget 類別' {

    # ========================================================
    # 建構子測試
    # ========================================================

    Context '建構子' {

        It '雙參數建構子應正確初始化名稱與位址' {
            $target = [PingTarget]::new('google', '8.8.8.8')

            $target.Name | Should -Be 'google'
            $target.Address | Should -Be '8.8.8.8'
            $target.Source | Should -BeNullOrEmpty
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

        It '三參數建構子應正確設定來源介面' {
            $target = [PingTarget]::new('myhost', '192.168.1.1', 'eth0')

            $target.Name | Should -Be 'myhost'
            $target.Address | Should -Be '192.168.1.1'
            $target.Source | Should -Be 'eth0'
        }
    }

    # ========================================================
    # GetResultChar() 測試
    # ========================================================

    Context 'GetResultChar 方法' {

        BeforeEach {
            $script:target = [PingTarget]::new('test', '8.8.8.8')
            $script:target.RttScale = 10
        }

        It 'Ping 失敗時應回傳 X' {
            $res = [PingResult]::new($false, [PingErrorCode]::Failed, 0, 0)
            $script:target.GetResultChar($res) | Should -Be 'X'
        }

        It 'RTT < 1x scale 時應回傳 ▁' {
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 5, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2581)
        }

        It 'RTT < 2x scale 時應回傳 ▂' {
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 15, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2582)
        }

        It 'RTT < 3x scale 時應回傳 ▃' {
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 25, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2583)
        }

        It 'RTT < 4x scale 時應回傳 ▄' {
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 35, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2584)
        }

        It 'RTT < 5x scale 時應回傳 ▅' {
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 45, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2585)
        }

        It 'RTT < 6x scale 時應回傳 ▆' {
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 55, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2586)
        }

        It 'RTT < 7x scale 時應回傳 ▇' {
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 65, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2587)
        }

        It 'RTT >= 7x scale 時應回傳 █' {
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 80, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2588)
        }

        It '自訂 RttScale 時應正確判斷' {
            $script:target.RttScale = 20
            # RTT 15 < 20*1，應回傳 ▁
            $res = [PingResult]::new($true, [PingErrorCode]::Success, 15, 64)
            $script:target.GetResultChar($res) | Should -Be ([char]0x2581)
        }
    }

    # ========================================================
    # ConsumeResult() 測試
    # ========================================================

    Context 'ConsumeResult 方法' {

        BeforeEach {
            $script:target = [PingTarget]::new('test', '8.8.8.8')
            $script:target.Sent = 1  # 模擬已送出一次 Ping
        }

        It 'Ping 成功時應正確更新統計' {
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

        It 'Ping 失敗時應增加遺失計數' {
            $res = [PingResult]::new($false, [PingErrorCode]::Failed, 0, 0)
            $script:target.ConsumeResult($res)

            $script:target.State | Should -BeFalse
            $script:target.Loss | Should -Be 1
            $script:target.LossRate | Should -Be 100.0
        }

        It '多次 Ping 後應正確計算平均值' {
            # 第一次 Ping 成功（RTT = 10ms）
            $res1 = [PingResult]::new($true, [PingErrorCode]::Success, 10.0, 64)
            $script:target.ConsumeResult($res1)

            # 第二次 Ping 成功（RTT = 20ms）
            $script:target.Sent = 2
            $res2 = [PingResult]::new($true, [PingErrorCode]::Success, 20.0, 64)
            $script:target.ConsumeResult($res2)

            $script:target.Total | Should -Be 30.0
            $script:target.Average | Should -Be 15.0
            $script:target.RTT | Should -Be 20.0  # 最後一次 RTT
        }

        It '結果應被插入歷史紀錄最前方' {
            $res1 = [PingResult]::new($true, [PingErrorCode]::Success, 5.0, 64)
            $script:target.ConsumeResult($res1)

            $script:target.Sent = 2
            $res2 = [PingResult]::new($false, [PingErrorCode]::Failed, 0, 0)
            $script:target.ConsumeResult($res2)

            # 最新的結果（失敗=X）應在最前面
            $script:target.ResultHistory[0] | Should -Be 'X'
            # 較舊的結果應在後面
            $script:target.ResultHistory[1] | Should -Be ([char]0x2581)
        }

        It '混合成功與失敗時遺失率應正確' {
            # 1 次成功 + 2 次失敗 = 66.67% 遺失率
            $res1 = [PingResult]::new($true, [PingErrorCode]::Success, 10.0, 64)
            $script:target.ConsumeResult($res1)

            $script:target.Sent = 2
            $res2 = [PingResult]::new($false, [PingErrorCode]::Failed, 0, 0)
            $script:target.ConsumeResult($res2)

            $script:target.Sent = 3
            $res3 = [PingResult]::new($false, [PingErrorCode]::Failed, 0, 0)
            $script:target.ConsumeResult($res3)

            $script:target.Loss | Should -Be 2
            # 遺失率 = 2/3 * 100 ≈ 66.67
            [Math]::Round($script:target.LossRate, 2) | Should -Be 66.67
        }
    }

    # ========================================================
    # Refresh() 測試
    # ========================================================

    Context 'Refresh 方法' {

        It '應重置所有統計資料' {
            $target = [PingTarget]::new('test', '8.8.8.8')
            # 模擬一些累計資料
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

            # 執行重置
            $target.Refresh()

            # 驗證所有統計資料已歸零
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

        It '重置後名稱與位址應保持不變' {
            $target = [PingTarget]::new('google', '8.8.8.8')
            $target.Refresh()

            $target.Name | Should -Be 'google'
            $target.Address | Should -Be '8.8.8.8'
        }
    }

    # ========================================================
    # ToString() 測試
    # ========================================================

    Context 'ToString 方法' {

        It '無來源介面時應回傳 名稱:位址' {
            $target = [PingTarget]::new('google', '8.8.8.8')
            $target.ToString() | Should -Be 'google:8.8.8.8'
        }

        It '有來源介面時應回傳 名稱:位址:來源' {
            $target = [PingTarget]::new('myhost', '192.168.1.1', 'eth0')
            $target.ToString() | Should -Be 'myhost:192.168.1.1:eth0'
        }
    }

    # ========================================================
    # Send() 方法測試（使用 Mock）
    # ========================================================

    Context 'Send 方法' {

        It '呼叫 Send 後 Sent 計數應增加' {
            # 模擬 Test-Connection 回傳成功結果
            Mock Test-Connection {
                return [PSCustomObject]@{
                    Status  = 'Success'
                    Latency = 10
                    Reply   = [PSCustomObject]@{
                        Options = [PSCustomObject]@{ Ttl = 64 }
                    }
                }
            }

            $target = [PingTarget]::new('test', '127.0.0.1')
            $target.Send()

            $target.Sent | Should -Be 1
        }

        It 'Ping 成功時應更新狀態為存活' {
            Mock Test-Connection {
                return [PSCustomObject]@{
                    Status  = 'Success'
                    Latency = 5
                    Reply   = [PSCustomObject]@{
                        Options = [PSCustomObject]@{ Ttl = 128 }
                    }
                }
            }

            $target = [PingTarget]::new('test', '127.0.0.1')
            $target.Send()

            $target.State | Should -BeTrue
            $target.RTT | Should -Be 5
        }

        It 'Ping 失敗時應更新狀態為無回應' {
            Mock Test-Connection {
                throw "Ping failed"
            }

            $target = [PingTarget]::new('test', '192.0.2.1')
            $target.Send()

            $target.State | Should -BeFalse
            $target.Loss | Should -Be 1
        }
    }
}

Describe 'Separator 類別' {

    It '應可正確建立 Separator 物件' {
        $sep = New-Object Separator
        $sep.GetType().Name | Should -Be 'Separator'
    }
}

Describe 'PingErrorCode 列舉' {

    It 'Success 值應為 0' {
        [int][PingErrorCode]::Success | Should -Be 0
    }

    It 'Failed 值應為 -1' {
        [int][PingErrorCode]::Failed | Should -Be -1
    }
}
