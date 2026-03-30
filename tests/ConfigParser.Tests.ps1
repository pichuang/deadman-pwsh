# -*- coding: utf-8 -*-
# ConfigParser.Tests.ps1 — 設定檔解析函式的單元測試
# 使用 Pester 5 測試框架

BeforeAll {
    # 載入相依模組（類別定義須先載入）
    . "$PSScriptRoot/../lib/PingTarget.ps1"
    . "$PSScriptRoot/../lib/ConfigParser.ps1"

    # 輔助函式 — 建立暫時設定檔並回傳路徑
    function New-TempConfig {
        param([string]$Content)
        $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "deadman-test-$(New-Guid).conf"
        Set-Content -Path $tempFile -Value $Content -Encoding UTF8
        return $tempFile
    }
}

Describe 'Read-DeadmanConfig' {

    AfterEach {
        # 清理暫時設定檔
        Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'deadman-test-*.conf' |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # ========================================================
    # 基本功能測試
    # ========================================================

    Context '基本行解析' {

        It '應正確解析名稱與位址' {
            # 準備：建立包含兩個目標的設定檔
            $config = New-TempConfig -Content @"
googleDNS   8.8.8.8
quad9       9.9.9.9
"@
            $result = Read-DeadmanConfig -Path $config

            # 驗證：應回傳兩個 PingTarget 物件
            $result.Count | Should -Be 2
            $result[0].GetType().Name | Should -Be 'PingTarget'
            $result[0].Name | Should -Be 'googleDNS'
            $result[0].Address | Should -Be '8.8.8.8'
            $result[1].Name | Should -Be 'quad9'
            $result[1].Address | Should -Be '9.9.9.9'
        }

        It '應正確處理 Tab 分隔的行' {
            $config = New-TempConfig -Content "google`t8.8.8.8"
            $result = Read-DeadmanConfig -Path $config

            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'google'
            $result[0].Address | Should -Be '8.8.8.8'
        }

        It '應正確處理多個空格分隔的行' {
            $config = New-TempConfig -Content "google     8.8.8.8"
            $result = Read-DeadmanConfig -Path $config

            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'google'
            $result[0].Address | Should -Be '8.8.8.8'
        }
    }

    # ========================================================
    # 選項解析測試
    # ========================================================

    Context '選項解析' {

        It '應正確解析 source 選項' {
            $config = New-TempConfig -Content "myhost 192.168.1.1 source=eth0"
            $result = Read-DeadmanConfig -Path $config

            $result[0].Source | Should -Be 'eth0'
        }

        It '應忽略不支援的選項而不報錯' {
            # relay, os, via 等選項在此版本不使用，但不應導致錯誤
            $config = New-TempConfig -Content "myhost 8.8.8.8 relay=10.0.0.1 os=Linux via=ssh"
            $result = Read-DeadmanConfig -Path $config

            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'myhost'
            $result[0].Address | Should -Be '8.8.8.8'
        }
    }

    # ========================================================
    # 註解與空行測試
    # ========================================================

    Context '註解與空行處理' {

        It '應忽略以 # 開頭的註解行' {
            $config = New-TempConfig -Content @"
# 這是註解
googleDNS   8.8.8.8
# 另一行註解
"@
            $result = Read-DeadmanConfig -Path $config

            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'googleDNS'
        }

        It '應忽略空行' {
            $config = New-TempConfig -Content @"
googleDNS   8.8.8.8

quad9       9.9.9.9

"@
            $result = Read-DeadmanConfig -Path $config

            $result.Count | Should -Be 2
        }

        It '應忽略純空白行' {
            $config = New-TempConfig -Content "googleDNS   8.8.8.8`n   `n   "
            $result = Read-DeadmanConfig -Path $config

            $result.Count | Should -Be 1
        }
    }

    # ========================================================
    # 分隔線測試
    # ========================================================

    Context '分隔線處理' {

        It '應將 --- 解析為 Separator 物件' {
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

        It '應支援不同長度的分隔線' {
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
    # RTT 刻度傳遞測試
    # ========================================================

    Context 'RTT 刻度設定' {

        It '應將 RttScale 傳遞給每個 PingTarget' {
            $config = New-TempConfig -Content "google 8.8.8.8"
            $result = Read-DeadmanConfig -Path $config -RttScale 20

            $result[0].RttScale | Should -Be 20
        }

        It '預設 RttScale 應為 10' {
            $config = New-TempConfig -Content "google 8.8.8.8"
            $result = Read-DeadmanConfig -Path $config

            $result[0].RttScale | Should -Be 10
        }
    }

    # ========================================================
    # 錯誤處理測試
    # ========================================================

    Context '錯誤處理' {

        It '設定檔不存在時應拋出例外' {
            { Read-DeadmanConfig -Path '/nonexistent/path/deadman.conf' } |
                Should -Throw '設定檔不存在*'
        }

        It '缺少位址欄位時應產生警告並跳過該行' {
            $config = New-TempConfig -Content @"
google
quad9   9.9.9.9
"@
            $result = Read-DeadmanConfig -Path $config -WarningAction SilentlyContinue

            # 只有 quad9 應被解析成功
            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'quad9'
        }
    }

    # ========================================================
    # 與原版設定檔相容性測試
    # ========================================================

    Context '原版設定檔相容性' {

        It '應正確解析原版格式的完整設定檔' {
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
