import Foundation

enum ReportLibraryError: LocalizedError {
  case unsafeReportPath(String)
  case incompleteReport(String)
  case unreadableReport(String)

  var errorDescription: String? {
    switch self {
    case .unsafeReportPath(let path):
      return "拒絕移除不在 MacStorageLens 報告快取內的路徑：\(path)"
    case .incompleteReport(let path):
      return "這份掃描報告尚未完成，不能加入掃描紀錄：\(path)"
    case .unreadableReport(let path):
      return "無法讀取掃描報告的目標資訊：\(path)"
    }
  }
}

struct ReportRecord: Identifiable, Hashable {
  let url: URL
  let target: ScanTarget
  let scannerVersion: String
  let generatedAt: String
  let fileSize: Int64
  let modifiedAt: Date
  let isImported: Bool

  var id: String { url.standardizedFileURL.path }
  var targetKey: String { target.reportRetentionKey }

  var sourceTitle: String { isImported ? "匯入報告" : "App 掃描" }
  var locationSymbol: String { target.kind.symbol }

  var locationTitle: String { target.locationTitle }
}

enum ReportRetentionPolicy {
  /// System storage keeps its own newest report and does not consume a non-system slot.
  static let maximumNonSystemLocations = 12
  static let maximumRecentUnscannedLocations = 12
  static let inlineMenuItems = 5
}

enum RecentScanTargetPolicy {
  static func normalized(
    _ targets: [ScanTarget],
    maximum: Int = ReportRetentionPolicy.maximumRecentUnscannedLocations
  ) -> [ScanTarget] {
    guard maximum > 0 else { return [] }
    var seen = Set<String>()
    var result: [ScanTarget] = []
    result.reserveCapacity(min(maximum, targets.count))
    for target in targets {
      guard target.kind != .system else { continue }
      guard seen.insert(target.reportRetentionKey).inserted else { continue }
      result.append(target)
      if result.count == maximum { break }
    }
    return result
  }

  static func inserting(
    _ target: ScanTarget,
    into targets: [ScanTarget],
    maximum: Int = ReportRetentionPolicy.maximumRecentUnscannedLocations
  ) -> [ScanTarget] {
    guard target.kind != .system else { return normalized(targets, maximum: maximum) }
    return normalized(
      [target] + targets.filter { $0.reportRetentionKey != target.reportRetentionKey },
      maximum: maximum
    )
  }

  static func pending(
    from targets: [ScanTarget],
    savedKeys: Set<String>,
    maximum: Int = ReportRetentionPolicy.maximumRecentUnscannedLocations
  ) -> [ScanTarget] {
    normalized(
      targets.filter { !savedKeys.contains($0.reportRetentionKey) },
      maximum: maximum
    )
  }
}

extension ScanTarget {
  /// One complete report is retained for each logical location. Volume UUIDs take
  /// priority so the same external disk stays the same record even if its mount
  /// name changes. A folder-picker selection of the volume root shares that UUID;
  /// ordinary nested folders remain path-specific.
  var reportRetentionKey: String {
    switch kind {
    case .system:
      return "system"
    case .volume:
      if let volumeUUID, !volumeUUID.isEmpty {
        return "volume:uuid:\(volumeUUID.lowercased())"
      }
      return "volume:path:\(normalizedReportPath)"
    case .folder:
      // A user can select the root of a mounted disk through the folder picker.
      // When the report carries that disk's UUID, treat it as the same logical
      // location as an explicit “other disk” scan instead of retaining duplicate
      // folder/volume records for one card. Nested folders remain path-specific.
      if let volumeUUID, !volumeUUID.isEmpty, isMountedVolumeRoot {
        return "volume:uuid:\(volumeUUID.lowercased())"
      }
      return "folder:path:\(normalizedReportPath)"
    }
  }

  var normalizedReportPath: String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private var isMountedVolumeRoot: Bool {
    let components = normalizedReportPath.split(separator: "/", omittingEmptySubsequences: true)
    return components.count == 2 && components.first == "Volumes"
  }
}

struct ReportLibrary {
  let rootURL: URL
  let scansURL: URL
  let importsURL: URL
  let scannerURL: URL
  let scanWorkURL: URL
  let cleanupHistoryURL: URL
  let reportIndexesURL: URL
  let cleanupIndexesURL: URL

  init(fileManager: FileManager = .default) throws {
    let support = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    try self.init(
      rootURL: support.appendingPathComponent("MacStorageLens", isDirectory: true),
      fileManager: fileManager
    )
  }

  init(rootURL: URL, fileManager: FileManager = .default) throws {
    self.rootURL = rootURL
    scansURL = rootURL.appendingPathComponent("Scans", isDirectory: true)
    importsURL = rootURL.appendingPathComponent("Imported Reports", isDirectory: true)
    scannerURL = rootURL.appendingPathComponent("Scanner", isDirectory: true)
    scanWorkURL = rootURL.appendingPathComponent("Scan Work", isDirectory: true)
    cleanupHistoryURL = rootURL.appendingPathComponent("Cleanup History", isDirectory: true)
    reportIndexesURL = rootURL.appendingPathComponent("Report Indexes", isDirectory: true)
    cleanupIndexesURL = rootURL.appendingPathComponent("Cleanup Indexes", isDirectory: true)
    for directory in [
      rootURL, scansURL, importsURL, scannerURL, scanWorkURL, cleanupHistoryURL,
      reportIndexesURL, cleanupIndexesURL,
    ] {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try? pruneScanDiagnostics(fileManager: fileManager)
  }

  func importReport(from source: URL, fileManager: FileManager = .default) throws -> URL {
    #if os(macOS)
      let started = source.startAccessingSecurityScopedResource()
      defer { if started { source.stopAccessingSecurityScopedResource() } }
    #endif

    // Copy first so importing the report currently shown by the App never deletes
    // its own source before the new copy has been validated.
    let staging =
      rootURL
      .appendingPathComponent(".report-import-\(UUID().uuidString)")
      .appendingPathExtension("md")
    defer { try? fileManager.removeItem(at: staging) }
    try fileManager.copyItem(at: source, to: staging)
    _ = try inspectRecord(staging, isImported: true, fileManager: fileManager)

    let base = source.deletingPathExtension().lastPathComponent
    let destination = uniqueDestination(
      directory: importsURL,
      baseName: base.isEmpty ? "imported-storage-tree" : base,
      fileManager: fileManager
    )
    try fileManager.moveItem(at: staging, to: destination)
    try keepLatestReportForLocation(destination, fileManager: fileManager)
    return destination
  }

  func reportRecords(fileManager: FileManager = .default) -> [ReportRecord] {
    allMarkdownReports(fileManager: fileManager)
      .compactMap { url in
        try? inspectRecord(
          url,
          isImported: isInside(url, root: importsURL),
          fileManager: fileManager
        )
      }
      .sorted { lhs, rhs in
        if lhs.modifiedAt == rhs.modifiedAt {
          return lhs.locationTitle.localizedStandardCompare(rhs.locationTitle) == .orderedAscending
        }
        return lhs.modifiedAt > rhs.modifiedAt
      }
  }

  func reportURLs(fileManager: FileManager = .default) -> [URL] {
    reportRecords(fileManager: fileManager).map(\.url)
  }

  func scanReportURLs(fileManager: FileManager = .default) -> [URL] {
    markdownReports(in: scansURL, fileManager: fileManager)
      .filter { isCompletedReport($0) }
      .sorted { modificationDate($0) > modificationDate($1) }
  }

  func importedReportURLs(fileManager: FileManager = .default) -> [URL] {
    markdownReports(in: importsURL, fileManager: fileManager)
      .filter { isCompletedReport($0) }
      .sorted { modificationDate($0) > modificationDate($1) }
  }

  func latestReportURL(fileManager: FileManager = .default) -> URL? {
    reportRecords(fileManager: fileManager).first?.url
  }

  func latestReportURL(for target: ScanTarget, fileManager: FileManager = .default) -> URL? {
    let records = reportRecords(fileManager: fileManager)
    let volumeAliases = unambiguousVolumeAliases(in: records)
    let targetKey = canonicalRetentionKey(for: target, volumeAliases: volumeAliases)
    return records.first(where: {
      canonicalRetentionKey(for: $0, volumeAliases: volumeAliases) == targetKey
    })?.url
  }

  func record(for url: URL, fileManager: FileManager = .default) -> ReportRecord? {
    let standardized = url.resolvingSymlinksInPath().standardizedFileURL
    return reportRecords(fileManager: fileManager).first {
      $0.url.resolvingSymlinksInPath().standardizedFileURL == standardized
    }
  }

  /// Delete App-owned scan/import copies. The user's original imported file is
  /// outside these roots and is never removed.
  func clearReportCache(fileManager: FileManager = .default) throws {
    for report in allMarkdownReports(fileManager: fileManager) {
      try removeOwnedReport(report, fileManager: fileManager)
    }
  }

  /// Migrate old global-retention caches to the current rule: one newest complete
  /// report for each system, volume or folder target. Incomplete App-owned files
  /// are discarded because they cannot be loaded safely.
  func pruneReportCacheKeepingLatestPerTarget(
    preservingTargets: [ScanTarget] = [],
    fileManager: FileManager = .default
  ) throws {
    let reports = allMarkdownReports(fileManager: fileManager)
    var records: [ReportRecord] = []

    for report in reports {
      do {
        let record = try inspectRecord(
          report,
          isImported: isInside(report, root: importsURL),
          fileManager: fileManager
        )
        records.append(record)
      } catch ReportLibraryError.incompleteReport(_) {
        // A report can briefly exist before its final completion marker is written.
        // Keep recent files so a manual history refresh cannot race an active scan;
        // abandoned partial reports are removed only after a conservative grace period.
        if modificationDate(report) < Date().addingTimeInterval(-24 * 60 * 60) {
          try removeOwnedReport(report, fileManager: fileManager)
        }
      } catch {
        try removeOwnedReport(report, fileManager: fileManager)
      }
    }

    let volumeAliases = unambiguousVolumeAliases(in: records)
    var groups: [String: [ReportRecord]] = [:]
    for record in records {
      groups[canonicalRetentionKey(for: record, volumeAliases: volumeAliases), default: []]
        .append(record)
    }

    for records in groups.values {
      let sorted = records.sorted { lhs, rhs in
        if lhs.modifiedAt == rhs.modifiedAt {
          return lhs.target.kind == .volume && rhs.target.kind != .volume
        }
        return lhs.modifiedAt > rhs.modifiedAt
      }
      for record in sorted.dropFirst() {
        try removeOwnedReport(record.url, fileManager: fileManager)
      }
    }

    try enforceNonSystemLocationLimit(
      preservingTargets: preservingTargets,
      fileManager: fileManager
    )
  }

  /// Retain the completed report and remove only older reports for the same
  /// logical location. Reports for other disks and folders remain available.
  func keepLatestReportForLocation(
    _ reportToKeep: URL,
    fileManager: FileManager = .default
  ) throws {
    let keep = reportToKeep.resolvingSymlinksInPath().standardizedFileURL
    guard isOwnedReport(keep) else {
      throw ReportLibraryError.unsafeReportPath(reportToKeep.path)
    }

    let recordToKeep = try inspectRecord(
      reportToKeep,
      isImported: isInside(reportToKeep, root: importsURL),
      fileManager: fileManager
    )
    let records = reportRecords(fileManager: fileManager)
    let volumeAliases = unambiguousVolumeAliases(in: records)
    let keepKey = canonicalRetentionKey(for: recordToKeep, volumeAliases: volumeAliases)
    for record in records {
      let candidate = record.url.resolvingSymlinksInPath().standardizedFileURL
      if candidate != keep,
        canonicalRetentionKey(for: record, volumeAliases: volumeAliases) == keepKey
      {
        try removeOwnedReport(record.url, fileManager: fileManager)
      }
    }

    try enforceNonSystemLocationLimit(
      preservingTargets: [recordToKeep.target],
      fileManager: fileManager
    )
  }

  private func enforceNonSystemLocationLimit(
    preservingTargets: [ScanTarget],
    fileManager: FileManager
  ) throws {
    let records = reportRecords(fileManager: fileManager)
    let nonSystem = records.filter { $0.target.kind != .system }
    let volumeAliases = unambiguousVolumeAliases(in: records)
    let locationKeys = Set(
      nonSystem.map { canonicalRetentionKey(for: $0, volumeAliases: volumeAliases) }
    )
    guard locationKeys.count > ReportRetentionPolicy.maximumNonSystemLocations else { return }

    let protectedKeys = Set(
      preservingTargets
        .filter { $0.kind != .system }
        .map { canonicalRetentionKey(for: $0, volumeAliases: volumeAliases) }
    )
    var keepKeys = Set<String>()

    // Preserve requested targets first, but still respect the hard upper bound.
    for record in nonSystem {
      let key = canonicalRetentionKey(for: record, volumeAliases: volumeAliases)
      guard protectedKeys.contains(key) else { continue }
      guard keepKeys.count < ReportRetentionPolicy.maximumNonSystemLocations else { break }
      keepKeys.insert(key)
    }

    // Fill the remaining slots from newest to oldest.
    for record in nonSystem {
      guard keepKeys.count < ReportRetentionPolicy.maximumNonSystemLocations else { break }
      keepKeys.insert(canonicalRetentionKey(for: record, volumeAliases: volumeAliases))
    }

    for record in nonSystem
    where !keepKeys.contains(canonicalRetentionKey(for: record, volumeAliases: volumeAliases)) {
      try removeOwnedReport(record.url, fileManager: fileManager)
    }
  }

  /// A volume root can historically appear as both a folder target and a volume
  /// target. Merge those records only when the mount path maps to one unambiguous
  /// volume identity; two different cards that reused the same mount name must
  /// remain separate.
  private func unambiguousVolumeAliases(
    in records: [ReportRecord]
  ) -> [String: String] {
    var keysByPath: [String: Set<String>] = [:]
    for record in records where record.target.kind == .volume {
      keysByPath[record.target.normalizedReportPath, default: []].insert(record.targetKey)
    }
    var result: [String: String] = [:]
    for (path, keys) in keysByPath where keys.count == 1 {
      result[path] = keys.first
    }
    return result
  }

  private func canonicalRetentionKey(
    for record: ReportRecord,
    volumeAliases: [String: String]
  ) -> String {
    canonicalRetentionKey(for: record.target, volumeAliases: volumeAliases)
  }

  private func canonicalRetentionKey(
    for target: ScanTarget,
    volumeAliases: [String: String]
  ) -> String {
    if target.kind == .folder,
      let volumeKey = volumeAliases[target.normalizedReportPath]
    {
      return volumeKey
    }
    return target.reportRetentionKey
  }

  private func inspectRecord(
    _ url: URL,
    isImported: Bool,
    fileManager: FileManager
  ) throws -> ReportRecord {
    guard isCompletedReport(url) else {
      throw ReportLibraryError.incompleteReport(url.path)
    }
    guard let prefix = readPrefix(url), !prefix.isEmpty else {
      throw ReportLibraryError.unreadableReport(url.path)
    }

    let fields = keyValueFields(in: prefix)
    let kind = ScanTargetKind(rawValue: fields["scan_target_kind"] ?? "") ?? .system
    let defaultPath = kind == .system ? ScanTarget.systemStorage.path : "/"
    let path = nonempty(fields["scan_target_path"]) ?? defaultPath
    let defaultName: String
    switch kind {
    case .system:
      defaultName = ScanTarget.systemStorage.displayName
    case .volume, .folder:
      let candidate = URL(fileURLWithPath: path).lastPathComponent
      defaultName = candidate.isEmpty ? path : candidate
    }
    let displayName = nonempty(fields["scan_target_display_name"]) ?? defaultName
    let rawUUID = nonempty(fields["scan_target_volume_uuid"])
    let volumeUUID = rawUUID?.caseInsensitiveCompare("NONE") == .orderedSame ? nil : rawUUID
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])

    return ReportRecord(
      url: url,
      target: ScanTarget(
        kind: kind,
        displayName: displayName,
        path: path,
        volumeUUID: volumeUUID
      ),
      scannerVersion: nonempty(fields["scanner_version"]) ?? "未知",
      generatedAt: nonempty(fields["generated_at"]) ?? "未知",
      fileSize: Int64(values?.fileSize ?? 0),
      modifiedAt: values?.contentModificationDate ?? .distantPast,
      isImported: isImported
    )
  }

  private func keyValueFields(in text: String) -> [String: String] {
    var result: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2 else { continue }
      let key = String(pair[0]).trimmingCharacters(in: .whitespacesAndNewlines)
      let value = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
      result[key] = value
    }
    return result
  }

  private func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func readPrefix(_ url: URL, maximumBytes: Int = 131_072) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    do {
      let data = try handle.read(upToCount: maximumBytes) ?? Data()
      return String(decoding: data, as: UTF8.self)
    } catch {
      return nil
    }
  }

  private func isCompletedReport(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    do {
      let size = try handle.seekToEnd()
      try handle.seek(toOffset: size > 131_072 ? size - 131_072 : 0)
      let data = try handle.readToEnd() ?? Data()
      let text = String(decoding: data, as: UTF8.self)
      return text.split(whereSeparator: \.isNewline).contains("report_complete=true")
    } catch {
      return false
    }
  }

  private func uniqueDestination(
    directory: URL,
    baseName: String,
    fileManager: FileManager
  ) -> URL {
    let sanitized = baseName.replacingOccurrences(of: "/", with: "-")
    var destination = directory.appendingPathComponent(sanitized).appendingPathExtension("md")
    var suffix = 2
    while fileManager.fileExists(atPath: destination.path) {
      destination = directory.appendingPathComponent("\(sanitized)-\(suffix)")
        .appendingPathExtension("md")
      suffix += 1
    }
    return destination
  }

  private func allMarkdownReports(fileManager: FileManager) -> [URL] {
    markdownReports(in: scansURL, fileManager: fileManager)
      + markdownReports(in: importsURL, fileManager: fileManager)
  }

  func pruneScanDiagnostics(fileManager: FileManager = .default) throws {
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    let keys: Set<URLResourceKey> = [
      .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey,
    ]
    let children = try fileManager.contentsOfDirectory(
      at: scanWorkURL,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles]
    )
    let root = scanWorkURL.standardizedFileURL.path + "/"
    let directories = children.compactMap { child -> (URL, Date)? in
      let values = try? child.resourceValues(forKeys: keys)
      guard values?.isDirectory == true, values?.isSymbolicLink != true else { return nil }
      let standardized = child.standardizedFileURL
      guard standardized.path.hasPrefix(root) else { return nil }
      return (standardized, values?.contentModificationDate ?? .distantPast)
    }
    .sorted { $0.1 > $1.1 }

    // Keep enough recent sessions to compare repeated scans without allowing the
    // diagnostics directory to grow indefinitely. Age and count limits both apply.
    for (index, item) in directories.enumerated()
    where item.1 < cutoff || index >= 12 {
      try? fileManager.removeItem(at: item.0)
    }
  }

  func pruneReportIndexes(fileManager: FileManager = .default) {
    guard
      let store = try? ReportPresentationIndexStore(
        directoryURL: reportIndexesURL,
        fileManager: fileManager
      )
    else { return }
    store.prune(
      keepingReportURLs: allMarkdownReports(fileManager: fileManager),
      fileManager: fileManager
    )
  }

  private func markdownReports(in directory: URL, fileManager: FileManager) -> [URL] {
    let keys: Set<URLResourceKey> = [
      .contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
    ]
    return
      ((try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )) ?? [])
      .filter { url in
        guard url.pathExtension.lowercased() == "md" else { return false }
        let values = try? url.resourceValues(forKeys: keys)
        return values?.isRegularFile == true && values?.isSymbolicLink != true
      }
  }

  private func modificationDate(_ url: URL) -> Date {
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
    return values?.contentModificationDate ?? .distantPast
  }

  private func isOwnedReport(_ url: URL) -> Bool {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    let roots = [scansURL, importsURL].map {
      $0.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    }
    return resolved.pathExtension.lowercased() == "md"
      && roots.contains(where: { resolved.path.hasPrefix($0) })
  }

  private func isInside(_ url: URL, root: URL) -> Bool {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
    let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    return resolved.hasPrefix(rootPath)
  }

  private func removeOwnedReport(_ url: URL, fileManager: FileManager) throws {
    guard isOwnedReport(url) else {
      throw ReportLibraryError.unsafeReportPath(url.path)
    }
    if let store = try? ReportPresentationIndexStore(
      directoryURL: reportIndexesURL,
      fileManager: fileManager
    ) {
      store.remove(for: url, fileManager: fileManager)
    }
    try fileManager.removeItem(at: url)
  }
}
