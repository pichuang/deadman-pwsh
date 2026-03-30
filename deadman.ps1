#!/usr/bin/env pwsh
# -*- coding: utf-8 -*-
# deadman.ps1 — 主程式進入點
# 改寫自 https://github.com/upa/deadman (MIT License)
#
# deadman 是一個使用 Ping 監控主機狀態的觀測工具。
# 此版本完全使用 PowerShell 7+ 實作，透過 System.Console API 繪製終端機 UI。
#
# 使用方式：
#   ./deadman.ps1 -ConfigFile deadman.conf
#   ./deadman.ps1 -ConfigFile deadman.conf -AsyncMode
#   ./deadman.ps1 -ConfigFile deadman.conf -Scale 20 -LogDir ./logs

[CmdletBinding()]
param(
    # 設定檔路徑（必要參數）
    [Parameter(Mandatory, Position = 0)]
    [string]$ConfigFile,

    # RTT 柱狀圖刻度（毫秒），預設 10ms
    [Alias('s')]
    [int]$Scale = 10,

    # 啟用非同步 Ping 模式（同時對所有目標發送 Ping）
    [Alias('a')]
    [switch]$AsyncMode,

    # 非同步模式下閃爍箭頭指示器
    [Alias('b')]
    [switch]$BlinkArrow,

    # 日誌目錄路徑（選填，指定後會將 Ping 結果寫入日誌）
    [Alias('l')]
    [string]$LogDir
)

# ============================================================
# 載入模組
# ============================================================

# 取得腳本所在目錄
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# 依序載入函式庫（順序重要：類別定義需先載入）
. (Join-Path $scriptRoot 'lib' 'PingTarget.ps1')
. (Join-Path $scriptRoot 'lib' 'ConfigParser.ps1')
. (Join-Path $scriptRoot 'lib' 'ConsoleUI.ps1')

# ============================================================
# 驗證環境
# ============================================================

# 確認 PowerShell 版本 >= 7
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "deadman 需要 PowerShell 7 或更新版本。目前版本: $($PSVersionTable.PSVersion)"
    exit 1
}

# ============================================================
# 解析設定檔
# ============================================================

$targets = Read-DeadmanConfig -Path $ConfigFile -RttScale $Scale

if ($targets.Count -eq 0) {
    Write-Error "設定檔中沒有任何有效的目標: $ConfigFile"
    exit 1
}

# ============================================================
# Ping 間隔常數（秒）
# ============================================================

# 逐一 Ping 之間的間隔
$PING_INTERVAL = 0.05
# 完成一輪所有目標後的等待間隔
$PING_ALLTARGET_INTERVAL = 1

# ============================================================
# 初始化 UI
# ============================================================

$ui = [ConsoleUI]::new($Scale)
$ui.UpdateLayout($targets)
$ui.PrintTitle($false)
$ui.PrintReference()

# 繪製初始畫面（空白行與分隔線）
for ($idx = 0; $idx -lt $targets.Count; $idx++) {
    $number = $idx + 1
    if ($targets[$idx] -is [Separator]) {
        $ui.PrintSeparator($number)
    }
    else {
        $ui.PrintPingTarget($targets[$idx], $number)
    }
}

# ============================================================
# 按鍵處理函式 — 非阻塞讀取按鍵
# ============================================================

function Invoke-KeyHandler {
    param(
        [ConsoleUI]$UI,
        [System.Collections.Generic.List[object]]$Targets
    )

    # 檢查是否有按鍵輸入（非阻塞）
    while ([System.Console]::KeyAvailable) {
        $keyInfo = [System.Console]::ReadKey($true)
        $key = $keyInfo.KeyChar

        switch ($key) {
            'r' {
                # 重置所有目標的統計資料
                for ($i = 0; $i -lt $Targets.Count; $i++) {
                    if ($Targets[$i] -is [Separator]) { continue }
                    $Targets[$i].Refresh()
                    $number = $i + 1
                    $UI.ErasePingTarget($number)
                    $UI.PrintPingTarget($Targets[$i], $number)
                }
            }
            'q' {
                # 退出程式
                $UI.Cleanup()
                exit 0
            }
        }
    }
}

# ============================================================
# 同步模式主迴圈 — 逐一對目標發送 Ping
# ============================================================

function Start-SyncMode {
    param(
        [ConsoleUI]$UI,
        [System.Collections.Generic.List[object]]$Targets,
        [string]$LogDirectory,
        [double]$PingInterval,
        [double]$AllTargetInterval
    )

    while ($true) {
        # 檢測終端機尺寸變化，必要時重繪
        $newW = [System.Console]::WindowWidth
        $newH = [System.Console]::WindowHeight
        if ($newW -ne $UI.Width -or $newH -ne $UI.Height) {
            $UI.Reinit()
            $UI.UpdateLayout($Targets)
            $UI.PrintTitle($false)
            $UI.PrintReference()
            for ($i = 0; $i -lt $Targets.Count; $i++) {
                $number = $i + 1
                if ($Targets[$i] -is [Separator]) {
                    $UI.PrintSeparator($number)
                }
                else {
                    $UI.PrintPingTarget($Targets[$i], $number)
                }
            }
        }

        $UI.UpdateLayout($Targets)
        $UI.EraseTitle()
        $UI.PrintTitle($false)
        $UI.EraseReference()
        $UI.PrintReference()

        # 逐一 Ping 每個目標
        for ($idx = 0; $idx -lt $Targets.Count; $idx++) {
            $number = $idx + 1
            if ($Targets[$idx] -is [Separator]) { continue }

            $target = $Targets[$idx]

            # 顯示箭頭指示目前正在 Ping 的目標
            $UI.PrintArrow($number)

            # 執行 Ping
            $target.Send()

            # 更新 UI
            $UI.ErasePingTarget($number)
            $UI.PrintPingTarget($target, $number)

            # 寫入日誌
            if (-not [string]::IsNullOrEmpty($LogDirectory)) {
                $UI.WriteLog($LogDirectory, $target)
            }

            # 處理按鍵
            Invoke-KeyHandler -UI $UI -Targets $Targets

            # 短暫等待後繼續下一個目標
            Start-Sleep -Milliseconds ([int]($PingInterval * 1000))

            # 清除箭頭
            $UI.EraseArrow($number)
        }

        # 一輪完成後，在最後一個目標顯示箭頭並等待
        $lastIdx = $Targets.Count
        $UI.PrintArrow($lastIdx)
        Start-Sleep -Milliseconds ([int]($AllTargetInterval * 1000))
        $UI.EraseArrow($lastIdx)
        $UI.ErasePingTarget($lastIdx + 1)

        # 處理按鍵
        Invoke-KeyHandler -UI $UI -Targets $Targets
    }
}

# ============================================================
# 非同步模式主迴圈 — 同時對所有目標發送 Ping
# ============================================================

function Start-AsyncMode {
    param(
        [ConsoleUI]$UI,
        [System.Collections.Generic.List[object]]$Targets,
        [string]$LogDirectory,
        [double]$AllTargetInterval,
        [bool]$BlinkArrowEnabled
    )

    while ($true) {
        # 檢測終端機尺寸變化
        $newW = [System.Console]::WindowWidth
        $newH = [System.Console]::WindowHeight
        if ($newW -ne $UI.Width -or $newH -ne $UI.Height) {
            $UI.Reinit()
            $UI.UpdateLayout($Targets)
            $UI.PrintTitle($true)
            $UI.PrintReference()
            for ($i = 0; $i -lt $Targets.Count; $i++) {
                $number = $i + 1
                if ($Targets[$i] -is [Separator]) {
                    $UI.PrintSeparator($number)
                }
                else {
                    $UI.PrintPingTarget($Targets[$i], $number)
                }
            }
        }

        $UI.UpdateLayout($Targets)
        $UI.IncrementStep()
        $UI.EraseTitle()
        $UI.PrintTitle($true)
        $UI.EraseReference()
        $UI.PrintReference()

        # 閃爍箭頭（可選）
        if ($BlinkArrowEnabled) {
            for ($i = 0; $i -lt $Targets.Count; $i++) {
                if ($Targets[$i] -is [Separator]) { continue }
                $UI.PrintArrow($i + 1)
            }
        }

        # 記錄開始時間
        $start = [System.Diagnostics.Stopwatch]::StartNew()

        # 收集非 Separator 的目標以進行並行 Ping
        $pingTargets = @()
        $pingIndices = @()
        for ($i = 0; $i -lt $Targets.Count; $i++) {
            if ($Targets[$i] -is [Separator]) { continue }
            $pingTargets += $Targets[$i]
            $pingIndices += $i
        }

        # 使用 PowerShell 7 的 ForEach-Object -Parallel 並行 Ping
        # 由於 -Parallel 在新的 Runspace 執行，無法直接呼叫物件方法
        # 改用 Runspace Pool 實作真正的並行處理
        $runspacePool = [System.Management.Automation.Runspaces.RunspacePool]::new(1, $pingTargets.Count, [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault(), [System.Management.Automation.Host.PSHost]::Default)

        # 使用 Jobs 並行 Ping 每個目標
        $jobs = @()
        foreach ($t in $pingTargets) {
            $job = Start-ThreadJob -ScriptBlock {
                param($addr)
                try {
                    $reply = Test-Connection -TargetName $addr -Count 1 -TimeoutSeconds 1 -Ping -ErrorAction Stop
                    if ($reply.Status -eq 'Success') {
                        $ttl = -1
                        if ($null -ne $reply.Reply -and $null -ne $reply.Reply.Options) {
                            $ttl = [int]$reply.Reply.Options.Ttl
                        }
                        return @{ Success = $true; RTT = [double]$reply.Latency; TTL = $ttl }
                    }
                    return @{ Success = $false; RTT = 0; TTL = 0 }
                }
                catch {
                    return @{ Success = $false; RTT = 0; TTL = 0 }
                }
            } -ArgumentList $t.Address
            $jobs += @{ Job = $job; Target = $t }
        }

        # 等待所有 Jobs 完成
        $allJobs = $jobs | ForEach-Object { $_.Job }
        $null = Wait-Job -Job $allJobs -Timeout 5

        # 收集結果並更新每個目標
        foreach ($entry in $jobs) {
            $result = Receive-Job -Job $entry.Job -ErrorAction SilentlyContinue
            Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue

            $t = $entry.Target
            $t.Sent++

            $pingResult = [PingResult]::new()
            if ($null -ne $result -and $result.Success) {
                $pingResult.Success = $true
                $pingResult.ErrorCode = [PingErrorCode]::Success
                $pingResult.RTT = $result.RTT
                $pingResult.TTL = $result.TTL
            }
            $t.ConsumeResult($pingResult)
        }

        $elapsed = $start.Elapsed.TotalSeconds

        # 更新所有目標的 UI 顯示
        for ($i = 0; $i -lt $Targets.Count; $i++) {
            $number = $i + 1
            if ($Targets[$i] -is [Separator]) { continue }

            $UI.ErasePingTarget($number)
            $UI.PrintPingTarget($Targets[$i], $number)

            if ($BlinkArrowEnabled) {
                $UI.EraseArrow($number)
            }

            # 寫入日誌
            if (-not [string]::IsNullOrEmpty($LogDirectory)) {
                $UI.WriteLog($LogDirectory, $Targets[$i])
            }
        }

        # 更新旋轉動畫
        $UI.IncrementStep()
        $UI.EraseTitle()
        $UI.PrintTitle($true)

        # 等待至少 AllTargetInterval 秒
        if ($elapsed -lt $AllTargetInterval) {
            Start-Sleep -Milliseconds ([int](($AllTargetInterval - $elapsed) * 1000))
        }

        Start-Sleep -Milliseconds ([int]($AllTargetInterval * 1000))

        # 處理按鍵
        Invoke-KeyHandler -UI $UI -Targets $Targets
    }
}

# ============================================================
# 主程式啟動
# ============================================================

try {
    if ($AsyncMode) {
        Start-AsyncMode -UI $ui -Targets $targets `
                        -LogDirectory $LogDir `
                        -AllTargetInterval $PING_ALLTARGET_INTERVAL `
                        -BlinkArrowEnabled $BlinkArrow.IsPresent
    }
    else {
        Start-SyncMode -UI $ui -Targets $targets `
                       -LogDirectory $LogDir `
                       -PingInterval $PING_INTERVAL `
                       -AllTargetInterval $PING_ALLTARGET_INTERVAL
    }
}
catch {
    # 捕捉 Ctrl+C 或其他中斷
    if ($ui) { $ui.Cleanup() }
    throw
}
finally {
    # 確保終端機設定還原
    if ($ui) { $ui.Cleanup() }
}
