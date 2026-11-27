# pingpongman

[![CI](https://github.com/pichuang/pingpongman/actions/workflows/ci.yml/badge.svg)](https://github.com/pichuang/pingpongman/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/pichuang/pingpongman/badge)](https://scorecard.dev/viewer/?uri=github.com/pichuang/pingpongman)

以**單一 PowerShell 檔案**即時監控 ICMP、TCP、HTTP 與 HTTPS。
本專案由 [upa/deadman](https://github.com/upa/deadman) 的 Python 版本移植，
採 MIT 授權。執行時只使用 PowerShell 內建指令與系統 .NET API，
不需要額外模組、外部執行檔、編譯輔助程式、背景工作或第三方執行階段相依套件。

[English documentation](README.md)。本頁提供繁體中文說明；程式、終端介面與 `-Help` 仍維持 ASCII 英文。

## 快速開始

從 [GitHub 倉庫](https://github.com/pichuang/pingpongman) 取得程式；
已發布版本可在 [Releases](https://github.com/pichuang/pingpongman/releases) 查看。
確認下載版本內的實際檔名：歷史版本仍可能使用舊名稱。
使用者只需複製 **`pingpongman.ps1`** 到目的機器，
編輯檔案開頭的 `$script:EmbeddedConfig` 目標清單，再從互動式 PowerShell 終端執行：

```powershell
.\pingpongman.ps1
.\pingpongman.ps1 -AsyncMode
.\pingpongman.ps1 -Interval 1 -Timeout 3 -Scale 20 -LogDir .\logs
.\pingpongman.ps1 -Help
```

如需獨立設定檔，可加上 `-ConfigFile .\pingpongman.conf`，取代內嵌目標。
程式**不會**自動讀取同目錄的設定檔；不傳此參數就只使用內嵌內容。
請遵循組織的執行原則，程式不要求變更 execution policy。

## 執行需求與 Windows 驗證範圍

- Windows PowerShell **5.1** 搭配 **.NET Framework 4.7.2 以上**，建議 4.8；
  或使用作業系統正式支援的 **PowerShell 7+** 版本。
- 互動式 `powershell.exe` 或 `pwsh` 終端，例如傳統 conhost、Windows Terminal、
  VS Code terminal。不支援 PowerShell ISE 或重新導向的輸入／輸出，遇到時會明確報錯。
- 可正常使用的 DNS、網路路由、受信任的 HTTPS 根憑證與系統 TLS 設定。
  防火牆及 ICMP 權限可能造成探測失敗。
- 一般 TCP／HTTP 探測不需要系統管理員權限。

| 環境 | 覆蓋範圍／前置需求 |
|---|---|
| Windows 10／Windows 11 | 目標使用環境，仍需實機終端驗證 |
| Windows Server 2016 | 確認 Windows PowerShell 5.1 與 .NET 前置需求，仍需實機驗證 |
| Windows Server 2012 | 先安裝 WMF 5.1 與受支援的 .NET Framework，仍需實機驗證 |
| Windows Server 2022／2025 | CI 自動執行 Windows PowerShell 5.1 與 PowerShell 7 的 Pester 測試 |
| macOS／Linux 搭配 PowerShell 7 | 使用相同 .NET 探測與終端 API，不代表已驗證舊版 Windows |

Server 2022／2025 的 CI **不能取代** Windows 10／11／Server 2012／2016 實機及終端測試。
各 PowerShell 7 版本另有自身的作業系統支援範圍，本專案不會延長其支援。
舊系統還需要適當修補、TLS 設定與根憑證，才能連線至現代 HTTPS 站台。
程式不提供略過 TLS 驗證的選項。

### 避免終端亂碼

程式原始碼、說明與終端介面均為可列印的 ASCII 英文。
RTT 歷史使用數字 `1..8` 而非 Unicode 方塊；
不需要執行 `chcp`、變更字型、修改編碼或啟用 ANSI。
程式不變更終端色彩與編碼，只會在執行期間調整 Windows 游標可見性與 Ctrl+C 處理，
並在 `finally` 還原原始狀態。

## 監控目標

內嵌清單與選用設定範例均以 `ifconfig.blackair.io` 作為四協定的成功代表：

```text
blackair-icmp  ifconfig.blackair.io
blackair-tcp   ifconfig.blackair.io          via=tcp port=443
blackair-http  http://ifconfig.blackair.io/
blackair-https https://ifconfig.blackair.io/
```

2026 年 11 月 27 日從開發環境實測：收到 ICMP echo reply、成功連線 TCP 443，
HTTP 與 HTTPS 的最終回應皆為 **200**，HTTPS 保留正常憑證驗證。
公開服務可用性與各環境的 ICMP／TLS 政策不同，這些範例不是成功保證，也不是自動測試的外部相依。

### 故意失敗的範例

內嵌與選用設定也會啟用以下目標，方便比較正常與失敗的執行結果：

```text
fail-dns  no-such-host.invalid
fail-port ifconfig.blackair.io via=tcp port=81
```

| 目標 | 預期失敗原因 | 修正方式 |
|---|---|---|
| `fail-dns` | `.invalid` 為無效名稱保留網域，一般 DNS 解析會失敗 | 改成真實主機名稱，例如 `ifconfig.blackair.io`；真實名稱也失敗時檢查 DNS 設定 |
| `fail-port` | 故意使用不同於正常 TCP 範例 443 的連接埠 81；未監聽時可能拒絕連線，防火牆也可能導致逾時 | 改成實際服務連接埠，例如 443，並檢查服務監聽、路由與防火牆 |

2026 年 11 月 27 日的開發環境分別觀察到名稱解析錯誤與逾時。
公開連接埠不保證永遠關閉；若日後 port 81 有服務，此範例也可能成功。
錯誤細節會隨作業系統與網路而異。這些目標會顯示失敗 `X`，
但不妨礙其他目標繼續監控；示範後可刪除或註解這兩列。

執行時探測失敗與**設定格式錯誤**不同。
例如 `bad-port localhost via=tcp port=70000` 或 `bad-url https:///`
會讓程式在啟動時停止，並顯示來源及行號；這類錯誤設定並未啟用在預設範例中。
請先將連接埠修正為 1..65535，或提供完整 HTTP／HTTPS URL，再重新啟動。

### 設定語法

內嵌內容與選用 UTF-8 設定檔使用**同一個嚴格解析器**。
以下為其他語法示例，請替換為自己的端點：

```text
# name        address                         options
gateway       192.0.2.1
loopback-v6   ::1
dns           dns.example.com                  via=icmp
---
database      db.example.com                   via=tcp port=1433
health        http://localhost:8080/health
website       https://example.com/              via=https
```

- 以空格或 Tab 分隔：`name address [via=protocol] [port=number]`。
- 名稱不分大小寫且不得重複，長度 1..64；僅接受 ASCII 字母、數字、`_`、`-`、`.`，
  並以字母或數字開頭。結尾句點、Windows 裝置保留名稱及路徑字元會被拒絕，
  確保名稱可安全用於日誌檔名。
- 主機名稱、IPv4／IPv6 位址預設使用 ICMP；TCP 必須指定 `via=tcp port=1..65535`。
  TCP 檢查會建立完整連線，不是 raw SYN 探測。
- 完整 `http://` 或 `https://` URL 會自動選擇協定；
  若明確指定 `via=http`／`via=https`，必須與 URL scheme 一致。
  HTTP 連接埠寫在 URL 內；IPv6 URL 使用方括號，例如 `http://[::1]:8080/`。
  不接受內含帳號密碼的 URL。
- `---`（三個以上連字號）加入群組分隔列，也占一列捲動範圍。
  空白行與整行 `#` 註解會被忽略；目標後方可加 `; # comment`，URL 的 `#fragment` 會保留。
- 不支援的 SSH／relay、SNMP、來源／介面、netns、VRF 及未知選項，
  會**明確報錯並附來源與行號**。連接埠／URL 不合法、重複選項、缺少位址或沒有實際目標也會報錯。
  相較舊解析器，這是刻意採取的嚴格行為，不會悄悄退回 ICMP。

## 探測與計時

| 協定 | 成功條件 | 計時範圍 |
|---|---|---|
| ICMP | 收到狀態為 `Success` 的 echo reply | 回應所記錄的往返時間 |
| TCP | 成功建立連線 | DNS 與 TCP connect，包含不同位址重試 |
| HTTP／HTTPS | **最終回應為 200..399** | 從 GET 到最終回應標頭，包含 DNS、TCP、TLS 與重新導向 |

HTTP 使用 `ResponseHeadersRead`，**不會**下載或等待完整回應本文。
HTTP 400..599 視為失敗，終端與日誌會顯示狀態碼。
自動重新導向最多 **5 次**；到達上限時，不同執行階段可能回傳最終 3xx
（依上述規則仍視為成功），或回報重新導向錯誤。
HTTPS 採平台正常憑證驗證與預設 TLS，不設定全域憑證 callback、不變更全域 TLS，也不提供 bypass。

每次探測有各自的期限，預設 **3 秒，包含 DNS**。
程式逐筆輪詢已完成的 task，不使用 `WaitAll`，所以慢目標不會灌大其他目標的 RTT。
TCP／HTTP 計時受主迴圈輪詢粒度影響，通常約 10 ms，主機負載可能增加排程延遲。

預設循序探測；`-AsyncMode` 會同時啟動該輪全部目標。
`-Interval` 預設 **1 秒**，代表各輪開始時間的最小間距，不是慢速輪次完成後再額外等待一秒。
不同輪次不會重疊；兩種模式在等待探測時都會處理鍵盤與終端尺寸變化。

部分舊 .NET DNS 操作無法立即取消。逾時或重設後，程式丟棄結果、關閉自己建立的網路資源，
且每個目標最多保留**一個**未完成 task。
尚未收尾時顯示 `Previous probe still finishing`，避免持續累積背景工作；
晚到的 fault 會被觀察，HTTP response 也會在重試前釋放。

## 畫面與操作

| 按鍵 | 功能 |
|---|---|
| 上／下方向鍵 | 捲動**目標清單**，不是 RTT 歷史 |
| R | 取消目前輪次並重設所有目標統計 |
| Q／Ctrl+C | 停止探測、釋放資源並還原終端狀態 |

標題與可見列範圍固定顯示；畫面外的目標仍繼續探測，群組分隔列隨清單捲動。
視窗縮放會限制捲動偏移、清除舊列並裁切窄畫面。
寬度達 110 欄時顯示位址欄，窄畫面優先保留統計。
視窗太矮會提示放大，但仍接受按鍵；最後一欄與最後一列保留不繪製，避免終端自動捲動。

`LOSS%` 計算失敗比例；`AVG` 只平均**成功**的 RTT；
`SNT` 為已完成探測次數，包含失敗。
失敗時清除目前 RTT／TTL，改顯示錯誤細節或 HTTP 狀態，不保留過時 RTT。
待完成探測以 `>` 標示，可用 `-BlinkArrow` 讓標記閃爍。

歷史由新到舊排列，每個目標最多保留 **256** 筆：
成功值為 `min(8, floor(RTT / Scale) + 1)`，失敗為 `X`。
使用 `-Scale 10` 時，0 至未滿 10 ms 顯示 `1`、10 至未滿 20 ms 顯示 `2`、70 ms 以上顯示 `8`。

## 參數

| 參數 | 預設值 | 說明 |
|---|---|---|
| `-ConfigFile` | 內嵌目標 | 選用設定檔，也可作為位置參數傳入 |
| `-Scale`、`-s` | 10 | RTT 數字區間寬度，單位毫秒，須為正整數 |
| `-Interval` | 1 | 輪次開始間距，0.01..86400 秒 |
| `-Timeout` | 3 | 單次探測期限，0.01..86400 秒 |
| `-AsyncMode`、`-a` | 關閉 | 同時探測多個目標 |
| `-BlinkArrow`、`-b` | 關閉 | 閃爍待完成探測標記 |
| `-LogDir`、`-l` | 無 | 每個目標附加寫入 `<name>.jsonl` 日誌 |
| `-Help`、`-h` | 關閉 | 顯示說明，也接受 `--help` |

每行 JSON 日誌包含帶 UTC offset 的時間戳、目標名稱／位址、協定、成功與否、
RTT、平均值、探測次數、失敗次數、HTTP 狀態及錯誤細節。
寫入失敗會停止監控並報錯，不會默默丟失資料。
日誌可能含內部位址與 URL，請妥善保護。

## 開發與驗證

Pester 與 PSScriptAnalyzer 只屬於**開發相依**，一般執行不需要安裝：

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester ./tests/ -Output Detailed -ExcludeTag Network
Invoke-ScriptAnalyzer ./pingpongman.ps1 -Severity Error,Warning -ExcludeRule PSAvoidUsingWriteHost
Invoke-ScriptAnalyzer ./pingpongman.ps1 -Settings @{
    IncludeRules = @('PSUseCompatibleSyntax')
    Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } }
}
```

測試使用可控制的 task 完成狀態與本機 TCP／HTTP／TLS 服務，不依賴公開網際網路端點。
捲動範圍與按鍵計算不需要真正終端；`Fuzz` 涵蓋產生式解析器與有界狀態案例。
真正 ICMP 測試因權限／防火牆差異標記為 `Network`。

交付前，仍應在實際 Windows 目標機器人工確認：只帶單檔啟動、四種協定及
受信任／不受信任 HTTPS、多於可見列的上下捲動、慢 DNS／探測期間捲動、
縮成窄／矮視窗、忙碌時重設、Q／Ctrl+C 結束，以及原始終端狀態還原。
請記錄實際作業系統、PowerShell／.NET 版本與終端主機，不可由 CI runner 名稱推論覆蓋範圍。

CI 保留 Windows Server 2022／2025 × PowerShell 5.1／7，GitHub Actions 均以 SHA 固定版本。
開發採 `develop` → PR 至受保護的 `main`，通過既定 CI 與審核後才能合併，不繞過保護。
Release 壓縮檔包含程式、選用設定／文件與 MIT 授權。
使用者只需要程式單檔，其內已包含版權與授權文字。

## 來源與變更歷史

pingpongman 是原名 **deadman-pwsh** 的 PowerShell 移植版本，
**不是**將原始 Python 專案重新命名。

- **原始 Python 專案：**[upa/deadman](https://github.com/upa/deadman)，
  由 ShowNet NOC 團隊為 Interop Tokyo ShowNet 設計。
  原始[提交歷史](https://github.com/upa/deadman/commits/master/)與
  [MIT 授權](https://github.com/upa/deadman/blob/master/LICENSE)保留於上游。
- **PowerShell 移植：**於 2026-03-30 從
  [6c5286d](https://github.com/pichuang/pingpongman/commit/6c5286d) 開始；
  2026-03-31 的 [c8c0498](https://github.com/pichuang/pingpongman/commit/c8c0498)
  將程式整合成單一檔案。
- **四協定改寫：**2026-11-27 的
  [6120b68](https://github.com/pichuang/pingpongman/commit/6120b68)
  加入 HTTP／HTTPS、嚴格設定解析、獨立探測期限、數字 ASCII 歷史與目標清單捲動。
- **更名為 pingpongman：**GitHub 倉庫原地更名，保留 commit ID、issues 與 pull requests。
  執行入口改為 `pingpongman.ps1`，選用設定改為 `pingpongman.conf`，協定行為不變。
  歷史提交與已發布資產保留當時的 `deadman-pwsh`／`deadman.ps1` 名稱，不改寫過去。

本移植版的[完整歷史](https://github.com/pichuang/pingpongman/commits/main/)可在 GitHub 查閱。
上游與既有 PowerShell 移植版的版權聲明均保留於 [LICENSE](LICENSE) 與可散布的單檔程式中。

## 授權與致謝

採 [MIT License](LICENSE)，保留上游來源標示。
原始 Python 設計來自 [upa/deadman](https://github.com/upa/deadman)
與 Interop Tokyo ShowNet NOC 團隊。
私下回報安全問題的方式請見 [SECURITY.md](SECURITY.md)。
