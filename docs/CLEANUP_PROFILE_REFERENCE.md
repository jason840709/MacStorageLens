# MacStorageLens 清理等級與範圍參考

這份文件描述安全清理的長期資訊架構，不綁定特定版本。App 只保留六種既有模式：超級保守、保守、平衡、激進、超激進與自定義。

## 介面規則

- 清理等級選擇器是唯一入口。
- 所選等級下方的「掃描範圍與安全規則」由 `CleanupScope.cases(for:)` 與 `CleanupScope.minimumTier(...)` 動態產生。
- L5 選取後才顯示高影響資料、廢紙簍永久清空、系統管理僅檢視三項附加功能。
- 自定義選取後才顯示逐項 scope 開關與最低容量。
- 第三方研究來源只以低干擾說明呈現，不建立版本專屬卡片或第七種模式。

## 六種模式

### 超級保守（L1）

- `standardCaches`
- `sandboxAndGroupCaches`
- broad User Caches 的負面安全規則會在容量計算前排除 Spotify offline cache、broad Gradle state 等不應被列入的內容。

### 保守（L2）

包含 L1，再加入：

- `clipboardTemporary`
- `applicationWebCaches`
- `downloadResidue` 中停滯的未完成下載。

### 平衡（L3）

包含 L1–L2，再加入：

- `developerCaches`
- `packageManagerCaches`
- Xcode Previews、Cursor／Antigravity 標準 Electron cache、Claude／Codex cache/scratch、Cargo／Gradle 精確 allowlist。

### 激進（L4）

包含 L1–L3，再加入：

- `appLeftovers`：安全 Library roots、嚴格 reverse-DNS bundle-ID lineage、shared runtime exclusions。
- `brokenPreferences`：只限實際無法解析的第三方 plist。
- `diagnosticsAndLogs`：使用者 logs／diagnostics。

### 超激進（L5）

L5 基礎範圍包含 L1–L4，再加入較舊的安裝套件與磁碟映像候選。選取 L5 後，畫面才會就地顯示三個**預設關閉**的附加範圍：

- `highImpactUserData`：備份、郵件下載與 Xcode 封存；逐項手動選取。
- `trashBins`：目前 UID 廢紙簍；二次確認後永久清空。
- `systemManagedReview`：系統管理項目；只供檢視。

三者彼此獨立，開啟其中一項不會連帶開啟另外兩項。

### 自定義

- 所有目前模式可用 scope 都在畫面上獨立開關。
- 新 scope 不會因版本升級而偷偷寫入既有使用者偏好。
- 自定義不會繞過 risk、manual-selection、review-only 或 live-revalidation 契約。

## 廢紙簍安全範圍

會處理：

- `~/.Trash` 的掃描時第一層項目。
- 經 live validator 證明為本機、可寫、非內置、非 Time Machine 外接卷宗的 `.Trashes/<目前 UID>` 第一層項目。

不會處理其他 UID、整棵 `.Trashes`、垃圾桶 root、NAS／伺服器 `#recycle`、遠端 mount、symlink、特殊檔案、控制字元路徑、越界路徑或掃描後新加入的項目。

## 研究來源

部分系統垃圾判定研究參考 MacSai 開源專案。MacStorageLens 保留自己的掃描器、候選模型、六級風險、逐項選取、Finder 可見垃圾桶、直接刪除、外接／NAS capability、刪除前重驗證與 JSON log。授權與來源追蹤見 [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)、[`ThirdParty/MacSai-LICENSE.txt`](../ThirdParty/MacSai-LICENSE.txt) 與 [`MACSAI_SOURCE_REVIEW.md`](MACSAI_SOURCE_REVIEW.md)。
