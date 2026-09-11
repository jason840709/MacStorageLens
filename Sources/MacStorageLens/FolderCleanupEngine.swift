import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

final class FolderCleanupEngine {
  typealias ProgressHandler = (CleanupScanProgress) -> Void

  private struct MatchGroup {
    var paths: [String] = []
    var pathSet: Set<String> = []
    var bytesByPath: [String: Int64] = [:]
    var bytes: Int64 = 0
  }

  private struct AppleDoubleTally {
    var finderCompanions = 0
    var windowsCompanions = 0
    var orphanedMetadataOnly = 0
    var pairedMetadataOnly = 0
    var sensitive = 0
    var unrecognized = 0

    var total: Int {
      finderCompanions + windowsCompanions + orphanedMetadataOnly
        + pairedMetadataOnly + sensitive + unrecognized
    }
  }

  private let fileManager: FileManager
  private let home: URL
  private let appleDoubleInspector: AppleDoubleInspector
  private let targetCapabilityResolver: (ScanTarget) -> CleanupTargetCapabilities

  init(
    fileManager: FileManager = .default,
    homeURL: URL? = nil,
    targetCapabilityResolver: @escaping (ScanTarget) -> CleanupTargetCapabilities =
      CleanupTargetCapabilityResolver.resolve
  ) {
    self.fileManager = fileManager
    home = (homeURL ?? fileManager.homeDirectoryForCurrentUser).standardizedFileURL
    appleDoubleInspector = AppleDoubleInspector(fileManager: fileManager)
    self.targetCapabilityResolver = targetCapabilityResolver
  }

  func scanCandidates(
    configuration: CleanupScanConfiguration,
    target: ScanTarget,
    progress: ProgressHandler? = nil
  ) throws -> CleanupScanResult {
    let startedAt = Date()
    let root = try validatedRoot(for: target)
    let targetCapabilities = targetCapabilityResolver(target)
    let prioritizesExternalAppleDouble =
      targetCapabilities.prioritizesExternalAppleDoubleCleanup
    var notices: [String] = []
    var groups: [CleanupRuleID: MatchGroup] = [:]
    var appleDoubleTally = AppleDoubleTally()
    var visited = 0
    var diagnostics = 0
    var skippedServerRecycleDirectories = 0

    // Traversal asks only for type/package metadata. Requesting three size keys
    // for every ordinary book, photo, or document on a FAT/exFAT card made the
    // cleanup candidate scan much more expensive than the actual rule matching.
    // Allocation sizes are fetched lazily only after a name matches a rule.
    let resourceKeys: [URLResourceKey] = [
      .isDirectoryKey,
      .isRegularFileKey,
      .isSymbolicLinkKey,
      .isPackageKey,
    ]

    progress?(
      CleanupScanProgress(
        message: "檢查一般位置的隱藏中繼資料",
        currentPath: root.path,
        currentStep: 0,
        totalSteps: 2
      ))

    appendLegacyHiddenTrashResiduesIfIncluded(
      root: root,
      target: target,
      configuration: configuration,
      groups: &groups,
      notices: &notices
    )

    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: resourceKeys,
        options: [.skipsPackageDescendants],
        errorHandler: { url, error in
          diagnostics += 1
          if notices.count < 20 {
            notices.append("無法讀取 \(url.path)：\(error.localizedDescription)")
          }
          return true
        }
      )
    else {
      throw CleanupValidationError.rejected("無法建立資料夾掃描器：\(root.path)")
    }

    while let url = enumerator.nextObject() as? URL {
      visited += 1
      let values: URLResourceValues
      do {
        values = try url.resourceValues(forKeys: Set(resourceKeys))
      } catch {
        diagnostics += 1
        if notices.count < 20 {
          notices.append("無法讀取 \(url.path)：\(error.localizedDescription)")
        }
        continue
      }

      if values.isSymbolicLink == true {
        if values.isDirectory == true { enumerator.skipDescendants() }
        continue
      }

      if values.isDirectory == true {
        if isServerRecycleDirectory(
          url,
          root: root,
          capabilities: targetCapabilities
        ) {
          skippedServerRecycleDirectories += 1
          enumerator.skipDescendants()
          continue
        }

        let name = url.lastPathComponent
        switch name {
        case "__MACOSX":
          if configuration.includes(tier: .balanced, scope: .folderArchiveMetadata) {
            append(
              url,
              bytes: allocatedSizeRecursively(at: url),
              rule: .folderMacOSXDirectory,
              groups: &groups
            )
          }
          enumerator.skipDescendants()
          continue
        case ".AppleDouble", ".AppleDB", ".AppleDesktop":
          if configuration.includes(tier: .ultraAggressive, scope: .folderLegacyReview) {
            append(
              url,
              bytes: allocatedSizeRecursively(at: url),
              rule: .folderLegacyAppleMetadata,
              groups: &groups
            )
          }
          enumerator.skipDescendants()
          continue
        case ".Spotlight-V100":
          appendMacManagedReviewIfIncluded(
            url,
            values: values,
            rule: .folderSpotlightMetadata,
            root: root,
            configuration: configuration,
            groups: &groups
          )
          enumerator.skipDescendants()
          continue
        case ".fseventsd":
          appendMacManagedReviewIfIncluded(
            url,
            values: values,
            rule: .folderFSEventsMetadata,
            root: root,
            configuration: configuration,
            groups: &groups
          )
          enumerator.skipDescendants()
          continue
        case ".Trashes", ".Trash":
          appendMacManagedReviewIfIncluded(
            url,
            values: values,
            rule: .folderTrashMetadata,
            root: root,
            configuration: configuration,
            groups: &groups
          )
          enumerator.skipDescendants()
          continue
        case ".DocumentRevisions-V100", ".TemporaryItems", ".MobileBackups":
          appendMacManagedReviewIfIncluded(
            url,
            values: values,
            rule: .folderMacVolumeMarkerMetadata,
            root: root,
            configuration: configuration,
            groups: &groups
          )
          enumerator.skipDescendants()
          continue
        default:
          break
        }

        if shouldSkipDirectory(url, values: values) {
          enumerator.skipDescendants()
          continue
        }
      } else if values.isRegularFile == true {
        let name = url.lastPathComponent
        if name == ".DS_Store",
          configuration.includes(tier: .ultraConservative, scope: .folderFinderMetadata)
        {
          append(
            url,
            bytes: allocatedBytes(at: url, fallback: values),
            rule: .folderDSStore,
            groups: &groups
          )
        } else if Self.windowsMetadataNames.contains(name.lowercased()),
          configuration.includes(tier: .conservative, scope: .folderWindowsMetadata)
        {
          append(
            url,
            bytes: allocatedBytes(at: url, fallback: values),
            rule: .folderWindowsMetadata,
            groups: &groups
          )
        } else if Self.macVolumeMarkerNames.contains(name)
          || name.hasPrefix(".com.apple.timemachine.")
        {
          if configuration.includes(tier: .ultraAggressive, scope: .folderMacManagedReview) {
            append(
              url,
              bytes: allocatedBytes(at: url, fallback: values),
              rule: .folderMacVolumeMarkerMetadata,
              groups: &groups
            )
          }
        } else if name.hasPrefix("._"), name.count > 2 {
          classifyAppleDouble(
            url,
            values: values,
            configuration: configuration,
            prioritizingExternalAppleDouble: prioritizesExternalAppleDouble,
            tally: &appleDoubleTally,
            groups: &groups
          )
        }
      }

      if visited.isMultiple(of: 500) {
        progress?(
          CleanupScanProgress(
            message: "已檢查 \(visited.formatted()) 個項目",
            currentPath: url.path,
            currentStep: 1,
            totalSteps: 2
          ))
      }
    }

    progress?(
      CleanupScanProgress(
        message: "整理隱藏中繼資料候選",
        currentPath: root.path,
        currentStep: 2,
        totalSteps: 2
      ))

    if diagnostics > notices.count {
      notices.append("另有 \(diagnostics - notices.count) 筆讀取診斷未逐一列出。")
    }
    if appleDoubleTally.total > 0 {
      notices.append(
        "已檢查 \(appleDoubleTally.total.formatted()) 個 ._ 檔：Finder／Windows 伴隨 \(appleDoubleTally.finderCompanions + appleDoubleTally.windowsCompanions)、孤立 metadata \(appleDoubleTally.orphanedMetadataOnly)、配對 metadata \(appleDoubleTally.pairedMetadataOnly)、敏感內容 \(appleDoubleTally.sensitive)、無法驗證 \(appleDoubleTally.unrecognized)。"
      )
    }
    if skippedServerRecycleDirectories > 0 {
      notices.append(
        "已略過 \(skippedServerRecycleDirectories) 個遠端 #recycle 伺服器回收區；安全清理不會進入或分析其中內容。"
      )
    }
    if prioritizesExternalAppleDouble {
      notices.append(
        "目前目標屬於非本機儲存：已提高可驗證 metadata-only AppleDouble 的清理優先級；resource fork、未知 entry、package／symlink companion 與格式不明 ._ 項目仍只供檢視。"
      )
    }
    notices.append("已檢查 \(visited.formatted()) 個檔案系統項目；符號連結、App 套件與受保護目錄不會跟隨。")

    let candidates = candidates(
      from: groups,
      root: root,
      configuration: configuration,
      targetCapabilities: targetCapabilities
    )
    return CleanupScanResult(
      configuration: configuration,
      candidates: candidates,
      startedAt: startedAt,
      finishedAt: Date(),
      notices: notices,
      mode: .generalLocation,
      target: target
    )
  }

  func scanCandidatesUsingReport(
    configuration: CleanupScanConfiguration,
    target: ScanTarget,
    document: ReportDocument,
    parser: ReportParser,
    progress: ProgressHandler? = nil
  ) throws -> CleanupScanResult {
    let startedAt = Date()
    let root = try validatedRoot(for: target)
    let targetCapabilities = targetCapabilityResolver(target)
    let prioritizesExternalAppleDouble =
      targetCapabilities.prioritizesExternalAppleDoubleCleanup
    guard document.summary.reportComplete else {
      throw CleanupValidationError.rejected("既有容量報告尚未完成，不能作為快速清理索引。")
    }

    let reportTarget = document.summary.target
    let reportRootPath = URL(fileURLWithPath: document.summary.targetPath).standardizedFileURL.path
    let sameLogicalTarget =
      reportTarget.reportRetentionKey == target.reportRetentionKey || reportRootPath == root.path
    guard sameLogicalTarget else {
      throw CleanupValidationError.rejected("既有容量報告不是目前清理位置的報告，請改用完整重新掃描。")
    }
    guard document.section(containing: reportRootPath) != nil else {
      throw CleanupValidationError.rejected("既有容量報告缺少 DIRECTORY_TREE，無法建立快速清理索引。")
    }

    var notices: [String] = []
    var groups: [CleanupRuleID: MatchGroup] = [:]
    var appleDoubleTally = AppleDoubleTally()
    var visitedDirectories = 0
    var candidateEntriesInspected = 0
    var diagnostics = 0
    var skippedServerRecycleDirectories = 0
    var blockedPrefixes: Set<String> = []

    progress?(
      CleanupScanProgress(
        message: "讀取既有容量報告的資料夾索引",
        currentPath: document.url.path,
        currentStep: 0,
        totalSteps: 3
      ))

    appendLegacyHiddenTrashResiduesIfIncluded(
      root: root,
      target: target,
      configuration: configuration,
      groups: &groups,
      notices: &notices
    )

    let directoryKeys: Set<URLResourceKey> = [
      .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
    ]
    let candidateKeys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
    ]

    func liveURL(for reportPath: String) -> URL? {
      if reportPath == reportRootPath { return root }
      let prefix = reportRootPath == "/" ? "/" : reportRootPath + "/"
      guard reportPath.hasPrefix(prefix) else { return nil }
      let suffix = String(reportPath.dropFirst(reportRootPath.count))
      return URL(fileURLWithPath: root.path + suffix).standardizedFileURL
    }

    func isBlocked(_ path: String) -> Bool {
      var current = path
      while true {
        if blockedPrefixes.contains(current) { return true }
        if current == root.path || current == "/" { return false }
        let parent = (current as NSString).deletingLastPathComponent
        if parent == current { return false }
        current = parent
      }
    }

    func block(_ url: URL) {
      blockedPrefixes.insert(url.standardizedFileURL.path)
    }

    let reportDirectoryCount = try parser.forEachDirectoryNode(
      document: document,
      under: reportRootPath
    ) { node in
      guard let directory = liveURL(for: node.path) else { return }
      let directoryPath = directory.path
      guard !isBlocked(directoryPath) else { return }
      guard directoryPath == root.path || isStrictDescendant(directory, of: root) else {
        diagnostics += 1
        return
      }

      if directoryPath != root.path,
        containsServerRecycleComponent(
          directory,
          root: root,
          capabilities: targetCapabilities
        )
      {
        if isServerRecycleDirectory(
          directory,
          root: root,
          capabilities: targetCapabilities
        ) {
          skippedServerRecycleDirectories += 1
        }
        block(directory)
        return
      }

      if directoryPath != root.path,
        Self.packageExtensions.contains(directory.pathExtension.lowercased())
      {
        block(directory)
        return
      }

      let directoryValues: URLResourceValues
      do {
        directoryValues = try directory.resourceValues(forKeys: directoryKeys)
      } catch {
        diagnostics += 1
        if notices.count < 20 {
          notices.append("容量報告中的資料夾目前無法讀取：\(directoryPath)：\(error.localizedDescription)")
        }
        block(directory)
        return
      }
      guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
        block(directory)
        return
      }

      if directoryPath != root.path {
        if inspectReportGuidedDirectory(
          directory,
          values: directoryValues,
          reportAllocatedBytes: node.allocatedBytes,
          root: root,
          configuration: configuration,
          groups: &groups
        ) {
          block(directory)
          return
        }
        if shouldSkipDirectory(directory, values: directoryValues) {
          block(directory)
          return
        }
      }

      visitedDirectories += 1
      let needsAppleDoubleListing = needsAppleDoubleDirectoryListing(
        configuration: configuration,
        prioritizingExternalAppleDouble: prioritizesExternalAppleDouble
      )
      let needsRootManagedListing =
        directoryPath == root.path
        && configuration.includes(tier: .ultraAggressive, scope: .folderMacManagedReview)
      let needsNameListing = needsAppleDoubleListing || needsRootManagedListing

      let entries: [URL]
      if needsNameListing {
        do {
          entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [],
            options: []
          )
        } catch {
          diagnostics += 1
          if notices.count < 20 {
            notices.append("無法列出 \(directoryPath)：\(error.localizedDescription)")
          }
          return
        }
      } else {
        var exactNames = Set<String>()
        if configuration.includes(tier: .ultraConservative, scope: .folderFinderMetadata) {
          exactNames.formUnion([".DS_Store", "._.DS_Store"])
        }
        if configuration.includes(tier: .conservative, scope: .folderWindowsMetadata) {
          for name in Self.windowsMetadataExactProbeNames {
            exactNames.insert(name)
            exactNames.insert("._" + name)
          }
        }
        entries = exactNames.compactMap { name in
          let url = directory.appendingPathComponent(name)
          return fileManager.fileExists(atPath: url.path) ? url : nil
        }
      }

      for entry in entries {
        let name = entry.lastPathComponent
        let lowercased = name.lowercased()
        let isCandidateFile =
          name == ".DS_Store"
          || Self.windowsMetadataNames.contains(lowercased)
          || Self.macVolumeMarkerNames.contains(name)
          || name.hasPrefix(".com.apple.timemachine.")
          || (name.hasPrefix("._") && name.count > 2)
        let isRootManagedDirectory =
          directoryPath == root.path
          && [
            ".Spotlight-V100", ".fseventsd", ".Trashes", ".Trash",
            ".DocumentRevisions-V100", ".TemporaryItems", ".MobileBackups",
          ].contains(name)
        guard isCandidateFile || isRootManagedDirectory else { continue }

        let values: URLResourceValues
        do {
          values = try entry.resourceValues(forKeys: candidateKeys)
        } catch {
          diagnostics += 1
          if notices.count < 20 {
            notices.append("候選項目目前無法讀取：\(entry.path)：\(error.localizedDescription)")
          }
          continue
        }
        candidateEntriesInspected += 1
        if values.isSymbolicLink == true { continue }

        if values.isDirectory == true {
          _ = inspectReportGuidedDirectory(
            entry,
            values: values,
            reportAllocatedBytes: nil,
            root: root,
            configuration: configuration,
            groups: &groups
          )
          continue
        }
        guard values.isRegularFile == true else { continue }
        inspectReportGuidedFile(
          entry,
          values: values,
          configuration: configuration,
          prioritizingExternalAppleDouble: prioritizesExternalAppleDouble,
          appleDoubleTally: &appleDoubleTally,
          groups: &groups
        )
      }

      if visitedDirectories.isMultiple(of: 250) {
        progress?(
          CleanupScanProgress(
            message: "已依容量報告檢查 \(visitedDirectories.formatted()) 個資料夾",
            currentPath: directoryPath,
            currentStep: 1,
            totalSteps: 3
          ))
      }
    }

    progress?(
      CleanupScanProgress(
        message: "整理並即時驗證快速清理候選",
        currentPath: root.path,
        currentStep: 2,
        totalSteps: 3
      ))

    if diagnostics > notices.count {
      notices.append("另有 \(diagnostics - notices.count) 筆讀取診斷未逐一列出。")
    }
    if appleDoubleTally.total > 0 {
      notices.append(
        "已即時驗證 \(appleDoubleTally.total.formatted()) 個 ._ 檔；AppleDouble 判定沒有直接相信容量報告。"
      )
    }
    notices.append(
      "快速模式使用既有容量報告的 \(reportDirectoryCount.formatted()) 個資料夾節點作為走訪索引；已核對 \(visitedDirectories.formatted()) 個仍存在的資料夾，只有 \(candidateEntriesInspected.formatted()) 個命名命中項目進一步讀取 metadata。低風險等級會直接探測已知檔名，不列出整個資料夾；需要搜尋任意 ._ AppleDouble 時才讀取第一層名稱。"
    )
    if skippedServerRecycleDirectories > 0 {
      notices.append(
        "已從容量報告導航中略過 \(skippedServerRecycleDirectories) 個遠端 #recycle 伺服器回收區；不會對其內容發出 SMB 目錄列舉或清理候選查詢。"
      )
    }
    if prioritizesExternalAppleDouble {
      notices.append(
        "目前目標屬於非本機儲存：metadata-only AppleDouble 會提早出現在較低清理等級；敏感 payload 的安全紅線不變。"
      )
    }
    notices.append(
      "容量報告不包含每個普通檔案，因此它只作為導航索引；所有候選仍以目前檔案系統狀態驗證，執行刪除前也會再次重驗證。新增但不在報告中的整個新資料夾不會由快速模式主動發現。"
    )

    progress?(
      CleanupScanProgress(
        message: "快速候選掃描完成",
        currentPath: root.path,
        currentStep: 3,
        totalSteps: 3
      ))

    return CleanupScanResult(
      configuration: configuration,
      candidates: candidates(
        from: groups,
        root: root,
        configuration: configuration,
        targetCapabilities: targetCapabilities
      ),
      startedAt: startedAt,
      finishedAt: Date(),
      notices: notices,
      mode: .generalLocation,
      target: target,
      scanSource: .existingStorageReport,
      sourceReportURL: document.url
    )
  }

  func scanCandidateDirectories(
    configuration: CleanupScanConfiguration,
    target: ScanTarget,
    directoryPaths: Set<String>,
    scanSource: CleanupScanSource = .existingStorageReport,
    progress: ProgressHandler? = nil
  ) throws -> CleanupScanResult {
    let startedAt = Date()
    let root = try validatedRoot(for: target)
    let targetCapabilities = targetCapabilityResolver(target)
    let prioritizesExternalAppleDouble =
      targetCapabilities.prioritizesExternalAppleDoubleCleanup
    let rootPath = root.path
    var groups: [CleanupRuleID: MatchGroup] = [:]
    var appleDoubleTally = AppleDoubleTally()
    var notices: [String] = []
    var inspectedDirectories = 0
    var inspectedEntries = 0
    var diagnostics = 0

    let validDirectories = directoryPaths.compactMap { path -> URL? in
      let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
      guard url.path == rootPath || isStrictDescendant(url, of: root) else { return nil }
      guard
        !containsServerRecycleComponent(
          url,
          root: root,
          capabilities: targetCapabilities
        )
      else { return nil }
      return url
    }
    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

    progress?(
      CleanupScanProgress(
        message: "增量刷新受影響資料夾",
        currentPath: validDirectories.first?.path ?? rootPath,
        currentStep: 0,
        totalSteps: max(1, validDirectories.count)
      ))

    if validDirectories.contains(where: { $0.path == rootPath }) {
      appendLegacyHiddenTrashResiduesIfIncluded(
        root: root,
        target: target,
        configuration: configuration,
        groups: &groups,
        notices: &notices
      )
    }

    let directoryKeys: Set<URLResourceKey> = [
      .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
    ]
    let candidateKeys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
    ]
    let needsAppleDoubleListing = needsAppleDoubleDirectoryListing(
      configuration: configuration,
      prioritizingExternalAppleDouble: prioritizesExternalAppleDouble
    )
    let needsMacManagedRootListing = configuration.includes(
      tier: .ultraAggressive,
      scope: .folderMacManagedReview
    )

    for (index, directory) in validDirectories.enumerated() {
      let directoryValues: URLResourceValues
      do {
        directoryValues = try directory.resourceValues(forKeys: directoryKeys)
      } catch {
        diagnostics += 1
        if notices.count < 20 {
          notices.append("增量刷新無法讀取資料夾：\(directory.path)：\(error.localizedDescription)")
        }
        continue
      }
      guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true,
        directoryValues.isPackage != true
      else { continue }
      if directory.path != rootPath, shouldSkipDirectory(directory, values: directoryValues) {
        continue
      }
      inspectedDirectories += 1

      let entries: [URL]
      let needsNameListing =
        needsAppleDoubleListing || (directory.path == rootPath && needsMacManagedRootListing)
      if needsNameListing {
        do {
          entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [],
            options: []
          )
        } catch {
          diagnostics += 1
          if notices.count < 20 {
            notices.append("增量刷新無法列出 \(directory.path)：\(error.localizedDescription)")
          }
          continue
        }
      } else {
        var exactNames = Set<String>()
        if configuration.includes(tier: .ultraConservative, scope: .folderFinderMetadata) {
          exactNames.formUnion([".DS_Store", "._.DS_Store"])
        }
        if configuration.includes(tier: .conservative, scope: .folderWindowsMetadata) {
          for name in Self.windowsMetadataExactProbeNames {
            exactNames.insert(name)
            exactNames.insert("._" + name)
          }
        }
        if configuration.includes(tier: .balanced, scope: .folderArchiveMetadata) {
          exactNames.insert("__MACOSX")
        }
        if configuration.includes(tier: .ultraAggressive, scope: .folderLegacyReview) {
          exactNames.formUnion([".AppleDouble", ".AppleDB", ".AppleDesktop"])
        }
        entries = exactNames.compactMap { name in
          let url = directory.appendingPathComponent(name)
          return fileManager.fileExists(atPath: url.path) ? url : nil
        }
      }

      for entry in entries {
        let name = entry.lastPathComponent
        let lowercased = name.lowercased()
        let isCandidateFile =
          name == ".DS_Store"
          || Self.windowsMetadataNames.contains(lowercased)
          || Self.macVolumeMarkerNames.contains(name)
          || name.hasPrefix(".com.apple.timemachine.")
          || (name.hasPrefix("._") && name.count > 2)
        let isCandidateDirectory =
          name == "__MACOSX"
          || [".AppleDouble", ".AppleDB", ".AppleDesktop"].contains(name)
          || (directory.path == rootPath && Self.macManagedDirectoryNames.contains(name))
        guard isCandidateFile || isCandidateDirectory else { continue }

        let values: URLResourceValues
        do {
          values = try entry.resourceValues(forKeys: candidateKeys)
        } catch {
          diagnostics += 1
          if notices.count < 20 {
            notices.append("增量刷新候選無法讀取：\(entry.path)：\(error.localizedDescription)")
          }
          continue
        }
        inspectedEntries += 1
        if values.isSymbolicLink == true { continue }
        if values.isDirectory == true {
          _ = inspectReportGuidedDirectory(
            entry,
            values: values,
            reportAllocatedBytes: nil,
            root: root,
            configuration: configuration,
            groups: &groups
          )
        } else if values.isRegularFile == true {
          inspectReportGuidedFile(
            entry,
            values: values,
            configuration: configuration,
            prioritizingExternalAppleDouble: prioritizesExternalAppleDouble,
            appleDoubleTally: &appleDoubleTally,
            groups: &groups
          )
        }
      }

      progress?(
        CleanupScanProgress(
          message: "已增量刷新 \(index + 1) / \(validDirectories.count) 個資料夾",
          currentPath: directory.path,
          currentStep: index + 1,
          totalSteps: max(1, validDirectories.count)
        ))
    }

    if diagnostics > notices.count {
      notices.append("另有 \(diagnostics - notices.count) 筆增量刷新診斷未逐一列出。")
    }
    notices.append(
      "本次只刷新 \(inspectedDirectories.formatted()) 個受清理影響的資料夾，檢查 \(inspectedEntries.formatted()) 個命名候選；沒有重新遞迴整個目標。"
    )

    return CleanupScanResult(
      configuration: configuration,
      candidates: candidates(
        from: groups,
        root: root,
        configuration: configuration,
        targetCapabilities: targetCapabilities
      ),
      startedAt: startedAt,
      finishedAt: Date(),
      notices: notices,
      mode: .generalLocation,
      target: target,
      scanSource: scanSource
    )
  }

  private func inspectReportGuidedDirectory(
    _ url: URL,
    values: URLResourceValues,
    reportAllocatedBytes: Int64?,
    root: URL,
    configuration: CleanupScanConfiguration,
    groups: inout [CleanupRuleID: MatchGroup]
  ) -> Bool {
    let name = url.lastPathComponent
    switch name {
    case "__MACOSX":
      if configuration.includes(tier: .balanced, scope: .folderArchiveMetadata) {
        append(
          url,
          bytes: reportAllocatedBytes ?? allocatedSizeRecursively(at: url),
          rule: .folderMacOSXDirectory,
          groups: &groups
        )
      }
      return true
    case ".AppleDouble", ".AppleDB", ".AppleDesktop":
      if configuration.includes(tier: .ultraAggressive, scope: .folderLegacyReview) {
        append(
          url,
          bytes: reportAllocatedBytes ?? allocatedSizeRecursively(at: url),
          rule: .folderLegacyAppleMetadata,
          groups: &groups
        )
      }
      return true
    case ".Spotlight-V100":
      appendMacManagedReviewIfIncluded(
        url,
        values: values,
        rule: .folderSpotlightMetadata,
        root: root,
        configuration: configuration,
        groups: &groups
      )
      return true
    case ".fseventsd":
      appendMacManagedReviewIfIncluded(
        url,
        values: values,
        rule: .folderFSEventsMetadata,
        root: root,
        configuration: configuration,
        groups: &groups
      )
      return true
    case ".Trashes", ".Trash":
      appendMacManagedReviewIfIncluded(
        url,
        values: values,
        rule: .folderTrashMetadata,
        root: root,
        configuration: configuration,
        groups: &groups
      )
      return true
    case ".DocumentRevisions-V100", ".TemporaryItems", ".MobileBackups":
      appendMacManagedReviewIfIncluded(
        url,
        values: values,
        rule: .folderMacVolumeMarkerMetadata,
        root: root,
        configuration: configuration,
        groups: &groups
      )
      return true
    default:
      return false
    }
  }

  private func inspectReportGuidedFile(
    _ url: URL,
    values: URLResourceValues,
    configuration: CleanupScanConfiguration,
    prioritizingExternalAppleDouble: Bool,
    appleDoubleTally: inout AppleDoubleTally,
    groups: inout [CleanupRuleID: MatchGroup]
  ) {
    let name = url.lastPathComponent
    if name == ".DS_Store",
      configuration.includes(tier: .ultraConservative, scope: .folderFinderMetadata)
    {
      append(
        url,
        bytes: allocatedBytes(at: url, fallback: values),
        rule: .folderDSStore,
        groups: &groups
      )
    } else if Self.windowsMetadataNames.contains(name.lowercased()),
      configuration.includes(tier: .conservative, scope: .folderWindowsMetadata)
    {
      append(
        url,
        bytes: allocatedBytes(at: url, fallback: values),
        rule: .folderWindowsMetadata,
        groups: &groups
      )
    } else if Self.macVolumeMarkerNames.contains(name)
      || name.hasPrefix(".com.apple.timemachine.")
    {
      if configuration.includes(tier: .ultraAggressive, scope: .folderMacManagedReview) {
        append(
          url,
          bytes: allocatedBytes(at: url, fallback: values),
          rule: .folderMacVolumeMarkerMetadata,
          groups: &groups
        )
      }
    } else if name.hasPrefix("._"), name.count > 2 {
      classifyAppleDouble(
        url,
        values: values,
        configuration: configuration,
        prioritizingExternalAppleDouble: prioritizingExternalAppleDouble,
        tally: &appleDoubleTally,
        groups: &groups
      )
    }
  }

  private func classifyAppleDouble(
    _ url: URL,
    values: URLResourceValues,
    configuration: CleanupScanConfiguration,
    prioritizingExternalAppleDouble: Bool,
    tally: inout AppleDoubleTally,
    groups: inout [CleanupRuleID: MatchGroup]
  ) {
    let inspection = appleDoubleInspector.inspect(url)
    let companionName = inspection.companionPath.map {
      URL(fileURLWithPath: $0).lastPathComponent
    }
    let isFinderCompanion = companionName == ".DS_Store"
    let isWindowsCompanion =
      companionName.map {
        Self.windowsMetadataNames.contains($0.lowercased())
      } ?? false
    let isMacManagedCompanion = companionName.map(Self.isMacManagedName) ?? false
    let bytes = allocatedBytes(at: url, fallback: values)

    switch inspection.kind {
    case .orphanedMetadataOnly, .pairedMetadataOnly:
      if isFinderCompanion {
        tally.finderCompanions += 1
        if configuration.includes(tier: .ultraConservative, scope: .folderFinderMetadata) {
          append(
            url,
            bytes: bytes,
            rule: .folderDSStoreAppleDoubleSidecar,
            groups: &groups
          )
        }
      } else if isWindowsCompanion {
        tally.windowsCompanions += 1
        if configuration.includes(tier: .conservative, scope: .folderWindowsMetadata) {
          append(
            url,
            bytes: bytes,
            rule: .folderWindowsAppleDoubleSidecar,
            groups: &groups
          )
        }
      } else if isMacManagedCompanion {
        tally.sensitive += 1
        if configuration.includes(tier: .ultraAggressive, scope: .folderAppleDoubleReview) {
          append(
            url,
            bytes: bytes,
            rule: .folderSensitiveAppleDoubleSidecar,
            groups: &groups
          )
        }
      } else if inspection.kind == .orphanedMetadataOnly {
        tally.orphanedMetadataOnly += 1
        let tier: CleanupTier = prioritizingExternalAppleDouble ? .conservative : .balanced
        if configuration.includes(tier: tier, scope: .folderAppleDoubleRemnants) {
          append(
            url,
            bytes: bytes,
            rule: .folderOrphanedAppleDoubleSidecar,
            groups: &groups
          )
        }
      } else {
        tally.pairedMetadataOnly += 1
        let tier: CleanupTier = prioritizingExternalAppleDouble ? .balanced : .aggressive
        if configuration.includes(tier: tier, scope: .folderAppleDouble) {
          append(
            url,
            bytes: bytes,
            rule: .folderAppleDoubleSidecar,
            groups: &groups
          )
        }
      }

    case .orphanedSensitive, .pairedSensitive:
      tally.sensitive += 1
      if configuration.includes(tier: .ultraAggressive, scope: .folderAppleDoubleReview) {
        append(
          url,
          bytes: bytes,
          rule: .folderSensitiveAppleDoubleSidecar,
          groups: &groups
        )
      }

    case .unrecognized:
      tally.unrecognized += 1
      if configuration.includes(tier: .ultraAggressive, scope: .folderAppleDoubleReview) {
        append(
          url,
          bytes: bytes,
          rule: .folderUnrecognizedDotUnderscore,
          groups: &groups
        )
      }
    }
  }

  private func appendMacManagedReviewIfIncluded(
    _ url: URL,
    values: URLResourceValues,
    rule: CleanupRuleID,
    root: URL,
    configuration: CleanupScanConfiguration,
    groups: inout [CleanupRuleID: MatchGroup]
  ) {
    guard configuration.includes(tier: .ultraAggressive, scope: .folderMacManagedReview) else {
      return
    }
    guard url.deletingLastPathComponent().standardizedFileURL.path == root.path else { return }
    let bytes: Int64
    switch rule {
    case .folderSpotlightMetadata, .folderFSEventsMetadata:
      // These service databases can contain hundreds of thousands of tiny files.
      // Recursively sizing them here duplicated the full-volume scanner's work and
      // made repeated cleanup/rescan cycles progressively slower. Keep the size
      // explicitly unknown; the volume's complete df accounting still includes it.
      bytes = 0
    default:
      bytes = allocatedBytes(at: url, fallback: values)
    }
    append(url, bytes: bytes, rule: rule, groups: &groups)
  }

  private func appendLegacyHiddenTrashResiduesIfIncluded(
    root: URL,
    target: ScanTarget,
    configuration: CleanupScanConfiguration,
    groups: inout [CleanupRuleID: MatchGroup],
    notices: inout [String]
  ) {
    guard target.kind == .volume,
      configuration.includes(tier: .ultraAggressive, scope: .folderMacManagedReview)
    else { return }

    let uid = String(getuid())
    let possibleTrashRoots = [
      root
        .appendingPathComponent(".Trashes", isDirectory: true)
        .appendingPathComponent(uid, isDirectory: true)
        .standardizedFileURL,
      root.appendingPathComponent(".Trash", isDirectory: true).standardizedFileURL,
    ]
    var found = 0

    for trashRoot in possibleTrashRoots where fileManager.fileExists(atPath: trashRoot.path) {
      let children: [URL]
      do {
        children = try fileManager.contentsOfDirectory(
          at: trashRoot,
          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey],
          options: []
        )
      } catch {
        notices.append(
          "無法核對舊版隱藏垃圾桶殘留：\(trashRoot.path)：\(error.localizedDescription)"
        )
        continue
      }

      for child in children {
        guard
          let values = try? child.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey,
          ]), values.isDirectory == true, values.isSymbolicLink != true,
          child.resolvingSymlinksInPath().standardizedFileURL.path
            == child.standardizedFileURL.path,
          child.lastPathComponent.hasPrefix(".") || values.isHidden == true
        else { continue }

        if ExternalVolumeCleanupExecutor.isAllowedLegacyTrashName(
          child.lastPathComponent,
          requiredBase: ".Spotlight-V100"
        ) {
          append(
            child,
            bytes: 0,
            rule: .folderLegacySpotlightTrashResidue,
            groups: &groups
          )
          found += 1
        } else if ExternalVolumeCleanupExecutor.isAllowedLegacyTrashName(
          child.lastPathComponent,
          requiredBase: ".fseventsd"
        ) {
          append(
            child,
            bytes: 0,
            rule: .folderLegacyFSEventsTrashResidue,
            groups: &groups
          )
          found += 1
        }
      }
    }

    if found > 0 {
      notices.append(
        "找到 \(found) 個舊版留在 Finder 管理垃圾桶、但因點號名稱可能不顯示的殘留；它們會逐項列出，而且只能直接徹底刪除。"
      )
    }
  }

  func validatedRoot(for target: ScanTarget) throws -> URL {
    guard target.kind != .system else {
      throw CleanupValidationError.rejected("一般位置清理不能使用系統掃描根目錄。")
    }

    let source = URL(fileURLWithPath: target.path, isDirectory: true).standardizedFileURL
    guard fileManager.fileExists(atPath: source.path) else {
      throw CleanupValidationError.missing(source.path)
    }

    let values = try source.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
    ])
    guard values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true else {
      throw CleanupValidationError.rejected("清理目標必須是一般資料夾或磁碟根目錄：\(source.path)")
    }

    let resolved = source.resolvingSymlinksInPath().standardizedFileURL
    guard !isProtectedRoot(resolved) else {
      throw CleanupValidationError.rejected("這個位置屬於系統或 App 資料範圍，不能使用一般資料夾清理：\(resolved.path)")
    }
    return resolved
  }

  func validateMatchedPath(
    _ path: String,
    rule: CleanupRuleID,
    rootPath: String
  ) throws -> URL {
    let rootTarget = ScanTarget(
      kind: rootPath.hasPrefix("/Volumes/") ? .volume : .folder,
      displayName: URL(fileURLWithPath: rootPath).lastPathComponent,
      path: rootPath,
      volumeUUID: nil
    )
    let root = try validatedRoot(for: rootTarget)
    let targetCapabilities = targetCapabilityResolver(rootTarget)
    let source = URL(fileURLWithPath: path).standardizedFileURL
    guard
      !containsServerRecycleComponent(
        source,
        root: root,
        capabilities: targetCapabilities
      )
    else {
      throw CleanupValidationError.rejected(
        "遠端 #recycle 由 NAS／伺服器自行管理，MacStorageLens 不會進入或清理：\(source.path)"
      )
    }
    guard fileManager.fileExists(atPath: source.path) else {
      throw CleanupValidationError.missing(source.path)
    }

    let values = try source.resourceValues(forKeys: [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
    ])
    guard values.isSymbolicLink != true else {
      throw CleanupValidationError.rejected(source.path)
    }

    let resolved = source.resolvingSymlinksInPath().standardizedFileURL
    guard resolved.path == source.path,
      isStrictDescendant(resolved, of: root), !containsBlockedComponent(resolved, root: root)
    else {
      throw CleanupValidationError.rejected(source.path)
    }

    let name = resolved.lastPathComponent
    switch rule {
    case .folderDSStore:
      guard values.isRegularFile == true, name == ".DS_Store" else {
        throw CleanupValidationError.rejected(source.path)
      }
    case .folderDSStoreAppleDoubleSidecar:
      let inspection = appleDoubleInspector.inspect(resolved)
      guard values.isRegularFile == true,
        isExecutableMetadataInspection(inspection),
        appleDoubleCompanionName(inspection) == ".DS_Store"
      else { throw CleanupValidationError.rejected(source.path) }
    case .folderWindowsMetadata:
      guard values.isRegularFile == true, Self.windowsMetadataNames.contains(name.lowercased())
      else {
        throw CleanupValidationError.rejected(source.path)
      }
    case .folderWindowsAppleDoubleSidecar:
      let inspection = appleDoubleInspector.inspect(resolved)
      guard values.isRegularFile == true,
        isExecutableMetadataInspection(inspection),
        appleDoubleCompanionName(inspection).map({
          Self.windowsMetadataNames.contains($0.lowercased())
        }) == true
      else { throw CleanupValidationError.rejected(source.path) }
    case .folderMacOSXDirectory:
      guard values.isDirectory == true, values.isPackage != true, name == "__MACOSX" else {
        throw CleanupValidationError.rejected(source.path)
      }
    case .folderOrphanedAppleDoubleSidecar:
      let inspection = appleDoubleInspector.inspect(resolved)
      guard values.isRegularFile == true,
        inspection.isExecutableOrphan,
        !isSpecialAppleDoubleCompanion(inspection)
      else { throw CleanupValidationError.rejected(source.path) }
    case .folderAppleDoubleSidecar:
      let inspection = appleDoubleInspector.inspect(resolved)
      guard values.isRegularFile == true,
        inspection.isExecutablePairedMetadata,
        !isSpecialAppleDoubleCompanion(inspection)
      else { throw CleanupValidationError.rejected(source.path) }
    case .folderSpotlightMetadata:
      guard values.isDirectory == true, values.isPackage != true,
        name == ".Spotlight-V100",
        resolved.deletingLastPathComponent().standardizedFileURL.path == root.path
      else { throw CleanupValidationError.rejected(source.path) }
    case .folderFSEventsMetadata:
      guard values.isDirectory == true, values.isPackage != true,
        name == ".fseventsd",
        resolved.deletingLastPathComponent().standardizedFileURL.path == root.path
      else { throw CleanupValidationError.rejected(source.path) }
    case .folderLegacySpotlightTrashResidue, .folderLegacyFSEventsTrashResidue:
      throw CleanupValidationError.rejected(
        "舊版不可見垃圾桶殘留只能由外接卷宗直接刪除執行器逐項重新驗證。"
      )
    case .folderSensitiveAppleDoubleSidecar, .folderUnrecognizedDotUnderscore,
      .folderTrashMetadata, .folderMacVolumeMarkerMetadata, .folderLegacyAppleMetadata:
      throw CleanupValidationError.rejected("這個 Apple／macOS metadata 類型只供檢視。")
    default:
      throw CleanupValidationError.rejected(source.path)
    }
    return source
  }

  private func candidates(
    from groups: [CleanupRuleID: MatchGroup],
    root: URL,
    configuration: CleanupScanConfiguration,
    targetCapabilities: CleanupTargetCapabilities
  ) -> [CleanupCandidate] {
    let prioritizesExternalAppleDouble =
      targetCapabilities.prioritizesExternalAppleDoubleCleanup
    let orphanedAppleDoubleTier: CleanupTier =
      prioritizesExternalAppleDouble ? .conservative : .balanced
    let pairedAppleDoubleTier: CleanupTier =
      prioritizesExternalAppleDouble ? .balanced : .aggressive
    let orphanedAppleDoubleRisk: CleanupRisk =
      prioritizesExternalAppleDouble ? .low : .moderate
    let pairedAppleDoubleRisk: CleanupRisk =
      prioritizesExternalAppleDouble ? .moderate : .high

    let definitions:
      [(
        CleanupRuleID, CleanupScope, CleanupTier, CleanupCategory, CleanupActionKind,
        String, CleanupRisk, String, String, String
      )] = [
        (
          .folderDSStore,
          .folderFinderMetadata,
          .ultraConservative,
          .folderFinderMetadata,
          .moveMatchedItemsToTrash,
          ".DS_Store",
          .minimal,
          "Finder 用它保存資料夾的檢視方式、排序與圖示位置；不包含資料夾內的原始檔案。",
          "刪除後該資料夾可能回到預設顯示方式，Finder 之後可能再次建立。",
          "重新開啟資料夾並調整 Finder 顯示設定即可重建。"
        ),
        (
          .folderDSStoreAppleDoubleSidecar,
          .folderFinderMetadata,
          .ultraConservative,
          .folderFinderMetadata,
          .moveMatchedItemsToTrash,
          "._.DS_Store 側邊檔",
          .minimal,
          "binary header 已驗證為 AppleDouble，而且同名主檔是 .DS_Store；它只伴隨 Finder 顯示中繼資料。",
          "Finder 的資料夾檢視、排序或圖示位置可能回到預設值。",
          "Finder 需要時會重新建立 .DS_Store 與相關顯示 metadata。"
        ),
        (
          .folderWindowsMetadata,
          .folderWindowsMetadata,
          .conservative,
          .folderWindowsMetadata,
          .moveMatchedItemsToTrash,
          "Windows 顯示中繼資料",
          .low,
          "Thumbs.db、ehthumbs.db 與 Desktop.ini 保存 Windows 縮圖或資料夾外觀，不是主要內容。",
          "Windows 端可能重新建立縮圖或失去資料夾自訂圖示／顯示方式。",
          "重新在 Windows 開啟資料夾後通常會自動重建。"
        ),
        (
          .folderWindowsAppleDoubleSidecar,
          .folderWindowsMetadata,
          .conservative,
          .folderWindowsMetadata,
          .moveMatchedItemsToTrash,
          "Windows metadata 的 ._ 側邊檔",
          .low,
          "binary header 已驗證為 AppleDouble，而且同名主檔是 Thumbs.db、ehthumbs.db 或 Desktop.ini。",
          "只會移除 Windows 顯示中繼資料的 Mac 伴隨 metadata；主要文件不受影響。",
          "Windows 或 Finder 需要時可重新建立對應的顯示資料。"
        ),
        (
          .folderMacOSXDirectory,
          .folderArchiveMetadata,
          .balanced,
          .folderArchiveMetadata,
          .moveMatchedItemsToTrash,
          "__MACOSX 封裝資料夾",
          .moderate,
          "macOS 壓縮工具常用這個伴隨資料夾保存 Finder 標籤、註解、資源分支或自訂圖示。",
          "主要檔案保留，但部分 Finder metadata 或舊式資源分支可能消失。",
          "若仍有原始 Mac 檔案，可重新壓縮產生；否則遺失的 metadata 未必能重建。"
        ),
        (
          .folderOrphanedAppleDoubleSidecar,
          .folderAppleDoubleRemnants,
          orphanedAppleDoubleTier,
          .folderAppleDoubleRemnants,
          .moveMatchedItemsToTrash,
          "孤立的 ._ AppleDouble",
          orphanedAppleDoubleRisk,
          prioritizesExternalAppleDouble
            ? "格式與 entry table 均有效、主檔已不存在，且沒有資源分支或未知 entry；在非本機儲存上屬於高價值殘留清理。"
            : "格式與 entry table 均有效，但同名主檔已不存在，而且側邊檔沒有資源分支或未知 entry。",
          "只會移除已失去主檔的 Finder／延伸屬性殘留，不會移除任何可見主檔。",
          targetCapabilities.isRemote
            ? "遠端卷宗不經 Finder 垃圾桶；NAS 端是否保留於伺服器回收筒／快照由伺服器政策決定。"
            : "項目可移到 Finder 可見垃圾桶；需要時可在清空 Finder 垃圾桶前還原。"
        ),
        (
          .folderAppleDoubleSidecar,
          .folderAppleDouble,
          pairedAppleDoubleTier,
          .folderAppleDouble,
          .moveMatchedItemsToTrash,
          "配對中的 ._ metadata",
          pairedAppleDoubleRisk,
          prioritizesExternalAppleDouble
            ? "同名主檔仍存在，且 AppleDouble 已證明沒有資源分支或未知 entry；非本機儲存上會提高這類 sidecar 的清理優先級。"
            : "同名主檔仍存在，而且 AppleDouble 沒有資源分支或未知 entry；但它仍可能保存 Finder 資訊、標籤與延伸屬性。",
          "主檔內容會保留，但 Finder 標籤、自訂圖示、隔離屬性或其他 Mac metadata 可能消失。",
          prioritizesExternalAppleDouble
            ? "若這個外部媒體仍需要保留 Mac 專屬 Finder metadata，請先備份；真正含 resource fork 或未知 payload 的 sidecar 不會進入此可刪除類別。"
            : "優先考慮在 Mac 上以 dot_clean 合併；直接移除後部分 metadata 未必能重建。"
        ),
        (
          .folderSensitiveAppleDoubleSidecar,
          .folderAppleDoubleReview,
          .ultraAggressive,
          .folderAppleDoubleReview,
          .reviewOnly,
          "含敏感內容的 ._ AppleDouble",
          .reviewOnly,
          "側邊檔含非空資源分支、未知／應用程式自訂 entry，或配對的是 package、符號連結、macOS 管理項目。",
          "直接刪除可能讓舊式文件、字型、圖示、App 資源或唯一殘留的 Mac metadata 永久失效。",
          "MacStorageLens 不直接清理；請先備份，再以 dot_clean 或原始 App 驗證。"
        ),
        (
          .folderUnrecognizedDotUnderscore,
          .folderAppleDoubleReview,
          .ultraAggressive,
          .folderAppleDoubleReview,
          .reviewOnly,
          "無法驗證的 ._ 檔案",
          .reviewOnly,
          "檔名像 AppleDouble，但 magic、版本、entry table 或資料範圍未通過驗證。",
          "它可能是普通使用者檔案、損壞 metadata 或未知格式；不能只憑 ._ 前綴判定為垃圾。",
          "先在 Finder 或十六進位工具確認來源；MacStorageLens 不提供直接清理。"
        ),
        (
          .folderSpotlightMetadata,
          .folderMacManagedReview,
          .ultraAggressive,
          .folderMacManagedReview,
          .moveMatchedItemsToTrash,
          "Spotlight 索引",
          .high,
          ".Spotlight-V100 是這個卷宗的 Spotlight 搜尋索引。對只在手機、相機或 Windows 使用的外接媒體，它通常不是主要內容，但不是一般無風險垃圾。",
          "『移到 Finder 可見垃圾桶』會先改成非點號可見名稱，再交給 Finder 語意的系統回收操作；清空 Finder 垃圾桶前仍占用原卷宗空間。『直接徹底刪除』則直接移除精確來源，不經任何垃圾桶。macOS 仍可能建立新的同名索引。",
          "兩種方式都必須逐項手動選取。可逆方式完成後，App 只在驗證到 Finder 可見目的地時回報成功；需要立即釋放容量時才使用直接徹底刪除。"
        ),
        (
          .folderFSEventsMetadata,
          .folderMacManagedReview,
          .ultraAggressive,
          .folderMacManagedReview,
          .moveMatchedItemsToTrash,
          "FSEvents 事件紀錄",
          .high,
          ".fseventsd 保存卷宗的檔案系統事件歷史，備份與同步工具可能依賴它判斷變更。",
          "『移到 Finder 可見垃圾桶』會建立可在 Finder 垃圾桶中辨識的非隱藏名稱；清空前仍占用原卷宗空間。『直接徹底刪除』直接移除精確來源，不經垃圾桶，也不建立任何 no_log 或其他隱藏標記。備份與同步工具可能需要重新完整掃描。",
          "只有不需要 Mac 增量事件歷史、且位於 /Volumes 根層的外接卷宗，才可逐項執行；macOS 之後仍可能重新建立新的 .fseventsd。"
        ),
        (
          .folderLegacySpotlightTrashResidue,
          .folderMacManagedReview,
          .ultraAggressive,
          .folderLegacyTrashResidue,
          .permanentDeleteMatchedItems,
          "舊版隱藏垃圾桶中的 Spotlight 殘留",
          .high,
          "這是舊版曾移入外接卷宗 .Trashes、但 Finder 可能不顯示的點號 Spotlight 副本；它仍占用卷宗容量。",
          "只能直接徹底刪除；不會再移入另一個垃圾桶，也不會碰 .Trashes 中其他任何項目。",
          "逐項核對路徑後使用『直接徹底刪除』，再重新掃描卷宗容量。"
        ),
        (
          .folderLegacyFSEventsTrashResidue,
          .folderMacManagedReview,
          .ultraAggressive,
          .folderLegacyTrashResidue,
          .permanentDeleteMatchedItems,
          "舊版隱藏垃圾桶中的 FSEvents 殘留",
          .high,
          "這是舊版曾移入外接卷宗 .Trashes、但 Finder 可能不顯示的點號 FSEvents 副本；它仍占用卷宗容量。",
          "只能直接徹底刪除；不會再移入另一個垃圾桶，也不會建立 no_log。",
          "逐項核對路徑後使用『直接徹底刪除』，再重新掃描卷宗容量。"
        ),
        (
          .folderTrashMetadata,
          .folderMacManagedReview,
          .ultraAggressive,
          .folderMacManagedReview,
          .reviewOnly,
          "外接卷宗垃圾桶",
          .reviewOnly,
          ".Trashes 是 macOS／Finder 管理的卷宗垃圾桶。MacStorageLens 不會建立、搬入或清空自訂隱藏垃圾桶。",
          "整個垃圾桶可能包含使用者仍想還原的項目，不能批次當作垃圾。舊版留下的精確點號 Spotlight／FSEvents 副本會另外列成直接刪除候選。",
          "新操作只接受 Finder 可見垃圾桶目的地；其他垃圾桶內容請在 Finder 中檢查與清空。"
        ),
        (
          .folderMacVolumeMarkerMetadata,
          .folderMacManagedReview,
          .ultraAggressive,
          .folderMacManagedReview,
          .reviewOnly,
          "macOS 卷宗 marker／暫存資料",
          .reviewOnly,
          "包含 .TemporaryItems、.DocumentRevisions-V100、.VolumeIcon.icns、Spotlight／Time Machine marker 等功能性資料。",
          "刪除可能影響進行中的暫存工作、文件版本、自訂磁碟圖示、索引或備份行為。",
          "只提供辨識與說明；需要處理時應使用對應的 macOS 功能。"
        ),
        (
          .folderLegacyAppleMetadata,
          .folderLegacyReview,
          .ultraAggressive,
          .folderLegacyReview,
          .reviewOnly,
          "舊式 Apple metadata 目錄",
          .reviewOnly,
          ".AppleDouble、.AppleDB 與 .AppleDesktop 可能由舊式 AFP／Netatalk 或跨平台檔案服務建立。",
          "用途依伺服器與檔案服務而異；直接清除可能破壞舊式 metadata 對照。",
          "先確認來源服務與備份；MacStorageLens 不提供直接清理。"
        ),
      ]

    return definitions.compactMap { definition in
      let group = groups[definition.0] ?? MatchGroup()
      guard !group.paths.isEmpty else { return nil }
      let effectiveMinimum = configuration.effectiveMinimumBytes(for: .generalLocation)
      let ignoresMinimumBecauseDirectorySizeIsUnknown =
        definition.0 == .folderSpotlightMetadata || definition.0 == .folderFSEventsMetadata
        || definition.0 == .folderLegacySpotlightTrashResidue
        || definition.0 == .folderLegacyFSEventsTrashResidue
      if definition.4 != .reviewOnly && !ignoresMinimumBecauseDirectorySizeIsUnknown {
        guard group.bytes >= effectiveMinimum || effectiveMinimum == 0 else {
          return nil
        }
      }
      let sortedPaths = group.paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      return CleanupCandidate(
        ruleID: definition.0,
        scope: definition.1,
        tier: definition.2,
        category: definition.3,
        action: definition.4,
        path: root.path,
        displayName: "\(definition.5) · \(sortedPaths.count) 項",
        bytes: group.bytes,
        risk: definition.6,
        reason: definition.7,
        impact: definition.8,
        recovery: definition.9,
        matchedPaths: sortedPaths,
        matchedPathBytes: group.bytesByPath,
        cleanupRootPath: root.path
      )
    }
    .sorted { $0.tier < $1.tier }
  }

  private func appleDoubleCompanionName(
    _ inspection: AppleDoubleInspection
  ) -> String? {
    inspection.companionPath.map { URL(fileURLWithPath: $0).lastPathComponent }
  }

  private func isExecutableMetadataInspection(
    _ inspection: AppleDoubleInspection
  ) -> Bool {
    inspection.kind == .orphanedMetadataOnly || inspection.kind == .pairedMetadataOnly
  }

  private func isSpecialAppleDoubleCompanion(
    _ inspection: AppleDoubleInspection
  ) -> Bool {
    guard let name = appleDoubleCompanionName(inspection) else { return false }
    return name == ".DS_Store"
      || Self.windowsMetadataNames.contains(name.lowercased())
      || Self.isMacManagedName(name)
  }

  private func append(
    _ url: URL,
    bytes: Int64,
    rule: CleanupRuleID,
    groups: inout [CleanupRuleID: MatchGroup]
  ) {
    var group = groups[rule] ?? MatchGroup()
    let path = url.standardizedFileURL.path
    guard group.pathSet.insert(path).inserted else { return }
    group.paths.append(path)
    let safeBytes = max(0, bytes)
    group.bytesByPath[path] = safeBytes
    group.bytes += safeBytes
    groups[rule] = group
  }

  private func allocatedBytes(at url: URL, fallback: URLResourceValues) -> Int64 {
    let keys: Set<URLResourceKey> = [
      .fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
    ]
    if let values = try? url.resourceValues(forKeys: keys) {
      return allocatedBytes(values)
    }
    return allocatedBytes(fallback)
  }

  private func allocatedBytes(_ values: URLResourceValues) -> Int64 {
    Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
  }

  private func allocatedSizeRecursively(at root: URL) -> Int64 {
    var total: Int64 = 0
    let keys: [URLResourceKey] = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      .fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
    ]
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: keys,
        options: [.skipsPackageDescendants],
        errorHandler: { _, _ in true }
      )
    else { return 0 }

    while let url = enumerator.nextObject() as? URL {
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
      if values.isSymbolicLink == true {
        if values.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      if values.isRegularFile == true {
        total += allocatedBytes(values)
      }
    }
    return total
  }

  private func needsAppleDoubleDirectoryListing(
    configuration: CleanupScanConfiguration,
    prioritizingExternalAppleDouble: Bool
  ) -> Bool {
    let orphanedTier: CleanupTier =
      prioritizingExternalAppleDouble ? .conservative : .balanced
    let pairedTier: CleanupTier =
      prioritizingExternalAppleDouble ? .balanced : .aggressive
    return configuration.includes(tier: orphanedTier, scope: .folderAppleDoubleRemnants)
      || configuration.includes(tier: pairedTier, scope: .folderAppleDouble)
      || configuration.includes(tier: .ultraAggressive, scope: .folderAppleDoubleReview)
  }

  private func isServerRecycleDirectory(
    _ url: URL,
    root: URL,
    capabilities: CleanupTargetCapabilities
  ) -> Bool {
    guard capabilities.isRemote else { return false }
    let standardized = url.standardizedFileURL
    let standardizedRoot = root.standardizedFileURL
    guard standardized.deletingLastPathComponent().path == standardizedRoot.path else {
      return false
    }
    return standardized.lastPathComponent.caseInsensitiveCompare("#recycle") == .orderedSame
  }

  private func containsServerRecycleComponent(
    _ url: URL,
    root: URL,
    capabilities: CleanupTargetCapabilities
  ) -> Bool {
    guard capabilities.isRemote else { return false }
    let standardized = url.standardizedFileURL
    let standardizedRoot = root.standardizedFileURL
    let rootPath = standardizedRoot.path
    guard standardized.path.hasPrefix(rootPath + "/") else { return false }
    let relative = String(standardized.path.dropFirst(rootPath.count + 1))
    guard let firstComponent = relative.split(separator: "/", omittingEmptySubsequences: true).first
    else { return false }
    return String(firstComponent).caseInsensitiveCompare("#recycle") == .orderedSame
  }

  private func shouldSkipDirectory(_ url: URL, values: URLResourceValues) -> Bool {
    if values.isPackage == true || Self.packageExtensions.contains(url.pathExtension.lowercased()) {
      return true
    }
    return Self.blockedDirectoryNames.contains(url.lastPathComponent)
  }

  private func containsBlockedComponent(_ url: URL, root: URL) -> Bool {
    var ancestor = url.deletingLastPathComponent().standardizedFileURL
    let rootPath = root.standardizedFileURL.path

    while ancestor.path != rootPath {
      guard ancestor.path.hasPrefix(rootPath + "/") else { return true }
      let name = ancestor.lastPathComponent
      if Self.blockedDirectoryNames.contains(name)
        || Self.packageExtensions.contains(ancestor.pathExtension.lowercased())
      {
        return true
      }
      guard
        let values = try? ancestor.resourceValues(forKeys: [
          .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        ]),
        values.isDirectory == true,
        values.isSymbolicLink != true,
        values.isPackage != true
      else { return true }
      ancestor.deleteLastPathComponent()
    }
    return false
  }

  private func isProtectedRoot(_ url: URL) -> Bool {
    let path = url.path
    let blockedTrees = [
      "/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/Applications",
      home.appendingPathComponent("Library", isDirectory: true).path,
    ]
    if blockedTrees.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
      return true
    }

    // The container roots themselves are too broad, but explicitly selected
    // folders below /Users and mounted volumes are valid general-cleanup roots.
    let blockedExactRoots = ["/", "/Users", "/Volumes", home.path]
    return blockedExactRoots.contains(path)
  }

  private func isStrictDescendant(_ url: URL, of root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    return path.hasPrefix(rootPath + "/")
  }

  private static let windowsMetadataNames: Set<String> = [
    "thumbs.db", "ehthumbs.db", "desktop.ini",
  ]

  // The full recursive scanner compares these names case-insensitively. Quick
  // report-guided cleanup avoids listing every low-risk directory, so it probes
  // the common on-disk spellings explicitly to preserve the same behavior on
  // case-sensitive filesystems.
  private static let windowsMetadataExactProbeNames: Set<String> = [
    "Thumbs.db", "thumbs.db", "ehthumbs.db", "Desktop.ini", "desktop.ini",
  ]

  private static let macManagedDirectoryNames: Set<String> = [
    ".Spotlight-V100", ".fseventsd", ".Trashes", ".Trash", ".DocumentRevisions-V100",
    ".TemporaryItems", ".MobileBackups",
  ]

  private static let macVolumeMarkerNames: Set<String> = [
    ".VolumeIcon.icns", ".metadata_never_index", ".metadata_never_index_unless_rootfs",
    ".apdisk", ".localized", ".hidden", "Icon\r", ".com.apple.timemachine.donotpresent",
    ".com.apple.timemachine.supported",
  ]

  private static func isMacManagedName(_ name: String) -> Bool {
    macManagedDirectoryNames.contains(name)
      || macVolumeMarkerNames.contains(name)
      || name.hasPrefix(".com.apple.timemachine.")
  }

  private static let blockedDirectoryNames: Set<String> = [
    ".git", ".svn", ".hg", ".Spotlight-V100", ".fseventsd", ".Trashes", ".Trash",
    ".DocumentRevisions-V100", ".TemporaryItems", ".MobileBackups",
    "System Volume Information",
  ]

  private static let packageExtensions: Set<String> = [
    "app", "bundle", "framework", "plugin", "appex", "xcodeproj", "xcworkspace",
    "photoslibrary", "photolibrary", "musiclibrary", "imovielibrary", "pages", "numbers",
    "key", "rtfd", "playground", "pkg",
  ]
}
