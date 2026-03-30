# Dead Man (PowerShell 版)

> 改寫自 [upa/deadman](https://github.com/upa/deadman)（MIT License）

deadman 是一個使用 Ping 監控主機狀態的觀測工具。透過 ICMP Echo 或 TCP SYN 檢查主機是否存活，並以終端機 UI 即時顯示結果。

此版本完全使用 **PowerShell 7+** 實作，透過 `System.Console` API 繪製終端機介面，適用於 Windows、macOS、Linux。

## 功能特色

- 🔍 即時 Ping 監控多個主機
- 📊 Unicode 柱狀圖顯示 RTT 歷史（▁▂▃▄▅▆▇█）
- 🎨 色彩標示：綠色 = 存活、紅色 = 無回應
- ⚡ 支援同步（逐一）與非同步（並行）Ping 模式
- � TCP Ping 支援：Windows 使用 `Test-NetConnection`，macOS/Linux 使用 `hping3`
- �📁 設定檔格式與原版完全相容
- 📝 可選的日誌記錄功能
- 🔄 按鍵互動：`r` 重置統計、`q` 退出
- 📐 自動偵測終端機尺寸變化並重繪

## 前置條件

- **PowerShell 7.0** 或更新版本
  - Windows：`winget install Microsoft.PowerShell`
  - macOS：`brew install powershell`
  - Linux：參考 [官方安裝指南](https://learn.microsoft.com/zh-tw/powershell/scripting/install/installing-powershell-on-linux)
- 非同步模式需要 `ThreadJob` 模組（PowerShell 7 內建）
- macOS/Linux 的 TCP Ping 需要安裝 [hping3](https://github.com/antirez/hping)（`brew install hping` / `apt install hping3`）
- macOS/Linux 的 TCP Ping 需要 `sudo`（root 權限）以發送 raw packets：`sudo pwsh ./deadman.ps1 ...`
- Windows 的 TCP Ping 使用內建的 `Test-NetConnection` Cmdlet

## 快速開始

```powershell
# 複製專案
git clone https://github.com/pichuang/deadman-win.git
cd deadman-win

# 使用預設設定檔啟動（同步模式）
./deadman.ps1 -ConfigFile deadman.conf

# 非同步模式（同時 Ping 所有目標）
./deadman.ps1 -ConfigFile deadman.conf -AsyncMode

# 自訂 RTT 刻度為 20ms 並啟用日誌
./deadman.ps1 -ConfigFile deadman.conf -Scale 20 -LogDir ./logs
```

## 參數說明

| 參數 | 別名 | 類型 | 說明 |
|------|------|------|------|
| `-ConfigFile` | | string | 設定檔路徑（必要） |
| `-Scale` | `-s` | int | RTT 柱狀圖刻度，預設 10（毫秒） |
| `-AsyncMode` | `-a` | switch | 啟用非同步 Ping 模式 |
| `-BlinkArrow` | `-b` | switch | 非同步模式下閃爍箭頭指示器 |
| `-LogDir` | `-l` | string | 日誌目錄路徑 |

## 設定檔格式

設定檔格式與[原版 deadman](https://github.com/upa/deadman) 完全相容：

```conf
#
# deadman 設定檔
# 格式：名稱    位址    [選項]
#

# === 基本目標 ===
googleDNS       8.8.8.8
quad9           9.9.9.9

# === 分隔線（用 --- 或更多連字號）===
---

# === IPv6 目標 ===
googleDNS-v6    2001:4860:4860::8888

# === 指定來源介面 ===
local-eth0      192.168.1.1     source=eth0

# === TCP Ping 目標 ===
web-https       10.0.0.1        via=tcp port=443
web-http        10.0.0.2        via=tcp port=80
```

### 支援的選項

| 選項 | 說明 |
|------|------|
| `source=介面` | 指定 Ping 的來源網路介面 |
| `via=tcp` | 使用 TCP SYN Ping 取代 ICMP |
| `port=埠號` | TCP 埠號（需搭配 `via=tcp`） |

> **注意**：原版的 SSH relay（`relay=`）、SNMP（`via=snmp`）、netns、VRF 等進階選項在設定檔中會被正常解析但不使用，不會產生錯誤。

## 按鍵操作

| 按鍵 | 功能 |
|------|------|
| `r` | 重置所有目標的統計資料 |
| `q` | 退出程式 |

## 執行測試

使用 [Pester 5](https://pester.dev/) 測試框架：

```powershell
# 安裝 Pester（如尚未安裝）
Install-Module -Name Pester -MinimumVersion 5.0 -Force -Scope CurrentUser

# 執行所有測試
Invoke-Pester ./tests/ -Output Detailed

# 僅執行特定測試檔案
Invoke-Pester ./tests/ConfigParser.Tests.ps1 -Output Detailed

# 排除需要網路的測試
Invoke-Pester ./tests/ -Output Detailed -ExcludeTag 'Network'
```

## 專案結構

```
deadman-win/
├── deadman.ps1           # 主程式進入點（參數解析、主迴圈）
├── deadman.conf          # 範例設定檔
├── lib/
│   ├── PingTarget.ps1    # PingTarget / PingResult 類別定義
│   ├── ConfigParser.ps1  # 設定檔解析函式
│   └── ConsoleUI.ps1     # 終端機 UI 繪製類別
├── tests/
│   ├── PingTarget.Tests.ps1    # PingTarget 單元測試
│   ├── ConfigParser.Tests.ps1  # ConfigParser 單元測試
│   ├── ConsoleUI.Tests.ps1     # ConsoleUI 單元測試
│   └── Integration.Tests.ps1   # 整合測試
└── README.md
```

## 與原版差異

| 功能 | 原版 (Python) | 此版 (PowerShell) |
|------|--------------|------------------|
| 語言 | Python 3 + curses | PowerShell 7+ |
| UI 框架 | curses | System.Console API |
| Ping 實作 | subprocess (ping 指令) | Test-Connection Cmdlet |
| 非同步 | asyncio | ThreadJob / ForEach-Object -Parallel |
| SSH Relay | ✅ | ❌（設定檔相容，但不使用） |
| SNMP Ping | ✅ | ❌ |
| RouterOS API | ✅ | ❌ |
| netns / VRF | ✅ | ❌ |
| TCP Ping (hping3) | ✅ | ✅（Windows: tnc，macOS/Linux: hping3） |
| SIGHUP 重載 | ✅ | ❌（Windows 不支援 SIGHUP） |

## 授權

MIT License — 與原版相同

## 致謝

- [upa/deadman](https://github.com/upa/deadman) — 原始 Python 版本
- 原始設計與實作：Interop Tokyo ShowNet NOC 團隊
