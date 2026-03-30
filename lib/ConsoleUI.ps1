# -*- coding: utf-8 -*-
# ConsoleUI.ps1 — 終端機 UI 繪製類別
# 改寫自 https://github.com/upa/deadman (MIT License)
# 使用 [System.Console] API 完全支援 PowerShell 7+

# ============================================================
# 常數定義
# ============================================================

# 程式名稱與版本
$script:TITLE_PROGNAME = "Dead Man"
$script:TITLE_VERSION = "[ver 1.0.0-ps]"
# 標題區域佔用的垂直行數
$script:TITLE_VERTIC_LENGTH = 4

# 箭頭指示器
$script:ARROW = " > "
$script:REAR  = "   "

# 欄位最大寬度限制
$script:MAX_HOSTNAME_LENGTH = 20
$script:MAX_ADDRESS_LENGTH = 40

# 預設結果歷史紀錄可顯示長度
$script:RESULT_STR_LENGTH = 10

# ============================================================
# ConsoleUI 類別 — 封裝終端機繪製邏輯
# ============================================================
class ConsoleUI {
    # 終端機尺寸
    [int]$Width
    [int]$Height

    # 各欄位起始位置與長度
    [int]$StartArrow
    [int]$LengthArrow
    [int]$StartHostname
    [int]$LengthHostname
    [int]$StartAddress
    [int]$LengthAddress
    [int]$RefStart
    [int]$RefLength
    [int]$ResStart
    [int]$ResLength

    # RTT 柱狀圖刻度（毫秒）
    [int]$RttScale

    # 主機資訊字串
    [string]$HostInfo

    # 全域步進計數器（用於旋轉動畫）
    [int]$GlobalStep = 0

    # 原始前景與背景色（用於還原）
    hidden [System.ConsoleColor]$OrigFg
    hidden [System.ConsoleColor]$OrigBg

    # 建構子 — 初始化主機資訊與終端機尺寸
    ConsoleUI([int]$rttScale) {
        $this.RttScale = $rttScale

        # 取得主機名稱與 IP，建構主機資訊字串
        $hostname = [System.Net.Dns]::GetHostName()
        try {
            $ip = ([System.Net.Dns]::GetHostAddresses($hostname) |
                   Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                   Select-Object -First 1).IPAddressToString
            $this.HostInfo = "From: $hostname ($ip)"
        }
        catch {
            $this.HostInfo = "From: $hostname"
        }

        # 儲存原始終端機色彩
        $this.OrigFg = [System.Console]::ForegroundColor
        $this.OrigBg = [System.Console]::BackgroundColor

        # 初始化終端機
        $this.Reinit()
    }

    # 遞增全域步進計數器（旋轉動畫用）
    [void] IncrementStep() {
        $this.GlobalStep++
    }

    # 取得主機資訊字串，可選是否附帶旋轉動畫
    [string] GetHostInfo([bool]$withWheel) {
        if (-not $withWheel) {
            return $this.HostInfo
        }
        # 旋轉動畫字元：| / - \
        $wheelChars = @('|', '/', '-', '\')
        $wheel = $wheelChars[$this.GlobalStep % 4]
        return "$($this.HostInfo) $wheel"
    }

    # 重新初始化終端機畫面（清空並重設游標）
    [void] Reinit() {
        [System.Console]::Clear()
        [System.Console]::CursorVisible = $false
        $this.Width = [System.Console]::WindowWidth
        $this.Height = [System.Console]::WindowHeight
    }

    # 安全寫入字串到指定座標，防止超出終端機範圍
    [void] WriteAt([int]$row, [int]$col, [string]$text) {
        if ($row -lt 0 -or $row -ge $this.Height) { return }
        if ($col -lt 0 -or $col -ge $this.Width) { return }

        # 截斷超出螢幕寬度的文字
        $maxLen = $this.Width - $col
        if ($text.Length -gt $maxLen) {
            $text = $text.Substring(0, [Math]::Max(0, $maxLen))
        }
        if ($text.Length -eq 0) { return }

        [System.Console]::SetCursorPosition($col, $row)
        [System.Console]::Write($text)
    }

    # 安全寫入帶色彩的字串到指定座標
    [void] WriteAt([int]$row, [int]$col, [string]$text, [System.ConsoleColor]$fg) {
        $prevFg = [System.Console]::ForegroundColor
        [System.Console]::ForegroundColor = $fg
        $this.WriteAt($row, $col, $text)
        [System.Console]::ForegroundColor = $prevFg
    }

    # 根據目標列表計算各欄位的起始位置與寬度
    # 對齊原版 CursesCtrl.update_info() 的邏輯
    [void] UpdateLayout([System.Collections.Generic.List[object]]$targets) {
        $this.Width = [System.Console]::WindowWidth
        $this.Height = [System.Console]::WindowHeight

        # 箭頭欄位
        $this.StartArrow = 0
        $this.LengthArrow = $script:ARROW.Length

        # 主機名稱欄位 — 取所有目標中最長的名稱
        $hlen = "HOSTNAME ".Length
        foreach ($t in $targets) {
            if ($t -is [Separator]) { continue }
            if ($t.Name.Length -gt $hlen) { $hlen = $t.Name.Length }
        }
        if ($hlen -gt $script:MAX_HOSTNAME_LENGTH) { $hlen = $script:MAX_HOSTNAME_LENGTH }
        $this.StartHostname = $this.StartArrow + $this.LengthArrow
        $this.LengthHostname = $hlen

        # 位址欄位 — 取所有目標中最長的位址
        $alen = "ADDRESS ".Length
        foreach ($t in $targets) {
            if ($t -is [Separator]) { continue }
            if ($t.Address.Length -gt $alen) { $alen = $t.Address.Length }
        }
        if ($alen -gt $script:MAX_ADDRESS_LENGTH) {
            $alen = $script:MAX_ADDRESS_LENGTH
        }
        else {
            $alen += 5
        }
        $this.StartAddress = $this.StartHostname + $this.LengthHostname + 1
        $this.LengthAddress = $alen

        # 參考值欄位（LOSS RTT AVG SNT）
        $this.RefStart = $this.StartAddress + $this.LengthAddress + 1
        $this.RefLength = " LOSS  RTT  AVG  SNT".Length

        # 結果柱狀圖欄位
        $this.ResStart = $this.RefStart + $this.RefLength + 2
        $this.ResLength = $this.Width - ($this.RefStart + $this.RefLength + 2)

        # 如果結果欄位太窄，向左壓縮以確保至少顯示 10 字元
        if ($this.ResLength -lt 10) {
            $rev = 10 - $this.ResLength + $script:ARROW.Length
            $this.RefStart -= $rev
            $this.ResStart -= $rev
            $this.ResLength = 10
        }

        # 更新全域結果字串長度
        $script:RESULT_STR_LENGTH = $this.ResLength
    }

    # 繪製標題列（程式名稱、主機資訊、版本號、RTT 刻度說明）
    [void] PrintTitle([bool]$withWheel) {
        # 程式名稱置中於第一行
        $spacelen = [int](($this.Width - $script:TITLE_PROGNAME.Length) / 2)
        $this.WriteAt(0, $spacelen, $script:TITLE_PROGNAME, [System.ConsoleColor]::White)

        # 主機資訊於第二行左側
        $displayHostInfo = $this.GetHostInfo($withWheel)
        $this.WriteAt(1, $this.StartHostname, $displayHostInfo, [System.ConsoleColor]::White)

        # 版本號於第二行右側
        $versionCol = $this.Width - ($script:ARROW.Length + $script:TITLE_VERSION.Length)
        if ($versionCol -gt 0) {
            $this.WriteAt(1, $versionCol, $script:TITLE_VERSION, [System.ConsoleColor]::White)
        }

        # RTT 刻度說明於第三行
        $scaleInfo = "RTT Scale $($this.RttScale)ms. Keys: (r)efresh (q)uit"
        $this.WriteAt(2, $script:ARROW.Length, $scaleInfo)
    }

    # 清除標題區域
    [void] EraseTitle() {
        $blank = ' ' * $this.Width
        for ($row = 0; $row -lt 3; $row++) {
            $this.WriteAt($row, 0, $blank)
        }
    }

    # 繪製表頭參考列（HOSTNAME、ADDRESS、LOSS、RTT、AVG、SNT、RESULT）
    [void] PrintReference() {
        $linenum = $script:TITLE_VERTIC_LENGTH
        $this.WriteAt($linenum, $script:ARROW.Length, "HOSTNAME", [System.ConsoleColor]::White)
        $this.WriteAt($linenum, $this.StartAddress, "ADDRESS", [System.ConsoleColor]::White)

        $valuesStr = " LOSS  RTT  AVG  SNT  RESULT"
        $this.WriteAt($linenum, $this.RefStart, $valuesStr, [System.ConsoleColor]::White)
    }

    # 清除表頭參考列
    [void] EraseReference() {
        $linenum = $script:TITLE_VERTIC_LENGTH
        $this.WriteAt($linenum, 0, (' ' * $this.Width))
    }

    # 繪製分隔線
    [void] PrintSeparator([int]$number) {
        $linenum = $number + $script:TITLE_VERTIC_LENGTH
        $dashLen = $this.Width - $this.StartHostname - $script:ARROW.Length
        if ($dashLen -gt 0) {
            $this.WriteAt($linenum, $this.StartHostname, ('-' * $dashLen))
        }
    }

    # 繪製單一 Ping 目標的結果行
    [void] PrintPingTarget([PingTarget]$target, [int]$number) {
        $linenum = $number + $script:TITLE_VERTIC_LENGTH

        # 根據目標狀態選擇色彩：存活=綠色，無回應=紅色
        $lineColor = if ($target.State) {
            [System.ConsoleColor]::Green
        }
        else {
            [System.ConsoleColor]::Red
        }

        # 主機名稱
        $nameStr = $target.Name
        if ($nameStr.Length -gt $this.LengthHostname) {
            $nameStr = $nameStr.Substring(0, $this.LengthHostname)
        }
        $this.WriteAt($linenum, $this.StartHostname, $nameStr, $lineColor)

        # 位址
        $addrStr = $target.Address
        if ($addrStr.Length -gt $this.LengthAddress) {
            $addrStr = $addrStr.Substring(0, $this.LengthAddress)
        }
        $this.WriteAt($linenum, $this.StartAddress, $addrStr, $lineColor)

        # 統計值：LOSS% RTT AVG SNT
        $valuesStr = ' {0,3:N0}% {1,4:N0} {2,4:N0} {3,4:N0}  ' -f @(
            [int]$target.LossRate,
            [int]$target.RTT,
            [int]$target.Average,
            $target.Sent
        )
        $this.WriteAt($linenum, $this.RefStart, $valuesStr, $lineColor)

        # 繪製結果柱狀圖
        $maxChars = [Math]::Min($target.ResultHistory.Count, $this.ResLength)
        for ($n = 0; $n -lt $maxChars; $n++) {
            $ch = $target.ResultHistory[$n]
            $col = $this.ResStart + $n
            if ($col -ge $this.Width) { break }

            if ($ch -eq 'X' -or $ch -eq 't' -or $ch -eq 's') {
                $this.WriteAt($linenum, $col, $ch, [System.ConsoleColor]::Red)
            }
            else {
                $this.WriteAt($linenum, $col, $ch, [System.ConsoleColor]::Green)
            }
        }

        # 清除行尾殘留字元
        $rearCol = $this.Width - $script:REAR.Length
        if ($rearCol -gt 0) {
            $this.WriteAt($linenum, $rearCol, $script:REAR)
        }
    }

    # 繪製箭頭指示器（標示目前正在 Ping 的目標）
    [void] PrintArrow([int]$number) {
        $linenum = $number + $script:TITLE_VERTIC_LENGTH
        $this.WriteAt($linenum, $this.StartArrow, $script:ARROW)
    }

    # 清除箭頭指示器
    [void] EraseArrow([int]$number) {
        $linenum = $number + $script:TITLE_VERTIC_LENGTH
        $this.WriteAt($linenum, $this.StartArrow, (' ' * $script:ARROW.Length))
    }

    # 清除指定 Ping 目標行的內容
    [void] ErasePingTarget([int]$number) {
        $linenum = $number + $script:TITLE_VERTIC_LENGTH
        $blank = ' ' * [Math]::Max(0, $this.Width - 2)
        $this.WriteAt($linenum, 2, $blank)
    }

    # 處理日誌記錄 — 將 Ping 結果追加寫入日誌檔案
    [void] WriteLog([string]$logDir, [PingTarget]$target) {
        if ([string]::IsNullOrEmpty($logDir)) { return }

        # 確保日誌目錄存在
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        # 組合日誌路徑（使用目標名稱為檔名）
        $filePath = Join-Path $logDir $target.Name
        # 格式：時間戳 RTT 平均RTT 已送出次數
        $logLine = "{0} {1} {2} {3}" -f @(
            (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'),
            $target.RTT,
            $target.Average,
            $target.Sent
        )
        # 追加寫入（使用 UTF-8 編碼）
        Add-Content -LiteralPath $filePath -Value $logLine -Encoding UTF8
    }

    # 還原終端機設定（程式結束時呼叫）
    [void] Cleanup() {
        [System.Console]::ForegroundColor = $this.OrigFg
        [System.Console]::BackgroundColor = $this.OrigBg
        [System.Console]::CursorVisible = $true
        [System.Console]::Clear()
    }
}
