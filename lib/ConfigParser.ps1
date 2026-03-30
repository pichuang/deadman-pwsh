# -*- coding: utf-8 -*-
# ConfigParser.ps1 — 設定檔解析函式
# 改寫自 https://github.com/upa/deadman (MIT License)
# 完全支援 PowerShell 7+

# ============================================================
# Read-DeadmanConfig — 解析 deadman 設定檔
# ============================================================
# 設定檔格式（與原版相容）：
#   名稱    位址    [key=value ...]
#   ---                              （分隔線）
#   # 這是註解                        （忽略）
#
# 支援的選項：
#   source=介面名稱   — 指定來源介面
#   os=作業系統        — 原版用，此版本忽略
#   relay=主機         — 原版用，此版本忽略（SSH relay）
#   via=方式           — 原版用，此版本忽略（snmp/netns/vrf）
#   其他 key=value     — 解析但忽略，不會報錯
# ============================================================

function Read-DeadmanConfig {
    [CmdletBinding()]
    param(
        # 設定檔路徑
        [Parameter(Mandatory)]
        [string]$Path,

        # RTT 柱狀圖刻度（毫秒），傳入 PingTarget 物件
        [int]$RttScale = 10
    )

    # 驗證設定檔是否存在
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "設定檔不存在: $Path"
    }

    # 讀取所有行
    $lines = Get-Content -LiteralPath $Path -Encoding UTF8

    # 儲存解析結果的陣列
    $targets = [System.Collections.Generic.List[object]]::new()

    foreach ($rawLine in $lines) {
        # 將 Tab 替換為空格
        $line = $rawLine -replace '\t', ' '
        # 合併多餘空格
        $line = $line -replace '\s+', ' '
        # 移除註解（以 # 開頭）
        $line = $line -replace '^\s*#.*', ''
        # 移除行內註解（以 ; # 開頭的部分）
        $line = $line -replace ';\s*#.*', ''
        # 去除首尾空白
        $line = $line.Trim()

        # 跳過空行
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        # 以空格分割欄位
        $parts = $line -split '\s+'
        $name = $parts[0]

        # 檢查是否為分隔線（由連字號組成，如 --- 或 -----）
        if ($name -match '^-+$') {
            $targets.Add([Separator]::new())
            continue
        }

        # 解析位址（第二個欄位）
        if ($parts.Count -lt 2) {
            Write-Warning "設定檔格式錯誤，缺少位址欄位: $rawLine"
            continue
        }
        $address = $parts[1]

        # 解析選項（第三個欄位以後的 key=value）
        $source = $null
        for ($i = 2; $i -lt $parts.Count; $i++) {
            $option = $parts[$i]
            if ($option -match '^(\w+)=(.+)$') {
                $key = $Matches[1]
                $value = $Matches[2]

                switch ($key) {
                    'source' { $source = $value }
                    # 其餘選項（os, relay, via, community, user, key 等）
                    # 解析但不使用，保持與原版設定檔相容
                    default { <# 忽略不支援的選項 #> }
                }
            }
        }

        # 建立 PingTarget 物件
        if ($source) {
            $target = [PingTarget]::new($name, $address, $source)
        }
        else {
            $target = [PingTarget]::new($name, $address)
        }

        # 設定 RTT 刻度
        $target.RttScale = $RttScale

        $targets.Add($target)
    }

    return , $targets
}
