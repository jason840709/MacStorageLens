# 清理功能的維護與擴充

這份文件寫給接手磁碟透視的開發者。先閱讀[清理邏輯](cleanup-logic.md)，確認一鍵清理、人工整理和舊版進階規則的用途，再依本文件修改程式。

目前實作採用「先記錄候選檔案，再重新驗證，最後處理」的流程。掃描得到的容量不能當成刪除授權。擴充時，應先決定資料能否重新取得，以及誤判後會失去什麼，再決定是否允許自動處理。

## 開發時應維持的行為

新增自動規則必須限於固定、可解釋的產生資料位置，並且有保留期限、擁有者與使用狀態判斷。只要無法證明，先提供人工檢視。私人文件、模型、備份、套件安裝目錄和整個同步資料夾，都不應因容量很大而變成自動清理對象。

自動清理只處理原清單中的普通檔案。不能在執行時改成遞迴移除整個目錄，否則掃描後新增的資料也會被帶走。手動整理資料夾依賴使用者確認與清理前重驗；它和逐檔自動清理的保證不同，程式與文件要保留這個區別。

新增規則需要可重現的暫存測試：包含會成功的案例，也包含外觀相似但應保留的案例。真實電腦用來做唯讀盤點、權限與介面驗證；不能為了測試，把真實使用者資料送入刪除流程。

## 還有什麼需要改善

程式資料的歸屬依已知位置與識別名稱判斷，尚未涵蓋系統服務、共享群組、鑰匙圈或所有自訂安裝位置。需要專用卸載器的軟體仍應使用原廠方法。

專案使用狀態目前檢查工作目錄，不能偵測所有已開啟檔案與建置方式；下載套件中的私人修改也不能完整自動辨識。因此專案整理維持人工確認。

重複檔案依完整內容比對，沒有自動合併標籤、延伸屬性、權限或資源分支。手動移動資料夾時，如果其他程式在最後檢查後才新增內容，新內容仍可能一起移入垃圾桶。自動清理只移除原清單內的檔案，保護方式不同；使用者應先停止相關工作。

清理紀錄目前只有查看與 Finder 定位，沒有自動整批還原或永久的逐檔備份。容量統計也無法單靠檔案配置量推算檔案系統快照和共享區塊的實際回收量。

## 介面文字的維護

頁面標題直接指出功能或資料，不補口號。每段說明應讓使用者知道對象、條件、數值來源、動作或後果；同一張卡片已交代的內容，不再換句話重述。檢查結果、報告快照、即時數字與未檢查狀態必須分清楚，不能為了縮短文字改變判準。

確認畫面必須對應實際選取範圍；混選一般項目與垃圾桶時，不能把整批說成只有垃圾桶。Terminal 執行與 App 執行的停止方式不同。詳細耗時和原始診斷留在可展開區，保留追查所需的資料。介面改字後，需同步核對顯示文字別名、說明分支及操作後果；原始報告鍵與保存格式保持相容。

## 附錄：模組地圖

| 檔案 | 責任 |
|---|---|
| `CleanupWorkbenchView.swift` | 新 CleanerView：主操作、分類、選取確認、檢視、保留清單與紀錄 |
| `CleanupWorkbenchModel.swift` | 每個視窗的狀態、背景工作、取消、重新掃描、讀取歷史 |
| `CleanupWorkbenchModels.swift` | 工具／決策／檔案 snapshot／候選／掃描／執行紀錄／取消 token |
| `SmartCleanupEngine.swift` | 共用引擎、固定快取 recipes、自動掃描與 frozen-file execution、容量與紀錄 |
| `CleanupWorkbenchFiles.swift` | 專案、安裝檔、大型舊檔、三階段重複比對 |
| `ProjectArtifactPolicy.swift` | 產物識別依據與手寫／版本管理內容檢查 |
| `CleanupWorkbenchApplications.swift` | 程式與關聯資料發現；按需檢視容量 |
| `CleanupApplicationCatalog.swift` | 有界 app 發現、ID 驗證、固定 vendor folder、嵌入 app owner、執行狀態 |
| `CleanupWorkbenchExecution.swift` | 手動方案去重、keeper 防護、分類重驗、Finder Trash、專案 cwd 檢查 |
| `CleanupWorkbenchFileSafety.swift` | realpath、lstat、snapshot、下載狀態、openat／unlinkat 不跟隨 symlink |
| `CleanupWorkbenchCoordinator.swift` | 跨視窗 owner lock、執行 mutex、revision 失效 |
| `CleanupProtectionPolicy.swift` | 內建保護、Mole data whitelist、Python registry、literal 自訂保留清單 |
| `ProcessRunner.swift` | 自己啟動的程序、timeout／cancel、pipe draining |
| `AllocatedSizeReader.swift` | UTF-8 du 量測、批次失敗逐項重試、不完整容量 |
| `FinderVisibleTrash.swift` | Finder 可見垃圾桶、hidden source 暫存可見命名、receipt |
| `CleanerView.swift` | 舊版 AdvancedCleanupView；進階六層規則 |
| `AppModel.swift` | 舊掃描與清理互斥、完成後使 cleanup index 失效與更新容量 |

既有 Overview／資料樹掃描器沿用；本次沒有改掃描器報告格式或新增外部套件。專案仍為 SwiftPM、macOS 14 以上原生 AppKit／SwiftUI。

## 附錄：重要資料契約

`CleanupWorkbenchItem` 是不可變值。`id = tool|rule|path`；包含 reason、impact、bytes、snapshot、files、referencePath、contentHash、applicationID、revision。`decision` 是可自動、人工確認、保留或讀取受限。`canSelect` 不是最終授權；executor 必須重驗 rule↔tool 與現況。

`CleanupFileSnapshot` 保存 physical path、device、inode、uid、mode、logical／allocated bytes、nlink、st_flags、mtime 秒與奈秒。自動刪除以 root descriptor 和各層 `openat(O_NOFOLLOW)`、leaf `fstatat` 驗證後 `unlinkat`，不遞迴刪目錄。path-based 手動 Trash 有不同的剩餘競態，不能宣稱同等保證。

`CleanupWorkbenchCoordinator` 有 UI operation owner 與 execution owner 兩個層次。execution release 增加 revision；舊候選全數過期，不能只把舊 row 換成新 revision。Model 重新掃描剩餘項目，取消或無法更新時清掉舊結果。

每次執行產生 `CleanupWorkbenchExecution`：entries 分成功數、配置容量、錯誤和垃圾桶 receipts，另有 cancelled、availableBytesBefore／After。最多保存每組前三十個錯誤訊息。候選未量得的容量保持 nil；手動執行按需量測並重驗，執行紀錄的 sizeKnown=false 明示未加入容量統計。不能以零推論該資料夾為空。執行紀錄寫入失敗時，executor 仍回傳實際 entries 與 persistenceWarning，UI 保留結果和警示；不能用重新執行整批作為通用重試策略。

保留清單採 version 1 JSON，paths 為 literal absolute paths；限制 1 MiB／5,000 路徑，拒絕 symlink、控制字元和 `..`。正規化與 fnmatch escaping 不可移除，否則名稱中的 `*?[]` 會擴張範圍。設定解析失敗會 fail closed。

## 附錄：如何新增一條規則

1. 在研究文件加上第一手來源、測試的 app／資料版本、固定路徑和可重建原因，說明離線與重新下載的影響。
2. 優先新增人工工具候選。若要 automatic，限制 owner、age、leaf type、depth／entry cap、incomplete handling，並保留 user exclusion 和 runtime registry。
3. 掃描端與執行端必須共享同一規則依據。執行端從固定 recipe 重新建立合法根；不得信任 UI 或磁碟上 JSON 自帶的 rule／path。
4. 測試錯誤 owner、同名資料夾、symbolic link、root replacement、hard link、cloud placeholder、recent modification、取消、late protection 和舊 revision。
5. 有多份 owner 或共享資料時，先保留。不要以 CFBundleName／app filename 拼出 Support 或 Containers 路徑。
6. 修改 UI 文案、此規則文件與測試入口，跑完整原始碼驗證和原生 release build。

## 附錄：驗證入口

`Verification/SmartCleanupAudit.swift` 以 fake home 建立已知 app、舊新暫存和保護設定，實際刪除的只有 temporary fixture；包括 late protection、檔案改變、app 新啟動、新專案標記與偽造 root。

`Verification/CleanupWorkbenchFixtureAudit.swift` 驗證 app 改名與路徑跳脫、嵌入 app sharing、專案證據、手寫來源、虛擬環境保留、遞迴安裝檔、duplicate 全內容／keeper／hardlink、revision 與 cancellation。測試以注入的 recycle closure 移入 temporary fixture trash，不操作真實垃圾桶。

`Verification/CleanupWorkbenchBoundaryAudit.swift` 補充 literal 保留名稱、設定毀損、套件快取、app+data 次序、權限與大小寫、實際專案移動／cwd 拒絕及取消邊界。完整原始碼驗證入口為 `scripts/驗證原始碼.command`；release build 使用 `swift build -c release`。實際通過的結果與環境請看該版 release notes，不把文件中的測試入口當作已通過紀錄。

本機唯讀掃描結果可能包含私人路徑；不得提交。公開的 regression fixtures 一律使用 temporary fake home。編譯期間勿編輯同一組 Swift source，避免編譯器讀到不同版本。
