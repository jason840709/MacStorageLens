# Changelog

## 1.7.5 — 2026-08-26 — 系統垃圾規則深度整合與廢紙簍

- 重新以 MacSai 實際 Swift source／tests 為依據完成 System Junk knowledge integration；嚴格 App orphan、corrupt plist、下載殘留、Xcode／IDE／AI／package-manager cache allowlist，以及 Spotify／Gradle／shared-runtime／user-data negative rules 都由 MacStorageLens 自己的 policy 與 executor 實作。
- Build 33 移除安全清理頁的版本專屬「1.7.5 清理規則整併位置」卡片。清理等級選擇器現在是唯一入口：所選 profile 的摘要由 `CleanupScope.cases(for:)` 與 `minimumTier` 動態列出掃描範圍，不再為每個版本堆疊一次性 UI。
- 選取 L5 時，摘要內就地呈現高影響資料、廢紙簍永久清空與系統僅檢視三項附加功能；選取自定義時才顯示逐項 scope 開關。MacSai attribution 收斂為摘要底部的一行低干擾來源說明。
- 新增 `trashBins` scope/category 與 `trashBinContents` rule。L5 掃描目前使用者 `~/.Trash`，以及本機、可寫、非內置、非 Time Machine 外接卷宗 `.Trashes/<目前 UID>`。
- 廢紙簍候選為 direct-only／high-risk／manual-only；只永久移除本次掃描列出的第一層項目，保留 root。其他 UID、整棵 `.Trashes`、NAS `#recycle`、遠端 mount、符號連結、控制字元與越界 forged path 全部拒絕。
- `CleanupIncrementalIndex` schema 升為 6，讓 Build 32 曾自動包含的 L5 高影響範圍失效重建；Trash 執行後仍會移除 `.trashBins` covered scope，使下一次補充掃描重新列舉。
- `ExternalVolumeCleanupExecutor.validateExternalVolumeRoot` 保留可注入 volumes root 的 fixture seam；正式 App 仍只允許 `/Volumes` 一層真實外接卷宗，並維持 local／writable／non-internal／non-Time-Machine gate。
- `TrashBinsCleanupAudit.swift`、source-reviewed policy／filesystem fixtures、1.7.5 provenance 與靜態契約均保留；UI contract 改為檢查「沒有版本卡、動態 scope 詳情、L5 contextual options、自定義逐項設定」。
- App：1.7.5 / Build 33；Scanner：2.5.3。

## 1.7.4 — 2026-08-23 — 外部 AppleDouble 高價值清理與 NAS 回收區排除

- 新增內建／外部儲存辨識：macOS mount capability 讀取 `volumeIsInternal`，遠端 mount 或 `isInternal == false` 的 SD 卡、USB／外接磁碟與 NAS 採外部 AppleDouble policy；本機內建磁碟維持原分級。
- 外部媒體上，metadata-only 孤立 AppleDouble 從平衡提前到保守，metadata-only 配對 AppleDouble 從激進提前到平衡；候選風險分別降為 low／moderate，UI 明示這是外部媒體的高價值殘留清理。
- AppleDouble binary 安全紅線完全保留：非空 resource fork、未知／應用程式 entry、package／symlink companion、無法驗證 header 的 `._*` 仍是 review-only。
- Safe Cleanup 對遠端 mount 的根層 `#recycle` 整棵跳過。live scan、report-guided scan、dirty-directory refresh 與執行前 path revalidation 都拒絕進入 server recycle subtree；容量總覽資料仍可保留其容量帳務。
- 修正 Application Support render cache 大小寫/canonical-path 假候選：不再自行拼 `Cache`，改由實際 directory entry 尋找 case-insensitive cache markers；scanner 與 executor 共用同一 marker 判斷。
- Cleanup Incremental Index schema 升為 2，避免舊 index 沿用 1.7.3 前的 AppleDouble tier 與 `#recycle` discovery 狀態。
- 新增 `ExternalAppleDoubleCleanupAudit`、Application Cache canonical path audit，並擴充 report-guided、mount capability 與 incremental-index fixtures。
- App 更新為 1.7.4 / Build 31；Scanner 維持 2.5.3。

## 1.7.3 — 2026-08-23 — 補充掃描與完整重新掃描分流

- 修正 1.7.2 把增量掃描最佳化變成唯一入口的 UX 問題。第一次沒有 index 時只顯示「開始掃描」；已有 index 後同時顯示「補充掃描」與「完整重新掃描」。
- 補充掃描維持 delta workflow：只處理 missing scopes 與 dirty parent directories，不重做已覆蓋 discovery。
- 完整重新掃描使用 `CleanupIncrementalIndex.resettingDiscovery()` 從空白 index 開始，舊 candidates、covered scopes、dirty directories 都不會帶入。
- 完整重掃採交易式替換：新 index 成功才覆寫舊 index；若掃描失敗，App 恢復上一份 index，persisted report-guided index 也不會被失敗工作破壞。
- Cleaner 的增量索引卡明示兩種掃描語意；cleanup source 與 index refresh choice 保持分離。
- `CleanupIncrementalIndexAudit` 增加 full-rebuild reset checks；靜態契約增加 first-scan single action、雙按鈕 UI、fresh-index branch 與 failure rollback。
- App 更新為 1.7.3 / Build 30；Scanner 維持 2.5.3。

## 1.7.2 — 2026-08-23 — 安全清理增量索引與跨等級重用

- 新增 `CleanupIncrementalIndex`，把已驗證 cleanup scopes 與候選保存成可增量重用的索引；切換清理等級時只掃描新增規則。
- report-guided 一般位置索引綁定 `ScanTarget`、掃描來源、Markdown 路徑與 `ReportFileSignature`，只在簽章仍相同時跨啟動載入；corrupt、stale 或來源不符立即捨棄。
- 完成清理後不再把整份候選清空。成功刪除的 exact paths 從索引移除；失敗與未選取項目保留；只把受影響的一般位置父資料夾標記為 dirty。
- 新增 targeted directory refresh，只列舉 dirty parents 的第一層或執行精確名稱 probe，不會重新遞迴整個 NAS。
- `CleanupCandidate` 新增 `matchedPathBytes`，群組候選可在部分成功／部分失敗時精確保留剩餘路徑與容量。
- AppleDouble remnants／paired metadata／review 三個 scope 在需要任一者時共用同次第一層 listing；不預先拉入 unrelated mac-managed／legacy scopes。
- profile、custom scopes 與 minimum size 變更改為重新套用現有 index；只有缺少 scopes 或 dirty directories 才產生實際 I/O。
- deletion safety contract 不變：cache/index 不是 deletion authority，執行前仍逐項 live revalidation，遠端 mount capability 也照 1.7.1 再檢查。
- 新增 `CleanupIncrementalIndexAudit`；ReportLibrary 增加 `Cleanup Indexes` 目錄。App 更新為 1.7.2 / Build 29，Scanner 維持 2.5.3。

## 1.7.1 — 2026-08-22 — 容量報告快速安全清理與 NAS 刪除能力辨識

- 安全清理新增兩種候選來源：「使用既有容量報告（快速）」與「重新掃描目標（完整）」。
- 快速模式串流讀取同一邏輯目標的 `DIRECTORY_TREE` 作為資料夾導航索引，不再為大型 NAS 重做整棵遞迴 discovery；命中清理規則後仍以目前檔案系統即時驗證 metadata 與 AppleDouble。
- Markdown 明確不作為刪除授權；報告後新增的整個新資料夾可能不在快速導航索引中，資料樹大幅變更時保留完整重新掃描。
- 新增 `CleanupTargetCapabilityResolver`：macOS 以 `statfs` filesystem type、`MNT_LOCAL`、`MNT_RDONLY` 判斷目前掛載清理能力，必要時以 URL volume resource values 保守 fallback。
- SMB／CIFS、NFS、WebDAV／DAVFS、AFP、SSHFS 等遠端卷宗自動停用「移到 Finder 可見垃圾桶」；畫面改為灰色不可按並說明原因，只保留直接刪除。
- 唯讀掛載停用 Finder Trash 與直接刪除；無法可靠辨識 local／remote 的掛載也不會冒充 Finder Trash 可用。
- CleanupEngine 執行前重新解析 mount capability，避免掛載狀態在候選掃描後改變。遠端直接刪除仍逐項重驗證後呼叫 `FileManager.removeItem`。
- 遠端 cleanup log 使用 `client_direct_delete_server_retention_unknown`；明示客戶端不經 Finder Trash，但 NAS／伺服器的 recycle bin、snapshot 或版本保護仍可能保留資料。
- 不自行把檔案搬入 `#recycle` 或其他廠商私有回收目錄，避免假裝那是跨 NAS 通用垃圾桶。
- 新增 `ReportGuidedCleanupAudit` 與 `CleanupTargetCapabilityAudit`；App 更新為 1.7.1 / Build 28，Scanner 維持 2.5.3。

## 1.7.0 — 2026-08-22 — 容量地圖完整鑽取與高門檻合併

- 移除每層固定只顯示 12 個子資料夾的過度積極合併；同層 2,048 項以下全部直接呈現。
- 超過 2,048 個同層子資料夾時才啟用密度保護，保留最大的 512 項並建立「其他 N 項」。
- `.otherChildren` 由不可互動帳務節點改為可展開 aggregate，保留父資料夾路徑。
- 點擊「其他 N 項」會從既有 Markdown 報告索引恢復完整省略清單，切換到 aggregate focus；所有項目可逐項進入，不需要重新掃描檔案系統。
- 資料樹與容量圖提示同步說明展開行為；上一層返回原父節點。
- Report presentation index schema 升為 2 / `report-presentation-1.7.0-v1`，舊 1.6.x presentation cache 自動失效。
- 新增 `SunburstAggregationAudit`，驗證小量 13 項不合併、大量 2,055 項才合併且 aggregate 可完整還原。
- App 更新為 1.7.0 / Build 27；Scanner 維持 2.5.3。

## 1.6.8 — 2026-08-22 — NAS 長時間掃描活動式逾時與署名修正

- 將開發者名稱由錯誤的 `Jason Chan` 修正為 `Jason Chen`，同步更新 App metadata、建置 Info.plist 與版權字串。
- 移除 `ScannerLauncher` 的 30 分鐘 `maximumRunSeconds` 總執行硬上限；長時間 NAS／遠端磁碟掃描不再因總耗時達 30 分鐘而被中止。
- 新增 10 分鐘 `meaningfulProgressTimeoutSeconds` 活動式逾時：目錄節點、錯誤計數、目前路徑、步驟、階段或完成狀態有實質變化就重設計時。
- 進度 token 明確排除 epoch、elapsed 與純 heartbeat／delayed 狀態，避免每 5 秒心跳把真正卡死誤認為仍有進展。
- App 傳給 scanner supervisor 的核心無輸出逾時由 120 秒放寬為 600 秒；底層程序存活保護仍保留。
- App 更新為 1.6.8／Build 26；Scanner 維持 2.5.3，報告 schema、APFS 帳務、Finder 可見垃圾桶與直接刪除安全邊界不變。

## 1.6.7 — 2026-08-19 — macOS 建置修正與 UI 列舉契約

- 修正 `CleanerView.scopeTint(_:)` 把 `CleanupCategory.folderLegacyTrashResidue` 誤用成 `CleanupScope` case，造成 Apple Swift 6.3.3 release build 回報 `type CleanupScope has no member folderLegacyTrashResidue`。
- legacy residue 的 `CleanupCategory`、`trash.slash` 圖示、L5 候選分類與 direct-only 行為完整保留；只移除非法的 scope tint case。
- 將報告索引寫入改成 `_ = try? ...`，消除 Swift 6 的 unused-result warning。
- 新增 `ui_enum_context_audit.py`，直接核對 `CleanupScope`／`CleanupCategory` 與 UI switch 的 extra、missing、duplicate cases。
- 原始碼驗證增加獨立 UI enum context gate；靜態契約也禁止 category-only case 再出現在 scope switch。
- App 更新為 1.6.7／Build 25；Scanner 維持 2.5.3，清理執行、報告解析、容量帳務與掃描效能核心未改。

## 1.6.6 — 2026-08-19 — Finder 可見垃圾桶與無中介直接刪除

- 承認並修正舊外接卷宗清理的嚴重語意缺陷：點號 Spotlight／FSEvents 可能被放進卷宗隱藏 `.Trashes/<uid>`，來源消失但容量未釋放，而且 Finder／App 未必能看到。
- 清理介面固定只保留兩種執行結果：「移到 Finder 可見垃圾桶」與「直接徹底刪除」。沒有第三種私有 Trash、隱藏暫存或自動降級路徑。
- 新增 `FinderVisibleTrash` coordinator。可逆動作統一使用 `NSWorkspace.recycle`；MacStorageLens 不自行建立 `.Trashes`／`.Trash`。
- 點號或 hidden 來源會先在原父層改成唯一的非點號可見名稱。只有 Finder 回傳的目的地仍存在、是 Finder 管理垃圾桶直接子項、名稱非點號且 `hidden=false` 時才記錄成功。
- 成功後立即要求 Finder 以 `activateFileViewerSelecting` 選取精確目的地；AppKit 沒有 Finder 視窗渲染回呼，因此紀錄描述的是結構可見性驗證與 reveal request，不冒充實際畫面回執。
- Finder 回收或可見性驗證失敗時，App 不會宣稱成功，也不會改用隱藏垃圾桶；會嘗試還原來源，無法原位還原時保存成來源旁的可見項目並回報精確路徑。
- 直接徹底刪除不再先移入垃圾桶。一般路徑直接使用 `FileManager.removeItem`；外接卷宗 Spotlight／FSEvents 仍額外驗證卷宗 root、local／non-internal／writable、symlink、package、device／inode 與重建狀態。
- 移除 direct path 的 `no_log` 建立、舊 Trash discovery side effect、root shell／osascript／`rm -rf` 與 Trash 中介。
- 系統快取、沙盒快取、開發工具、一般資料夾 metadata、AppleDouble 與外接卷宗全部共用兩模式契約；官方 Homebrew／Conda 候選只在直接模式執行固定 executable／argv。
- 外接卷宗 L5 會非遞迴列出舊版 `.Trashes/<uid>`／`.Trash` 中精確的點號 Spotlight／FSEvents 殘留。這些候選只可逐項直接刪除，不參與全選；不掃描或清空垃圾桶其他內容。
- 新 cleanup JSON 加入 `finderVisibleTrashItems`、`spaceReleaseSemantics`、`removalMethod`。`pending_finder_trash_empty` 明確表示清空 Finder 垃圾桶前仍占來源卷宗空間；`immediate_direct_delete` 表示無垃圾桶中介。
- 自我稽核舊 Macintosh HD 清理：歷史 JSON 可證明來源被交給垃圾桶 API 且沒有回報失敗，但缺少目的地／可見性欄位，不能追溯性宣稱每個歷史項目都曾在 Finder UI 可見。1.6.6 後 system cleanup 也使用同一 receipt-based coordinator。
- App 更新為 1.6.6／Build 24；Scanner 維持 2.5.3，報告解析、presentation index、APFS 帳務與外接掃描效能核心未改。

## 1.6.5 — 2026-08-19 — 單次報告索引與容量地圖快速載入

- 根據 v1.6.4 實機紀錄，確認約 89.7 MB／447,428 行 Macintosh HD 報告在 Scanner 完成後，仍需約 3.32 秒完整解析與 2.58 秒第二次讀取初始 Data section 建立容量圖。
- `ReportParser` 改為單次 UTF-8 串流：同一輪建立 summary、APFS／df 帳務、section offsets、頂層節點與初始四層／每層 12 項 presentation，不再為第一個畫面重讀 Data section。
- `ReportDocument` 內嵌 `ReportInitialPresentation`；資料樹與總覽共用同一份初始 children／sunburst model。
- 新增 `ReportPresentationIndexStore`，在本機 `Report Indexes` 目錄保存 summary、section offsets、頂層節點與初始 presentation；同一份未變更報告可直接還原畫面。
- Index 以路徑、大小、修改時間與頭／中／尾 64 KiB FNV-1a 樣本簽章驗證；schema、簽章、完整性或 JSON 不符時自動捨棄並回到 Markdown 單次解析。
- Index 目錄使用 0700、檔案使用 0600，單檔最大 16 MiB；刪除 App-owned 報告時連動移除，啟動與報告庫更新時清理 corrupt／orphan index。
- 首次解析新增實際 byte-offset 進度：「讀取報告索引 → 建立初始容量地圖 → 套用容量地圖」。
- 完成頁新增「建立容量索引／讀取容量索引」與「索引寫入」計時；`session-summary.json` 保存 `presentation_index_source` 與 write time。
- 修正同一外接卷宗曾以 folder／volume 方式掃描所留下的重複紀錄：Volume UUID 可唯一確認時共用 canonical retention key；同名掛載點對應多個 UUID 時不合併。
- `ReportLibraryAudit` 擴充 legacy volume-root lookup、唯一 alias 合併、重用掛載名稱歧義保護與 canonical location cap。
- 新增 `ReportPresentationIndexAudit`，驗證單次 presentation、進度單調、0600 權限、cache round-trip、中段內容變更失效、corrupt／orphan 清理。
- App 更新為 1.6.5（Build 23）；Scanner 維持 2.5.3，掃描與清理核心未擴張。

## 1.6.4 — 2026-08-19 — 外接卷宗實際耗時與 Spotlight 狀態診斷

- 根據使用者連續掃描 2 秒、18 秒、22 秒與最新 `MacStorageLens(5).zip`，確認目前保留下來的 scanner 2.5.2 完成報告只記錄 2 秒；舊版沒有保存前三次成功工作階段與端到端計時，故不能只靠該報告精確歸因。
- 移除兩個已確認不適用且不在舊報告計時內的前置工作：外接磁碟與指定資料夾不再執行 App／scanner 的 Mail、Messages、Safari、AddressBook 完整磁碟存取探針；報告改記 `NOT_APPLICABLE` 與 `selected_location`。
- scanner 全程計時從 target validation／TCC／Disk Arbitration preflight 之前開始，修正「畫面等 20 秒、報告卻寫 2 秒」的失真。
- FAT32、exFAT 等非 APFS 目標不再讀取整台 Mac 的 APFS container inventory 或 target APFS snapshots；APFS 外接卷仍保留精確 APFS 資訊。
- 修正 filesystem type 判定：不再誤用 macOS BSD `stat -f %T`，改以 `df` 裝置／掛載點精確配對 `/sbin/mount` 的 filesystem option，必要時才回退 `diskutil info -plist`。
- volume target 先直接驗證已保存掛載路徑；只有路徑失效或 UUID 不符才列舉所有 mounted volumes，並可依 UUID 找回改名後的同一張卡。
- 報告新增準備、路徑、metadata、寫入與總耗時；每個 `capture_command` 另保存自己的 `duration_seconds`。
- 新增 Spotlight、FSEvents 與卷宗 Trash 的根層 `PRESENT`／`ABSENT` 狀態、類型、device、inode 與 mtime；不遞迴計算容量。
- 總覽穩定卷宗帳務卡直接顯示三個根層狀態與各階段耗時。
- scanner 資源只在內容變更時重新安裝，不再每次掃描先刪除再複製。
- 一般位置清理完成後不再暗中自動重跑候選遍歷，避免它與使用者立即啟動的容量掃描同時讀取同一個外接卷宗；候選改為失效並等待手動重掃。
- 一般位置候選掃描只在命中精確規則後才查詢 allocated size，不再替每個普通檔案預先讀取三組容量 resource key。
- 成功掃描也保留精簡 Scan Work 診斷與 `session-summary.json`；最多 12 份、24 小時，並移除大型 TCC raw overlay，避免診斷本身累積。
- 新增 `ExternalVolumeRescanAudit.swift`，驗證非 APFS、權限不適用、Spotlight／FSEvents／Trash 狀態及分階段耗時欄位。
- scanner 完成 Markdown 後，掃描視窗維持在 99%「解析與建立畫面」；只有初始報告、資料樹與總覽容量圖都套用後才顯示完成。
- 初始根節點只執行一次 presentation 建立；同一份結果同時供資料樹與總覽使用，移除第一個畫面的重複 section 解析。
- 完成頁新增端到端、Scanner 核心、Scanner 外等待、報告解析、初始容量圖與六個 scanner phase 的耗時拆解。
- `session-summary.json` 新增目標解析、scanner 安裝、權限探測、session 準備、scanner 啟動與 post-processing 時間；Terminal 相容模式也延後到畫面真正可用後才完成。
- 報告解析期間鎖定掃描視窗，不能關閉，也不顯示已失效的取消按鈕。
- App 更新為 1.6.4（Build 22）；scanner 更新為 2.5.3。

## 1.6.3 — 2026-08-18 — 外接卷宗垃圾桶清除與穩定快速重掃

- 根據實機 cleanup JSON 確認 1.6.2 外層授權程序雖回傳 0，內層 `/bin/rm` 對 `.Spotlight-V100`／`.fseventsd` 實際回傳 `Operation not permitted`；移到垃圾桶則成功落在外接卷宗 `.Trashes/<uid>`。
- 移除 `PrivilegedCleanupExecutor`、AppleScript 管理員 shell 與固定 `rm -rf` helper；新增 `ExternalVolumeCleanupExecutor`，讓永久操作保留在 MacStorageLens 的 removable-volume TCC 責任鏈內。
- 強制模式先使用 `FileManager.trashItem` 取得精確垃圾桶 URL，再以 `FileManager.removeItem` 永久清除；若垃圾桶步驟不可用，僅在精確路徑、device／inode 再驗證通過後使用 App-owned direct removal。
- 讀取新 `trashItemPaths`、舊版「垃圾桶位置：」notes，並直接列出目前 `.Trashes/<uid>` 的 hidden direct children；Finder 手動移入且名稱精確匹配的 Spotlight／FSEvents 副本也能永久清除。
- JSON 新增 `trashItemPaths`、`removalMethod`、`errorDomain`、`errorCode`；強制流程不再寫入假的 `commandExitStatus=0`，並以 `sourceRemoved`／partial outcome 避免把部分成功冒充全部成功。
- 建立 App 的 Info.plist 新增 `NSRemovableVolumesUsageDescription`。
- Scanner 升級為 2.5.2；整顆外接卷宗使用 `fast_stable_volume_tree`，保留完整 `df` 帳務，但不深度遍歷 `.Trashes`、Spotlight、FSEvents、TemporaryItems、DocumentRevisions 與 MobileBackups。
- 總覽將被略過的容量標成「卷宗中繼資料／垃圾桶」，並解釋它仍計入完整已用容量、不是全部可清理。
- 一般位置清理不再遞迴計算 Spotlight／FSEvents 資料庫大小，避免清理掃描和完整卷宗掃描重複遍歷。
- `ExternalVolumeCleanupAudit` 擴充為 63 項，static contract 擴充為 142 項；本版跨平台 assertions 合計 3,813／3,813。App 更新為 1.6.3（Build 21）。

## 1.6.2 — 2026-08-18 — 垃圾桶驗證與受限強制刪除

- `.Spotlight-V100` 與 `.fseventsd` 在一般位置 L5／自定義模式中改為可逐項手動選取，但永遠不參與分類或全域批次選取。
- 安全清理動作列新增「移到垃圾桶」與「強制刪除…」兩條明確路徑；一般項目仍只提供垃圾桶，強制刪除只接受外接卷宗根目錄的精確 Spotlight／FSEvents。
- 垃圾桶流程保存原始 device／inode、記錄實際垃圾桶位置，並在操作後辨識「舊項目仍存在」與「macOS 已建立不同身分的新同名目錄」。
- 強制刪除一定要求 macOS 管理員授權，不經垃圾桶且不可還原；固定 helper 只對已驗證的單一路徑執行 `/bin/rm -rf -- "$source_path"`，不接受 wildcard、`find -delete`、任意 shell 或任意路徑。
- App 與管理員 helper 會在授權前後重驗 `/Volumes` 一層掛載根、local／non-internal／writable volume、精確名稱、父路徑、symlink、device／inode，以及 Time Machine／network／virtual-disk 排除。
- Spotlight：舊索引成功刪除後停用該外接卷宗的索引；若 macOS 在停用前建立新索引，只再精確移除同一路徑一次。
- FSEvents：舊事件歷史成功刪除後建立 `.fseventsd/no_log`；只剩 `no_log` 的小型 marker 不再列為可清理的大型候選。
- 最終確認明示永久刪除、搜尋失效、增量事件歷史消失、備份／同步可能完整重掃與持久政策變更；高風險項目仍需直接勾 checkbox。
- JSON 紀錄新增 `removalMode`、永久刪除、macOS 重新建立、失敗與政策備註；單一候選失敗不會偽裝成成功。
- 新增 38 項 `PrivilegedCleanupAudit`，一般位置 fixture 擴充為 65 項；App 更新為 1.6.2（Build 20），scanner 維持 2.5.1。

## 1.6 — 2026-08-18 — 智慧 AppleDouble 與外接媒體清理

- 新增 bounded `AppleDoubleInspector`，驗證 magic、version、entry descriptor、payload bounds、重複／重疊 entry 與 Data Fork 禁止條件，不再只憑 `._` 檔名判定。
- 將 AppleDouble 拆成 Finder／Windows 伴隨、孤立 metadata-only、配對 metadata-only、resource-fork／unknown-entry sensitive，以及格式無法驗證等類別。
- L1–L4 可執行規則依風險累進；resource fork、App 自訂 entry、package／symlink companion 與 malformed `._` 在 L5 只供檢視。
- 新增 `.Spotlight-V100`、`.fseventsd`、`.Trashes`／`.Trash`、DocumentRevisions、TemporaryItems、MobileBackups、volume marker 與 legacy Apple metadata 說明；這些均不可直接清理。
- 執行前重新解析 binary header、重驗 companion orphan／paired 狀態、symlink、root 與所有 package／blocked ancestors。
- 一般位置候選仍預設未勾選，精確項目只移到垃圾桶，不永久刪除、不自動清空垃圾桶。
- `FolderCleanupAudit` 擴充為完整 AppleDouble corruption、resource fork、unknown entry、package／symlink、TOCTOU 與 managed metadata fixture。
- App 更新為 1.6（Build 18）；scanner 維持 2.5.1，容量 parser、v1.5.1 外接帳務修正、TCC、ReportLibrary 與系統六級清理不變。

## 1.5.1 — 2026-08-18 — 外接磁碟容量帳務隔離修正

- 修正 FAT32／exFAT 等非 APFS 外接磁碟被錯接到內建 Macintosh HD APFS container，導致顯示約 494 GB、Data、System、VM、Preboot、Recovery 的問題。
- `ReportParser.valueAfterColon` 改為只接受去除 diskutil tree 裝飾後的精確欄位前綴，避免 `Snapshot Mount Point:` 被解析成 `Mount Point:`。
- `selectPrimaryContainer` 與 `ScanSummary.targetAPFSVolume` 改為只以 `target_mount_point` 精確配對，不再把 `/` 視為所有絕對路徑的 APFS ancestor。
- 非系統 volume 只有在找到精確 APFS volume 時才使用 container total/free；否則使用該目標在 `df -kP` 中記錄的容量。
- 新增 11 項 foreign-APFS-inventory regression assertions，並以實際使用者報告核對：31.09 GB total、4.10 GB used、26.98 GB available。
- App 更新為 1.5.1（Build 17）；scanner 維持 2.5.1，安全清理與報告保存邏輯未變。

## 1.5 — 2026-08-18 — 掃描目標狀態與一般位置清理

- 新選擇的下次掃描位置在首次掃描前立即顯示，並標記「已保存／尚未掃描」。
- 目前顯示位置與掃描目標不同時，主要動作顯示「開始掃描」；相同時顯示「重新掃描」。
- 新增最近未掃描 target persistence；最近未掃描與已保存 non-system locations 各限制 12 項。
- menu 每一類只顯示五項，超出項目使用向右展開的「更多最近位置／更多已保存位置」。
- ReportLibrary 新增 non-system location hard cap；系統報告仍獨立保存一份，每個 logical target 仍只保留最新完整報告。
- 非系統 target 的安全清理切換為一般位置模式，分類 `.DS_Store`、Windows metadata、`__MACOSX`、`._*` 與 legacy Apple metadata review-only。
- 一般位置掃描不跟隨 symlink、不進入 package／VCS／Spotlight／Trash 等目錄，不允許系統根或 `~/Library`。
- 每個 matched path 在執行前重驗證並只使用 `FileManager.trashItem`；所有候選預設未勾選，L5 legacy metadata 不可選。
- 新增 26 項 `FolderCleanupAudit`，`ReportLibraryAudit` 擴充為 36 項。
- App 更新為 1.5（Build 16）；scanner 2.5.1 與 APFS／TCC／容量 foundation 保持不變。

## 1.4.1 — 2026-08-18 — SwiftUI 動畫 API 建置修正

- 修正 `LensMotion.hover` 誤用不存在的 `Animation.ease(duration:)`，造成 macOS release build 在 `LensDesign.swift` 中止。
- 改用 SwiftUI 支援的 `Animation.easeOut(duration: 0.10)`；hover 時長與不改變 layout 的互動契約不變。
- App 更新為 1.4.1（Build 15）；scanner 2.5.1、報告庫、容量解析、清理引擎與安全政策未修改。
- 靜態契約新增「禁止 `Animation.ease(duration:)`、必須使用受支援 eased animation API」檢查。

## 1.4 — 2026-08-17 — 多位置掃描紀錄與互動一致性

- 修正 `LensSegmentedBar` tooltip 參與父層尺寸計算造成的 track 增厚、跳動與圖例遮蔽；改為固定高度 track + layout-independent overlay。
- 「目前已用」與 Data volume 核對共用同一修正；hover 只改亮度／透明度，segment hit 切換停用動畫。
- 掃描報告改成每個 system、volume 或 folder 各保留最新一份完整報告；同一位置替換，其他位置保留。
- volume retention 優先使用 UUID，folder 使用 standardized path；App cache 內 symbolic-link 報告不索引、不跟隨。
- 總覽新增獨立的「目前顯示位置」與「下次掃描位置」menu；載入報告不再改寫 scan target。
- 已保存位置可直接作為下一次掃描目標；scan target 使用 `UserDefaults` 保存。
- 掃描紀錄顯示 location identity、path、App scan／import、scanner version、檔案大小與時間。
- 共用 button／icon／row／menu styles 加入快速 hover 與約 140 ms press feedback；Reduce Motion 停用不必要縮放。
- 工具列掃描圖示改為穩定 `magnifyingglass`，三個控制都加入即時自訂 tooltip、原生 `.help` 與 accessibility hint。
- 最大項目與 scan-quality pills 增加用途、Finder path 與不可清理原因說明。
- 新增 `ReportLibraryAudit.swift` 28 項 fixture，並將正式驗證腳本升級為 17 階段。
- App 更新為 1.4（Build 14）；scanner、parser、capacity builder、cleanup engine、models 與 policy 保持 v1.3 blob 不變。

## 1.3 — 2026-08-17 — 互動密度與資訊架構重構

- 建立「工作流區塊要能操作、資料區塊要能即時解釋、純說明要整合或收合」的介面契約。
- 移除安全清理頁獨占空間的靜態說明卡，改為會隨六級模式更新的摘要、門檻與可展開安全規則。
- Data volume 的可映射資料樹與帳務差額加入綠色／紫色一致標記；數值與分段容量條提供即時自訂 hover 說明。
- 新增 Foundation-only `SegmentedBarLayout` 及 19 項幾何命中測試，避免 padding、gap 或未分配區域被誤判成容量 segment。
- 已就緒報告加入「Finder 顯示」與真正的「打開報告」；檔案開啟與只開所在資料夾的 Finder 動作保持分離。
- 設定頁整合完整磁碟存取權核對、APFS 入口、可保存的預設清理等級、永久安全邊界、掃描報告與清理紀錄。
- 清理模式、自定義 scopes 與最低容量保存於 `UserDefaults`；容量門檻強制限制 0–500 MiB。
- 關於頁改為高密度、可複製的產品／維護資料，並把完整歷程收進 `DisclosureGroup`。
- 側邊欄即時容量卡改為可點擊返回總覽；高頻 hover 不加入等待動畫或重複系統 tooltip。
- App 更新為 1.3（Build 13）；scanner 維持 2.5.1。Scanner、CleanupEngine、Models 與 `CLEANUP_POLICY_1.2.md` 與 v1.2 byte-for-byte 相同。

## 1.2 — 六級安全清理與通用候選目錄

- 新增超級保守、保守、平衡、激進、超激進與自定義六種掃描模式。
- 掃描等級只控制候選廣度與容量門檻；所有項目預設未勾選。
- 擴充標準 cache、sandbox／group cache、App render／offline cache、開發工具、套件管理器、使用者 diagnostics、高影響資料與系統僅檢視分類。
- Application Support 只接受精確 cache marker，不碰 Cookie、Local Storage、IndexedDB、database 或 profile。
- Homebrew 與 Conda 以固定 argv 的官方命令執行；禁止 shell interpolation 與 Conda `--force-pkgs-dirs`。
- 一般路徑使用 `FileManager.trashItem`；review-only 永不可選；高影響／managed action 需要第二層確認。
- 新增清理掃描進度、結果摘要、tier／risk／action／impact／recovery 標籤與 category 勾選。
- 新增 `CleanupPolicyAudit.swift` 與 `cleanup_report_audit.py`，並以使用者 scanner 2.5.1 真實報告核對 catalogue。
- App 更新為 1.2（Build 12）；scanner 維持 2.5.1。

## 1.1 — 2026-08-16

- 從正式 1.0 commit 直接建立 1.1（Build 11）；英文 runtime 模式從未進入這條分支，產品維持繁體中文單語。
- 新增原生 Finder 右鍵工作流：sunburst、總覽最大項目、資料樹、直接檔案、安全清理與掃描紀錄可顯示、打開所在資料夾或複製路徑。
- 對檔案執行「打開」時只開啟所在資料夾；真正空閒、APFS metadata、未解析帳務差額等非路徑節點不會偽造 Finder 位置。
- 總覽改為非對稱首屏工作區：左側容量／掃描品質／Data 核對，右側完整容量地圖；窄版先顯示容量圖。
- Scan Quality 的探針路徑與 TCC overlay tree／replaced／delta 收進 DisclosureGroup，先顯示結論。
- Data Tree 完整保留 1.0 原生 `HSplitView` 的 400／470 與 480／650 幾何，不使用語言層、GeometryReader 或 ViewThatFits 重寫 pane。
- 修正總覽配色的 dead ID：以 `SunburstColorHint.selectedVolume`／`.mappedTree` 取代從未生成的 `overview-data-volume`。
- Data 容量帳務層維持低飽和霧藍；進入 mapped tree 後，Applications、Users、Library 等第一層真實資料夾重新取得獨立支系色。
- 深色／淺色每層明度步進提高為 0.070／0.058，彩度下限提高為 0.16，使內外環深度更容易辨識。
- 安全清理標籤、掃描紀錄操作列、設定卡與關於卡片改為局部 adaptive layout；保留原生導覽與低動態規範。
- Scanner 維持 2.5.1，沒有改變 APFS／TCC schema、管理員掃描、App overlay 或清理白名單。

## 1.0 — 2026-08-16

- 正式版版本號升級為 1.0（Build 10）；唯讀掃描器維持 2.5.1，沒有修改掃描與清理安全邊界。
- 新增 Foundation-only `StorageColorModel`，以 12 組低飽和度支系色建立單一階層配色來源。
- 同一分支的所有後代固定保留父支系色相；外圈只按深度提高明度、略降彩度，並設置 0.145 彩度下限，避免深層節點退化成無關灰色。
- `直接檔案`、`其他項目` 與其他結構性虛擬節點改為繼承支系顏色，不再使用全域灰色常數；帳務差額、容器 metadata、取樣差額、真正空閒與可回收仍保留固定語意色。
- APFS System、Preboot、VM、Recovery 等頂層卷使用各自穩定支系色；圖表、最大項目圖例與資料樹列共用同一個 hash／palette resolver。
- 決定性種子改用標準 FNV-1a 64-bit offset basis，並加入已知向量回歸；hash 只提供同層微小明度差，不改變支系色相。
- Data 核對條也改為依深／淺色模式取得同一語意色，不再固定使用深色版本。
- 放射圖分隔線由 0.72 降為 0.52，扇區徑向與角向間距同步縮小，降低密集圖形的碎裂感；游標命中與即時 tooltip 不加入動畫延遲。
- 總覽圖標示「掃描快照 · 同支系同色 · 外圈漸亮」；資料瀏覽圖明示同一分支的色相規則，並區分即時容量與報告取樣時點。
- 新增階層配色 assertions，覆蓋深度單調性、色相不漂移、彩度下限、語意色固定、FNV-1a 已知向量與深／淺色模式。
- 以使用者 scanner 2.5.1 實際報告新增精確 profile：App TCC 覆蓋已套用、92.51 GB App 樹取代 66.77 GB 管理員子樹、淨增加 25.74 GB；186 條剩餘診斷誠實維持部分覆蓋，容量根與子節點精確閉合。
- 參考提供的科學圖形規範中「同族色一致優先、降低飽和度、保留少量語意色」原則；該規範明示不適用於 dashboard，因此只轉譯色彩紀律，沒有套用論文圖的白底、字級或匯出流程。

## 0.7.2 — 2026-08-15

- 修正 0.7.1 在 Swift 6.2 release build 的 `ScannerLauncher.swift` 編譯錯誤：`ambiguous use of index(after:)`。
- 將 App TCC overlay 的 key-value 解析抽成 Foundation-only `KeyValuePayload`，改用單次 `=` 分割，保留空值及值內額外等號。
- 新增 9 項 `KeyValuePayloadAudit`，涵蓋重複鍵、空值、CRLF、UTF-8、值內等號及無效行；驗證腳本會先型別檢查這段曾失敗的程式，再進入完整 App build。
- App 權限探針的非同步 completion 改為 `@MainActor @Sendable`，並由 helper 保證回到 main queue，移除非 Sendable `AppModel` 捕捉警告，同時保持 Swift 6 相容。
- 安全清理完成後正式使用清理結果：成功時顯示紀錄檔，部分失敗時顯示失敗數與詳細紀錄；ScannerLauncher 也明確消耗 `createFile` 回傳值，清除本輪可重現的編譯警告。
- 建立工具加入編譯器版本輸出與乾淨 release build，避免舊 `.build` 快取遮蔽來源問題。
- App 升級為 0.7.2（Build 9）；唯讀掃描器維持 2.5.1，容量、權限、外接磁碟與 UI／motion 行為不變。

## 0.7.1 — 2026-08-15

- 修正 scanner 2.5.0 把獨立管理員／root 子程序的 TCC 探針錯誤呈現成 MacStorageLens App 授權狀態的問題。
- 新增由 App 程序本身直接執行的 Full Disk Access 探針；不再把權限判定委派給 shell／AppleScript 子程序。
- 報告 schema 新增 App 探針、scanner 子程序探針、掃描權限通道、有效覆蓋來源與 App TCC overlay 帳務欄位。
- 系統「App + 管理員掃描」先由 App 唯讀掃描目前使用者 home，再以管理員權限掃描系統／APFS，最後以 App 資料樹取代同一子樹並調整所有祖先容量。
- 若 App 探針受阻或無法判定，不再執行耗時的 App overlay；管理員掃描仍可繼續，並在報告中誠實標示限制。
- scanner 2.5.1 分開保存 App、管理員子程序與 Terminal 的責任鏈，並保留 scanner 2.5.0 舊報告的「只能判定管理員子程序」相容語意。
- 掃描品質卡改為顯示掃描通道、App TCC、scanner TCC、管理員權限、報告生成與資料覆蓋；移除一刀切的「完整磁碟存取未生效」。
- 掃描設定保留 Terminal 診斷模式、只用 App 權限、App + 管理員掃描三個明確入口。
- App 啟動、回到前景、開啟掃描設定與掃描完成後都會重新核對 App 自身探針。
- 建立腳本優先使用穩定的 Apple Development／Developer ID code-signing identity；找不到時才使用 ad-hoc 並警告可能需要重新授權 TCC。
- 移除舊 scanner 2.5.0 build resources，安裝 2.5.1 時也會清除 Application Support 內殘留的舊 scanner `.command`。
- 依介面／動畫 Skill 收斂掃描階段轉場：0.26 秒臨界阻尼、按壓 0.14 秒／0.975 scale、Reduce Motion 退回淡入淡出；高頻 sunburst 游標追蹤維持即時，不加延遲彈簧。
- App 升級為 0.7.1（Build 8）；內附掃描器升級為 2.5.1。

## 0.7.0 — 2026-08-15

- 完整容量地圖改以 APFS 容器總容量為根，不再以 Data 卷已用量冒充整顆磁碟。
- 修正 ReportParser 只接受英文 `--- pre-scan df -kP`、無法辨識 scanner 2.4.1 中文 `df -kP` 標題的問題；改以報告階段與實際命令識別 pre/post 帳務。
- 新增 APFS container／volume 串流解析，從實際 `diskutil apfs list` 還原 capacity、free、Data、System、Preboot、Recovery 與 VM。
- 第一層加入真正空閒、Data、System、Preboot、VM、Recovery 與 APFS 容器帳務／metadata。
- Data／磁碟節點加入「帳務差額（未解析）」與「掃描／容量取樣差額」，所有圖形層級精確閉合，不再留下無標籤扇形缺口。
- 將不可讀路徑、snapshot、APFS metadata 與 filesystem semantics 的混合差額明確標示為不可直接清理。
- 掃描品質拆分為管理員權限、完整磁碟存取探針、報告生成、資料覆蓋與診斷行數。
- 系統快照與 Time Machine 本機快照分開計數。
- Terminal 相容模式恢復為初始掃描畫面的固定入口，並與 App 模式共用 scanner core 2.5.0。
- 新增掃描目標：Macintosh HD、其他已掛載磁碟、任意資料夾。
- 外接磁碟使用單一掛載根與 `du -x`；資料夾模式不把所在磁碟的剩餘空間畫成資料夾子項。
- 掃描報告新增 target kind/path/name/volume UUID、launcher mode 與通用 target accounting 區段。
- App 可自動偵測 `system-storage-tree`、`volume-storage-tree` 與 `folder-storage-tree` 報告。
- 即時容量卡保持與目前載入報告一致；選擇下一個掃描目標時不再把新磁碟容量混入舊報告畫面。
- App 升級為 0.7.0（Build 7）；內附掃描器升級為 2.5.0。

## 0.6.0 — 2026-08-15

- 修正管理員掃描在輸入密碼後立即出現 `execution error ... non-zero status (1)` 的問題。
- 根因是 zsh 的 `status` 為唯讀特殊參數；管理員包裝、Terminal 包裝與進度監督器均已改用非保留名稱。
- 進度監督器同時避開 zsh 特殊 `path` 參數，防止局部 PATH 被意外遮蔽。
- 內附掃描器升級為 2.4.1；App 升級為 0.6.0（Build 6）。
- Terminal 相容模式改為前景直接執行唯讀核心並明確使用 `--sudo`，不再讓背景子程序嘗試讀取密碼。
- Terminal 掃描完成後，App 會挑選最新的完整報告自動載入；回到 App 前景時也會再次復原偵測。
- Terminal 報告監看期限由 15 分鐘調整為 30 分鐘。
- 若報告已有 `report_complete=true`，即使外層授權／收尾包裝之後失敗，App 仍會把完成報告視為權威結果並載入。
- 授權失敗時優先顯示 `scanner.log` 的具體 shell 訊息，不再只顯示 AppleScript 行號與狀態碼。
- 意外失敗 session 的診斷檔保留最多 24 小時；成功與使用者取消仍立即清理。
- 掃描失敗頁新增「診斷資料」按鈕。
- Terminal 與 App 將 `du` 的非致命輸出重新標示為「受限／診斷行」。
- 根節點 `du exit=1` 時明確說明「部分路徑受限；已保留全部可讀結果」，不再讓它看起來像整體掃描失敗。
- 總覽主卡新增報告狀態 banner；移除側邊欄左下角獨立狀態卡。
- 無報告、掃描中、載入中、完成、取消與失敗狀態皆在主要操作卡內顯示。

## 0.5.0 — 2026-08-15

- 加入分階段進度、目前路徑、心跳、節點與警告統計、估計剩餘時間與取消控制。
- 加入 20／60／120 秒健康門檻與 30 分鐘總上限。
- 掃描監督器與唯讀核心分離，完成後自動載入。

## 0.4.0 — 2026-08-15

- 加入 App 內授權掃描、自動載入、直接檔案檢視器、游標提示定位、正式 App 圖示與關於頁。

## 0.3.0 — 2026-08-15

- 完整重構 SwiftUI 介面與低飽和視覺系統。

## 0.2.0 — 2026-08-15

- 放射圖改為單一 Canvas 與即時極座標命中；報告最多保留一份。

## 0.1.0 — 2026-08-14

- 建立原生 SwiftUI 原型、APFS 容量地圖、資料樹與白名單式清理。
