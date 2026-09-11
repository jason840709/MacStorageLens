import AppKit
import Foundation

struct AppRelease: Identifiable, Hashable {
  let version: String
  let title: String
  let summary: String

  var id: String { version }
}

enum AppMetadata {
  static let displayName = "磁碟透視"
  static let productName = "MacStorageLens"
  static let developer = "Jason Chen"
  static let developmentAssistant = "GPT‑5.6 Pro"
  static let scannerVersion = "2.5.3"
  static let fallbackVersion = "1.7.5"
  static let fallbackBuild = "33"
  static let copyright = "Copyright © 2026 Jason Chen"

  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? fallbackVersion
  }

  static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      ?? fallbackBuild
  }

  static var versionLine: String { "Version \(version) (Build \(build))" }

  static var codeSigningMode: String {
    Bundle.main.object(forInfoDictionaryKey: "MacStorageLensCodeSigningMode") as? String
      ?? "development"
  }

  static var codeSigningIdentity: String? {
    Bundle.main.object(forInfoDictionaryKey: "MacStorageLensCodeSigningIdentity") as? String
  }

  static var hasStableCodeSigningIdentity: Bool { codeSigningMode == "identity" }

  static let releases: [AppRelease] = [
    AppRelease(
      version: "1.7.5",
      title: "系統垃圾規則深度整合與廢紙簍清理",
      summary:
        "以 MacSai 實際 Swift 原始碼與測試為研究依據，將嚴格 App leftovers、損壞 plist、下載殘留、IDE／AI／套件管理器精確快取與負面排除規則吸收到既有六級安全清理。介面不再放置版本專屬規則卡；所選等級直接呈現目前生效範圍。超激進模式提供高影響資料、廢紙簍永久清空與系統僅檢視三個額外開關，全部預設關閉；自定義模式則按風險分組逐項設定。新增獨立『廢紙簍（永久清空）』範圍，只有手動開啟才納入掃描，候選仍預設不勾選且只能直接永久刪除；只處理 ~/.Trash 與本機可寫外接卷宗 .Trashes/<目前 UID> 中掃描時已列出的直接子項，其他 UID、整棵 .Trashes、NAS #recycle 與網路卷宗一律排除。"
    ),
    AppRelease(
      version: "1.7.4",
      title: "外部 AppleDouble 高價值清理與 NAS 回收區排除",
      summary:
        "針對 SD 卡、USB／外接磁碟與 NAS 等非本機儲存，提高可驗證 metadata-only AppleDouble sidecar 的清理優先級：主檔不存在且不含 resource fork／未知 entry 的 ._ 殘留於保守等級即可列出；仍有同名主檔但只含可辨識 metadata 的 ._ 於平衡等級列出。本機內建磁碟維持原本較保守門檻。真正含非空 resource fork、未知／應用程式 entry、package／symlink companion 或格式不明的 ._ 項目仍只供檢視，安全紅線不放寬。遠端 SMB #recycle 視為 NAS 伺服器管理區域，安全清理整棵略過、不列舉、不產生二次候選；容量總覽仍可計入其佔用。另修正 Application Support 中實際目錄名稱為 cache／其他大小寫時，掃描器自行拼出 Cache 路徑而導致執行安全驗證拒絕的假候選，改為使用檔案系統實際回傳的 canonical entry。"
    ),
    AppRelease(
      version: "1.7.3",
      title: "安全清理補充掃描與完整重掃分流",
      summary:
        "安全清理不再把增量索引最佳化變成唯一入口。第一次執行只顯示開始掃描；已有清理索引後，介面同時提供補充掃描與完整重新掃描。補充掃描只處理新開啟規則與清理後標記為 dirty 的資料夾；完整重新掃描則不合併舊候選、不沿用 covered scopes 或 dirty 狀態，從零建立目前等級的新索引。完整重掃採交易式替換：新結果成功後才覆寫既有索引，若掃描失敗仍保留上一份可用索引。掃描資料來源仍由既有容量報告快速模式或目前檔案系統完整模式獨立決定，刪除前的 live revalidation 與 NAS direct-only 安全邊界不變。"
    ),
    AppRelease(
      version: "1.7.2",
      title: "安全清理增量索引與跨等級重用",
      summary:
        "安全清理不再因切換保守、平衡或激進等級就把先前掃描成果全部丟棄。每個已掃描規則範圍會寫入可重用候選索引；提高等級時只補掃新增規則，容量門檻變更只重新篩選。一般位置在既有容量報告快速模式下會把索引安全保存到本機，並綁定目標與報告簽章；AppleDouble 類規則一旦需要列舉資料夾，就同輪完成後續等級所需分類，避免 NAS 重複讀取。完成清理後，成功項目直接從索引扣除，未選取與失敗項目保留，只把受影響的父資料夾標記為待刷新；下一次只重查這些位置。真正刪除前仍會即時重驗證目前檔案系統，索引不會被當成刪除授權。"
    ),
    AppRelease(
      version: "1.7.1",
      title: "容量報告快速安全清理與 NAS 刪除能力辨識",
      summary:
        "安全清理新增兩種候選來源：可沿用儲存空間總覽已完成的容量報告，以 DIRECTORY_TREE 作為資料夾導航索引，避免對大型 NAS 再做一次完整遞迴發現；也可維持原本的完整重新掃描。快速模式不把 Markdown 當成刪除授權，會在目前檔案系統即時探測命名候選、驗證 AppleDouble 與 metadata，執行前仍做最後安全重驗證。清理頁也會依目前 mount 的檔案系統能力自動調整：SMB、NFS、WebDAV、AFP、SSHFS 等網路卷宗停用 Finder 垃圾桶，只保留直接刪除；唯讀掛載則停用所有刪除，並明示 NAS 端 recycle bin、snapshot 或版本保護仍由伺服器政策決定。"
    ),
    AppRelease(
      version: "1.7.0",
      title: "容量地圖完整鑽取與高門檻合併",
      summary:
        "容量地圖不再只顯示固定 12 個同層子資料夾：同層不超過 2,048 項時全部直接呈現；只有真正進入數千項密度時才建立「其他 N 項」。合併節點現在可點擊展開，從原始 Markdown 報告恢復完整被合併清單，並可逐項繼續深入資料樹與 Finder。"
    ),
    AppRelease(
      version: "1.6.8",
      title: "NAS 長時間掃描活動式逾時",
      summary:
        "移除掃描 30 分鐘總執行上限，改為只在連續 10 分鐘沒有新增目錄節點、路徑、步驟或階段進展時才安全中止；單純心跳與經過時間不算實質進度，因此大型 NAS 可持續掃描數小時，只要資料樹仍在前進。底層無輸出保護仍保留，並將開發者署名修正為 Jason Chen。"
    ),
    AppRelease(
      version: "1.6.7",
      title: "macOS 建置修正與 UI 列舉契約",
      summary:
        "修正 1.6.6 在 CleanerView 的 CleanupScope 配色 switch 誤用了只屬於 CleanupCategory 的 folderLegacyTrashResidue，造成 macOS release build 回報 type CleanupScope has no member。新版移除錯誤 case，保留舊版隱藏垃圾桶殘留的 category 圖示與候選分類；同時消除報告索引寫入的 unused try? 警告，並新增 UI enum context audit，直接核對 scopeTint 與 categorySymbol 的 enum 成員，避免相同跨列舉誤用再次通過僅語法解析的 Linux 驗證。掃描器、容量帳務、Finder 可見垃圾桶與直接刪除行為均未改變。"
    ),
    AppRelease(
      version: "1.6.6",
      title: "Finder 可見垃圾桶與無中介直接刪除",
      summary:
        "清理介面只保留兩種可驗證語意：Finder 可見垃圾桶，或直接徹底刪除。可逆模式統一使用 NSWorkspace 的 Finder 回收語意；點號或 hidden 項目會先在原位置改成非點號可見名稱，只有系統回傳的垃圾桶目的地仍存在、名稱可見、hidden=false，且屬於 Finder 管理的垃圾桶直接子項時才記錄成功；接著立即要求 Finder 選取該項目。不可逆模式直接對重新驗證過的來源呼叫 Foundation removeItem，不再先搬進任何垃圾桶，也不建立 no_log 或其他隱藏標記。舊版曾留在外接卷宗 .Trashes 中的點號 Spotlight／FSEvents 副本會另列成逐項直接刪除候選；系統快取與一般位置也共用同一套兩模式契約。"
    ),
    AppRelease(
      version: "1.6.5",
      title: "單次報告索引與容量地圖快速載入",
      summary:
        "大型 Markdown 報告首次載入時只遍歷一次：同一輪建立 section offsets、容量帳務、頂層節點與第一個四層容量地圖，不再於 Scanner 完成後第二次讀取 Data 樹。完成後會在本機 Report Indexes 建立小型 presentation index；報告大小、修改時間與頭／中／尾樣本簽章一致時，重新載入可直接還原摘要與初始地圖。索引損壞、過大、來源變更或 schema 不符會自動捨棄並回到完整 Markdown。報告庫也會在 Volume UUID 可唯一確認時，合併同一外接卷宗曾以資料夾與磁碟模式留下的重複紀錄。"
    ),
    AppRelease(
      version: "1.6.4",
      title: "外接卷宗實際耗時與 Spotlight 狀態診斷",
      summary:
        "使用者實機連續掃描同一張外接記憶卡時看到 2 秒、18 秒、22 秒，但最新 Scanner 2.5.2 報告本身只記錄兩秒；舊版沒有保存前三次工作階段與完整端到端計時，因此無法只靠該報告精確歸因。Scanner 2.5.3 移除兩個已確認不適用且位於舊計時之外的外接目標前置工作：不再探測 Mail、Messages、Safari 或 AddressBook，非 APFS 目標也不再查詢整台 Mac 的 APFS 容器。一般位置清理完成後也不再暗中重跑候選遍歷，避免它與容量掃描同時讀取同一張卡。報告新增準備、路徑、磁碟狀態、寫入與總耗時，以及 Spotlight、FSEvents、卷宗垃圾桶根目錄是否存在的非遞迴狀態；成功工作階段保留精簡診斷 24 小時，下一輪可用證據定位剩餘延遲。"
    ),
    AppRelease(
      version: "1.6.3",
      title: "外接卷宗垃圾桶清除與穩定快速重掃",
      summary:
        "修正外接卷宗強制刪除交由獨立 root shell 後被 removable-volume TCC 拒絕的問題。新版永久操作留在 MacStorageLens 程序：先以 Foundation 移動精確 Spotlight／FSEvents 舊目錄，再永久清除實際回傳的卷宗垃圾桶 URL；同時清除先前清理紀錄中可驗證的同類垃圾桶副本。Scanner 2.5.2 對整顆外接磁碟採穩定快速樹模式，不再遞迴遍歷 .Trashes、Spotlight、FSEvents 等高變動卷宗中繼資料；完整 df 容量仍保留，略過部分會顯示為卷宗中繼資料／垃圾桶帳務。"
    ),
    AppRelease(
      version: "1.6.2",
      title: "垃圾桶與受限強制刪除",
      summary:
        "外接卷宗根目錄的 .Spotlight-V100 與 .fseventsd 首次提供垃圾桶與不可逆強制刪除兩條流程。這一版使用一次性管理員 shell，後續實機紀錄證明該獨立程序可能失去 MacStorageLens 的可卸除式卷宗 TCC 責任鏈，因此已由 1.6.3 的 App 內 Foundation 流程取代。"
    ),
    AppRelease(
      version: "1.6",
      title: "智慧 AppleDouble 與外接媒體清理",
      summary:
        "一般位置清理不再只用 ._ 檔名判定。新版會解析 AppleDouble magic、版本、entry table、資源分支與同名主檔狀態：._.DS_Store 與 Windows 顯示 metadata 可在低風險等級處理；主檔已不存在且不含敏感 entry 的殘留可移到垃圾桶；仍配對的 metadata 只在激進模式逐項確認；資源分支、未知 entry、package、符號連結與格式不明項目一律只供檢視。Spotlight、FSEvents、卷宗垃圾桶與 Time Machine marker 也會被辨識說明，但不提供直接刪除。"
    ),
    AppRelease(
      version: "1.5.1",
      title: "外接磁碟容量帳務隔離修正",
      summary:
        "修正掃描 FAT、exFAT 等非 APFS 外接磁碟時，報告中的全機 APFS 診斷清單被誤認為目標磁碟容器，導致畫面錯誤顯示內建 Macintosh HD 的容量、Data、VM、Preboot 與 Recovery。現在 APFS 容器只會以掃描報告記錄的精確掛載點配對；Snapshot Mount Point 也不會再覆寫卷宗本身的 Mount Point。"
    ),
    AppRelease(
      version: "1.5",
      title: "掃描目標狀態與一般位置清理",
      summary:
        "下次掃描位置會在首次掃描前立即顯示並保存；掃描按鈕依目前顯示位置與目標位置切換為開始掃描或重新掃描。未掃描與已保存位置各有數量上限及分層更多選單。安全清理會在非系統目標切換為一般位置模式，分類檢查 .DS_Store、Windows metadata、__MACOSX 與 AppleDouble，執行前逐路徑重驗證並只移到垃圾桶。"
    ),
    AppRelease(
      version: "1.4.1",
      title: "SwiftUI 動畫 API 建置修正",
      summary:
        "修正 1.4 在 macOS release build 使用不存在的 Animation.ease(duration:) 而中止的問題。游標回饋改用 SwiftUI 支援的 Animation.easeOut(duration:)；掃描器、報告模型、容量帳務與六級安全清理邏輯均未改變。"
    ),
    AppRelease(
      version: "1.4",
      title: "多位置掃描紀錄與互動一致性",
      summary:
        "容量條游標提示改為完全脫離版面配置，停留時不再增厚、跳動或遮住圖例。掃描紀錄改成每個系統、磁碟與資料夾各保留最新一份完整報告；總覽把目前顯示的位置與下次掃描位置拆成兩個獨立選擇器。共用按鈕補上游標回饋，容量圖例、掃描品質與最大項目加入即時說明；工具列掃描圖示與三個按鈕的提示文字也已補齊。"
    ),
    AppRelease(
      version: "1.3",
      title: "互動密度與資訊架構重構",
      summary:
        "移除安全清理頁的靜態說明卡，將規則整合到可展開的等級摘要；總覽容量條與 Data 帳務核對加入即時色彩對應、游標說明與原始報告 Finder 操作。設定頁改為可檢查權限、保存清理等級、開啟帳務／清理／本機資料的工作台；關於頁壓縮為可複製的產品資料與可展開版本歷程。"
    ),
    AppRelease(
      version: "1.2",
      title: "六級安全清理與通用候選目錄",
      summary:
        "安全清理改為超級保守、保守、平衡、激進、超激進與自定義六種模式。掃描等級只控制候選廣度，所有項目仍預設不勾選；新增沙盒／Group Container、App 網頁繪圖 cache、開發工具、套件管理器、診斷日誌、高影響資料與系統僅檢視項目。Conda 與 Homebrew 使用受限制的官方命令，CloudKit、VM、snapshot 與系統資料庫仍禁止直接刪除。"
    ),
    AppRelease(
      version: "1.1",
      title: "繁中單語介面、Finder 工作流與容量圖重構",
      summary:
        "從 1.0 正式基線直接重建，不引入語言切換層。環狀圖、最大項目、資料樹、直接檔案、安全清理與掃描紀錄加入一致的 Finder 右鍵操作；總覽改為非對稱首屏工作區。容量圖以明確的 selectedVolume／mappedTree 語意重新分配真實資料夾支系色，並加大外圈明度階差，避免總覽被 Data 水藍色壟斷。"
    ),
    AppRelease(
      version: "1.0",
      title: "階層配色與正式版視覺收斂",
      summary:
        "完整容量地圖改為固定支系色相：同一分支往外只依層級漸亮、略降彩度；直接檔案與其他項目不再跳成全域灰色。APFS 帳務、真正空閒與差額保留語意色，圖例與資料列共用同一套決定性配色；同時以 scanner 2.5.1 真實報告確認 App TCC 覆蓋已套用、容量帳務閉合。"
    ),
    AppRelease(
      version: "0.7.2",
      title: "macOS Release 建置相容性修正",
      summary:
        "修正 Swift 6.2 在管理員掃描結果解析器中對 Substring.index(after:) 的多載歧義，讓 release build 能繼續產生 App；同時加入可獨立型別檢查的 key-value parser 回歸，並清除 App 權限探針與安全清理流程的編譯警告。"
    ),
    AppRelease(
      version: "0.7.1",
      title: "完整磁碟存取責任鏈與 App TCC 合併",
      summary:
        "分開核對 MacStorageLens App 與管理員掃描子程序的 TCC 權限；系統掃描先由 App 讀取受保護的使用者資料，再合併到管理員唯讀掃描，避免把 root 子程序受阻誤報成 App 未授權。同步更新權限介面、低動態轉場與簽章提示。"
    ),
    AppRelease(
      version: "0.7.0",
      title: "容量帳務閉合與可切換掃描目標",
      summary:
        "完整容量地圖改以 APFS 容器為根，補回真正空閒、各 APFS 卷與未解析帳務節點；拆分管理員與完整磁碟存取狀態，恢復 Terminal 相容模式，並加入外接磁碟與資料夾掃描。"
    ),
    AppRelease(
      version: "0.6.0",
      title: "授權收尾修正與狀態整合",
      summary: "修正 zsh 保留變數造成的管理員與 Terminal 掃描假失敗；完成報告可從外層啟動錯誤中復原，並把尚無報告、載入與掃描狀態整合到總覽主卡。"
    ),
    AppRelease(
      version: "0.5.0",
      title: "可觀測、可取消的完整掃描",
      summary: "加入分階段進度、目前路徑、心跳、節點與錯誤統計、估計剩餘時間、取消控制，以及無核心輸出時的安全中止機制。"
    ),
    AppRelease(
      version: "0.4.0",
      title: "整合掃描與可追溯資料",
      summary: "加入 App 內原生授權掃描、自動載入、直接檔案檢視器、游標提示定位、正式 App 圖示與關於頁。"
    ),
    AppRelease(
      version: "0.3.0",
      title: "完整介面重構",
      summary: "建立低飽和視覺系統、重新編排總覽／資料樹／安全清理資訊層級，並改善互動回饋。"
    ),
    AppRelease(
      version: "0.2.0",
      title: "資料視覺化與報告管理",
      summary: "改寫放射圖即時命中、固定保留重新掃描與重新載入，並把掃描報告收斂為最新一份。"
    ),
    AppRelease(
      version: "0.1.0",
      title: "原型建立",
      summary: "把完整 macOS 儲存空間掃描、APFS 帳務核對、資料樹瀏覽與白名單式清理整合為 SwiftUI App。"
    ),
  ]

  static func applicationIcon() -> NSImage? {
    if let url = Bundle.main.url(forResource: "MacStorageLens", withExtension: "icns"),
      let image = NSImage(contentsOf: url)
    {
      return image
    }

    if let url = Bundle.main.url(forResource: "MacStorageLens-icon-1024", withExtension: "png"),
      let image = NSImage(contentsOf: url)
    {
      return image
    }

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    for relativePath in [
      "Resources/MacStorageLens.icns",
      "Resources/MacStorageLens-icon-1024.png",
    ] {
      let url = root.appendingPathComponent(relativePath)
      if let image = NSImage(contentsOf: url) { return image }
    }
    return nil
  }

  static func applyApplicationIcon() {
    if let icon = applicationIcon() {
      NSApplication.shared.applicationIconImage = icon
    }
  }
}

final class MacStorageLensAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    AppMetadata.applyApplicationIcon()
  }
}
