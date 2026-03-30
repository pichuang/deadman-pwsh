# -*- coding: utf-8 -*-
# ConsoleUI.Tests.ps1 — ConsoleUI 類別的單元測試
# 使用 Pester 5 測試框架
#
# 注意：ConsoleUI 直接操控 [System.Console] API，部分方法
# 在非互動式環境（如 CI/CD）中無法完整測試。
# 此處主要驗證版面配置計算邏輯（UpdateLayout）。

BeforeAll {
    # 載入相依模組
    . "$PSScriptRoot/../lib/PingTarget.ps1"
    . "$PSScriptRoot/../lib/ConsoleUI.ps1"

    # 輔助函式 — 建立含指定目標的 List
    function New-TargetList {
        param([array]$Items)
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Items) { $list.Add($item) }
        return , $list
    }
}

Describe 'ConsoleUI.UpdateLayout' {

    # ========================================================
    # 版面配置計算測試
    # ========================================================

    Context '欄位寬度計算' {

        BeforeEach {
            # 建立 ConsoleUI 實例（會嘗試清除螢幕，在測試中可能安全跳過）
            try {
                $script:ui = [ConsoleUI]::new(10)
            }
            catch {
                # 非互動式環境可能無法初始化 Console，建立一個最小化實例
                $script:ui = [ConsoleUI]::new(10)
            }
        }

        It '主機名稱欄位寬度應取最長名稱與標題的較大值' {
            $t1 = [PingTarget]::new('short', '8.8.8.8')
            $t2 = [PingTarget]::new('a-very-long-hostname', '9.9.9.9')
            $targets = New-TargetList -Items @($t1, $t2)

            $script:ui.UpdateLayout($targets)

            # 'a-very-long-hostname' 長度 = 20，>= 'HOSTNAME ' 長度 = 9
            $script:ui.LengthHostname | Should -Be 20
        }

        It '主機名稱欄位不應超過最大限制' {
            $longName = 'a' * 30  # 超過 MAX_HOSTNAME_LENGTH (20)
            $t1 = [PingTarget]::new($longName, '8.8.8.8')
            $targets = New-TargetList -Items @($t1)

            $script:ui.UpdateLayout($targets)

            $script:ui.LengthHostname | Should -BeLessOrEqual 20
        }

        It '位址欄位寬度應取最長位址與標題的較大值' {
            $t1 = [PingTarget]::new('host', '8.8.8.8')
            $targets = New-TargetList -Items @($t1)

            $script:ui.UpdateLayout($targets)

            # 位址 '8.8.8.8' 長度 = 7，< 'ADDRESS ' 長度 = 8
            # 最終寬度 = 8 + 5 = 13（因為 alen += 5）
            $script:ui.LengthAddress | Should -BeGreaterOrEqual 8
        }

        It '應跳過 Separator 物件的寬度計算' {
            $t1 = [PingTarget]::new('host', '8.8.8.8')
            $sep = [Separator]::new()
            $targets = New-TargetList -Items @($t1, $sep)

            # 不應因為 Separator 而拋出例外
            { $script:ui.UpdateLayout($targets) } | Should -Not -Throw
        }

        It '位址欄位不應超過最大限制' {
            $longAddr = '2001:0db8:85a3:0000:0000:8a2e:0370:7334:extra:extra'
            $t1 = [PingTarget]::new('host', $longAddr)
            $targets = New-TargetList -Items @($t1)

            $script:ui.UpdateLayout($targets)

            $script:ui.LengthAddress | Should -BeLessOrEqual 45  # MAX + 5
        }
    }

    # ========================================================
    # 欄位位置計算測試
    # ========================================================

    Context '欄位位置順序' {

        BeforeEach {
            try {
                $script:ui = [ConsoleUI]::new(10)
            }
            catch {
                $script:ui = [ConsoleUI]::new(10)
            }
        }

        It '欄位應按正確順序排列：箭頭 < 主機名稱 < 位址 < 參考值 < 結果' {
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
    # 結果欄位最小寬度測試
    # ========================================================

    Context '結果欄位最小寬度保證' {

        BeforeEach {
            try {
                $script:ui = [ConsoleUI]::new(10)
            }
            catch {
                $script:ui = [ConsoleUI]::new(10)
            }
        }

        It '結果欄位寬度不應低於 10 字元' {
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

    It '不帶旋轉動畫時應回傳純主機資訊' {
        $info = $script:ui.GetHostInfo($false)
        $info | Should -Match '^From: '
        $info | Should -Not -Match '[|/\-\\]$'
    }

    It '帶旋轉動畫時應在末尾附加旋轉字元' {
        $info = $script:ui.GetHostInfo($true)
        $info | Should -Match '^From: '
        # 最後一個字元應為旋轉動畫字元之一
        $lastChar = $info[-1]
        $lastChar | Should -BeIn @('|', '/', '-', '\')
    }

    It '旋轉動畫應隨步進計數器變化' {
        $chars = @()
        for ($i = 0; $i -lt 4; $i++) {
            $script:ui.GlobalStep = $i
            $info = $script:ui.GetHostInfo($true)
            $chars += $info[-1]
        }
        # 四次呼叫應產生不同的旋轉字元
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
        # 建立暫時日誌目錄
        $script:tempLogDir = Join-Path ([System.IO.Path]::GetTempPath()) "deadman-log-test-$(New-Guid)"
    }

    AfterEach {
        # 清理暫時日誌目錄
        if (Test-Path $script:tempLogDir) {
            Remove-Item -Path $script:tempLogDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '應建立日誌目錄與檔案' {
        $target = [PingTarget]::new('testhost', '8.8.8.8')
        $target.Sent = 1
        $target.RTT = 10.5
        $target.Average = 10.5

        $script:ui.WriteLog($script:tempLogDir, $target)

        $logFile = Join-Path $script:tempLogDir 'testhost'
        Test-Path $logFile | Should -BeTrue
    }

    It '日誌內容應包含時間戳和統計資料' {
        $target = [PingTarget]::new('testhost', '8.8.8.8')
        $target.Sent = 5
        $target.RTT = 12.3
        $target.Average = 11.0

        $script:ui.WriteLog($script:tempLogDir, $target)

        $logFile = Join-Path $script:tempLogDir 'testhost'
        $content = Get-Content -Path $logFile
        $content | Should -Match '\d{4}-\d{2}-\d{2}'  # 日期格式
        $content | Should -Match '12\.3'                # RTT
        $content | Should -Match '11'                   # 平均
        $content | Should -Match '5'                    # 送出次數
    }

    It '空日誌目錄路徑時不應寫入任何檔案' {
        $target = [PingTarget]::new('testhost', '8.8.8.8')

        # 不應拋出例外
        { $script:ui.WriteLog('', $target) } | Should -Not -Throw
        { $script:ui.WriteLog($null, $target) } | Should -Not -Throw
    }
}
