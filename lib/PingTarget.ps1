# -*- coding: utf-8 -*-
# PingTarget.ps1 — Ping 結果與目標類別定義
# 改寫自 https://github.com/upa/deadman (MIT License)
# 完全支援 PowerShell 7+

# ============================================================
# 常數定義
# ============================================================

# Ping 錯誤碼列舉
enum PingErrorCode {
    # Ping 成功
    Success = 0
    # Ping 失敗（逾時或無回應）
    Failed = -1
}

# ============================================================
# PingResult 類別 — 封裝單次 Ping 結果
# ============================================================
class PingResult {
    # 是否成功
    [bool]$Success = $false
    # 錯誤碼
    [PingErrorCode]$ErrorCode = [PingErrorCode]::Failed
    # 往返時間（毫秒）
    [double]$RTT = 0.0
    # 存活時間
    [int]$TTL = 0

    # 預設建構子
    PingResult() {}

    # 帶參數建構子
    PingResult([bool]$success, [PingErrorCode]$errorCode, [double]$rtt, [int]$ttl) {
        $this.Success = $success
        $this.ErrorCode = $errorCode
        $this.RTT = $rtt
        $this.TTL = $ttl
    }
}

# ============================================================
# Separator 類別 — 設定檔中的分隔線標記
# ============================================================
class Separator {
    # 分隔線不需要任何屬性，僅作為標記物件使用
}

# ============================================================
# PingTarget 類別 — 封裝單一 Ping 監控目標
# ============================================================
class PingTarget {
    # 目標名稱（顯示用）
    [string]$Name
    # 目標位址（IP 或主機名稱）
    [string]$Address
    # 來源介面（選填）
    [string]$Source
    # 目前狀態（true = 存活, false = 無回應）
    [bool]$State = $false
    # 累計遺失次數
    [int]$Loss = 0
    # 遺失率（百分比）
    [double]$LossRate = 0.0
    # 最近一次 RTT（毫秒）
    [double]$RTT = 0
    # RTT 總和（用於計算平均值）
    [double]$Total = 0
    # 平均 RTT（毫秒）
    [double]$Average = 0
    # 已送出的 Ping 次數
    [int]$Sent = 0
    # 最近一次 TTL
    [int]$TTL = 0
    # 結果歷史紀錄（最新在前，用於繪製柱狀圖）
    [System.Collections.Generic.List[string]]$ResultHistory
    # RTT 刻度（毫秒），用於柱狀圖字元判斷
    [int]$RttScale = 10

    # 建構子 — 初始化目標名稱與位址
    PingTarget([string]$name, [string]$address) {
        $this.Name = $name
        $this.Address = $address
        $this.Source = $null
        $this.ResultHistory = [System.Collections.Generic.List[string]]::new()
    }

    # 建構子 — 初始化目標名稱、位址與來源介面
    PingTarget([string]$name, [string]$address, [string]$source) {
        $this.Name = $name
        $this.Address = $address
        $this.Source = $source
        $this.ResultHistory = [System.Collections.Generic.List[string]]::new()
    }

    # 執行單次 Ping 並更新統計資料
    # 使用 Test-Connection（PowerShell 7+ 原生 Cmdlet）
    [void] Send() {
        $result = [PingResult]::new()

        try {
            # 組建 Test-Connection 參數
            $params = @{
                TargetName    = $this.Address
                Count         = 1
                TimeoutSeconds = 1
                Ping          = $true
                ErrorAction   = 'Stop'
            }

            $reply = Test-Connection @params

            if ($reply.Status -eq 'Success') {
                $result.Success = $true
                $result.ErrorCode = [PingErrorCode]::Success
                # Latency 屬性為往返時間（毫秒）
                $result.RTT = [double]$reply.Latency
                $result.TTL = if ($null -ne $reply.Reply -and $null -ne $reply.Reply.Options) {
                    [int]$reply.Reply.Options.Ttl
                } else {
                    -1
                }
            }
        }
        catch {
            # Ping 失敗（逾時、主機不可達等）
            $result.Success = $false
            $result.ErrorCode = [PingErrorCode]::Failed
        }

        $this.Sent++
        $this.ConsumeResult($result)
    }

    # 消化 Ping 結果，更新統計資料
    [void] ConsumeResult([PingResult]$res) {
        if ($res.Success) {
            # Ping 成功 — 更新 RTT 統計
            $this.State = $true
            $this.RTT = $res.RTT
            $this.Total += $res.RTT
            $this.Average = $this.Total / $this.Sent
            $this.TTL = $res.TTL
        }
        else {
            # Ping 失敗 — 增加遺失計數
            $this.Loss++
            $this.State = $false
        }

        # 計算遺失率
        $this.LossRate = [double]$this.Loss / [double]$this.Sent * 100.0

        # 將結果字元插入歷史紀錄最前方
        $this.ResultHistory.Insert(0, $this.GetResultChar($res))
    }

    # 根據 Ping 結果回傳對應的 Unicode 柱狀圖字元
    # RTT 越高，柱狀圖越高；失敗則回傳 'X'
    [string] GetResultChar([PingResult]$res) {
        if ($res.ErrorCode -eq [PingErrorCode]::Failed) {
            return 'X'
        }

        $scale = $this.RttScale
        if ($res.RTT -lt ($scale * 1)) { return [char]0x2581 }  # ▁
        if ($res.RTT -lt ($scale * 2)) { return [char]0x2582 }  # ▂
        if ($res.RTT -lt ($scale * 3)) { return [char]0x2583 }  # ▃
        if ($res.RTT -lt ($scale * 4)) { return [char]0x2584 }  # ▄
        if ($res.RTT -lt ($scale * 5)) { return [char]0x2585 }  # ▅
        if ($res.RTT -lt ($scale * 6)) { return [char]0x2586 }  # ▆
        if ($res.RTT -lt ($scale * 7)) { return [char]0x2587 }  # ▇

        return [char]0x2588  # █（RTT >= scale * 7）
    }

    # 重置所有統計資料（保留名稱與位址）
    [void] Refresh() {
        $this.State = $false
        $this.Loss = 0
        $this.LossRate = 0.0
        $this.RTT = 0
        $this.Total = 0
        $this.Average = 0
        $this.Sent = 0
        $this.TTL = 0
        $this.ResultHistory.Clear()
    }

    # 字串表示（用於比較與除錯）
    [string] ToString() {
        $parts = @($this.Name, $this.Address)
        if ($this.Source) { $parts += $this.Source }
        return ($parts -join ':')
    }
}
