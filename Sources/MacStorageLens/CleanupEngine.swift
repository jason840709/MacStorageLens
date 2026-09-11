import Foundation

#if os(macOS)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

final class CleanupEngine {
  typealias ProgressHandler = (CleanupScanProgress) -> Void

  private struct ScanStep {
    let name: String
    let path: String?
    let body: () throws -> [CleanupCandidate]
  }

  private let fileManager: FileManager
  private let library: ReportLibrary
  private let home: URL
  private let localLibrary: URL
  private let privateRoot: URL
  private let volumesRoot: URL
  private let currentUserID: UInt32

  init(
    library: ReportLibrary,
    fileManager: FileManager = .default,
    homeURL: URL? = nil,
    localLibraryURL: URL = URL(fileURLWithPath: "/Library", isDirectory: true),
    privateRootURL: URL = URL(fileURLWithPath: "/private", isDirectory: true),
    volumesRootURL: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
    currentUserID: UInt32? = nil
  ) {
    self.library = library
    self.fileManager = fileManager
    self.home = (homeURL ?? fileManager.homeDirectoryForCurrentUser).standardizedFileURL
    self.localLibrary = localLibraryURL.standardizedFileURL
    self.privateRoot = privateRootURL.standardizedFileURL
    self.volumesRoot = volumesRootURL.standardizedFileURL
    self.currentUserID = currentUserID ?? UInt32(getuid())
  }

  func scanCandidates(
    configuration: CleanupScanConfiguration,
    target: ScanTarget = .systemStorage,
    scanSource: CleanupScanSource = .liveFilesystem,
    reportDocument: ReportDocument? = nil,
    reportParser: ReportParser? = nil,
    progress: ProgressHandler? = nil
  ) throws -> CleanupScanResult {
    if CleanupMode.forTarget(target) == .generalLocation {
      let folderEngine = FolderCleanupEngine(fileManager: fileManager, homeURL: home)
      switch scanSource {
      case .existingStorageReport:
        guard let reportDocument, let reportParser else {
          throw CleanupValidationError.rejected(
            "尚未提供可重用的容量報告；請選擇完整重新掃描，或先在儲存空間總覽完成掃描。"
          )
        }
        return try folderEngine.scanCandidatesUsingReport(
          configuration: configuration,
          target: target,
          document: reportDocument,
          parser: reportParser,
          progress: progress
        )
      case .liveFilesystem:
        return try folderEngine.scanCandidates(
          configuration: configuration,
          target: target,
          progress: progress
        )
      }
    }

    let startedAt = Date()
    var notices: [String] = []
    let steps = scanSteps(configuration: configuration, notices: &notices)
    var candidates: [CleanupCandidate] = []

    for (index, step) in steps.enumerated() {
      progress?(
        CleanupScanProgress(
          message: step.name,
          currentPath: step.path,
          currentStep: index,
          totalSteps: steps.count
        ))
      do {
        candidates.append(contentsOf: try step.body())
      } catch {
        notices.append("\(step.name)：\(error.localizedDescription)")
      }
    }

    progress?(
      CleanupScanProgress(
        message: "整理候選、排除重疊與受保護路徑",
        currentPath: nil,
        currentStep: steps.count,
        totalSteps: steps.count
      ))

    candidates = normalizedCandidates(candidates, configuration: configuration)
    return CleanupScanResult(
      configuration: configuration,
      candidates: candidates,
      startedAt: startedAt,
      finishedAt: Date(),
      notices: notices,
      mode: .system,
      target: target,
      scanSource: .liveFilesystem
    )
  }

  func refreshGeneralLocationDirectories(
    configuration: CleanupScanConfiguration,
    target: ScanTarget,
    directoryPaths: Set<String>,
    scanSource: CleanupScanSource,
    progress: ProgressHandler? = nil
  ) throws -> CleanupScanResult {
    guard CleanupMode.forTarget(target) == .generalLocation else {
      throw CleanupValidationError.rejected("增量資料夾刷新只適用於一般位置清理。")
    }
    return try FolderCleanupEngine(fileManager: fileManager, homeURL: home)
      .scanCandidateDirectories(
        configuration: configuration,
        target: target,
        directoryPaths: directoryPaths,
        scanSource: scanSource,
        progress: progress
      )
  }

  func visibleCandidates(
    from indexedCandidates: [CleanupCandidate],
    configuration: CleanupScanConfiguration,
    mode: CleanupMode
  ) -> [CleanupCandidate] {
    if mode == .system {
      return normalizedCandidates(indexedCandidates, configuration: configuration)
    }

    let effectiveMinimum = configuration.effectiveMinimumBytes(for: .generalLocation)
    let unknownSizeRules: Set<CleanupRuleID> = [
      .folderSpotlightMetadata,
      .folderFSEventsMetadata,
      .folderLegacySpotlightTrashResidue,
      .folderLegacyFSEventsTrashResidue,
    ]
    return indexedCandidates.filter { candidate in
      guard configuration.includes(tier: candidate.tier, scope: candidate.scope) else {
        return false
      }
      if candidate.action == .reviewOnly || unknownSizeRules.contains(candidate.ruleID) {
        return true
      }
      return effectiveMinimum == 0 || candidate.bytes >= effectiveMinimum
    }
    .sorted { lhs, rhs in
      if lhs.tier == rhs.tier {
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
      }
      return lhs.tier < rhs.tier
    }
  }

  func executeSelected(
    _ candidates: [CleanupCandidate],
    profile: CleanupProfile,
    target: ScanTarget = .systemStorage,
    removalMode: CleanupExecutionMode = .moveToTrash
  ) throws -> (CleanupLog, URL) {
    let selected = candidates.filter { $0.selected && $0.isSelectable }
    guard !selected.isEmpty else {
      throw CleanupValidationError.rejected("沒有選取可執行的清理項目。")
    }

    let targetCapabilities = CleanupTargetCapabilityResolver.resolve(target: target)
    let entries: [CleanupLog.Entry]
    switch removalMode {
    case .moveToTrash:
      guard targetCapabilities.supportsFinderVisibleTrash else {
        throw CleanupValidationError.rejected(
          targetCapabilities.finderTrashUnavailableReason
            ?? "目前目標無法使用 Finder 可見垃圾桶。"
        )
      }
      guard selected.allSatisfy(\.supportsFinderVisibleTrash) else {
        let directOnly = selected.filter { !$0.supportsFinderVisibleTrash }.map(\.displayName)
        throw CleanupValidationError.rejected(
          "下列項目不能假裝移到垃圾桶，必須改用『直接徹底刪除』："
            + directOnly.joined(separator: "、")
        )
      }
      entries = selected.map { candidate in
        do {
          switch candidate.action {
          case .moveContentsToTrash:
            return try moveContentsToTrash(candidate)
          case .moveItemToTrash:
            return try moveItemToTrash(candidate)
          case .moveMatchedItemsToTrash:
            return try moveMatchedItemsToTrash(candidate)
          case .permanentDeleteMatchedItems, .managedCommand, .reviewOnly:
            throw CleanupValidationError.rejected(
              "這個候選不支援 Finder 可見垃圾桶：\(candidate.displayName)"
            )
          }
        } catch {
          return failedLogEntry(candidate, mode: .moveToTrash, error: error)
        }
      }

    case .forceDelete:
      guard targetCapabilities.supportsDirectDeletion else {
        throw CleanupValidationError.rejected("目前目標是唯讀檔案系統，不能執行直接刪除。")
      }
      guard selected.allSatisfy(\.supportsDirectDeletion) else {
        throw CleanupValidationError.rejected("選取內容含不可執行的僅檢視項目。")
      }
      entries = selected.map { candidate in
        do {
          return try directlyDelete(candidate, targetCapabilities: targetCapabilities)
        } catch {
          return failedLogEntry(candidate, mode: .forceDelete, error: error)
        }
      }
    }

    let mode = CleanupMode.forTarget(target)
    let log = CleanupLog(
      createdAt: Date(),
      mode: mode == .system ? "explicit_mixed_cleanup" : "folder_metadata_cleanup",
      removalMode: removalMode.rawValue,
      profile: profile.rawValue,
      targetKind: target.kind.rawValue,
      targetPath: target.path,
      entries: entries
    )
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let logURL = library.cleanupHistoryURL.appendingPathComponent(
      "cleanup-\(formatter.string(from: Date())).json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(log).write(to: logURL, options: .atomic)
    return (log, logURL)
  }

  // MARK: - Scan catalogue

  private func scanSteps(
    configuration: CleanupScanConfiguration,
    notices: inout [String]
  ) -> [ScanStep] {
    var steps: [ScanStep] = []

    if scopeCanAppear(.standardCaches, configuration: configuration) {
      let root = home.appendingPathComponent("Library/Caches", isDirectory: true)
      steps.append(
        ScanStep(name: "檢查標準使用者快取", path: root.path) {
          try self.scanStandardUserCaches(configuration: configuration)
        })
    }

    if scopeCanAppear(.sandboxAndGroupCaches, configuration: configuration) {
      let containers = home.appendingPathComponent("Library/Containers", isDirectory: true)
      steps.append(
        ScanStep(name: "檢查沙盒 App 快取", path: containers.path) {
          try self.scanSandboxCaches(configuration: configuration)
        })
      let groups = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
      steps.append(
        ScanStep(name: "檢查群組容器快取", path: groups.path) {
          try self.scanGroupContainerCaches(configuration: configuration)
        })
    }

    if scopeCanAppear(.clipboardTemporary, configuration: configuration) {
      steps.append(
        ScanStep(name: "檢查跨裝置剪貼簿暫存", path: clipboardArchiveURL.path) {
          try self.scanClipboardArchive(configuration: configuration)
        })
    }

    if scopeCanAppear(.applicationWebCaches, configuration: configuration) {
      let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
      steps.append(
        ScanStep(name: "檢查 App 網頁與繪圖快取", path: appSupport.path) {
          try self.scanApplicationSupportCaches(configuration: configuration)
        })
    }

    if scopeCanAppear(.developerCaches, configuration: configuration) {
      let developer = home.appendingPathComponent("Library/Developer", isDirectory: true)
      steps.append(
        ScanStep(name: "檢查開發工具快取", path: developer.path) {
          try self.scanDeveloperCaches(configuration: configuration)
        })
    }

    if scopeCanAppear(.packageManagerCaches, configuration: configuration) {
      steps.append(
        ScanStep(name: "檢查套件管理器快取", path: home.path) {
          try self.scanPackageManagerCaches(configuration: configuration)
        })
      steps.append(
        ScanStep(name: "預覽 Homebrew 官方清理", path: nil) {
          try self.scanHomebrewCleanup(configuration: configuration)
        })
      steps.append(
        ScanStep(name: "檢查 Conda 未使用套件快取", path: nil) {
          try self.scanCondaCleanup(configuration: configuration)
        })
    }

    if scopeCanAppear(.downloadResidue, configuration: configuration) {
      let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
      steps.append(
        ScanStep(name: "檢查下載殘留與舊安裝檔", path: downloads.path) {
          try self.scanDownloadResidue(configuration: configuration)
        })
    }

    if scopeCanAppear(.appLeftovers, configuration: configuration) {
      steps.append(
        ScanStep(name: "檢查已卸載 App 的可重建殘留", path: home.path) {
          try self.scanAppLeftovers(configuration: configuration)
        })
    }

    if scopeCanAppear(.brokenPreferences, configuration: configuration) {
      let preferences = home.appendingPathComponent("Library/Preferences", isDirectory: true)
      steps.append(
        ScanStep(name: "驗證第三方偏好設定 plist", path: preferences.path) {
          try self.scanBrokenPreferences(configuration: configuration)
        })
    }

    if scopeCanAppear(.diagnosticsAndLogs, configuration: configuration) {
      let logs = home.appendingPathComponent("Library/Logs", isDirectory: true)
      steps.append(
        ScanStep(name: "檢查使用者診斷與日誌", path: logs.path) {
          try self.scanUserDiagnosticsAndLogs(configuration: configuration)
        })
    }

    if scopeCanAppear(.highImpactUserData, configuration: configuration) {
      steps.append(
        ScanStep(name: "檢查高影響可回收資料", path: home.path) {
          try self.scanHighImpactUserData(configuration: configuration)
        })
    }

    if scopeCanAppear(.trashBins, configuration: configuration) {
      let roots = trashBinRoots()
      if roots.isEmpty {
        let userTrash = home.appendingPathComponent(".Trash", isDirectory: true)
        steps.append(
          ScanStep(name: "檢查目前使用者的廢紙簍", path: userTrash.path) { [] })
      } else {
        for root in roots {
          steps.append(
            ScanStep(name: "檢查\(root.displayName)", path: root.url.path) {
              try self.scanTrashBin(root, configuration: configuration)
            })
        }
      }
    }

    if scopeCanAppear(.systemManagedReview, configuration: configuration) {
      steps.append(
        ScanStep(name: "核對系統管理項目（不直接清理）", path: "/") {
          try self.scanSystemManagedReview(configuration: configuration)
        })
    }

    if steps.isEmpty {
      notices.append("自定義模式尚未選擇任何掃描類型。")
    }
    return steps
  }

  private func scopeCanAppear(
    _ scope: CleanupScope,
    configuration: CleanupScanConfiguration
  ) -> Bool {
    // Use the same configuration authority as the UI and incremental index.
    // In particular, L5 optional scopes must not enumerate their roots until
    // the user has explicitly enabled the corresponding toggle.
    configuration.requiresScope(scope)
  }

  private func scanStandardUserCaches(
    configuration: CleanupScanConfiguration
  ) throws -> [CleanupCandidate] {
    let root = home.appendingPathComponent("Library/Caches", isDirectory: true)
    // Filter policy-level exclusions *before* walking directory trees for size.
    // Some excluded caches (notably Spotify offline media) can be large, and a
    // broad size probe should not need to traverse content we have already
    // decided must never become a cleanup candidate.
    let directories = immediateDirectories(in: root).filter { url in
      !isCloudOrSyncPath(url)
        && !SystemJunkKnowledge.shouldExcludeStandardUserCache(
          directoryName: url.lastPathComponent
        )
    }
    let sizes = try allocatedSizes(for: directories)

    return directories.compactMap { url in
      let name = url.lastPathComponent
      let isApple = isAppleIdentifier(name)
      let tier: CleanupTier = isApple ? .conservative : .ultraConservative
      guard configuration.includes(tier: tier, scope: .standardCaches) else { return nil }
      return CleanupCandidate(
        ruleID: .standardUserCache,
        scope: .standardCaches,
        tier: tier,
        category: .standardCache,
        action: .moveContentsToTrash,
        path: url.path,
        displayName: friendlyIdentifier(name),
        bytes: sizes[url.path] ?? 0,
        risk: isApple ? .low : .minimal,
        reason: "標準 ~/Library/Caches 子目錄；依 macOS 目錄語意，內容應可由 App 重新建立。",
        impact: isApple
          ? "Apple 服務可能重新分析、建立縮圖或下載資源。"
          : "相關 App 第一次啟動可能較慢，並重新下載部分資源。",
        recovery: "重新開啟相關 App 後由 App 自動重建。"
      )
    }
  }

  private func scanSandboxCaches(
    configuration: CleanupScanConfiguration
  ) throws -> [CleanupCandidate] {
    let root = home.appendingPathComponent("Library/Containers", isDirectory: true)
    let caches = immediateDirectories(in: root).compactMap { container -> URL? in
      guard !isCloudOrSyncPath(container) else { return nil }
      let cache = container.appendingPathComponent("Data/Library/Caches", isDirectory: true)
      return safeDirectoryExists(cache) ? cache : nil
    }
    let sizes = try allocatedSizes(for: caches)

    return caches.compactMap { url in
      let containerID = containerIdentifier(forSandboxCache: url)
      let isApple = isAppleIdentifier(containerID)
      let tier: CleanupTier = isApple ? .conservative : .ultraConservative
      guard configuration.includes(tier: tier, scope: .sandboxAndGroupCaches) else { return nil }
      return CleanupCandidate(
        ruleID: .sandboxCache,
        scope: .sandboxAndGroupCaches,
        tier: tier,
        category: .sandboxCache,
        action: .moveContentsToTrash,
        path: url.path,
        displayName: friendlyIdentifier(containerID),
        bytes: sizes[url.path] ?? 0,
        risk: isApple ? .low : .minimal,
        reason: "沙盒 App 的 Data/Library/Caches；只清內容並保留容器與父資料夾。",
        impact: isApple
          ? "可能觸發照片／媒體分析、桌布或其他 Apple 服務重新建立快取。"
          : "App 可能在下次啟動時重新產生縮圖、索引或下載快取。",
        recovery: "由對應 App 或 macOS 服務自動重建。"
      )
    }
  }

  private func scanGroupContainerCaches(
    configuration: CleanupScanConfiguration
  ) throws -> [CleanupCandidate] {
    guard configuration.includes(tier: .conservative, scope: .sandboxAndGroupCaches) else {
      return []
    }
    let root = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
    var caches: [URL] = []
    for group in immediateDirectories(in: root) where !isCloudOrSyncPath(group) {
      for relative in ["Library/Caches", "Data/Library/Caches"] {
        let cache = group.appendingPathComponent(relative, isDirectory: true)
        if safeDirectoryExists(cache) { caches.append(cache) }
      }
    }
    let unique = uniqueURLs(caches)
    let sizes = try allocatedSizes(for: unique)
    return unique.map { url in
      let groupID = groupContainerIdentifier(forCache: url)
      return CleanupCandidate(
        ruleID: .groupContainerCache,
        scope: .sandboxAndGroupCaches,
        tier: .conservative,
        category: .sandboxCache,
        action: .moveContentsToTrash,
        path: url.path,
        displayName: friendlyIdentifier(groupID),
        bytes: sizes[url.path] ?? 0,
        risk: .low,
        reason: "Group Container 中名稱與位置都明確的標準 Caches 目錄。",
        impact: "同一開發者的多個 App 可能共同重新建立或下載這些資料。",
        recovery: "由所屬 App 群組自動重建。"
      )
    }
  }

  private func scanClipboardArchive(
    configuration: CleanupScanConfiguration
  ) throws -> [CleanupCandidate] {
    guard configuration.includes(tier: .conservative, scope: .clipboardTemporary),
      safeDirectoryExists(clipboardArchiveURL)
    else { return [] }
    let bytes = try allocatedSizes(for: [clipboardArchiveURL])[clipboardArchiveURL.path] ?? 0
    return [
      CleanupCandidate(
        ruleID: .clipboardArchive,
        scope: .clipboardTemporary,
        tier: .conservative,
        category: .clipboardArchive,
        action: .moveContentsToTrash,
        path: clipboardArchiveURL.path,
        displayName: "Universal Clipboard 封存暫存",
        bytes: bytes,
        risk: .low,
        reason: "Handoff／Universal Clipboard 的 shared-pasteboard 封存；異常時可能持續累積。",
        impact: "目前跨裝置剪貼簿內容會消失；清理時不得有 Finder 複製作業。",
        recovery: "重新使用 Handoff／跨裝置剪貼簿時由系統重新建立。"
      )
    ]
  }

  private func scanApplicationSupportCaches(
    configuration: CleanupScanConfiguration
  ) throws -> [CleanupCandidate] {
    let root = home.appendingPathComponent("Library/Application Support", isDirectory: true)
    guard safeDirectoryExists(root) else { return [] }
    var discovered: [(URL, URL, Bool)] = []

    for appRoot in immediateDirectories(in: root) where !isCloudOrSyncPath(appRoot) {
      let bases = applicationCacheBases(for: appRoot)
      for base in bases {
        let baseChildren = immediateDirectories(in: base)
        for candidate in baseChildren where isRenderCacheMarker(candidate.lastPathComponent) {
          discovered.append((candidate, appRoot, false))
        }

        if let serviceWorker = immediateDirectory(
          named: "Service Worker",
          in: baseChildren
        ),
          let cacheStorage = immediateDirectory(
            named: "CacheStorage",
            in: immediateDirectories(in: serviceWorker)
          )
        {
          discovered.append((cacheStorage, appRoot, true))
        }

        if let webStorage = immediateDirectory(named: "WebStorage", in: baseChildren) {
          for partition in immediateDirectories(in: webStorage) {
            if let cacheStorage = immediateDirectory(
              named: "CacheStorage",
              in: immediateDirectories(in: partition)
            ) {
              discovered.append((cacheStorage, appRoot, true))
            }
          }
        }
      }
    }

    let paths = uniqueURLs(discovered.map(\.0))
    let sizes = try allocatedSizes(for: paths)
    var metadataByPath: [String: (URL, Bool)] = [:]
    for (url, appRoot, offline) in discovered {
      let existing = metadataByPath[url.path]
      if existing == nil || offline { metadataByPath[url.path] = (appRoot, offline) }
    }

    return paths.compactMap { url in
      guard let metadata = metadataByPath[url.path] else { return nil }
      let tier: CleanupTier = metadata.1 ? .aggressive : .conservative
      guard configuration.includes(tier: tier, scope: .applicationWebCaches) else { return nil }
      let relative = relativePath(url, from: metadata.0)
      return CleanupCandidate(
        ruleID: metadata.1 ? .applicationOfflineCache : .applicationRenderCache,
        scope: .applicationWebCaches,
        tier: tier,
        category: .applicationCache,
        action: .moveContentsToTrash,
        path: url.path,
        displayName: "\(friendlyIdentifier(metadata.0.lastPathComponent)) · \(relative)",
        bytes: sizes[url.path] ?? 0,
        risk: metadata.1 ? .moderate : .low,
        reason: metadata.1
          ? "名稱明確的 Service Worker／WebStorage CacheStorage；不包含 Cookie、IndexedDB、Local Storage 或資料庫。"
          : "Application Support 中名稱明確的 Cache、Code Cache、GPUCache 或 shader cache；不刪除 App profile。",
        impact: metadata.1
          ? "可能移除離線網頁內容，相關 App 需要重新連線與下載。"
          : "App 會重新編譯網頁程式碼、GPU shader 或下載暫存。",
        recovery: "重新啟動並連線後由對應 App 重建。"
      )
    }
  }

  private func scanDeveloperCaches(
    configuration: CleanupScanConfiguration
  ) throws -> [CleanupCandidate] {
    var candidates: [CleanupCandidate] = []
    let exact: [(URL, CleanupRuleID, CleanupTier, String, String, String)] = [
      (
        home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true),
        .xcodeDerivedData, .balanced, "Xcode DerivedData",
        "編譯產物與索引；專案原始碼不在此目錄。",
        "下一次建置或索引會花較多時間。"
      ),
      (
        home.appendingPathComponent("Library/Developer/Xcode/UserData/Previews", isDirectory: true),
        .xcodePreviewsCache, .balanced, "Xcode Previews",
        "SwiftUI／Xcode Preview 的可重建預覽資料；不包含專案原始碼。",
        "下一次開啟 Preview 時需要重新產生預覽資料。"
      ),
      (
        home.appendingPathComponent("Library/Developer/CoreSimulator/Caches", isDirectory: true),
        .coreSimulatorCache, .balanced, "CoreSimulator 快取",
        "Simulator 的標準 cache；不刪除模擬器裝置與 App 資料。",
        "下一次 Simulator 啟動可能需要重新建立快取。"
      ),
    ]
    let existing = exact.filter { safeDirectoryExists($0.0) }
    let sizes = try allocatedSizes(for: existing.map(\.0))
    for item in existing where configuration.includes(tier: item.2, scope: .developerCaches) {
      candidates.append(
        CleanupCandidate(
          ruleID: item.1,
          scope: .developerCaches,
          tier: item.2,
          category: .developerCache,
          action: .moveContentsToTrash,
          path: item.0.path,
          displayName: item.3,
          bytes: sizes[item.0.path] ?? 0,
          risk: .low,
          reason: item.4,
          impact: item.5,
          recovery: "由 Xcode／CoreSimulator 在需要時自動重建。"
        ))
    }

    // Source-reviewed MacSai targets for Cursor/Antigravity and Claude/Codex.
    // These are exact cache/scratch allowlist paths only; neighboring User,
    // extensions, sessions, history and project data are intentionally absent.
    let toolCacheURLs = SystemJunkKnowledge.developerToolCacheURLs(home: home)
    let existingToolCaches = toolCacheURLs.filter {
      configuration.includes(tier: .balanced, scope: .developerCaches)
        && safeDirectoryExists($0.1)
        && !SystemJunkKnowledge.isForbiddenDeveloperUserData(relativePath: $0.0.relativePath)
    }
    let toolSizes = try allocatedSizes(for: existingToolCaches.map(\.1))
    for (spec, url) in existingToolCaches {
      candidates.append(
        CleanupCandidate(
          ruleID: .developerToolCacheDirectory,
          scope: .developerCaches,
          tier: .balanced,
          category: .developerCache,
          action: .moveContentsToTrash,
          path: url.path,
          displayName: spec.displayName,
          bytes: toolSizes[url.path] ?? 0,
          risk: .low,
          reason: spec.reason,
          impact: "相關工具第一次重新啟動、索引或執行時可能較慢，並重新建立或下載 cache。",
          recovery: "由對應工具在需要時重新建立；使用者設定、專案、sessions 與 extensions 不在此規則中。"
        ))
    }

    if configuration.includes(tier: .aggressive, scope: .developerCaches) {
      let deviceSupport = home.appendingPathComponent(
        "Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true)
      let versions = immediateDirectories(in: deviceSupport)
      let versionSizes = try allocatedSizes(for: versions)
      for version in versions {
        candidates.append(
          CleanupCandidate(
            ruleID: .xcodeDeviceSupport,
            scope: .developerCaches,
            tier: .aggressive,
            category: .developerCache,
            action: .moveItemToTrash,
            path: version.path,
            displayName: "Xcode DeviceSupport · \(version.lastPathComponent)",
            bytes: versionSizes[version.path] ?? 0,
            risk: .moderate,
            reason: "連接特定 iOS 版本裝置時使用的符號與支援檔。",
            impact: "再次連接相同系統版本的裝置時可能重新準備或下載。",
            recovery: "由 Xcode 在需要時重新建立或下載。"
          ))
      }
    }
    return candidates
  }

  private func scanPackageManagerCaches(
    configuration: CleanupScanConfiguration
  ) throws -> [CleanupCandidate] {
    let paths = SystemJunkKnowledge.packageManagerCacheURLs(home: home).compactMap {
      spec, url -> (SystemJunkKnowledge.KnownCacheSpec, URL, CleanupTier)? in
      let tier: CleanupTier = spec.safety == .cautious ? .aggressive : .balanced
      guard configuration.includes(tier: tier, scope: .packageManagerCaches),
        safeDirectoryExists(url)
      else { return nil }
      return (spec, url, tier)
    }
    let sizes = try allocatedSizes(for: paths.map(\.1))
    return paths.map { spec, url, tier in
      CleanupCandidate(
        ruleID: .packageCacheDirectory,
        scope: .packageManagerCaches,
        tier: tier,
        category: .packageManagerCache,
        action: .moveContentsToTrash,
        path: url.path,
        displayName: spec.displayName,
        bytes: sizes[url.path] ?? 0,
        risk: tier >= .aggressive ? .moderate : .low,
        reason: spec.reason,
        impact: "之後安裝、建置或離線工作時可能需要重新下載；執行中的 Gradle daemon 也可能需要重啟。",
        recovery: "由對應套件管理器重新下載；本機 Maven 套件需自行確認。"
      )
    }
  }

  private func scanHomebrewCleanup(
    configuration: CleanupScanConfiguration
  ) throws -> [CleanupCandidate] {
    guard configuration.includes(tier: .balanced, scope: .packageManagerCaches),
      let brew = firstExecutable(
        named: "brew",
        knownPaths: [
          "/opt/homebrew/bin/brew", "/usr/local/bin/brew",
        ])
    else { return [] }

    let dryRun = try? ProcessRunner.run(brew, ["cleanup", "--dry-run"], timeout: 180)
    let output = (dryRun?.stdoutString ?? "") + "\n" + (dryRun?.stderrString ?? "")
    var estimated = parseApproximateBytes(output) ?? 0
    let cachePathResult = try? ProcessRunner.run(brew, ["--cache"], timeout: 30)
    let cachePath = cachePathResult?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    if estimated == 0, let cachePath, !cachePath.isEmpty {
      let cacheURL = URL(fileURLWithPath: cachePath, isDirectory: true)
      estimated = try allocatedSizes(for: [cacheURL])[cacheURL.path] ?? 0
    }
    guard estimated > 0 || dryRun?.status == 0 else { return [] }

    return [
      CleanupCandidate(
        ruleID: .homebrewCleanup,
        scope: .packageManagerCaches,
        tier: .balanced,
        category: .packageManagerCache,
        action: .managedCommand,
        path: cachePath?.isEmpty == false ? cachePath! : brew,
        displayName: "Homebrew 官方 cleanup",
        bytes: estimated,
        risk: .moderate,
        reason: "使用 brew cleanup --prune=all 移除過期下載、舊版本與 stale lock；先以 dry-run 估算。",
        impact: "舊版 formula／cask 與全部可清 download cache 會被永久移除，之後可能重新下載。",
        recovery: "需要時由 Homebrew 重新下載；此動作不是移到垃圾桶。",
        managedCommand: ManagedCleanupCommand(
          executable: brew,
          arguments: ["cleanup", "--prune=all"],
          displayCommand: "brew cleanup --prune=all",
          timeoutSeconds: 600
        )
      )
    ]
  }

  private func scanCondaCleanup(
    configuration: CleanupScanConfiguration
  ) throws -> [CleanupCandidate] {
    guard configuration.includes(tier: .balanced, scope: .packageManagerCaches),
      let conda = firstExecutable(
        named: "conda",
        knownPaths: [
          "/opt/anaconda3/bin/conda", "/opt/miniconda3/bin/conda",
          home.appendingPathComponent("anaconda3/bin/conda").path,
          home.appendingPathComponent("miniconda3/bin/conda").path,
        ])
    else { return [] }

    var packageDirectories: [URL] = []
    if let info = try? ProcessRunner.run(conda, ["info", "--json"], timeout: 90),
      info.status == 0,
      let object = try? JSONSerialization.jsonObject(with: info.stdout) as? [String: Any],
      let paths = object["pkgs_dirs"] as? [String]
    {
      packageDirectories.append(
        contentsOf: paths.map { URL(fileURLWithPath: $0, isDirectory: true) })
    }
    packageDirectories.append(contentsOf: [
      URL(fileURLWithPath: "/opt/anaconda3/pkgs", isDirectory: true),
      URL(fileURLWithPath: "/opt/miniconda3/pkgs", isDirectory: true),
      home.appendingPathComponent("anaconda3/pkgs", isDirectory: true),
      home.appendingPathComponent("miniconda3/pkgs", isDirectory: true),
      home.appendingPathComponent(".conda/pkgs", isDirectory: true),
    ])
    packageDirectories = uniqueURLs(packageDirectories.filter(safeDirectoryExists))
    guard !packageDirectories.isEmpty else { return [] }
    let sizes = try allocatedSizes(for: packageDirectories)
    let total = packageDirectories.reduce(Int64(0)) { $0 + (sizes[$1.path] ?? 0) }

    return [
      CleanupCandidate(
        ruleID: .condaCleanup,
        scope: .packageManagerCaches,
        tier: .balanced,
        category: .packageManagerCache,
        action: .managedCommand,
        path: packageDirectories.map(\.path).joined(separator: " · "),
        displayName: "Conda 未使用套件與下載快取",
        bytes: total,
        risk: .moderate,
        reason: "使用 conda clean --all --yes --json；不直接刪除 pkgs 目錄，也不使用危險的 --force-pkgs-dirs。",
        impact: "Conda 會移除 index、lock、tarball、log 與它判定未使用的 package cache；之後可能重新下載。",
        recovery: "需要的套件可由 Conda 重新下載；此動作不是移到垃圾桶。",
        managedCommand: ManagedCleanupCommand(
          executable: conda,
          arguments: ["clean", "--all", "--yes", "--json"],
          displayCommand: "conda clean --all --yes --json",
          timeoutSeconds: 900
        )
      )
    ]
  }

  private func scanDownloadResidue(
    configuration: CleanupScanConfiguration
  ) throws -> [CleanupCandidate] {
    let root = home.appendingPathComponent("Downloads", isDirectory: true).standardizedFileURL
    guard safeDirectoryExists(root) else { return [] }

    let items = immediateItems(in: root)
    var classified: [(URL, SystemJunkKnowledge.DownloadResidueKind)] = []
    for item in items {
      guard !isCloudOrSyncPath(item),
        let kind = downloadResidueKind(at: item)
      else { continue }

      let tier: CleanupTier
      switch kind {
      case .incompleteDownload: tier = .conservative
      case .staleInstaller, .staleDiskImage: tier = .ultraAggressive
      }
      guard configuration.includes(tier: tier, scope: .downloadResidue) else { continue }
      classified.append((item, kind))
    }

    let sizes = try allocatedSizes(for: classified.map(\.0))
    return classified.map { item, kind in
      switch kind {
      case .incompleteDownload:
        return CleanupCandidate(
          ruleID: .incompleteDownload,
          scope: .downloadResidue,
          tier: .conservative,
          category: .downloadResidue,
          action: .moveItemToTrash,
          path: item.path,
          displayName: "未完成下載 · \(item.lastPathComponent)",
          bytes: sizes[item.path] ?? 0,
          risk: .low,
          reason: "Downloads 根層的 .download／.crdownload／.part／.partial／.tmp 已至少 24 小時未修改，視為停滯下載。",
          impact: "若下載工作其實仍要續傳，移除後可能必須重新下載。",
          recovery: "預設先移到 Finder 可見垃圾桶；確認無需續傳後再清空垃圾桶。"
        )
      case .staleInstaller:
        return CleanupCandidate(
          ruleID: .staleInstallerPackage,
          scope: .downloadResidue,
          tier: .ultraAggressive,
          category: .downloadResidue,
          action: .moveItemToTrash,
          path: item.path,
          displayName: "舊安裝套件 · \(item.lastPathComponent)",
          bytes: sizes[item.path] ?? 0,
          risk: .high,
          reason: "Downloads 根層的 .pkg／.mpkg 已至少 7 天未修改；它可能只是安裝完成後留下的安裝媒體。",
          impact: "可能失去離線重新安裝所需的安裝套件，因此只在超激進等級顯示且不批次勾選。",
          recovery: "移到 Finder 可見垃圾桶後仍可還原；若已清空則需重新取得安裝程式。"
        )
      case .staleDiskImage:
        return CleanupCandidate(
          ruleID: .staleDiskImage,
          scope: .downloadResidue,
          tier: .ultraAggressive,
          category: .downloadResidue,
          action: .moveItemToTrash,
          path: item.path,
          displayName: "舊磁碟映像 · \(item.lastPathComponent)",
          bytes: sizes[item.path] ?? 0,
          risk: .high,
          reason: "Downloads 根層的 .dmg／.iso／.sparseimage 已至少 7 天未修改；只把它視為可檢查候選，不假設一定是垃圾。",
          impact: "磁碟映像可能是軟體安裝來源、封存或使用者自行建立的資料，因此必須逐項確認。",
          recovery: "移到 Finder 可見垃圾桶後仍可還原；清空後需由原始來源重新取得。"
        )
      }
    }
  }

  private func scanAppLeftovers(
    configuration: CleanupScanConfiguration
  ) throws -> [CleanupCandidate] {
    guard configuration.includes(tier: .aggressive, scope: .appLeftovers) else { return [] }

    let installed = installedApplicationBundleIdentifiers()
    guard !installed.isEmpty else {
      throw CleanupValidationError.rejected(
        "無法建立已安裝 App 的 bundle identifier 清單；為避免誤判，已停止 App 殘留掃描。"
      )
    }

    var matches: [(URL, SystemJunkKnowledge.LeftoverRootKind, String)] = []
    for (kind, root) in SystemJunkKnowledge.leftoverRoots(home: home) {
      guard safeDirectoryExists(root), !isCloudOrSyncPath(root) else { continue }
      for item in immediateItems(in: root) {
        guard !isCloudOrSyncPath(item),
          SystemJunkKnowledge.isOrphanedAppEntry(
            entryName: item.lastPathComponent,
            rootKind: kind,
            installedBundleIdentifiers: installed
          ),
          let identifier = SystemJunkKnowledge.candidateBundleIdentifier(
            entryName: item.lastPathComponent,
            rootKind: kind
          )
        else { continue }
        matches.append((item, kind, identifier))
      }
    }

    let sizes = try allocatedSizes(for: matches.map(\.0))
    return matches.map { item, kind, identifier in
      CleanupCandidate(
        ruleID: .appLeftoverEntry,
        scope: .appLeftovers,
        tier: .aggressive,
        category: .appLeftovers,
        action: .moveItemToTrash,
        path: item.path,
        displayName: "\(friendlyIdentifier(identifier)) · \(kind.displayName)",
        bytes: sizes[item.path] ?? 0,
        risk: .moderate,
        reason:
          "只在可重建的 \(kind.displayName) 根層辨識 reverse-DNS 項目；目前標準 App 目錄中找不到相同或同 lineage 的 bundle identifier。",
        impact: "若 App 安裝在非標準位置，仍可能被誤判，因此此類候選固定需要逐項確認。Preferences、Containers、Keychains 不在掃描範圍。",
        recovery: "預設移到 Finder 可見垃圾桶；重新安裝／啟動 App 也通常能重建這些 cache、log 或 WebKit 狀態。"
      )
    }
  }

  private func scanBrokenPreferences(
    configuration: CleanupScanConfiguration
  ) throws -> [CleanupCandidate] {
    guard configuration.includes(tier: .aggressive, scope: .brokenPreferences) else { return [] }
    let root = home.appendingPathComponent("Library/Preferences", isDirectory: true)
      .standardizedFileURL
    guard safeDirectoryExists(root) else { return [] }

    var matches: [URL] = []
    for item in immediateItems(in: root) {
      guard SystemJunkKnowledge.preferenceDomain(fileName: item.lastPathComponent) != nil,
        let values = try? item.resourceValues(forKeys: [
          .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]),
        values.isRegularFile == true,
        values.isDirectory != true,
        values.isSymbolicLink != true,
        let data = try? Data(contentsOf: item, options: [.mappedIfSafe]),
        SystemJunkKnowledge.plistIsCorrupt(data: data)
      else { continue }
      matches.append(item)
    }

    let sizes = try allocatedSizes(for: matches)
    return matches.map { item in
      let domain =
        SystemJunkKnowledge.preferenceDomain(fileName: item.lastPathComponent)
        ?? item.deletingPathExtension().lastPathComponent
      return CleanupCandidate(
        ruleID: .corruptPreferencePlist,
        scope: .brokenPreferences,
        tier: .aggressive,
        category: .brokenPreferences,
        action: .moveItemToTrash,
        path: item.path,
        displayName: "損壞 plist · \(friendlyIdentifier(domain))",
        bytes: sizes[item.path] ?? 0,
        risk: .moderate,
        reason: "PropertyListSerialization 無法解析這個第三方 Preferences plist；不是因為『找不到對應 App』而推測可刪。",
        impact: "相關 App 的偏好設定可能會在下次啟動時回到預設值；Apple/system domain 已明確排除。",
        recovery: "先移到 Finder 可見垃圾桶；需要時可還原原檔，或由 App 重新建立有效 plist。"
      )
    }
  }

  private func scanUserDiagnosticsAndLogs(
    configuration: CleanupScanConfiguration
  ) throws -> [CleanupCandidate] {
    guard configuration.includes(tier: .aggressive, scope: .diagnosticsAndLogs) else {
      return []
    }
    let logsRoot = home.appendingPathComponent("Library/Logs", isDirectory: true)
    let directories = immediateDirectories(in: logsRoot)
    let crashReporter = home.appendingPathComponent(
      "Library/Application Support/CrashReporter", isDirectory: true)
    let all = uniqueURLs(directories + (safeDirectoryExists(crashReporter) ? [crashReporter] : []))
    let sizes = try allocatedSizes(for: all)
    return all.map { url in
      let diagnostic =
        url.lastPathComponent == "DiagnosticReports"
        || url.lastPathComponent == "CrashReporter"
      return CleanupCandidate(
        ruleID: diagnostic ? .diagnosticReports : .userLogDirectory,
        scope: .diagnosticsAndLogs,
        tier: .aggressive,
        category: .diagnosticsAndLogs,
        action: .moveContentsToTrash,
        path: url.path,
        displayName: diagnostic ? "使用者診斷報告" : friendlyIdentifier(url.lastPathComponent),
        bytes: sizes[url.path] ?? 0,
        risk: .moderate,
        reason: diagnostic ? "使用者層 crash／diagnostic reports。" : "使用者 Library/Logs 內的 App 日誌。",
        impact: "會失去歷史故障排查資料；不影響 App 本體，但可能降低問題診斷能力。",
        recovery: "新的日誌會重新產生；舊紀錄無法由 App 重建。"
      )
    }
  }

  private func scanHighImpactUserData(
    configuration: CleanupScanConfiguration
  ) throws -> [CleanupCandidate] {
    guard configuration.includes(tier: .ultraAggressive, scope: .highImpactUserData) else {
      return []
    }
    var candidates: [CleanupCandidate] = []

    let backupRoot = home.appendingPathComponent(
      "Library/Application Support/MobileSync/Backup", isDirectory: true)
    let backups = immediateDirectories(in: backupRoot)
    let backupSizes = try allocatedSizes(for: backups)
    for backup in backups {
      candidates.append(
        CleanupCandidate(
          ruleID: .mobileDeviceBackup,
          scope: .highImpactUserData,
          tier: .ultraAggressive,
          category: .highImpactUserData,
          action: .moveItemToTrash,
          path: backup.path,
          displayName: "iPhone／iPad 本機備份 · \(backup.lastPathComponent)",
          bytes: backupSizes[backup.path] ?? 0,
          risk: .high,
          reason: "Finder／舊 iTunes 建立的本機裝置備份；不是快取。",
          impact: "刪除後將失去這個本機還原點；請先確認有其他有效備份。",
          recovery: "只能重新為裝置建立備份；舊備份內容無法重建。"
        ))
    }

    let archiveRoot = home.appendingPathComponent(
      "Library/Developer/Xcode/Archives", isDirectory: true)
    let archives = xcodeArchives(in: archiveRoot)
    let archiveSizes = try allocatedSizes(for: archives)
    for archive in archives {
      candidates.append(
        CleanupCandidate(
          ruleID: .xcodeArchive,
          scope: .highImpactUserData,
          tier: .ultraAggressive,
          category: .highImpactUserData,
          action: .moveItemToTrash,
          path: archive.path,
          displayName: archive.deletingPathExtension().lastPathComponent,
          bytes: archiveSizes[archive.path] ?? 0,
          risk: .high,
          reason: "Xcode .xcarchive，可能包含發行 binary、dSYM 與除錯符號；不是一般 cache。",
          impact: "可能失去重新匯出、符號化 crash 或提交舊版本的能力。",
          recovery: "只有保留原始碼與相同建置環境時才可能重新產生。"
        ))
    }

    let mailDownloads = home.appendingPathComponent(
      "Library/Containers/com.apple.mail/Data/Library/Mail Downloads", isDirectory: true)
    if safeDirectoryExists(mailDownloads) {
      let bytes = try allocatedSizes(for: [mailDownloads])[mailDownloads.path] ?? 0
      candidates.append(
        CleanupCandidate(
          ruleID: .mailDownloads,
          scope: .highImpactUserData,
          tier: .ultraAggressive,
          category: .highImpactUserData,
          action: .moveContentsToTrash,
          path: mailDownloads.path,
          displayName: "Mail 已下載附件副本",
          bytes: bytes,
          risk: .high,
          reason: "Apple Mail 為附件建立的本機下載副本；不是所有項目都保證可再次下載。",
          impact: "離線附件會消失；郵件伺服器已刪除或只有本機保存的內容可能無法恢復。",
          recovery: "仍存在郵件伺服器上的附件可重新下載。"
        ))
    }

    return candidates
  }

  private struct TrashBinRoot {
    let url: URL
    let displayName: String
    let isExternalVolume: Bool
  }

  private func trashBinRoots() -> [TrashBinRoot] {
    var roots: [TrashBinRoot] = []
    let userTrash = home.appendingPathComponent(".Trash", isDirectory: true).standardizedFileURL
    if fileSystemObjectExists(at: userTrash) {
      roots.append(
        TrashBinRoot(
          url: userTrash,
          displayName: "目前使用者廢紙簍",
          isExternalVolume: false
        ))
    }

    for volume in immediateDirectories(in: volumesRoot) {
      guard
        (try? ExternalVolumeCleanupExecutor.validateExternalVolumeRoot(
          volume.path,
          fileManager: fileManager,
          volumesRootURL: volumesRoot
        )) != nil
      else { continue }

      let root =
        volume
        .appendingPathComponent(".Trashes", isDirectory: true)
        .appendingPathComponent(String(currentUserID), isDirectory: true)
        .standardizedFileURL
      guard fileSystemObjectExists(at: root), isValidExternalTrashRoot(root) else { continue }
      roots.append(
        TrashBinRoot(
          url: root,
          displayName: "外接卷宗「\(volume.lastPathComponent)」廢紙簍",
          isExternalVolume: true
        ))
    }

    var seen = Set<String>()
    return roots.filter { seen.insert($0.url.path).inserted }
  }

  private func scanTrashBin(
    _ root: TrashBinRoot,
    configuration: CleanupScanConfiguration
  ) throws -> [CleanupCandidate] {
    guard configuration.includes(tier: .ultraAggressive, scope: .trashBins) else {
      return []
    }

    _ = try validatedTrashBinRoot(root.url)
    let items = try trashBinItems(in: root.url)
    guard !items.isEmpty else { return [] }

    let sizes = bestEffortAllocatedSizes(for: items)
    let matchedPaths = items.map(\.path).sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }
    let bytesByPath = Dictionary(
      uniqueKeysWithValues: matchedPaths.map { ($0, max(0, sizes[$0] ?? 0)) }
    )
    let totalBytes = bytesByPath.values.reduce(0, +)

    return [
      CleanupCandidate(
        ruleID: .trashBinContents,
        scope: .trashBins,
        tier: .ultraAggressive,
        category: .trashBins,
        action: .permanentDeleteMatchedItems,
        path: root.url.path,
        displayName: root.displayName,
        bytes: totalBytes,
        risk: .high,
        reason: root.isExternalVolume
          ? "Finder 已把這些項目放在本機可寫外接卷宗的 .Trashes/<目前 UID>；掃描只列出目前使用者的第一層項目。"
          : "Finder 已把這些項目放在目前使用者的 ~/.Trash；掃描只列出當下存在的第一層項目。",
        impact: "執行後會永久移除掃描時列出的 \(matchedPaths.count) 個項目，不會再搬進另一個垃圾桶，也無法由 Finder 還原。",
        recovery: "只能依靠 Time Machine、其他備份或檔案系統快照復原。",
        matchedPaths: matchedPaths,
        matchedPathBytes: bytesByPath,
        cleanupRootPath: root.url.path
      )
    ]
  }

  private func trashBinItems(in root: URL) throws -> [URL] {
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true,
      !isSymbolicLink(at: root)
    else {
      throw CleanupValidationError.rejected(root.path)
    }

    let rootAttributes = try fileManager.attributesOfItem(atPath: root.path)
    guard let rootDevice = numericAttribute(rootAttributes[.systemNumber]) else {
      throw CleanupValidationError.rejected("無法確認廢紙簍所在裝置：\(root.path)")
    }

    let items = try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsSubdirectoryDescendants]
    )
    return items.filter { item in
      let source = item.standardizedFileURL
      guard source.deletingLastPathComponent().standardizedFileURL.path == root.path,
        !source.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }
        ),
        !isSymbolicLink(at: source)
      else { return false }
      guard let attributes = try? fileManager.attributesOfItem(atPath: source.path),
        let type = attributes[.type] as? FileAttributeType,
        type == .typeDirectory || type == .typeRegular,
        numericAttribute(attributes[.systemNumber]) == rootDevice
      else { return false }
      return fileSystemObjectExists(at: source)
    }
  }

  private func bestEffortAllocatedSizes(for urls: [URL]) -> [String: Int64] {
    if let sizes = try? allocatedSizes(for: urls) { return sizes }
    var sizes: [String: Int64] = [:]
    for url in urls {
      if let value = try? allocatedSizes(for: [url])[url.path] { sizes[url.path] = value }
    }
    return sizes
  }

  private func scanSystemManagedReview(
    configuration: CleanupScanConfiguration
  ) throws -> [CleanupCandidate] {
    guard configuration.includes(tier: .ultraAggressive, scope: .systemManagedReview) else {
      return []
    }
    var candidates: [CleanupCandidate] = []
    var paths: [(URL, String, String, String)] = [
      (
        localLibrary.appendingPathComponent(
          "Caches/com.apple.iconservices.store", isDirectory: true),
        "IconServices 系統圖示快取",
        "可能很大，但應交由 macOS／安全模式管理，不直接 rm。",
        "刪除會觸發全系統圖示重建與額外 CPU／I/O。"
      ),
      (
        privateRoot.appendingPathComponent("var/db/diagnostics", isDirectory: true),
        "系統 diagnostics",
        "系統診斷資料，不是零影響垃圾。",
        "手動刪除會失去歷史診斷與故障分析資料。"
      ),
      (
        privateRoot.appendingPathComponent("var/db/uuidtext", isDirectory: true),
        "系統 uuidtext",
        "與統一日誌符號解析相關，不應由一般清理器刪除。",
        "可能降低診斷與日誌解析能力。"
      ),
      (
        privateRoot.appendingPathComponent("var/log", isDirectory: true),
        "系統日誌",
        "由 logd 與系統輪替機制管理。",
        "會失去系統與服務的故障排查紀錄。"
      ),
      (
        localLibrary.appendingPathComponent("Logs", isDirectory: true),
        "全系統 App 日誌",
        "位於 /Library/Logs，由 macOS 與安裝於所有使用者的 App 管理。",
        "手動清除會失去歷史故障排查資料，且部分服務可能仍在寫入。"
      ),
      (
        privateRoot.appendingPathComponent("tmp", isDirectory: true),
        "系統暫存區 /private/tmp",
        "暫存內容應優先交由重新啟動或安全模式處理。",
        "檔案可能仍被程序使用；MacStorageLens 不直接刪除。"
      ),
      (
        localLibrary.appendingPathComponent(
          "Application Support/Apple/AssetCache/Data", isDirectory: true),
        "Apple 內容快取資料",
        "若內容快取已啟用，應只從「系統設定 → 一般 → 共享 → 內容快取」查看與重設。",
        "清空後其他裝置可能需要重新從網路下載更新與內容。"
      ),
    ]

    let libraryCaches = localLibrary.appendingPathComponent("Caches", isDirectory: true)
    for cache in immediateDirectories(in: libraryCaches)
    where cache.lastPathComponent != "com.apple.iconservices.store" {
      paths.append(
        (
          cache,
          "系統層快取 · \(friendlyIdentifier(cache.lastPathComponent))",
          "位於 /Library/Caches；需要由 macOS、對應 App 或安全模式管理，只提供檢視。",
          "直接清除可能使所有使用者共用的服務重新下載、重建或暫時失效。"
        ))
    }

    let systemAppSupport = localLibrary.appendingPathComponent(
      "Application Support", isDirectory: true)
    for app in immediateDirectories(in: systemAppSupport) {
      for marker in ["cache", "Cache", "Caches"] {
        let cache = app.appendingPathComponent(marker, isDirectory: true)
        if safeDirectoryExists(cache) {
          paths.append(
            (
              cache,
              "\(friendlyIdentifier(app.lastPathComponent)) 系統層 cache",
              "位於 /Library/Application Support，由廠商服務管理；只提供檢視。",
              "直接刪除可能使服務重新初始化、下載或失去狀態。"
            ))
        }
      }
    }

    let existing = paths.filter { safeDirectoryExists($0.0) }
    let sizes = try allocatedSizes(for: existing.map(\.0))
    for item in existing {
      candidates.append(
        CleanupCandidate(
          ruleID: .systemManagedReview,
          scope: .systemManagedReview,
          tier: .ultraAggressive,
          category: .systemManagedReview,
          action: .reviewOnly,
          path: item.0.path,
          displayName: item.1,
          bytes: sizes[item.0.path] ?? 0,
          risk: .reviewOnly,
          reason: item.2,
          impact: item.3,
          recovery: "優先使用 App 自己的清理介面、安全模式或 macOS 支援流程。"
        ))
    }

    if let snapshots = try? ProcessRunner.run(
      "/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 30), snapshots.status == 0
    {
      for line in snapshots.stdoutString.split(separator: "\n") {
        let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("com.apple.TimeMachine.") else { continue }
        candidates.append(
          CleanupCandidate(
            ruleID: .systemManagedReview,
            scope: .systemManagedReview,
            tier: .ultraAggressive,
            category: .systemManagedReview,
            action: .reviewOnly,
            path: "snapshot:\(value)",
            displayName: "Time Machine 本機快照",
            bytes: 0,
            risk: .reviewOnly,
            reason: value,
            impact: "快照提供本機還原能力；其空間由 macOS 視為可用並在需要時自動回收。",
            recovery: "不要把它當成一般垃圾；需時由 Time Machine 設定管理。"
          ))
      }
    }
    return candidates
  }

  // MARK: - Execution

  private func moveContentsToTrash(_ candidate: CleanupCandidate) throws -> CleanupLog.Entry {
    let source = try validatedSource(for: candidate)
    let children = try fileManager.contentsOfDirectory(
      at: source,
      includingPropertiesForKeys: [.isSymbolicLinkKey],
      options: [.skipsSubdirectoryDescendants]
    )
    var moved: [String] = []
    var failures: [String] = []
    var notes: [String] = []
    var trashItemPaths: [String] = []
    var receipts: [FinderVisibleTrashReceipt] = []

    for child in children {
      do {
        let receipt = try FinderVisibleTrash.recycle(
          child,
          displayLabel: child.lastPathComponent,
          fileManager: fileManager
        )
        moved.append(child.path)
        trashItemPaths.append(receipt.destinationPath)
        receipts.append(receipt)
        notes.append(
          "Finder 可見垃圾桶：\(receipt.visibleName) → \(receipt.destinationPath)；清空 Finder 垃圾桶前仍占用來源卷宗空間。"
        )
      } catch {
        failures.append("\(child.path): \(error.localizedDescription)")
      }
    }
    return logEntry(
      candidate,
      mode: .moveToTrash,
      moved: moved,
      failures: failures,
      notes: notes,
      trashItemPaths: trashItemPaths,
      finderVisibleTrashItems: receipts,
      spaceReleaseSemantics: "pending_finder_trash_empty",
      removalMethod: "nsworkspace_recycle_finder_visible_verified"
    )
  }

  private func moveItemToTrash(_ candidate: CleanupCandidate) throws -> CleanupLog.Entry {
    let source = try validatedSource(for: candidate)
    var moved: [String] = []
    var failures: [String] = []
    var notes: [String] = []
    var trashItemPaths: [String] = []
    var receipts: [FinderVisibleTrashReceipt] = []
    do {
      let receipt = try FinderVisibleTrash.recycle(
        source,
        displayLabel: candidate.displayName,
        fileManager: fileManager
      )
      moved.append(source.path)
      trashItemPaths.append(receipt.destinationPath)
      receipts.append(receipt)
      notes.append(
        "Finder 可見垃圾桶：\(receipt.visibleName) → \(receipt.destinationPath)；清空 Finder 垃圾桶前仍占用來源卷宗空間。"
      )
    } catch {
      failures.append("\(source.path): \(error.localizedDescription)")
    }
    return logEntry(
      candidate,
      mode: .moveToTrash,
      moved: moved,
      failures: failures,
      notes: notes,
      trashItemPaths: trashItemPaths,
      finderVisibleTrashItems: receipts,
      spaceReleaseSemantics: "pending_finder_trash_empty",
      removalMethod: "nsworkspace_recycle_finder_visible_verified"
    )
  }

  private func moveMatchedItemsToTrash(
    _ candidate: CleanupCandidate
  ) throws -> CleanupLog.Entry {
    guard let rootPath = candidate.cleanupRootPath, !candidate.matchedPaths.isEmpty else {
      throw CleanupValidationError.rejected(candidate.path)
    }

    let folderEngine = FolderCleanupEngine(fileManager: fileManager, homeURL: home)
    var moved: [String] = []
    var recreated: [String] = []
    var failures: [String] = []
    var notes: [String] = []
    var trashItemPaths: [String] = []
    var receipts: [FinderVisibleTrashReceipt] = []

    for path in candidate.matchedPaths {
      do {
        let source = try folderEngine.validateMatchedPath(
          path,
          rule: candidate.ruleID,
          rootPath: rootPath
        )
        let originalIdentity = itemIdentity(at: source)
        let receipt = try FinderVisibleTrash.recycle(
          source,
          displayLabel: candidate.displayName,
          fileManager: fileManager
        )
        moved.append(source.path)
        trashItemPaths.append(receipt.destinationPath)
        receipts.append(receipt)
        notes.append(
          "Finder 可見垃圾桶：\(receipt.visibleName) → \(receipt.destinationPath)；清空 Finder 垃圾桶前仍占用來源卷宗空間。"
        )

        if receipt.sourcePathRecreated {
          recreated.append(source.path)
          notes.append(
            "舊項目已進入 Finder 可見垃圾桶，但原路徑已立即出現不同檔案系統身分的新項目：\(source.path)"
          )
        }

        if candidate.supportsExternalVolumeDirectDeletion {
          Thread.sleep(forTimeInterval: 0.20)
          if fileManager.fileExists(atPath: source.path) {
            let currentIdentity = itemIdentity(at: source)
            if originalIdentity != nil, currentIdentity != nil, originalIdentity != currentIdentity
            {
              if !recreated.contains(source.path) { recreated.append(source.path) }
              notes.append(
                "舊項目已進入 Finder 可見垃圾桶，但 macOS 已用不同 inode 重新建立同名路徑：\(source.path)"
              )
            } else {
              failures.append(
                "\(source.path): Finder 垃圾桶操作後原路徑仍是相同身分，未把它當成成功。"
              )
            }
          }
        }
      } catch {
        failures.append("\(path): \(error.localizedDescription)")
      }
    }
    return logEntry(
      candidate,
      mode: .moveToTrash,
      moved: moved,
      recreated: recreated,
      failures: failures,
      notes: notes,
      trashItemPaths: trashItemPaths,
      finderVisibleTrashItems: receipts,
      spaceReleaseSemantics: "pending_finder_trash_empty",
      removalMethod: "nsworkspace_recycle_finder_visible_verified"
    )
  }

  private func directlyDelete(
    _ candidate: CleanupCandidate,
    targetCapabilities: CleanupTargetCapabilities
  ) throws -> CleanupLog.Entry {
    switch candidate.action {
    case .moveContentsToTrash:
      return try directlyDeleteContents(candidate, targetCapabilities: targetCapabilities)
    case .moveItemToTrash:
      return try directlyDeleteItem(candidate, targetCapabilities: targetCapabilities)
    case .moveMatchedItemsToTrash, .permanentDeleteMatchedItems:
      if candidate.ruleID == .trashBinContents {
        return try directlyDeleteTrashBinItems(candidate)
      }
      if candidate.supportsExternalVolumeDirectDeletion {
        if targetCapabilities.isRemote,
          candidate.ruleID == .folderSpotlightMetadata
            || candidate.ruleID == .folderFSEventsMetadata
        {
          return try directlyDeleteMatchedItems(
            candidate,
            targetCapabilities: targetCapabilities
          )
        }
        return try directlyDeleteExternalVolumeCandidate(candidate)
      }
      return try directlyDeleteMatchedItems(candidate, targetCapabilities: targetCapabilities)
    case .managedCommand:
      return try runManagedCommand(candidate)
    case .reviewOnly:
      throw CleanupValidationError.rejected("僅檢視項目不可刪除：\(candidate.displayName)")
    }
  }

  private func directlyDeleteContents(
    _ candidate: CleanupCandidate,
    targetCapabilities: CleanupTargetCapabilities
  ) throws -> CleanupLog.Entry {
    let source = try validatedSource(for: candidate)
    let children = try fileManager.contentsOfDirectory(
      at: source,
      includingPropertiesForKeys: [.isSymbolicLinkKey],
      options: [.skipsSubdirectoryDescendants]
    )
    var deleted: [String] = []
    var failures: [String] = []
    for child in children {
      do {
        let validated = try validatedDirectChild(child, of: source)
        try fileManager.removeItem(at: validated)
        guard !fileManager.fileExists(atPath: validated.path) else {
          throw CleanupValidationError.rejected(
            "removeItem 回傳完成，但項目仍存在：\(validated.path)"
          )
        }
        deleted.append(validated.path)
      } catch {
        failures.append("\(child.path): \(error.localizedDescription)")
      }
    }
    return logEntry(
      candidate,
      mode: .forceDelete,
      moved: [],
      permanentlyDeleted: deleted,
      failures: failures,
      notes: [directDeletionNote(for: targetCapabilities)],
      spaceReleaseSemantics: directDeletionSpaceSemantics(for: targetCapabilities),
      removalMethod: targetCapabilities.isRemote
        ? "filemanager_remote_remove_direct_children" : "filemanager_remove_direct_children"
    )
  }

  private func directlyDeleteItem(
    _ candidate: CleanupCandidate,
    targetCapabilities: CleanupTargetCapabilities
  ) throws -> CleanupLog.Entry {
    let source = try validatedSource(for: candidate)
    try fileManager.removeItem(at: source)
    guard !fileManager.fileExists(atPath: source.path) else {
      throw CleanupValidationError.rejected(
        "removeItem 回傳完成，但項目仍存在：\(source.path)"
      )
    }
    return logEntry(
      candidate,
      mode: .forceDelete,
      moved: [],
      permanentlyDeleted: [source.path],
      failures: [],
      notes: [directDeletionNote(for: targetCapabilities)],
      spaceReleaseSemantics: directDeletionSpaceSemantics(for: targetCapabilities),
      removalMethod: targetCapabilities.isRemote
        ? "filemanager_remote_remove_exact_item" : "filemanager_remove_exact_item"
    )
  }

  private func directlyDeleteMatchedItems(
    _ candidate: CleanupCandidate,
    targetCapabilities: CleanupTargetCapabilities
  ) throws -> CleanupLog.Entry {
    guard let rootPath = candidate.cleanupRootPath, !candidate.matchedPaths.isEmpty else {
      throw CleanupValidationError.rejected(candidate.path)
    }
    let folderEngine = FolderCleanupEngine(fileManager: fileManager, homeURL: home)
    var deleted: [String] = []
    var failures: [String] = []

    for path in candidate.matchedPaths {
      do {
        let source = try folderEngine.validateMatchedPath(
          path,
          rule: candidate.ruleID,
          rootPath: rootPath
        )
        try fileManager.removeItem(at: source)
        guard !fileManager.fileExists(atPath: source.path) else {
          throw CleanupValidationError.rejected(
            "removeItem 回傳完成，但項目仍存在：\(source.path)"
          )
        }
        deleted.append(source.path)
      } catch {
        failures.append("\(path): \(error.localizedDescription)")
      }
    }

    return logEntry(
      candidate,
      mode: .forceDelete,
      moved: [],
      permanentlyDeleted: deleted,
      failures: failures,
      notes: [
        "每個匹配路徑都在刪除前重新驗證。" + directDeletionNote(for: targetCapabilities)
      ],
      spaceReleaseSemantics: directDeletionSpaceSemantics(for: targetCapabilities),
      removalMethod: targetCapabilities.isRemote
        ? "filemanager_remote_remove_validated_matches" : "filemanager_remove_validated_matches"
    )
  }

  private func directlyDeleteTrashBinItems(
    _ candidate: CleanupCandidate
  ) throws -> CleanupLog.Entry {
    guard candidate.ruleID == .trashBinContents,
      candidate.scope == .trashBins,
      candidate.category == .trashBins,
      candidate.action == .permanentDeleteMatchedItems,
      let rootPath = candidate.cleanupRootPath,
      rootPath == candidate.path,
      !candidate.matchedPaths.isEmpty
    else {
      throw CleanupValidationError.rejected(candidate.path)
    }

    let root = try validatedTrashBinRoot(URL(fileURLWithPath: rootPath, isDirectory: true))
    var deleted: [String] = []
    var failures: [String] = []
    var notes: [String] = []

    for path in candidate.matchedPaths {
      do {
        let liveRoot = try validatedTrashBinRoot(root)
        guard liveRoot.path == root.path else {
          throw CleanupValidationError.rejected(
            "廢紙簍根目錄在執行期間發生變更：\(root.path)"
          )
        }
        let source = try validatedTrashBinChild(path, root: liveRoot)
        guard fileSystemObjectExists(at: source) else {
          notes.append("\(source.path)：執行前已不存在，視為已由 Finder 或其他流程處理。")
          continue
        }
        try fileManager.removeItem(at: source)
        guard !fileSystemObjectExists(at: source) else {
          throw CleanupValidationError.rejected(
            "removeItem 回傳完成，但廢紙簍項目仍存在：\(source.path)"
          )
        }
        deleted.append(source.path)
      } catch CleanupValidationError.missing(let path) {
        notes.append("\(path)：執行前已不存在，視為已由 Finder 或其他流程處理。")
      } catch {
        failures.append("\(path): \(error.localizedDescription)")
      }
    }

    return logEntry(
      candidate,
      mode: .forceDelete,
      moved: [],
      permanentlyDeleted: deleted,
      failures: failures,
      notes: [
        "只永久移除掃描時列出的目前使用者廢紙簍直接子項；廢紙簍根目錄本身、其他 UID、NAS #recycle 與整棵 .Trashes 均未刪除。"
      ] + notes,
      spaceReleaseSemantics: "immediate_current_user_trash_empty",
      removalMethod: "filemanager_remove_validated_current_user_trash_matches"
    )
  }

  private func directDeletionNote(for capabilities: CleanupTargetCapabilities) -> String {
    if capabilities.isRemote {
      return
        "直接刪除由 FileManager.removeItem 對遠端掛載送出，不經 Finder 垃圾桶。NAS／伺服器若啟用自己的 recycle bin、snapshot 或版本保護，實際保留與空間釋放由伺服器端政策決定。"
    }
    return "直接徹底刪除由 FileManager.removeItem 執行；沒有移入垃圾桶或建立隱藏暫存。"
  }

  private func directDeletionSpaceSemantics(
    for capabilities: CleanupTargetCapabilities
  ) -> String {
    capabilities.isRemote
      ? "client_direct_delete_server_retention_unknown"
      : "immediate_direct_delete"
  }

  private func directlyDeleteExternalVolumeCandidate(
    _ candidate: CleanupCandidate
  ) throws -> CleanupLog.Entry {
    let folderEngine = FolderCleanupEngine(fileManager: fileManager, homeURL: home)
    let plans = try ExternalVolumeCleanupExecutor.makePlans(
      for: [candidate],
      folderEngine: folderEngine,
      fileManager: fileManager
    )
    let outcomes = try ExternalVolumeCleanupExecutor.execute(
      plans,
      fileManager: fileManager
    )

    var deleted: [String] = []
    var recreated: [String] = []
    var failures: [String] = []
    var notes: [String] = []
    var methods: [String] = []
    var errorDomain: String?
    var errorCode: Int?

    for outcome in outcomes {
      if outcome.sourceRemoved { deleted.append(outcome.plan.sourcePath) }
      deleted.append(contentsOf: outcome.purgedTrashPaths)
      if !outcome.method.isEmpty { methods.append(outcome.method) }
      if let value = outcome.errorDomain { errorDomain = value }
      if let value = outcome.errorCode { errorCode = value }

      switch outcome.kind {
      case .deleted:
        notes.append(outcome.detail)
      case .recreated:
        recreated.append(outcome.plan.sourcePath)
        notes.append(outcome.detail)
      case .partial:
        failures.append("\(outcome.plan.sourcePath)：只完成一部分（\(outcome.detail)）。")
      case .missing:
        notes.append("\(outcome.plan.sourcePath)：執行前已不存在。")
      case .rejected:
        failures.append("\(outcome.plan.sourcePath)：安全重驗證拒絕（\(outcome.detail)）。")
      case .failed:
        failures.append("\(outcome.plan.sourcePath)：直接徹底刪除失敗（\(outcome.detail)）。")
      }
    }

    return CleanupLog.Entry(
      ruleID: candidate.ruleID.rawValue,
      sourcePath: candidate.path,
      action: CleanupExecutionMode.forceDelete.title,
      movedItems: [],
      permanentlyDeletedItems: Array(Set(deleted)).sorted(),
      recreatedItems: Array(Set(recreated)).sorted(),
      failures: failures,
      notes: notes,
      estimatedBytes: candidate.bytes,
      command: nil,
      commandExitStatus: nil,
      commandStandardOutput: nil,
      commandStandardError: nil,
      trashItemPaths: nil,
      finderVisibleTrashItems: nil,
      spaceReleaseSemantics: "immediate_direct_delete",
      removalMethod: Array(Set(methods)).sorted().joined(separator: "+"),
      errorDomain: errorDomain,
      errorCode: errorCode
    )
  }

  private func validatedDirectChild(_ child: URL, of parent: URL) throws -> URL {
    let source = child.standardizedFileURL
    guard
      source.deletingLastPathComponent().standardizedFileURL.path
        == parent.standardizedFileURL.path,
      fileManager.fileExists(atPath: source.path),
      !source.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw CleanupValidationError.rejected(source.path)
    }
    let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink != true, !isSymbolicLink(at: source),
      source.resolvingSymlinksInPath().standardizedFileURL.path == source.path
    else {
      throw CleanupValidationError.rejected("拒絕直接刪除符號連結或跳脫路徑：\(source.path)")
    }
    return source
  }

  private func validatedTrashBinRoot(_ candidateRoot: URL) throws -> URL {
    let root = candidateRoot.standardizedFileURL
    guard fileSystemObjectExists(at: root) else {
      throw CleanupValidationError.missing(root.path)
    }
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true,
      !isSymbolicLink(at: root),
      root.resolvingSymlinksInPath().standardizedFileURL.path == root.path
    else {
      throw CleanupValidationError.rejected(root.path)
    }

    let expectedUserTrash = home.appendingPathComponent(".Trash", isDirectory: true)
      .standardizedFileURL
    if root.path == expectedUserTrash.path {
      return root
    }

    guard isValidExternalTrashRoot(root) else {
      throw CleanupValidationError.rejected(root.path)
    }
    let trashes = root.deletingLastPathComponent().standardizedFileURL
    let volume = trashes.deletingLastPathComponent().standardizedFileURL
    for directory in [volume, trashes] {
      let directoryValues = try directory.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      )
      guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true,
        !isSymbolicLink(at: directory),
        directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.path
      else {
        throw CleanupValidationError.rejected(directory.path)
      }
    }

    _ = try ExternalVolumeCleanupExecutor.validateExternalVolumeRoot(
      volume.path,
      fileManager: fileManager,
      volumesRootURL: volumesRoot
    )
    return root
  }

  private func validatedTrashBinChild(_ path: String, root: URL) throws -> URL {
    let source = URL(fileURLWithPath: path).standardizedFileURL
    guard source.path != root.path,
      source.deletingLastPathComponent().standardizedFileURL.path == root.path,
      !source.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw CleanupValidationError.rejected(source.path)
    }
    guard fileSystemObjectExists(at: source) else {
      throw CleanupValidationError.missing(source.path)
    }

    guard !isSymbolicLink(at: source) else {
      throw CleanupValidationError.rejected("拒絕永久刪除廢紙簍中的符號連結：\(source.path)")
    }
    let attributes = try fileManager.attributesOfItem(atPath: source.path)
    let type = attributes[.type] as? FileAttributeType
    guard type == .typeDirectory || type == .typeRegular else {
      throw CleanupValidationError.rejected(source.path)
    }
    let rootAttributes = try fileManager.attributesOfItem(atPath: root.path)
    guard let sourceDevice = numericAttribute(attributes[.systemNumber]),
      let rootDevice = numericAttribute(rootAttributes[.systemNumber]),
      sourceDevice == rootDevice
    else {
      throw CleanupValidationError.rejected("拒絕跨越廢紙簍所在裝置的項目：\(source.path)")
    }
    let resolved = source.resolvingSymlinksInPath().standardizedFileURL
    guard resolved.deletingLastPathComponent().standardizedFileURL.path == root.path else {
      throw CleanupValidationError.rejected("拒絕會跳脫廢紙簍根目錄的項目：\(source.path)")
    }
    return source
  }

  private func isValidExternalTrashRoot(_ root: URL) -> Bool {
    let candidate = root.standardizedFileURL
    guard candidate.lastPathComponent == String(currentUserID) else { return false }
    let trashes = candidate.deletingLastPathComponent().standardizedFileURL
    guard trashes.lastPathComponent == ".Trashes" else { return false }
    let volume = trashes.deletingLastPathComponent().standardizedFileURL
    return volume.deletingLastPathComponent().standardizedFileURL.path == volumesRoot.path
      && volume.path != volumesRoot.path
  }

  private struct ItemIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
  }

  private func itemIdentity(at url: URL) -> ItemIdentity? {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let device = numericAttribute(attributes[.systemNumber]),
      let inode = numericAttribute(attributes[.systemFileNumber])
    else { return nil }
    return ItemIdentity(device: device, inode: inode)
  }

  private func numericAttribute(_ value: Any?) -> UInt64? {
    if let number = value as? NSNumber { return number.uint64Value }
    if let value = value as? UInt64 { return value }
    if let value = value as? UInt { return UInt64(value) }
    if let value = value as? Int, value >= 0 { return UInt64(value) }
    return nil
  }

  private func runManagedCommand(_ candidate: CleanupCandidate) throws -> CleanupLog.Entry {
    guard let command = candidate.managedCommand else {
      throw CleanupValidationError.rejected("缺少受管理命令：\(candidate.displayName)")
    }
    try validateManagedCommand(candidate.ruleID, command: command)
    let result = try ProcessRunner.run(
      command.executable,
      command.arguments,
      timeout: command.timeoutSeconds
    )
    let failures =
      result.status == 0
      ? []
      : ["命令以狀態 \(result.status) 結束：\(result.stderrString)"]
    return CleanupLog.Entry(
      ruleID: candidate.ruleID.rawValue,
      sourcePath: candidate.path,
      action: CleanupExecutionMode.forceDelete.title,
      movedItems: [],
      permanentlyDeletedItems: [],
      recreatedItems: [],
      failures: failures,
      notes: ["受管理命令屬於直接清理，不會建立垃圾桶項目。"],
      estimatedBytes: candidate.bytes,
      command: command.displayCommand,
      commandExitStatus: result.status,
      commandStandardOutput: limitedLogText(result.stdoutString),
      commandStandardError: limitedLogText(result.stderrString),
      trashItemPaths: nil,
      finderVisibleTrashItems: nil,
      spaceReleaseSemantics: "managed_direct_cleanup",
      removalMethod: "managed_command_direct_delete"
    )
  }

  private func logEntry(
    _ candidate: CleanupCandidate,
    mode: CleanupExecutionMode,
    moved: [String],
    permanentlyDeleted: [String] = [],
    recreated: [String] = [],
    failures: [String],
    notes: [String] = [],
    trashItemPaths: [String]? = nil,
    finderVisibleTrashItems: [FinderVisibleTrashReceipt]? = nil,
    spaceReleaseSemantics: String? = nil,
    removalMethod: String? = nil
  ) -> CleanupLog.Entry {
    CleanupLog.Entry(
      ruleID: candidate.ruleID.rawValue,
      sourcePath: candidate.path,
      action: mode.title,
      movedItems: moved,
      permanentlyDeletedItems: permanentlyDeleted,
      recreatedItems: recreated,
      failures: failures,
      notes: notes,
      estimatedBytes: candidate.bytes,
      command: nil,
      commandExitStatus: nil,
      commandStandardOutput: nil,
      commandStandardError: nil,
      trashItemPaths: trashItemPaths,
      finderVisibleTrashItems: finderVisibleTrashItems,
      spaceReleaseSemantics: spaceReleaseSemantics,
      removalMethod: removalMethod
    )
  }

  private func failedLogEntry(
    _ candidate: CleanupCandidate,
    mode: CleanupExecutionMode,
    error: Error
  ) -> CleanupLog.Entry {
    CleanupLog.Entry(
      ruleID: candidate.ruleID.rawValue,
      sourcePath: candidate.path,
      action: mode.title,
      movedItems: [],
      permanentlyDeletedItems: [],
      recreatedItems: [],
      failures: [error.localizedDescription],
      notes: [],
      estimatedBytes: candidate.bytes,
      command: candidate.managedCommand?.displayCommand,
      commandExitStatus: nil,
      commandStandardOutput: nil,
      commandStandardError: nil,
      trashItemPaths: nil,
      finderVisibleTrashItems: nil,
      spaceReleaseSemantics: mode == .moveToTrash
        ? "finder_visible_trash_failed" : "direct_delete_failed",
      removalMethod: nil
    )
  }

  private func validatedSource(for candidate: CleanupCandidate) throws -> URL {
    guard candidate.action == .moveContentsToTrash || candidate.action == .moveItemToTrash else {
      throw CleanupValidationError.rejected(candidate.path)
    }
    let source = URL(fileURLWithPath: candidate.path).standardizedFileURL
    guard fileManager.fileExists(atPath: source.path) else {
      throw CleanupValidationError.missing(source.path)
    }
    let values = try source.resourceValues(
      forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
    )
    guard values.isSymbolicLink != true else {
      throw CleanupValidationError.rejected(source.path)
    }
    if candidate.action == .moveContentsToTrash {
      guard values.isDirectory == true else {
        throw CleanupValidationError.rejected(source.path)
      }
    } else {
      guard values.isDirectory == true || values.isRegularFile == true else {
        throw CleanupValidationError.rejected(source.path)
      }
    }
    let resolved = source.resolvingSymlinksInPath().standardizedFileURL
    try validateRulePath(candidate.ruleID, source: resolved)
    return source
  }

  private func validateRulePath(_ rule: CleanupRuleID, source: URL) throws {
    let userCacheRoot = home.appendingPathComponent("Library/Caches", isDirectory: true)
      .standardizedFileURL
    let containersRoot = home.appendingPathComponent("Library/Containers", isDirectory: true)
      .standardizedFileURL
    let groupsRoot = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
      .standardizedFileURL
    let applicationSupport = home.appendingPathComponent(
      "Library/Application Support", isDirectory: true
    ).standardizedFileURL
    let logsRoot = home.appendingPathComponent("Library/Logs", isDirectory: true)
      .standardizedFileURL
    let downloadsRoot = home.appendingPathComponent("Downloads", isDirectory: true)
      .standardizedFileURL
    let preferencesRoot = home.appendingPathComponent("Library/Preferences", isDirectory: true)
      .standardizedFileURL

    switch rule {
    case .standardUserCache:
      guard source.deletingLastPathComponent().path == userCacheRoot.path,
        !SystemJunkKnowledge.shouldExcludeStandardUserCache(
          directoryName: source.lastPathComponent
        ),
        !isCloudOrSyncPath(source)
      else { throw CleanupValidationError.rejected(source.path) }
    case .sandboxCache:
      guard isDescendant(source, of: containersRoot),
        source.path.hasSuffix("/Data/Library/Caches"),
        !isCloudOrSyncPath(source)
      else { throw CleanupValidationError.rejected(source.path) }
    case .groupContainerCache:
      guard isDescendant(source, of: groupsRoot),
        source.path.hasSuffix("/Library/Caches")
          || source.path.hasSuffix("/Data/Library/Caches"),
        !isCloudOrSyncPath(source)
      else { throw CleanupValidationError.rejected(source.path) }
    case .clipboardArchive:
      guard source.path == clipboardArchiveURL.standardizedFileURL.path else {
        throw CleanupValidationError.rejected(source.path)
      }
    case .applicationRenderCache, .applicationOfflineCache:
      guard isDescendant(source, of: applicationSupport),
        isAllowedApplicationCachePath(source, offline: rule == .applicationOfflineCache),
        !isCloudOrSyncPath(source)
      else { throw CleanupValidationError.rejected(source.path) }
    case .xcodeDerivedData:
      try requireExact(
        source,
        home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true))
    case .xcodePreviewsCache:
      try requireExact(
        source,
        home.appendingPathComponent("Library/Developer/Xcode/UserData/Previews", isDirectory: true))
    case .coreSimulatorCache:
      try requireExact(
        source,
        home.appendingPathComponent("Library/Developer/CoreSimulator/Caches", isDirectory: true))
    case .xcodeDeviceSupport:
      let root = home.appendingPathComponent(
        "Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true)
      guard isDirectChild(source, of: root) else {
        throw CleanupValidationError.rejected(source.path)
      }
    case .developerToolCacheDirectory:
      guard isAllowedDeveloperToolCachePath(source) else {
        throw CleanupValidationError.rejected(source.path)
      }
    case .packageCacheDirectory:
      guard isAllowedPackageCachePath(source) else {
        throw CleanupValidationError.rejected(source.path)
      }
    case .incompleteDownload, .staleInstallerPackage, .staleDiskImage:
      guard isDirectChild(source, of: downloadsRoot),
        let kind = downloadResidueKind(at: source)
      else { throw CleanupValidationError.rejected(source.path) }
      switch (rule, kind) {
      case (.incompleteDownload, .incompleteDownload),
        (.staleInstallerPackage, .staleInstaller),
        (.staleDiskImage, .staleDiskImage):
        break
      default:
        throw CleanupValidationError.rejected(source.path)
      }
    case .appLeftoverEntry:
      guard let (kind, _) = leftoverRoot(for: source) else {
        throw CleanupValidationError.rejected(source.path)
      }
      let installed = installedApplicationBundleIdentifiers()
      guard !installed.isEmpty,
        SystemJunkKnowledge.isOrphanedAppEntry(
          entryName: source.lastPathComponent,
          rootKind: kind,
          installedBundleIdentifiers: installed
        )
      else { throw CleanupValidationError.rejected(source.path) }
    case .corruptPreferencePlist:
      guard isDirectChild(source, of: preferencesRoot),
        SystemJunkKnowledge.preferenceDomain(fileName: source.lastPathComponent) != nil,
        let data = try? Data(contentsOf: source, options: [.mappedIfSafe]),
        SystemJunkKnowledge.plistIsCorrupt(data: data)
      else { throw CleanupValidationError.rejected(source.path) }
    case .userLogDirectory:
      guard isDirectChild(source, of: logsRoot) else {
        throw CleanupValidationError.rejected(source.path)
      }
    case .diagnosticReports:
      let crashReporter = applicationSupport.appendingPathComponent(
        "CrashReporter", isDirectory: true)
      guard
        isDirectChild(source, of: logsRoot)
          || source.path == crashReporter.standardizedFileURL.path
      else { throw CleanupValidationError.rejected(source.path) }
    case .mobileDeviceBackup:
      let root = applicationSupport.appendingPathComponent("MobileSync/Backup", isDirectory: true)
      guard isDirectChild(source, of: root) else {
        throw CleanupValidationError.rejected(source.path)
      }
    case .xcodeArchive:
      let root = home.appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true)
      guard isDescendant(source, of: root), source.pathExtension.lowercased() == "xcarchive"
      else { throw CleanupValidationError.rejected(source.path) }
    case .mailDownloads:
      try requireExact(
        source,
        home.appendingPathComponent(
          "Library/Containers/com.apple.mail/Data/Library/Mail Downloads", isDirectory: true))
    case .homebrewCleanup, .condaCleanup, .trashBinContents, .systemManagedReview,
      .folderDSStore, .folderDSStoreAppleDoubleSidecar,
      .folderWindowsMetadata, .folderWindowsAppleDoubleSidecar,
      .folderMacOSXDirectory, .folderOrphanedAppleDoubleSidecar,
      .folderAppleDoubleSidecar, .folderSensitiveAppleDoubleSidecar,
      .folderUnrecognizedDotUnderscore, .folderSpotlightMetadata,
      .folderFSEventsMetadata, .folderTrashMetadata,
      .folderLegacySpotlightTrashResidue, .folderLegacyFSEventsTrashResidue,
      .folderMacVolumeMarkerMetadata, .folderLegacyAppleMetadata:
      throw CleanupValidationError.rejected(source.path)
    }

    let blockedTokens = [
      "/Documents/", "/Desktop/", "/Pictures/", "/Movies/", "/Music/",
      "/.Spotlight-V100", "/.DocumentRevisions-V100", "/.fseventsd",
      "/private/var/db", "/System/Volumes/", "/CloudKit/", "/Mobile Documents/",
    ]
    guard !blockedTokens.contains(where: { source.path.contains($0) }) else {
      throw CleanupValidationError.rejected(source.path)
    }
  }

  private func validateManagedCommand(
    _ rule: CleanupRuleID,
    command: ManagedCleanupCommand
  ) throws {
    let executable = URL(fileURLWithPath: command.executable).standardizedFileURL
    guard fileManager.isExecutableFile(atPath: executable.path) else {
      throw CleanupValidationError.rejected(command.executable)
    }
    switch rule {
    case .homebrewCleanup:
      guard executable.lastPathComponent == "brew",
        command.arguments == ["cleanup", "--prune=all"]
      else { throw CleanupValidationError.rejected(command.displayCommand) }
    case .condaCleanup:
      guard executable.lastPathComponent == "conda",
        command.arguments == ["clean", "--all", "--yes", "--json"],
        !command.arguments.contains("--force-pkgs-dirs")
      else { throw CleanupValidationError.rejected(command.displayCommand) }
    default:
      throw CleanupValidationError.rejected(command.displayCommand)
    }
  }

  // MARK: - Normalization and policy

  private func normalizedCandidates(
    _ raw: [CleanupCandidate],
    configuration: CleanupScanConfiguration
  ) -> [CleanupCandidate] {
    var candidates = raw.filter { candidate in
      guard configuration.includes(tier: candidate.tier, scope: candidate.scope) else {
        return false
      }
      if candidate.action == .reviewOnly {
        return candidate.bytes > 0 || candidate.path.hasPrefix("snapshot:")
      }
      if candidate.ruleID == .corruptPreferencePlist {
        return true
      }
      if candidate.ruleID == .trashBinContents {
        return !candidate.matchedPaths.isEmpty
      }
      return candidate.bytes >= configuration.minimumBytes && candidate.bytes > 0
    }

    let leftoverPaths = Set(
      candidates.filter { $0.ruleID == .appLeftoverEntry }.map(\.path)
    )
    candidates.removeAll { candidate in
      candidate.ruleID != .appLeftoverEntry && leftoverPaths.contains(candidate.path)
    }

    let managedPaths = Set(
      candidates.filter { $0.action == .managedCommand }.flatMap { candidate -> [String] in
        switch candidate.ruleID {
        case .homebrewCleanup:
          return [
            home.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true).path
          ]
        case .condaCleanup:
          return candidate.path.components(separatedBy: " · ")
        default: return []
        }
      })
    candidates.removeAll { candidate in
      candidate.action != .managedCommand && managedPaths.contains(candidate.path)
    }

    var byPath: [String: CleanupCandidate] = [:]
    for candidate in candidates {
      let key = "\(candidate.action.rawValue)|\(candidate.path)"
      if let existing = byPath[key] {
        if candidateSpecificity(candidate) > candidateSpecificity(existing) {
          byPath[key] = candidate
        }
      } else {
        byPath[key] = candidate
      }
    }
    return byPath.values.sorted {
      if $0.tier != $1.tier { return $0.tier < $1.tier }
      if $0.category.rawValue != $1.category.rawValue {
        return $0.category.rawValue < $1.category.rawValue
      }
      return $0.bytes > $1.bytes
    }
  }

  private func candidateSpecificity(_ candidate: CleanupCandidate) -> Int {
    switch candidate.ruleID {
    case .homebrewCleanup, .condaCleanup: return 100
    case .applicationOfflineCache: return 90
    case .developerToolCacheDirectory: return 88
    case .applicationRenderCache: return 80
    case .appLeftoverEntry: return 95
    case .corruptPreferencePlist: return 92
    case .trashBinContents: return 98
    case .incompleteDownload, .staleInstallerPackage, .staleDiskImage: return 85
    case .packageCacheDirectory: return 70
    case .diagnosticReports: return 65
    case .sandboxCache, .groupContainerCache: return 60
    case .standardUserCache: return 50
    case .folderDSStore, .folderDSStoreAppleDoubleSidecar,
      .folderWindowsMetadata, .folderWindowsAppleDoubleSidecar,
      .folderMacOSXDirectory, .folderOrphanedAppleDoubleSidecar,
      .folderAppleDoubleSidecar, .folderSensitiveAppleDoubleSidecar,
      .folderUnrecognizedDotUnderscore, .folderSpotlightMetadata,
      .folderFSEventsMetadata, .folderTrashMetadata,
      .folderLegacySpotlightTrashResidue, .folderLegacyFSEventsTrashResidue,
      .folderMacVolumeMarkerMetadata, .folderLegacyAppleMetadata:
      return 75
    default: return 55
    }
  }

  // MARK: - Path helpers

  private var clipboardArchiveURL: URL {
    home.appendingPathComponent(
      "Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/archives",
      isDirectory: true)
  }

  private var renderCacheMarkers: [String] {
    ["Cache", "Caches", "Code Cache", "GPUCache", "DawnCache", "ShaderCache", "GrShaderCache"]
  }

  private var normalizedRenderCacheMarkers: Set<String> {
    Set(renderCacheMarkers.map { $0.lowercased() })
  }

  private func isRenderCacheMarker(_ name: String) -> Bool {
    normalizedRenderCacheMarkers.contains(name.lowercased())
  }

  private func immediateDirectory(named expectedName: String, in directories: [URL]) -> URL? {
    directories.first {
      $0.lastPathComponent.caseInsensitiveCompare(expectedName) == .orderedSame
    }
  }

  private func applicationCacheBases(for appRoot: URL) -> [URL] {
    // Application Support is often vendor/app/profile (Google/Chrome/Default) or
    // app/Partitions/session. We inspect only two structural levels and then only
    // exact cache-marker names; we never recursively walk databases or user content.
    var bases = [appRoot]
    let firstLevel = immediateDirectories(in: appRoot)
    bases.append(contentsOf: firstLevel)

    for child in firstLevel {
      let name = child.lastPathComponent
      if ["Partitions", "Profiles"].contains(name) {
        bases.append(contentsOf: immediateDirectories(in: child))
        continue
      }

      for grandchild in immediateDirectories(in: child) {
        let grandchildName = grandchild.lastPathComponent
        if grandchildName == "Default" || grandchildName == "Guest Profile"
          || grandchildName == "System Profile" || grandchildName.hasPrefix("Profile ")
          || ["Partitions", "Profiles"].contains(grandchildName)
        {
          bases.append(grandchild)
          if ["Partitions", "Profiles"].contains(grandchildName) {
            bases.append(contentsOf: immediateDirectories(in: grandchild))
          }
        }
      }
    }
    return uniqueURLs(bases)
  }

  private func xcodeArchives(in root: URL) -> [URL] {
    guard safeDirectoryExists(root) else { return [] }
    var archives: [URL] = []
    for dateDirectory in immediateDirectories(in: root) {
      let children =
        ((try? fileManager.contentsOfDirectory(
          at: dateDirectory,
          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles])) ?? [])
      for child in children where child.pathExtension.lowercased() == "xcarchive" {
        if safeDirectoryExists(child) { archives.append(child) }
      }
    }
    return uniqueURLs(archives)
  }

  private func immediateDirectories(in root: URL) -> [URL] {
    guard safeDirectoryExists(root) else { return [] }
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
    return
      ((try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )) ?? []).filter { url in
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
          && !isSymbolicLink(at: url)
      }
  }

  private func immediateItems(in root: URL) -> [URL] {
    guard fileManager.fileExists(atPath: root.path) else { return [] }
    let keys: [URLResourceKey] = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      .contentModificationDateKey, .creationDateKey,
    ]
    let items =
      (try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: keys,
        options: [.skipsSubdirectoryDescendants]
      )) ?? []
    return items.filter { item in
      guard let values = try? item.resourceValues(forKeys: Set(keys)) else { return false }
      return values.isSymbolicLink != true && !isSymbolicLink(at: item)
        && (values.isDirectory == true || values.isRegularFile == true)
    }
  }

  private func downloadResidueKind(at url: URL) -> SystemJunkKnowledge.DownloadResidueKind? {
    guard
      let values = try? url.resourceValues(
        forKeys: [.contentModificationDateKey, .creationDateKey, .isSymbolicLinkKey]
      ), values.isSymbolicLink != true,
      let date = values.contentModificationDate ?? values.creationDate
    else { return nil }
    return SystemJunkKnowledge.downloadResidueKind(
      pathExtension: url.pathExtension,
      modificationDate: date
    )
  }

  private func installedApplicationBundleIdentifiers() -> Set<String> {
    let roots = [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
      URL(fileURLWithPath: "/System/Applications", isDirectory: true),
      URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
      home.appendingPathComponent("Applications", isDirectory: true),
    ]

    var identifiers = Set<String>()
    for root in roots where fileManager.fileExists(atPath: root.path) {
      for app in immediateItems(in: root) where app.pathExtension.lowercased() == "app" {
        let infoURL = app.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL, options: [.mappedIfSafe]),
          let object = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
          ) as? [String: Any],
          let identifier = object["CFBundleIdentifier"] as? String,
          !identifier.isEmpty
        else { continue }
        identifiers.insert(identifier)
      }
    }
    return identifiers
  }

  private func leftoverRoot(
    for source: URL
  ) -> (SystemJunkKnowledge.LeftoverRootKind, URL)? {
    for (kind, root) in SystemJunkKnowledge.leftoverRoots(home: home) {
      if isDirectChild(source, of: root), !isCloudOrSyncPath(source) {
        return (kind, root)
      }
    }
    return nil
  }

  private func fileSystemObjectExists(at url: URL) -> Bool {
    (try? fileManager.attributesOfItem(atPath: url.path)) != nil
  }

  private func isSymbolicLink(at url: URL) -> Bool {
    if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
      return true
    }
    if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let type = attributes[.type] as? FileAttributeType
    {
      return type == .typeSymbolicLink
    }
    return false
  }

  private func safeDirectoryExists(_ url: URL) -> Bool {
    guard fileManager.fileExists(atPath: url.path) else { return false }
    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else {
      return false
    }
    return values.isDirectory == true && values.isSymbolicLink != true
      && !isSymbolicLink(at: url)
  }

  private func allocatedSizes(for urls: [URL]) throws -> [String: Int64] {
    guard !urls.isEmpty else { return [:] }
    var output: [String: Int64] = [:]
    let batchSize = 80

    for start in stride(from: 0, to: urls.count, by: batchSize) {
      let end = min(start + batchSize, urls.count)
      let batch = Array(urls[start..<end])
      let result = try ProcessRunner.run("/usr/bin/du", ["-sk"] + batch.map(\.path), timeout: 240)
      for line in result.stdoutString.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let tab = line.firstIndex(of: "\t"), let kiB = Int64(line[..<tab]) else {
          continue
        }
        let path = String(line[line.index(after: tab)...])
        output[path] = kiB * 1024
      }
    }
    return output
  }

  private func firstExecutable(named name: String, knownPaths: [String]) -> String? {
    for path in knownPaths where fileManager.isExecutableFile(atPath: path) { return path }
    let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for directory in environmentPath.split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
        .appendingPathComponent(name).path
      if fileManager.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
  }

  private func parseApproximateBytes(_ output: String) -> Int64? {
    let pattern = #"(?i)(?:approximately|about)\s+([0-9]+(?:\.[0-9]+)?)\s*(KB|MB|GB|TB)"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.matches(
        in: output, range: NSRange(output.startIndex..., in: output)
      ).last,
      let valueRange = Range(match.range(at: 1), in: output),
      let unitRange = Range(match.range(at: 2), in: output),
      let value = Double(output[valueRange])
    else { return nil }
    let unit = output[unitRange].uppercased()
    let multiplier: Double
    switch unit {
    case "KB": multiplier = 1_000
    case "MB": multiplier = 1_000_000
    case "GB": multiplier = 1_000_000_000
    case "TB": multiplier = 1_000_000_000_000
    default: return nil
    }
    return Int64(value * multiplier)
  }

  private func isCloudOrSyncPath(_ url: URL) -> Bool {
    let lower = url.path.lowercased()
    let blocked = [
      "cloudkit", "icloud", "mobile documents", "clouddocs", "com.apple.bird",
      "group.com.apple.cloud", "protectedcloudstorage",
    ]
    return blocked.contains(where: lower.contains)
  }

  private func isAppleIdentifier(_ value: String) -> Bool {
    let lower = value.lowercased()
    return lower.hasPrefix("com.apple.") || lower.hasPrefix("group.com.apple.")
      || lower.hasPrefix("apple.")
  }

  private func friendlyIdentifier(_ value: String) -> String {
    let stripped =
      value
      .replacingOccurrences(of: "group.", with: "")
      .replacingOccurrences(of: "com.apple.", with: "Apple · ")
    return stripped.isEmpty ? value : stripped
  }

  private func containerIdentifier(forSandboxCache url: URL) -> String {
    var current = url
    for _ in 0..<3 { current.deleteLastPathComponent() }
    return current.lastPathComponent
  }

  private func groupContainerIdentifier(forCache url: URL) -> String {
    let marker = "/Library/Group Containers/"
    guard let range = url.path.range(of: marker) else { return url.lastPathComponent }
    let remainder = url.path[range.upperBound...]
    return String(remainder.split(separator: "/").first ?? Substring(url.lastPathComponent))
  }

  private func relativePath(_ url: URL, from root: URL) -> String {
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return url.path.hasPrefix(prefix)
      ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
  }

  private func uniqueURLs(_ urls: [URL]) -> [URL] {
    var seen = Set<String>()
    return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
  }

  private func isDescendant(_ source: URL, of root: URL) -> Bool {
    let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    return resolvedSource.hasPrefix(resolvedRoot + "/")
  }

  private func isDirectChild(_ source: URL, of root: URL) -> Bool {
    source.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent().path
      == root.resolvingSymlinksInPath().standardizedFileURL.path
  }

  private func requireExact(_ source: URL, _ expected: URL) throws {
    guard source.path == expected.standardizedFileURL.path else {
      throw CleanupValidationError.rejected(source.path)
    }
  }

  private func isAllowedApplicationCachePath(_ source: URL, offline: Bool) -> Bool {
    let applicationSupport = home.appendingPathComponent(
      "Library/Application Support", isDirectory: true
    ).standardizedFileURL
    guard isDescendant(source, of: applicationSupport) else { return false }

    let relative = relativePath(source, from: applicationSupport)
    guard let appComponent = relative.split(separator: "/").first else { return false }
    let appRoot = applicationSupport.appendingPathComponent(String(appComponent), isDirectory: true)
    guard safeDirectoryExists(appRoot) else { return false }
    let allowedBases = Set(applicationCacheBases(for: appRoot).map { $0.standardizedFileURL.path })

    if offline {
      guard source.lastPathComponent.caseInsensitiveCompare("CacheStorage") == .orderedSame else {
        return false
      }
      let parent = source.deletingLastPathComponent()
      if parent.lastPathComponent.caseInsensitiveCompare("Service Worker") == .orderedSame {
        return allowedBases.contains(parent.deletingLastPathComponent().standardizedFileURL.path)
      }
      let webStorage = parent.deletingLastPathComponent()
      return webStorage.lastPathComponent.caseInsensitiveCompare("WebStorage") == .orderedSame
        && allowedBases.contains(webStorage.deletingLastPathComponent().standardizedFileURL.path)
    }

    return isRenderCacheMarker(source.lastPathComponent)
      && allowedBases.contains(source.deletingLastPathComponent().standardizedFileURL.path)
  }

  private func limitedLogText(_ value: String, maximumUTF8Bytes: Int = 200_000) -> String {
    guard value.utf8.count > maximumUTF8Bytes else { return value }
    let prefix = value.utf8.prefix(maximumUTF8Bytes)
    return String(decoding: prefix, as: UTF8.self)
      + "\n…輸出超過 200 KB，操作紀錄已截斷。"
  }

  private func isAllowedDeveloperToolCachePath(_ source: URL) -> Bool {
    let allowed = Set(
      SystemJunkKnowledge.developerToolCacheURLs(home: home)
        .filter {
          !SystemJunkKnowledge.isForbiddenDeveloperUserData(
            relativePath: $0.0.relativePath
          )
        }
        .map { $0.1.standardizedFileURL.path }
    )
    return allowed.contains(source.path)
  }

  private func isAllowedPackageCachePath(_ source: URL) -> Bool {
    let allowed = Set(
      SystemJunkKnowledge.packageManagerCacheURLs(home: home)
        .map { $0.1.standardizedFileURL.path }
    )
    return allowed.contains(source.path)
  }
}

enum CleanupValidationError: LocalizedError {
  case rejected(String)
  case missing(String)

  var errorDescription: String? {
    switch self {
    case .rejected(let path): return "安全規則拒絕清理此路徑或命令：\(path)"
    case .missing(let path): return "候選已不存在，請重新掃描：\(path)"
    }
  }
}
