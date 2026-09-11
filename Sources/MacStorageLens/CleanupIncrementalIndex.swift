import Foundation

struct CleanupIncrementalIndexStatus: Hashable {
  let available: Bool
  let coveredScopeCount: Int
  let dirtyDirectoryCount: Int
  let updatedAt: Date?
  let persisted: Bool
  let scanSource: CleanupScanSource?

  static let empty = CleanupIncrementalIndexStatus(
    available: false,
    coveredScopeCount: 0,
    dirtyDirectoryCount: 0,
    updatedAt: nil,
    persisted: false,
    scanSource: nil
  )
}

struct CleanupIncrementalIndex: Codable, Hashable {
  static let currentSchemaVersion = 6

  let schemaVersion: Int
  let target: ScanTarget
  let targetKey: String
  let scanSource: CleanupScanSource
  let sourceReportPath: String?
  let sourceReportSignature: ReportFileSignature?
  let createdAt: Date
  var updatedAt: Date
  var coveredScopes: Set<CleanupScope>
  var candidates: [CleanupCandidate]
  var dirtyDirectoryPaths: Set<String>

  init(
    target: ScanTarget,
    scanSource: CleanupScanSource,
    sourceReportURL: URL?,
    sourceReportSignature: ReportFileSignature?,
    createdAt: Date = Date()
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.target = target
    targetKey = target.reportRetentionKey
    self.scanSource = scanSource
    sourceReportPath = sourceReportURL?.resolvingSymlinksInPath().standardizedFileURL.path
    self.sourceReportSignature = sourceReportSignature
    self.createdAt = createdAt
    updatedAt = createdAt
    coveredScopes = []
    candidates = []
    dirtyDirectoryPaths = []
  }

  var status: CleanupIncrementalIndexStatus {
    CleanupIncrementalIndexStatus(
      available: true,
      coveredScopeCount: coveredScopes.count,
      dirtyDirectoryCount: dirtyDirectoryPaths.count,
      updatedAt: updatedAt,
      persisted: scanSource == .existingStorageReport,
      scanSource: scanSource
    )
  }

  func isValid(
    for target: ScanTarget,
    scanSource: CleanupScanSource,
    sourceReportURL: URL?,
    sourceReportSignature: ReportFileSignature?
  ) -> Bool {
    guard schemaVersion == Self.currentSchemaVersion,
      targetKey == target.reportRetentionKey,
      self.scanSource == scanSource,
      self.target.kind == target.kind,
      coveredScopes.allSatisfy({ $0.mode == CleanupMode.forTarget(target) }),
      candidates.count <= 50_000,
      dirtyDirectoryPaths.count <= 100_000
    else { return false }

    if scanSource == .existingStorageReport {
      guard let sourceReportURL, let sourceReportSignature else { return false }
      let reportPath = sourceReportURL.resolvingSymlinksInPath().standardizedFileURL.path
      guard sourceReportPath == reportPath,
        self.sourceReportSignature == sourceReportSignature
      else { return false }
    } else if sourceReportPath != nil || self.sourceReportSignature != nil {
      return false
    }

    let root = URL(fileURLWithPath: target.path, isDirectory: true).standardizedFileURL.path
    let prefix = root == "/" ? "/" : root + "/"
    func insideRoot(_ path: String) -> Bool {
      let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
      return standardized == root || standardized.hasPrefix(prefix)
    }

    for candidate in candidates {
      guard candidate.scope.mode == CleanupMode.forTarget(target),
        !candidate.selected
      else { return false }

      if candidate.scope == .trashBins {
        guard Self.isStructurallyValidTrashBinCandidate(candidate) else { return false }
        continue
      }

      if let cleanupRootPath = candidate.cleanupRootPath,
        URL(fileURLWithPath: cleanupRootPath).standardizedFileURL.path != root
      {
        return false
      }
      if !candidate.matchedPaths.isEmpty,
        !candidate.matchedPaths.allSatisfy(insideRoot)
      {
        return false
      }
      if !candidate.matchedPathBytes.keys.allSatisfy({ candidate.matchedPaths.contains($0) }) {
        return false
      }
    }

    return dirtyDirectoryPaths.allSatisfy(insideRoot)
  }

  private static func isStructurallyValidTrashBinCandidate(
    _ candidate: CleanupCandidate
  ) -> Bool {
    guard candidate.ruleID == .trashBinContents,
      candidate.category == .trashBins,
      candidate.action == .permanentDeleteMatchedItems,
      let cleanupRootPath = candidate.cleanupRootPath,
      !candidate.matchedPaths.isEmpty
    else { return false }

    let cleanupRoot = URL(fileURLWithPath: cleanupRootPath, isDirectory: true)
      .standardizedFileURL
    guard candidate.path == cleanupRoot.path,
      cleanupRoot.path != "/",
      cleanupRoot.lastPathComponent == ".Trash"
        || cleanupRoot.deletingLastPathComponent().lastPathComponent == ".Trashes"
    else { return false }

    if cleanupRoot.lastPathComponent != ".Trash" {
      guard UInt32(cleanupRoot.lastPathComponent) != nil else { return false }
    }

    guard
      candidate.matchedPaths.allSatisfy({ path in
        let item = URL(fileURLWithPath: path).standardizedFileURL
        return item.path != cleanupRoot.path
          && item.deletingLastPathComponent().standardizedFileURL.path == cleanupRoot.path
      })
    else { return false }

    return candidate.matchedPathBytes.keys.allSatisfy {
      candidate.matchedPaths.contains($0)
    }
  }

  func requiredScopes(
    for configuration: CleanupScanConfiguration,
    prioritizingExternalAppleDouble: Bool = false
  ) -> Set<CleanupScope> {
    let mode = CleanupMode.forTarget(target)
    return Set(
      CleanupScope.cases(for: mode).filter { scope in
        configuration.requiresScope(
          scope,
          prioritizingExternalAppleDouble: prioritizingExternalAppleDouble
        )
      })
  }

  func missingScopes(
    for configuration: CleanupScanConfiguration,
    prioritizingExternalAppleDouble: Bool = false
  ) -> Set<CleanupScope> {
    requiredScopes(
      for: configuration,
      prioritizingExternalAppleDouble: prioritizingExternalAppleDouble
    ).subtracting(coveredScopes)
  }

  func resettingDiscovery(at date: Date = Date()) -> CleanupIncrementalIndex {
    CleanupIncrementalIndex(
      target: target,
      scanSource: scanSource,
      sourceReportURL: sourceReportPath.map { URL(fileURLWithPath: $0) },
      sourceReportSignature: sourceReportSignature,
      createdAt: date
    )
  }

  mutating func merge(
    scanResult: CleanupScanResult,
    coveredScopes newlyCovered: Set<CleanupScope>
  ) {
    let retained = candidates.filter { !newlyCovered.contains($0.scope) }
    candidates = Self.mergeCandidates(retained + scanResult.candidates)
    coveredScopes.formUnion(newlyCovered)
    updatedAt = Date()
  }

  mutating func removeCandidatesInDirtyDirectories(_ directories: Set<String>) {
    guard !directories.isEmpty else { return }
    candidates = candidates.compactMap { candidate in
      Self.candidate(candidate, removingChildrenOf: directories)
    }
    updatedAt = Date()
  }

  mutating func markCleanupResult(
    selected: [CleanupCandidate],
    log: CleanupLog
  ) {
    guard !selected.isEmpty else { return }

    var successfulPaths = Set<String>()
    var recreatedPaths = Set<String>()
    var scopesNeedingFreshSystemScan = Set<CleanupScope>()

    for (candidate, entry) in zip(selected, log.entries) {
      if candidate.ruleID == .trashBinContents || candidate.scope == .trashBins {
        // A Trash directory can receive new items at any moment. Even after a
        // partial or fully successful deletion, force the next supplemental
        // scan to enumerate it again instead of treating the old match list as
        // complete.
        scopesNeedingFreshSystemScan.insert(.trashBins)
      }

      successfulPaths.formUnion(entry.movedItems)
      successfulPaths.formUnion(entry.permanentlyDeletedItems)
      recreatedPaths.formUnion(entry.recreatedItems)

      if candidate.matchedPaths.isEmpty {
        let commandSucceeded =
          entry.command != nil && entry.commandExitStatus == 0
          && entry.failures.isEmpty
        let sourceWasRemoved = !entry.movedItems.isEmpty || !entry.permanentlyDeletedItems.isEmpty
        if commandSucceeded || sourceWasRemoved {
          candidates.removeAll { Self.stableKey($0) == Self.stableKey(candidate) }
        }
        if CleanupMode.forTarget(target) == .system {
          scopesNeedingFreshSystemScan.insert(candidate.scope)
        }
      }
    }

    successfulPaths.formUnion(recreatedPaths)
    if !successfulPaths.isEmpty {
      candidates = candidates.compactMap { candidate in
        Self.candidate(candidate, removingMatchedPaths: successfulPaths)
      }
      if CleanupMode.forTarget(target) == .generalLocation {
        for path in successfulPaths {
          let url = URL(fileURLWithPath: path).standardizedFileURL
          let parent = url.deletingLastPathComponent().standardizedFileURL.path
          if parent == target.path || parent.hasPrefix(target.path + "/") {
            dirtyDirectoryPaths.insert(parent)
          }
        }
      }
    }

    if !scopesNeedingFreshSystemScan.isEmpty {
      coveredScopes.subtract(scopesNeedingFreshSystemScan)
    }
    candidates = Self.mergeCandidates(candidates)
    updatedAt = Date()
  }

  mutating func clearDirtyDirectories(_ directories: Set<String>) {
    dirtyDirectoryPaths.subtract(directories)
    updatedAt = Date()
  }

  private static func mergeCandidates(_ raw: [CleanupCandidate]) -> [CleanupCandidate] {
    var byKey: [String: CleanupCandidate] = [:]
    for candidate in raw {
      let deselected = candidate.replacingSelection(false)
      let key = stableKey(deselected)
      guard let existing = byKey[key] else {
        byKey[key] = deselected
        continue
      }

      if !existing.matchedPaths.isEmpty || !deselected.matchedPaths.isEmpty {
        let paths = Set(existing.matchedPaths).union(deselected.matchedPaths)
        var bytesByPath = existing.matchedPathBytes
        for (path, bytes) in deselected.matchedPathBytes {
          bytesByPath[path] = bytes
        }
        byKey[key] = existing.replacingMatchedPaths(
          paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
          matchedPathBytes: bytesByPath
        )
      } else {
        byKey[key] = deselected
      }
    }
    return byKey.values.sorted { lhs, rhs in
      if lhs.tier == rhs.tier {
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
      }
      return lhs.tier < rhs.tier
    }
  }

  private static func stableKey(_ candidate: CleanupCandidate) -> String {
    let root = candidate.cleanupRootPath ?? ""
    return "\(candidate.ruleID.rawValue)|\(candidate.action.rawValue)|\(root)|\(candidate.path)"
  }

  private static func candidate(
    _ candidate: CleanupCandidate,
    removingMatchedPaths removedPaths: Set<String>
  ) -> CleanupCandidate? {
    guard !candidate.matchedPaths.isEmpty else {
      return removedPaths.contains(candidate.path) ? nil : candidate
    }
    let paths = candidate.matchedPaths.filter { !removedPaths.contains($0) }
    guard !paths.isEmpty else { return nil }
    let bytesByPath = candidate.matchedPathBytes.filter { paths.contains($0.key) }
    return candidate.replacingMatchedPaths(paths, matchedPathBytes: bytesByPath)
  }

  private static func candidate(
    _ candidate: CleanupCandidate,
    removingChildrenOf directories: Set<String>
  ) -> CleanupCandidate? {
    func directParentIsDirty(_ path: String) -> Bool {
      let parent = URL(fileURLWithPath: path).standardizedFileURL
        .deletingLastPathComponent().standardizedFileURL.path
      return directories.contains(parent)
    }

    guard !candidate.matchedPaths.isEmpty else {
      return directParentIsDirty(candidate.path) ? nil : candidate
    }
    let paths = candidate.matchedPaths.filter { !directParentIsDirty($0) }
    guard !paths.isEmpty else { return nil }
    let bytesByPath = candidate.matchedPathBytes.filter { paths.contains($0.key) }
    return candidate.replacingMatchedPaths(paths, matchedPathBytes: bytesByPath)
  }
}

extension CleanupCandidate {
  fileprivate func replacingSelection(_ selected: Bool) -> CleanupCandidate {
    CleanupCandidate(
      id: id,
      ruleID: ruleID,
      scope: scope,
      tier: tier,
      category: category,
      action: action,
      path: path,
      displayName: displayName,
      bytes: bytes,
      risk: risk,
      reason: reason,
      impact: impact,
      recovery: recovery,
      managedCommand: managedCommand,
      matchedPaths: matchedPaths,
      matchedPathBytes: matchedPathBytes,
      cleanupRootPath: cleanupRootPath,
      selected: selected
    )
  }

  fileprivate func replacingMatchedPaths(
    _ paths: [String],
    matchedPathBytes: [String: Int64]
  ) -> CleanupCandidate {
    let totalBytes: Int64
    if matchedPathBytes.isEmpty {
      if paths.count == matchedPaths.count {
        totalBytes = bytes
      } else if matchedPaths.isEmpty {
        totalBytes = bytes
      } else {
        let average = bytes / Int64(max(1, matchedPaths.count))
        totalBytes = average * Int64(paths.count)
      }
    } else {
      totalBytes = paths.reduce(0) { $0 + max(0, matchedPathBytes[$1] ?? 0) }
    }

    let baseName: String
    if let range = displayName.range(of: " · ", options: .backwards),
      displayName[range.upperBound...].hasSuffix("項")
    {
      baseName = String(displayName[..<range.lowerBound])
    } else {
      baseName = displayName
    }

    return CleanupCandidate(
      id: id,
      ruleID: ruleID,
      scope: scope,
      tier: tier,
      category: category,
      action: action,
      path: path,
      displayName: "\(baseName) · \(paths.count) 項",
      bytes: totalBytes,
      risk: risk,
      reason: reason,
      impact: impact,
      recovery: recovery,
      managedCommand: managedCommand,
      matchedPaths: paths,
      matchedPathBytes: matchedPathBytes,
      cleanupRootPath: cleanupRootPath,
      selected: false
    )
  }
}

struct CleanupIncrementalIndexStore {
  let directoryURL: URL

  init(directoryURL: URL, fileManager: FileManager = .default) throws {
    self.directoryURL = directoryURL.standardizedFileURL
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: self.directoryURL.path, isDirectory: &isDirectory) {
      let values = try self.directoryURL.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ])
      guard isDirectory.boolValue, values.isDirectory == true, values.isSymbolicLink != true else {
        throw CleanupValidationError.rejected("清理索引目錄不是安全的本機資料夾：\(self.directoryURL.path)")
      }
    } else {
      try fileManager.createDirectory(
        at: self.directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    }
    try? fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: self.directoryURL.path
    )
  }

  func load(
    target: ScanTarget,
    scanSource: CleanupScanSource,
    sourceReportURL: URL?,
    fileManager: FileManager = .default
  ) -> CleanupIncrementalIndex? {
    // Long-lived disk reuse is deliberately limited to report-guided general-location
    // cleanup. System cleanup and live recursive scans may change underneath the App
    // too quickly for a persisted candidate snapshot to be a safe default.
    guard CleanupMode.forTarget(target) == .generalLocation,
      scanSource == .existingStorageReport,
      let sourceReportURL,
      let signature = try? ReportFileSignature.read(from: sourceReportURL, fileManager: fileManager)
    else { return nil }

    let url = indexURL(target: target, scanSource: scanSource, sourceReportURL: sourceReportURL)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let values = try? url.resourceValues(forKeys: [
      .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard values?.isRegularFile == true, values?.isSymbolicLink != true,
      (values?.fileSize ?? 0) <= 256 * 1024 * 1024
    else {
      try? fileManager.removeItem(at: url)
      return nil
    }

    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .millisecondsSince1970
      let payload = try decoder.decode(
        CleanupIncrementalIndex.self,
        from: Data(contentsOf: url, options: [.mappedIfSafe])
      )
      guard
        payload.isValid(
          for: target,
          scanSource: scanSource,
          sourceReportURL: sourceReportURL,
          sourceReportSignature: signature
        )
      else {
        try? fileManager.removeItem(at: url)
        return nil
      }
      return payload
    } catch {
      try? fileManager.removeItem(at: url)
      return nil
    }
  }

  @discardableResult
  func save(
    _ index: CleanupIncrementalIndex,
    fileManager: FileManager = .default
  ) throws -> URL? {
    guard CleanupMode.forTarget(index.target) == .generalLocation,
      index.scanSource == .existingStorageReport,
      let reportPath = index.sourceReportPath
    else { return nil }

    let reportURL = URL(fileURLWithPath: reportPath)
    guard
      let currentSignature = try? ReportFileSignature.read(
        from: reportURL, fileManager: fileManager),
      index.isValid(
        for: index.target,
        scanSource: index.scanSource,
        sourceReportURL: reportURL,
        sourceReportSignature: currentSignature
      )
    else { return nil }

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(index)
    guard data.count <= 256 * 1024 * 1024 else { return nil }
    let destination = indexURL(
      target: index.target,
      scanSource: index.scanSource,
      sourceReportURL: reportURL
    )
    try data.write(to: destination, options: .atomic)
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    return destination
  }

  func remove(
    target: ScanTarget,
    scanSource: CleanupScanSource,
    sourceReportURL: URL?,
    fileManager: FileManager = .default
  ) {
    try? fileManager.removeItem(
      at: indexURL(target: target, scanSource: scanSource, sourceReportURL: sourceReportURL)
    )
  }

  func prune(fileManager: FileManager = .default, maximumFiles: Int = 24) {
    let children =
      (try? fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [
          .contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
        ],
        options: [.skipsHiddenFiles]
      )) ?? []

    let valid = children.compactMap { child -> (URL, Date)? in
      guard child.pathExtension == "json" else { return nil }
      let values = try? child.resourceValues(forKeys: [
        .contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      guard values?.isRegularFile == true, values?.isSymbolicLink != true,
        (values?.fileSize ?? 0) <= 256 * 1024 * 1024
      else {
        try? fileManager.removeItem(at: child)
        return nil
      }
      return (child, values?.contentModificationDate ?? .distantPast)
    }
    .sorted { $0.1 > $1.1 }

    for item in valid.dropFirst(max(0, maximumFiles)) {
      try? fileManager.removeItem(at: item.0)
    }
  }

  private func indexURL(
    target: ScanTarget,
    scanSource: CleanupScanSource,
    sourceReportURL: URL?
  ) -> URL {
    let reportPath = sourceReportURL?.resolvingSymlinksInPath().standardizedFileURL.path ?? "none"
    let identity = "\(target.reportRetentionKey)|\(scanSource.rawValue)|\(reportPath)"
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in identity.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 1_099_511_628_211
    }
    return
      directoryURL
      .appendingPathComponent("cleanup-\(String(format: "%016llx", hash))")
      .appendingPathExtension("json")
  }
}
