import Foundation

enum ReportPresentationIndexError: LocalizedError {
  case invalidReport(String)
  case unsafeDirectory(String)

  var errorDescription: String? {
    switch self {
    case .invalidReport(let message):
      return "無法建立報告索引：\(message)"
    case .unsafeDirectory(let path):
      return "報告索引目錄不是安全的本機資料夾：\(path)"
    }
  }
}

struct ReportFileSignature: Codable, Hashable {
  let byteCount: UInt64
  let modificationNanoseconds: Int64
  let sampledFNV1A64: String

  static func read(
    from url: URL,
    fileManager: FileManager = .default,
    sampleBytes: Int = 64 * 1024
  ) throws -> ReportFileSignature {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    let values = try resolved.resourceValues(forKeys: [
      .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw ReportPresentationIndexError.invalidReport("報告不是一般檔案：\(url.path)")
    }

    let byteCount = UInt64(max(0, values.fileSize ?? 0))
    let modificationDate = values.contentModificationDate ?? .distantPast
    let modificationNanoseconds = Int64(
      (modificationDate.timeIntervalSince1970 * 1_000_000_000).rounded()
    )

    let handle = try FileHandle(forReadingFrom: resolved)
    defer { try? handle.close() }

    var hash: UInt64 = 14_695_981_039_346_656_037
    var byteCountLE = byteCount.littleEndian
    withUnsafeBytes(of: &byteCountLE) { updateFNV(&hash, bytes: $0) }
    var modificationLE = modificationNanoseconds.littleEndian
    withUnsafeBytes(of: &modificationLE) { updateFNV(&hash, bytes: $0) }

    let safeSampleBytes = max(0, sampleBytes)
    let headCount = Int(min(byteCount, UInt64(safeSampleBytes)))
    if headCount > 0 {
      let head = try handle.read(upToCount: headCount) ?? Data()
      updateFNV(&hash, bytes: head)
    }

    if byteCount > UInt64(headCount), safeSampleBytes > 0 {
      let middleCount = Int(min(byteCount, UInt64(safeSampleBytes)))
      let middleOffset =
        byteCount > UInt64(middleCount)
        ? (byteCount - UInt64(middleCount)) / 2
        : 0
      try handle.seek(toOffset: middleOffset)
      let middle = try handle.read(upToCount: middleCount) ?? Data()
      updateFNV(&hash, bytes: middle)

      let tailCount = Int(min(byteCount, UInt64(safeSampleBytes)))
      try handle.seek(toOffset: byteCount - UInt64(tailCount))
      let tail = try handle.read(upToCount: tailCount) ?? Data()
      updateFNV(&hash, bytes: tail)
    }

    return ReportFileSignature(
      byteCount: byteCount,
      modificationNanoseconds: modificationNanoseconds,
      sampledFNV1A64: String(format: "%016llx", hash)
    )
  }

  private static func updateFNV<C: Collection>(_ hash: inout UInt64, bytes: C)
  where C.Element == UInt8 {
    for byte in bytes {
      hash ^= UInt64(byte)
      hash = hash &* 1_099_511_628_211
    }
  }
}

struct ReportPresentationIndexPayload: Codable, Hashable {
  static let currentSchemaVersion = 2
  static let currentParserSchema = "report-presentation-1.7.0-v1"

  let schemaVersion: Int
  let parserSchema: String
  let reportPath: String
  let reportSignature: ReportFileSignature
  let createdAt: Date
  let summary: ScanSummary
  let sections: [String: SectionRange]
  let topLevelNodes: [String: [StorageNode]]
  let initialPresentation: ReportInitialPresentation

  init(
    reportURL: URL,
    reportSignature: ReportFileSignature,
    document: ReportDocument,
    initialPresentation: ReportInitialPresentation,
    createdAt: Date = Date()
  ) {
    schemaVersion = Self.currentSchemaVersion
    parserSchema = Self.currentParserSchema
    reportPath = reportURL.resolvingSymlinksInPath().standardizedFileURL.path
    self.reportSignature = reportSignature
    self.createdAt = createdAt
    summary = document.summary
    sections = document.sections
    topLevelNodes = document.topLevelNodes
    self.initialPresentation = initialPresentation
  }

  func document(for reportURL: URL) -> ReportDocument {
    ReportDocument(
      url: reportURL,
      summary: summary,
      sections: sections,
      topLevelNodes: topLevelNodes,
      initialPresentation: initialPresentation
    )
  }

  func isValid(for reportURL: URL, signature: ReportFileSignature) -> Bool {
    let expectedRoot =
      summary.targetKind == .system ? "/System/Volumes/Data" : summary.targetPath
    guard schemaVersion == Self.currentSchemaVersion,
      parserSchema == Self.currentParserSchema,
      reportPath == reportURL.resolvingSymlinksInPath().standardizedFileURL.path,
      reportSignature == signature,
      summary.reportComplete,
      !sections.isEmpty,
      sections.count <= 128,
      initialPresentation.rootPath == expectedRoot,
      sections[initialPresentation.rootPath] != nil,
      initialPresentation.maximumDepth == SunburstPresentationPolicy.maximumDepth,
      initialPresentation.maximumChildren
        == SunburstPresentationPolicy.visibleChildBudgetWhenAggregated,
      initialPresentation.children == (topLevelNodes[initialPresentation.rootPath] ?? []),
      initialPresentation.sunburst.id == expectedRoot,
      initialPresentation.sunburst.path == expectedRoot
    else { return false }

    for (root, range) in sections {
      guard root == range.root, root.hasPrefix("/"), range.startOffset < range.endOffset,
        range.endOffset <= signature.byteCount
      else { return false }
    }

    for (root, nodes) in topLevelNodes {
      guard sections[root] != nil, nodes.count <= 4_096 else { return false }
      guard
        nodes.allSatisfy({ node in
          !node.isVirtual && node.allocatedKiB >= 0 && node.path.hasPrefix("/")
            && node.parentPath == root
        })
      else { return false }
    }

    var nodeCount = 0
    func validatePresentation(_ item: SunburstItem, depth: Int) -> Bool {
      nodeCount += 1
      guard nodeCount <= 250_000, item.bytes >= 0,
        item.children.count <= SunburstPresentationPolicy.automaticAggregationThreshold + 2
      else { return false }

      if let path = item.path {
        let prefix = expectedRoot == "/" ? "/" : expectedRoot + "/"
        guard path == expectedRoot || path.hasPrefix(prefix) else { return false }
      }

      if item.kind == nil {
        guard depth <= initialPresentation.maximumDepth else { return false }
      } else if !item.children.isEmpty {
        return false
      }

      var representedBytes: Int64 = 0
      for child in item.children {
        let addition = representedBytes.addingReportingOverflow(child.bytes)
        guard !addition.overflow else { return false }
        representedBytes = addition.partialValue
        guard validatePresentation(child, depth: depth + 1) else { return false }
      }
      return representedBytes <= item.bytes
    }

    return validatePresentation(initialPresentation.sunburst, depth: 0)
  }
}

struct ReportPresentationIndexStore {
  let directoryURL: URL

  init(directoryURL: URL, fileManager: FileManager = .default) throws {
    self.directoryURL = directoryURL.standardizedFileURL
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: self.directoryURL.path, isDirectory: &isDirectory) {
      let values = try self.directoryURL.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ])
      guard isDirectory.boolValue, values.isDirectory == true, values.isSymbolicLink != true else {
        throw ReportPresentationIndexError.unsafeDirectory(self.directoryURL.path)
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
    for reportURL: URL,
    fileManager: FileManager = .default
  ) throws -> ReportPresentationIndexPayload? {
    let indexURL = indexURL(for: reportURL)
    guard fileManager.fileExists(atPath: indexURL.path) else { return nil }

    let values = try? indexURL.resourceValues(forKeys: [
      .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard values?.isRegularFile == true, values?.isSymbolicLink != true,
      (values?.fileSize ?? 0) <= 16 * 1024 * 1024
    else {
      try? fileManager.removeItem(at: indexURL)
      return nil
    }

    do {
      let signature = try ReportFileSignature.read(from: reportURL, fileManager: fileManager)
      let data = try Data(contentsOf: indexURL, options: [.mappedIfSafe])
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .millisecondsSince1970
      let payload = try decoder.decode(ReportPresentationIndexPayload.self, from: data)
      guard payload.isValid(for: reportURL, signature: signature) else {
        try? fileManager.removeItem(at: indexURL)
        return nil
      }
      return payload
    } catch {
      try? fileManager.removeItem(at: indexURL)
      return nil
    }
  }

  @discardableResult
  func save(
    document: ReportDocument,
    for reportURL: URL,
    fileManager: FileManager = .default
  ) throws -> URL? {
    guard let initialPresentation = document.initialPresentation else { return nil }
    let signature = try ReportFileSignature.read(from: reportURL, fileManager: fileManager)
    let payload = ReportPresentationIndexPayload(
      reportURL: reportURL,
      reportSignature: signature,
      document: document,
      initialPresentation: initialPresentation
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(payload)
    let destination = indexURL(for: reportURL)
    try data.write(to: destination, options: .atomic)
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    return destination
  }

  func remove(for reportURL: URL, fileManager: FileManager = .default) {
    try? fileManager.removeItem(at: indexURL(for: reportURL))
  }

  func prune(
    keepingReportURLs reportURLs: [URL],
    fileManager: FileManager = .default
  ) {
    let validPaths = Set(
      reportURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
    )
    let children =
      (try? fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )) ?? []

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    for child in children where child.pathExtension.lowercased() == "json" {
      let values = try? child.resourceValues(forKeys: [
        .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      guard values?.isRegularFile == true, values?.isSymbolicLink != true,
        (values?.fileSize ?? 0) <= 16 * 1024 * 1024
      else {
        try? fileManager.removeItem(at: child)
        continue
      }
      guard let data = try? Data(contentsOf: child),
        let payload = try? decoder.decode(ReportPresentationIndexPayload.self, from: data),
        validPaths.contains(payload.reportPath)
      else {
        try? fileManager.removeItem(at: child)
        continue
      }
    }
  }

  func indexURL(for reportURL: URL) -> URL {
    let reportPath = reportURL.resolvingSymlinksInPath().standardizedFileURL.path
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in reportPath.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 1_099_511_628_211
    }
    let base = reportURL.deletingPathExtension().lastPathComponent
      .replacingOccurrences(of: "/", with: "-")
    return
      directoryURL
      .appendingPathComponent("\(base)-\(String(format: "%016llx", hash))")
      .appendingPathExtension("presentation-index.json")
  }
}
