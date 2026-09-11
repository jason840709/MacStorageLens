import Foundation

private struct LineRecord {
  let text: String
  let startOffset: UInt64
  let endOffset: UInt64
}

private final class UTF8LineReader {
  private let handle: FileHandle
  private var buffer = Data()
  private var cursor = 0
  private var bufferFileOffset: UInt64
  private var reachedEOF = false
  private let chunkSize = 4 * 1024 * 1024

  init(url: URL, offset: UInt64 = 0) throws {
    handle = try FileHandle(forReadingFrom: url)
    bufferFileOffset = offset
    if offset > 0 {
      try handle.seek(toOffset: offset)
    }
  }

  deinit {
    try? handle.close()
  }

  func nextLine() throws -> LineRecord? {
    while true {
      if cursor < buffer.count,
        let newline = buffer[cursor...].firstIndex(of: 0x0A)
      {
        let lineStart = cursor
        let lineEnd = newline
        let consumedEnd = newline + 1
        let start = bufferFileOffset + UInt64(lineStart)
        let end = bufferFileOffset + UInt64(consumedEnd)
        let text = decode(buffer[lineStart..<lineEnd])
        cursor = consumedEnd
        compactIfNeeded()
        return LineRecord(text: text, startOffset: start, endOffset: end)
      }

      if reachedEOF {
        guard cursor < buffer.count else { return nil }
        let lineStart = cursor
        let lineEnd = buffer.count
        let start = bufferFileOffset + UInt64(lineStart)
        let end = bufferFileOffset + UInt64(lineEnd)
        let text = decode(buffer[lineStart..<lineEnd])
        cursor = lineEnd
        compactIfNeeded(force: true)
        return LineRecord(text: text, startOffset: start, endOffset: end)
      }

      if cursor > 0 {
        compactIfNeeded(force: true)
      }
      let chunk = try handle.read(upToCount: chunkSize) ?? Data()
      if chunk.isEmpty {
        reachedEOF = true
      } else {
        buffer.append(chunk)
      }
    }
  }

  private func compactIfNeeded(force: Bool = false) {
    guard cursor > 0, force || cursor >= chunkSize else { return }
    buffer.removeSubrange(0..<cursor)
    bufferFileOffset += UInt64(cursor)
    cursor = 0
  }

  private func decode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
    var value = String(decoding: bytes, as: UTF8.self)
    if value.last == "\r" { value.removeLast() }
    return value
  }
}

enum ReportParserError: LocalizedError {
  case invalidReport(String)
  case missingSection(String)

  var errorDescription: String? {
    switch self {
    case .invalidReport(let message): return "掃描報告格式無法辨識：\(message)"
    case .missingSection(let path): return "找不到路徑所屬的資料樹區段：\(path)"
    }
  }
}

private enum DFPhase {
  case pre
  case post
}

private struct DFRow {
  let capacityKiB: Int64
  let usedKiB: Int64
  let availableKiB: Int64
  let mountPoint: String
}

private struct APFSVolumeBuilder {
  var deviceIdentifier = ""
  var role = ""
  var name = ""
  var mountPoint: String?
  var consumedBytes: Int64 = 0

  var record: APFSVolumeRecord? {
    guard !deviceIdentifier.isEmpty, consumedBytes >= 0 else { return nil }
    return APFSVolumeRecord(
      deviceIdentifier: deviceIdentifier,
      role: role,
      name: name.isEmpty ? (role.isEmpty ? deviceIdentifier : role) : name,
      mountPoint: mountPoint,
      consumedBytes: consumedBytes
    )
  }
}

struct ReportParseProgress: Hashable {
  let fraction: Double
  let processedBytes: UInt64
  let totalBytes: UInt64
  let stage: String

  init(fraction: Double, processedBytes: UInt64, totalBytes: UInt64, stage: String) {
    self.fraction = min(1, max(0, fraction))
    self.processedBytes = processedBytes
    self.totalBytes = totalBytes
    self.stage = stage
  }
}

private struct APFSContainerBuilder {
  var reference = ""
  var totalBytes: Int64 = 0
  var usedBytes: Int64 = 0
  var freeBytes: Int64 = 0
  var volumes: [APFSVolumeRecord] = []

  var record: APFSContainerRecord? {
    guard !reference.isEmpty, totalBytes > 0 else { return nil }
    return APFSContainerRecord(
      reference: reference,
      totalBytes: totalBytes,
      usedBytes: max(0, usedBytes),
      freeBytes: max(0, freeBytes),
      volumes: volumes
    )
  }
}

final class ReportParser {
  func parse(
    url: URL,
    progress: ((ReportParseProgress) -> Void)? = nil
  ) throws -> ReportDocument {
    var summary = ScanSummary()
    var sections: [String: SectionRange] = [:]
    var topLevel: [String: [StorageNode]] = [:]
    var currentH2 = ""
    var snapshotSet = Set<String>()
    var dfPhase: DFPhase?
    var preDFRows: [DFRow] = []
    var postDFRows: [DFRow] = []

    var pendingTreeRoot: String?
    var activeTreeRoot: String?
    var activeTreeStart: UInt64?
    let initialMaximumDepth = SunburstPresentationPolicy.maximumDepth
    let initialMaximumChildren = SunburstPresentationPolicy.visibleChildBudgetWhenAggregated
    var initialPresentationRoot: String?
    var initialPresentationRecords: [String: StorageNode] = [:]

    var inAPFSList = false
    var apfsContainers: [APFSContainerRecord] = []
    var currentContainer: APFSContainerBuilder?
    var currentVolume: APFSVolumeBuilder?

    func finishVolume() {
      guard let volume = currentVolume?.record else {
        currentVolume = nil
        return
      }
      currentContainer?.volumes.append(volume)
      currentVolume = nil
    }

    func finishContainer() {
      finishVolume()
      if let container = currentContainer?.record {
        apfsContainers.append(container)
      }
      currentContainer = nil
    }

    let totalBytes = UInt64(
      max(0, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    )
    let progressStep = UInt64(8 * 1024 * 1024)
    var nextProgressOffset = progressStep
    progress?(
      ReportParseProgress(
        fraction: 0,
        processedBytes: 0,
        totalBytes: totalBytes,
        stage: "讀取報告索引"
      )
    )

    let reader = try UTF8LineReader(url: url)
    while let record = try reader.nextLine() {
      if record.endOffset >= nextProgressOffset {
        let fraction =
          totalBytes > 0
          ? min(0.96, Double(record.endOffset) / Double(totalBytes) * 0.96)
          : 0
        progress?(
          ReportParseProgress(
            fraction: fraction,
            processedBytes: record.endOffset,
            totalBytes: totalBytes,
            stage: "讀取報告索引"
          )
        )
        nextProgressOffset = record.endOffset + progressStep
      }
      let line = record.text

      if line.hasPrefix("## ") {
        if inAPFSList {
          finishContainer()
          inAPFSList = false
        }
        currentH2 = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        dfPhase = nil
      }

      if line.hasPrefix("--- ") {
        if line.contains("df -kP") {
          if currentH2 == "PRE_SCAN_ACCOUNTING_AND_SNAPSHOTS" {
            dfPhase = .pre
          } else if currentH2 == "POST_SCAN_VOLUME_AND_APFS_STATUS" {
            dfPhase = .post
          }
        } else {
          dfPhase = nil
        }

        let startsAPFSList =
          line.contains("APFS")
          && (line.contains("容器") || line.localizedCaseInsensitiveContains("container"))
          && (line.contains("卷") || line.localizedCaseInsensitiveContains("volume"))
        if startsAPFSList {
          finishContainer()
          inAPFSList = true
        } else if inAPFSList {
          finishContainer()
          inAPFSList = false
        }
      }

      if line.hasPrefix("### DIRECTORY_TREE (") && line.hasSuffix(")") {
        let prefix = "### DIRECTORY_TREE ("
        let root = String(line.dropFirst(prefix.count).dropLast())
        pendingTreeRoot = root
        continue
      }

      if let pending = pendingTreeRoot, line.hasPrefix("```") {
        activeTreeRoot = pending
        activeTreeStart = record.endOffset
        pendingTreeRoot = nil
        topLevel[pending] = []

        let preferredRoot =
          summary.targetKind == .system ? "/System/Volumes/Data" : summary.targetPath
        if pending == preferredRoot {
          initialPresentationRoot = pending
          initialPresentationRecords.removeAll(keepingCapacity: true)
        }
        continue
      }

      if let activeRoot = activeTreeRoot {
        if line.hasPrefix("```") {
          if let start = activeTreeStart {
            sections[activeRoot] = SectionRange(
              root: activeRoot, startOffset: start, endOffset: record.startOffset)
          }
          activeTreeRoot = nil
          activeTreeStart = nil
          continue
        }

        let indexedDepth = initialPresentationRoot == activeRoot ? initialMaximumDepth : 1
        let visualDepth = renderedTreeDepth(line)
        if let visualDepth, visualDepth > indexedDepth { continue }
        guard let fields = parseTreeLineComponents(line) else { continue }
        let path = String(line[fields.pathRange])
        let belongsToRoot =
          activeRoot == "/"
          ? path.hasPrefix("/")
          : (path == activeRoot || path.hasPrefix(activeRoot + "/"))
        guard belongsToRoot else { continue }
        let relativeDepth: Int
        if let visualDepth, visualDepth > 0 || path == activeRoot {
          relativeDepth = visualDepth
        } else {
          guard
            let legacyDepth = treeDepth(
              line,
              path: path,
              rootPath: activeRoot,
              maximum: indexedDepth
            )
          else { continue }
          relativeDepth = legacyDepth
        }
        let node = StorageNode(path: path, allocatedKiB: fields.allocatedKiB)
        if relativeDepth == 1 {
          topLevel[activeRoot, default: []].append(node)
        }
        if initialPresentationRoot == activeRoot, relativeDepth <= initialMaximumDepth {
          initialPresentationRecords[path] = node
        }
        continue
      }

      if line == "report_complete=true" {
        summary.reportComplete = true
      }

      if let phase = dfPhase, let row = parseDFRow(line) {
        switch phase {
        case .pre: preDFRows.append(row)
        case .post: postDFRows.append(row)
        }
      } else if dfPhase != nil, line.hasPrefix("exit_status=") {
        dfPhase = nil
      }

      if inAPFSList {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let value = valueAfterColon(trimmed, key: "APFS Container Reference") {
          finishContainer()
          currentContainer = APFSContainerBuilder(reference: value)
        } else if let value = byteValueAfterColon(trimmed, key: "Size (Capacity Ceiling)") {
          currentContainer?.totalBytes = value
        } else if let value = byteValueAfterColon(trimmed, key: "Capacity In Use By Volumes") {
          currentContainer?.usedBytes = value
        } else if let value = byteValueAfterColon(trimmed, key: "Capacity Not Allocated") {
          currentContainer?.freeBytes = value
        } else if let value = valueAfterColon(trimmed, key: "APFS Volume Disk (Role)") {
          finishVolume()
          let components = value.split(separator: " ", maxSplits: 1).map(String.init)
          var role = ""
          if let open = value.firstIndex(of: "("), let close = value[open...].firstIndex(of: ")") {
            role = String(value[value.index(after: open)..<close])
          }
          currentVolume = APFSVolumeBuilder(
            deviceIdentifier: components.first ?? "",
            role: role,
            name: "",
            mountPoint: nil,
            consumedBytes: 0
          )
        } else if let value = valueAfterColon(trimmed, key: "Name"), currentVolume != nil {
          currentVolume?.name = stripCaseSensitivitySuffix(value)
        } else if let value = valueAfterColon(trimmed, key: "Mount Point"), currentVolume != nil {
          currentVolume?.mountPoint = value == "Not Mounted" ? nil : value
        } else if let value = byteValueAfterColon(trimmed, key: "Capacity Consumed"),
          currentVolume != nil
        {
          currentVolume?.consumedBytes = value
        }
      }

      switch currentH2 {
      case "RUN_METADATA":
        if let (key, value) = parseKeyValue(line) {
          switch key {
          case "scanner_version": summary.scannerVersion = value
          case "generated_at": summary.generatedAt = value
          case "full_disk_access_probe": summary.fullDiskAccessProbe = value
          case "full_disk_access_probe_path": summary.fullDiskAccessProbePath = value
          case "full_disk_access_source": summary.fullDiskAccessSource = value
          case "app_full_disk_access_probe": summary.appFullDiskAccessProbe = value
          case "app_full_disk_access_probe_path": summary.appFullDiskAccessProbePath = value
          case "scanner_full_disk_access_probe": summary.scannerFullDiskAccessProbe = value
          case "scanner_full_disk_access_probe_path": summary.scannerFullDiskAccessProbePath = value
          case "scanner_privilege_channel": summary.scannerPrivilegeChannel = value
          case "tcc_overlay_status": summary.tccOverlayStatus = value
          case "tcc_overlay_root": summary.tccOverlayRoot = value
          case "tcc_overlay_applied": summary.tccOverlayApplied = value == "true"
          case "tcc_overlay_delta_kib": summary.tccOverlayDeltaKiB = Int64(value) ?? 0
          case "tcc_overlay_tree_kib": summary.tccOverlayTreeKiB = Int64(value) ?? 0
          case "tcc_overlay_replaced_kib": summary.tccOverlayReplacedKiB = Int64(value) ?? 0
          case "administrator_read_access": summary.administratorReadAccess = value == "true"
          case "du_error_line_count":
            summary.duErrorLineCount = Int(value) ?? summary.duErrorLineCount
          case "permission_or_tcc_error_count":
            summary.errorCount = Int(value) ?? summary.errorCount
          case "path_scan_status": summary.pathScanStatus = value
          case "scan_target_kind", "target_kind":
            if let kind = ScanTargetKind(rawValue: value) { summary.targetKind = kind }
          case "scan_target_path", "target_path": summary.targetPath = value
          case "scan_target_display_name", "scan_target_name", "target_display_name":
            summary.targetDisplayName = value
          case "scan_target_volume_uuid", "target_volume_uuid":
            summary.targetVolumeUUID = value.isEmpty || value == "NONE" ? nil : value
          case "target_mount_point": summary.targetMountPoint = value
          case "target_filesystem_type": summary.targetFilesystemType = value
          case "target_spotlight_root_status": summary.targetSpotlightRootStatus = value
          case "target_fsevents_root_status": summary.targetFSEventsRootStatus = value
          case "target_trash_root_status": summary.targetTrashRootStatus = value
          case "preflight_duration_seconds": summary.preflightDurationSeconds = Int(value) ?? 0
          case "prepare_duration_seconds": summary.prepareDurationSeconds = Int(value) ?? 0
          case "path_scan_duration_seconds": summary.pathScanDurationSeconds = Int(value) ?? 0
          case "metadata_duration_seconds": summary.metadataDurationSeconds = Int(value) ?? 0
          case "launcher_mode": summary.launcherMode = value
          case "volume_scan_profile": summary.volumeScanProfile = value
          case "volume_volatile_metadata_excluded":
            summary.volumeVolatileMetadataExcluded = value == "true"
          case "volume_volatile_metadata_names":
            summary.volumeVolatileMetadataNames = value.split(separator: ",").map(String.init)
          default: break
          }
        }

      case "DATA_VOLUME_ACCOUNTING_DIFFERENCE":
        if let (key, value) = parseKeyValue(line), let number = Int64(value) {
          switch key {
          case "data_volume_du_kib": summary.dataVolumeDUKiB = number
          case "data_volume_df_used_kib_pre_scan": summary.dataVolumeDFUsedKiB = number
          case "data_volume_df_used_kib_post_scan_before_report":
            summary.dataVolumeDFUsedPostKiB = number
          case "post_minus_pre_kib": summary.dataVolumeScanDeltaKiB = number
          case "df_pre_used_minus_du_kib": summary.accountingGapKiB = number
          default: break
          }
        }

      case "TARGET_VOLUME_ACCOUNTING_DIFFERENCE", "TARGET_ACCOUNTING_DIFFERENCE":
        if let (key, value) = parseKeyValue(line) {
          switch key {
          case "accounting_scope": summary.accountingScope = value
          case "accounting_gap_applicable": summary.accountingGapApplicable = value == "true"
          case "target_tree_du_kib": summary.targetTreeDUKiB = Int64(value) ?? 0
          case "target_volume_capacity_kib", "target_volume_df_capacity_kib_pre_scan":
            summary.targetVolumeCapacityKiB = Int64(value) ?? 0
          case "target_volume_used_kib_pre_scan", "target_volume_df_used_kib_pre_scan":
            summary.targetVolumeUsedKiB = Int64(value) ?? 0
          case "target_volume_available_kib_pre_scan", "target_volume_df_available_kib_pre_scan":
            summary.targetVolumeAvailableKiB = Int64(value) ?? 0
          case "target_volume_used_kib_post_scan", "target_volume_used_kib_post_scan_before_report",
            "target_volume_df_used_kib_post_scan",
            "target_volume_df_used_kib_post_scan_before_report":
            summary.targetVolumeUsedPostKiB = Int64(value) ?? 0
          case "target_post_minus_pre_kib":
            let delta = Int64(value) ?? 0
            summary.targetVolumeUsedPostKiB = summary.targetVolumeUsedKiB + delta
          case "target_accounting_gap_kib", "target_df_pre_used_minus_du_kib",
            "df_pre_used_minus_tree_kib":
            summary.targetAccountingGapKiB = Int64(value) ?? 0
          default: break
          }
        }

      case "CONTENT_CACHE_KEY_PATH":
        if let (key, value) = parseKeyValue(line), key == "du_kib" {
          summary.contentCacheKiB = Int64(value) ?? 0
        }

      case "ROOT_SCAN_SUMMARY":
        if let rootSummary = parseRootSummaryRow(line) {
          summary.rootSummaries.append(rootSummary)
        }

      case "COMPLETION":
        if let (key, value) = parseKeyValue(line) {
          switch key {
          case "total_duration_seconds": summary.totalDurationSeconds = Int(value) ?? 0
          case "report_write_duration_seconds": summary.reportWriteDurationSeconds = Int(value) ?? 0
          default: break
          }
        }

      default:
        break
      }

      if let name = parseSnapshotName(line) {
        snapshotSet.insert(name)
      }
    }

    if inAPFSList || currentContainer != nil {
      finishContainer()
    }

    summary.snapshotNames = snapshotSet.sorted()
    if summary.errorCount == 0 { summary.errorCount = summary.duErrorLineCount }
    for root in topLevel.keys {
      topLevel[root]?.sort(by: storageNodeOrder)
    }

    guard !sections.isEmpty else {
      throw ReportParserError.invalidReport("沒有 DIRECTORY_TREE 區段")
    }

    if summary.targetPath.isEmpty {
      summary.targetPath = sections.keys.sorted().first ?? "/"
    }
    if summary.targetMountPoint.isEmpty {
      summary.targetMountPoint =
        summary.targetKind == .system ? "/System/Volumes/Data" : summary.targetPath
    }

    if summary.dataVolumeDUKiB == 0,
      let data = summary.rootSummaries.first(where: { $0.root == "/System/Volumes/Data" })
    {
      summary.dataVolumeDUKiB = data.duKiB
    }
    if summary.targetTreeDUKiB == 0,
      let targetRoot = summary.rootSummaries.first(where: { $0.root == summary.targetPath })
        ?? summary.rootSummaries.first
    {
      summary.targetTreeDUKiB = targetRoot.duKiB
    }

    applyDFRows(preDFRows, postRows: postDFRows, to: &summary)

    // Scanner 2.5.0 exposed only one probe. For an App-launched administrator
    // report that value belongs to the detached elevated shell, not necessarily
    // to MacStorageLens itself. Preserve it as scanner state and leave App state
    // unknown instead of accusing the user's App permission grant.
    if summary.scannerFullDiskAccessProbe == "UNKNOWN" {
      summary.scannerFullDiskAccessProbe = summary.fullDiskAccessProbe
      summary.scannerFullDiskAccessProbePath = summary.fullDiskAccessProbePath
    }
    if summary.appFullDiskAccessProbe == "UNKNOWN",
      summary.launcherMode == "app", !summary.administratorReadAccess
    {
      summary.appFullDiskAccessProbe = summary.fullDiskAccessProbe
      summary.appFullDiskAccessProbePath = summary.fullDiskAccessProbePath
    }

    summary.primaryAPFSContainer = selectPrimaryContainer(apfsContainers, summary: summary)

    if let container = summary.primaryAPFSContainer {
      if let data = container.volumes.first(where: {
        $0.role.caseInsensitiveCompare("Data") == .orderedSame
      }),
        summary.dataVolumeDFUsedKiB == 0
      {
        summary.dataVolumeDFUsedKiB = data.consumedBytes / 1024
      }
      if let system = container.volumes.first(where: {
        $0.role.caseInsensitiveCompare("System") == .orderedSame
      }) {
        summary.systemVolumeUsedKiB = system.consumedBytes / 1024
      }
      if let preboot = container.volumes.first(where: {
        $0.role.caseInsensitiveCompare("Preboot") == .orderedSame
      }) {
        summary.prebootVolumeUsedKiB = preboot.consumedBytes / 1024
      }
      if let recovery = container.volumes.first(where: {
        $0.role.caseInsensitiveCompare("Recovery") == .orderedSame
      }) {
        summary.recoveryVolumeUsedKiB = recovery.consumedBytes / 1024
      }
      if let vm = container.volumes.first(where: {
        $0.role.caseInsensitiveCompare("VM") == .orderedSame
      }) {
        summary.vmVolumeUsedKiB = vm.consumedBytes / 1024
      }
    }

    if summary.targetKind == .system {
      summary.targetPath =
        sections["/System/Volumes/Data"] != nil ? "/System/Volumes/Data" : summary.targetPath
      summary.targetMountPoint = "/System/Volumes/Data"
      if summary.targetDisplayName.isEmpty { summary.targetDisplayName = "Macintosh HD" }
      summary.targetTreeDUKiB = summary.dataVolumeDUKiB
      summary.targetVolumeCapacityKiB = summary.dataVolumeCapacityKiB
      summary.targetVolumeUsedKiB = summary.dataVolumeDFUsedKiB
      summary.targetVolumeAvailableKiB = summary.dataVolumeAvailableKiB
      summary.targetVolumeUsedPostKiB = summary.dataVolumeDFUsedPostKiB
      summary.targetAccountingGapKiB = summary.accountingGapKiB
      summary.accountingScope = "system"
      summary.accountingGapApplicable = true
    } else if summary.targetAccountingGapKiB == 0, summary.accountingGapApplicable {
      summary.targetAccountingGapKiB = max(0, summary.targetVolumeUsedKiB - summary.targetTreeDUKiB)
    }

    progress?(
      ReportParseProgress(
        fraction: 0.97,
        processedBytes: totalBytes,
        totalBytes: totalBytes,
        stage: "建立初始容量地圖"
      )
    )

    let finalInitialRoot =
      summary.targetKind == .system ? "/System/Volumes/Data" : summary.targetPath
    let initialPresentation: ReportInitialPresentation?
    if initialPresentationRoot == finalInitialRoot,
      initialPresentationRecords[finalInitialRoot] != nil
    {
      let built = try makePresentation(
        records: initialPresentationRecords,
        parentPath: finalInitialRoot,
        maximumDepth: initialMaximumDepth,
        maximumChildren: initialMaximumChildren
      )
      initialPresentation = ReportInitialPresentation(
        rootPath: finalInitialRoot,
        maximumDepth: initialMaximumDepth,
        maximumChildren: initialMaximumChildren,
        children: built.0,
        sunburst: built.1
      )
    } else {
      initialPresentation = nil
    }

    progress?(
      ReportParseProgress(
        fraction: 1,
        processedBytes: totalBytes,
        totalBytes: totalBytes,
        stage: "報告索引完成"
      )
    )

    return ReportDocument(
      url: url,
      summary: summary,
      sections: sections,
      topLevelNodes: topLevel,
      initialPresentation: initialPresentation
    )
  }

  func loadChildren(document: ReportDocument, parentPath: String) throws -> [StorageNode] {
    if let initial = document.initialPresentation, initial.rootPath == parentPath {
      return initial.children
    }
    guard let section = document.section(containing: parentPath) else {
      throw ReportParserError.missingSection(parentPath)
    }

    let reader = try UTF8LineReader(url: document.url, offset: section.startOffset)
    var parentRenderedDepth: Int?
    var children: [StorageNode] = []
    let parentSuffix = "  " + parentPath

    while let record = try reader.nextLine(), record.startOffset < section.endOffset {
      let line = record.text
      if parentRenderedDepth == nil {
        guard line.hasSuffix(parentSuffix), let fields = parseTreeLineComponents(line) else {
          continue
        }
        let path = String(line[fields.pathRange])
        guard path == parentPath,
          let depth = treeDepth(line, path: path, rootPath: section.root, maximum: nil)
        else { continue }
        parentRenderedDepth = depth
        continue
      }

      guard let parentRenderedDepth else { continue }
      if let visualDepth = renderedTreeDepth(line), visualDepth > 0 {
        if visualDepth <= parentRenderedDepth { break }
        guard visualDepth == parentRenderedDepth + 1,
          let fields = parseTreeLineComponents(line)
        else { continue }
        children.append(
          StorageNode(path: String(line[fields.pathRange]), allocatedKiB: fields.allocatedKiB)
        )
        continue
      }

      guard let fields = parseTreeLineComponents(line) else { continue }
      let path = String(line[fields.pathRange])
      guard let depth = treeDepth(line, path: path, rootPath: section.root, maximum: nil) else {
        continue
      }
      if depth <= parentRenderedDepth { break }
      guard depth == parentRenderedDepth + 1 else { continue }
      children.append(StorageNode(path: path, allocatedKiB: fields.allocatedKiB))
    }

    return children.sorted(by: storageNodeOrder)
  }

  @discardableResult
  func forEachDirectoryNode(
    document: ReportDocument,
    under rootPath: String,
    _ body: (StorageNode) throws -> Void
  ) throws -> Int {
    guard let section = document.section(containing: rootPath) else {
      throw ReportParserError.missingSection(rootPath)
    }

    let reader = try UTF8LineReader(url: document.url, offset: section.startOffset)
    let descendantPrefix = rootPath == "/" ? "/" : rootPath + "/"
    var count = 0
    var foundRoot = false

    while let record = try reader.nextLine(), record.startOffset < section.endOffset {
      guard let fields = parseTreeLineComponents(record.text) else { continue }
      let path = String(record.text[fields.pathRange])
      guard path == rootPath || path.hasPrefix(descendantPrefix) else {
        if foundRoot { break }
        continue
      }
      if path == rootPath { foundRoot = true }
      try body(StorageNode(path: path, allocatedKiB: fields.allocatedKiB))
      count += 1
    }

    guard foundRoot else {
      throw ReportParserError.invalidReport("報告缺少清理目標的 DIRECTORY_TREE 根節點：\(rootPath)")
    }
    return count
  }

  func loadPresentation(
    document: ReportDocument,
    parentPath: String,
    maximumDepth: Int = SunburstPresentationPolicy.maximumDepth,
    maximumChildren: Int = SunburstPresentationPolicy.visibleChildBudgetWhenAggregated
  ) throws -> ([StorageNode], SunburstItem) {
    if let initial = document.initialPresentation,
      initial.rootPath == parentPath,
      initial.maximumDepth == maximumDepth,
      initial.maximumChildren == maximumChildren
    {
      return (initial.children, initial.sunburst)
    }

    guard let section = document.section(containing: parentPath) else {
      throw ReportParserError.missingSection(parentPath)
    }

    let reader = try UTF8LineReader(url: document.url, offset: section.startOffset)
    var records: [String: StorageNode] = [:]
    var parentRenderedDepth: Int?
    let parentSuffix = "  " + parentPath
    let acceptedDepth = max(1, maximumDepth)

    while let record = try reader.nextLine(), record.startOffset < section.endOffset {
      let line = record.text
      if parentRenderedDepth == nil {
        guard line.hasSuffix(parentSuffix), let fields = parseTreeLineComponents(line) else {
          continue
        }
        let path = String(line[fields.pathRange])
        guard path == parentPath,
          let depth = treeDepth(line, path: path, rootPath: section.root, maximum: nil)
        else { continue }
        records[path] = StorageNode(path: path, allocatedKiB: fields.allocatedKiB)
        parentRenderedDepth = depth
        continue
      }

      guard let parentRenderedDepth else { continue }
      if let visualDepth = renderedTreeDepth(line), visualDepth > 0 {
        if visualDepth <= parentRenderedDepth { break }
        guard visualDepth - parentRenderedDepth <= acceptedDepth,
          let fields = parseTreeLineComponents(line)
        else { continue }
        let path = String(line[fields.pathRange])
        let belongsToParent =
          parentPath == "/" ? path.hasPrefix("/") : path.hasPrefix(parentPath + "/")
        guard belongsToParent else { break }
        records[path] = StorageNode(path: path, allocatedKiB: fields.allocatedKiB)
        continue
      }

      guard let fields = parseTreeLineComponents(line) else { continue }
      let path = String(line[fields.pathRange])
      guard let depth = treeDepth(line, path: path, rootPath: section.root, maximum: nil) else {
        continue
      }
      if depth <= parentRenderedDepth { break }
      guard depth - parentRenderedDepth <= acceptedDepth else { continue }
      let belongsToParent =
        parentPath == "/" ? path.hasPrefix("/") : path.hasPrefix(parentPath + "/")
      guard belongsToParent else { break }
      records[path] = StorageNode(path: path, allocatedKiB: fields.allocatedKiB)
    }

    return try makePresentation(
      records: records,
      parentPath: parentPath,
      maximumDepth: maximumDepth,
      maximumChildren: maximumChildren
    )
  }

  func loadSunburst(
    document: ReportDocument,
    parentPath: String,
    maximumDepth: Int = SunburstPresentationPolicy.maximumDepth,
    maximumChildren: Int = SunburstPresentationPolicy.visibleChildBudgetWhenAggregated
  ) throws -> SunburstItem {
    try loadPresentation(
      document: document,
      parentPath: parentPath,
      maximumDepth: maximumDepth,
      maximumChildren: maximumChildren
    ).1
  }

  private func makePresentation(
    records: [String: StorageNode],
    parentPath: String,
    maximumDepth: Int,
    maximumChildren: Int
  ) throws -> ([StorageNode], SunburstItem) {
    guard let parentNode = records[parentPath] else {
      throw ReportParserError.invalidReport("找不到節點 \(parentPath)")
    }

    var childrenByParent: [String: [StorageNode]] = [:]
    childrenByParent.reserveCapacity(min(records.count, 4096))
    for node in records.values where node.path != parentPath {
      childrenByParent[node.parentPath, default: []].append(node)
    }
    for key in childrenByParent.keys {
      childrenByParent[key]?.sort(by: storageNodeOrder)
    }

    func build(_ node: StorageNode, depth: Int) -> SunburstItem {
      guard depth < maximumDepth else {
        return SunburstItem(
          id: node.path,
          label: node.name,
          path: node.path,
          bytes: node.allocatedBytes,
          kind: nil,
          children: []
        )
      }

      let allChildren = childrenByParent[node.path] ?? []
      let visibleCount = SunburstPresentationPolicy.visibleChildCount(
        childCount: allChildren.count,
        budget: maximumChildren
      )
      var builtChildren = allChildren.prefix(visibleCount).map { build($0, depth: depth + 1) }

      let childTotal = allChildren.reduce(Int64(0)) { partial, child in
        partial.addingReportingOverflow(child.allocatedBytes).partialValue
      }
      let directBytes = max(0, node.allocatedBytes - childTotal)
      let directThreshold = max(Int64(1024 * 1024), node.allocatedBytes / 500)
      if directBytes >= directThreshold {
        builtChildren.append(
          SunburstItem(
            id: node.path + "#direct",
            label: "直接檔案",
            path: node.path,
            bytes: directBytes,
            kind: .directFiles,
            children: []
          )
        )
      }

      if visibleCount < allChildren.count {
        let omitted = allChildren.dropFirst(visibleCount)
        let omittedBytes = omitted.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        builtChildren.append(
          SunburstItem(
            id: node.path + "#other",
            label: "其他 \(allChildren.count - visibleCount) 項",
            path: node.path,
            bytes: omittedBytes,
            kind: .otherChildren,
            children: []
          )
        )
      }

      builtChildren.sort { $0.bytes > $1.bytes }
      return SunburstItem(
        id: node.path,
        label: node.name,
        path: node.path,
        bytes: node.allocatedBytes,
        kind: nil,
        children: builtChildren
      )
    }

    return (childrenByParent[parentPath] ?? [], build(parentNode, depth: 0))
  }

  private func storageNodeOrder(_ lhs: StorageNode, _ rhs: StorageNode) -> Bool {
    if lhs.allocatedKiB == rhs.allocatedKiB { return lhs.path < rhs.path }
    return lhs.allocatedKiB > rhs.allocatedKiB
  }

  private func parseDFRow(_ line: String) -> DFRow? {
    guard line.hasPrefix("/dev/") else { return nil }
    let fields = line.split(
      maxSplits: 5,
      omittingEmptySubsequences: true,
      whereSeparator: { $0 == " " || $0 == "\t" }
    ).map(String.init)
    guard fields.count == 6,
      let capacity = Int64(fields[1]),
      let used = Int64(fields[2]),
      let available = Int64(fields[3])
    else { return nil }
    return DFRow(
      capacityKiB: capacity,
      usedKiB: used,
      availableKiB: available,
      mountPoint: fields[5].trimmingCharacters(in: .whitespaces)
    )
  }

  private func applyDFRows(_ preRows: [DFRow], postRows: [DFRow], to summary: inout ScanSummary) {
    func exact(_ mount: String, rows: [DFRow]) -> DFRow? {
      rows.first { $0.mountPoint == mount }
    }

    if let data = exact("/System/Volumes/Data", rows: preRows) {
      summary.dataVolumeCapacityKiB = data.capacityKiB
      if summary.dataVolumeDFUsedKiB == 0 { summary.dataVolumeDFUsedKiB = data.usedKiB }
      summary.dataVolumeAvailableKiB = data.availableKiB
    }
    if let dataPost = exact("/System/Volumes/Data", rows: postRows),
      summary.dataVolumeDFUsedPostKiB == 0
    {
      summary.dataVolumeDFUsedPostKiB = dataPost.usedKiB
    }
    if let system = exact("/", rows: preRows), summary.systemVolumeUsedKiB == 0 {
      summary.systemVolumeUsedKiB = system.usedKiB
    }
    if let vm = exact("/System/Volumes/VM", rows: preRows) { summary.vmVolumeUsedKiB = vm.usedKiB }
    if let preboot = exact("/System/Volumes/Preboot", rows: preRows) {
      summary.prebootVolumeUsedKiB = preboot.usedKiB
    }
    if let update = exact("/System/Volumes/Update", rows: preRows) {
      summary.updateVolumeUsedKiB = update.usedKiB
    }

    let targetMount =
      summary.targetMountPoint.isEmpty ? summary.targetPath : summary.targetMountPoint
    if let target = bestDFRow(for: targetMount, targetPath: summary.targetPath, rows: preRows) {
      if summary.targetVolumeCapacityKiB == 0 {
        summary.targetVolumeCapacityKiB = target.capacityKiB
      }
      if summary.targetVolumeUsedKiB == 0 { summary.targetVolumeUsedKiB = target.usedKiB }
      if summary.targetVolumeAvailableKiB == 0 {
        summary.targetVolumeAvailableKiB = target.availableKiB
      }
      summary.targetMountPoint = target.mountPoint
    }
    if let targetPost = bestDFRow(for: targetMount, targetPath: summary.targetPath, rows: postRows),
      summary.targetVolumeUsedPostKiB == 0
    {
      summary.targetVolumeUsedPostKiB = targetPost.usedKiB
    }
  }

  private func bestDFRow(for mountPoint: String, targetPath: String, rows: [DFRow]) -> DFRow? {
    if let exact = rows.first(where: { $0.mountPoint == mountPoint }) { return exact }
    return
      rows
      .filter { path(targetPath, belongsToMount: $0.mountPoint) }
      .max { $0.mountPoint.count < $1.mountPoint.count }
  }

  private func selectPrimaryContainer(
    _ containers: [APFSContainerRecord], summary: ScanSummary
  ) -> APFSContainerRecord? {
    guard !containers.isEmpty else { return nil }
    if summary.targetKind == .system {
      if let exact = containers.first(where: { container in
        container.volumes.contains {
          normalizedMountPath($0.mountPoint) == "/System/Volumes/Data"
        }
      }) {
        return exact
      }

      // Legacy reports should still load if they omitted the Data mount point, but
      // exact identity always wins so an external APFS volume named “Data” cannot
      // displace the internal Macintosh HD container.
      return containers.first { container in
        container.volumes.contains {
          $0.role.caseInsensitiveCompare("Data") == .orderedSame && $0.name == "Data"
        }
      }
    }

    // `diskutil apfs list` inventories every APFS container on the Mac, even when
    // the selected target is a non-APFS external disk. Match only the exact mount
    // point identified by `df`; otherwise `/` would lexically match every absolute
    // external path and graft the internal Macintosh HD accounting onto it.
    let targetMount = normalizedMountPath(
      summary.targetMountPoint.isEmpty ? summary.targetPath : summary.targetMountPoint)
    guard let targetMount else { return nil }
    return containers.first { container in
      container.volumes.contains { volume in
        normalizedMountPath(volume.mountPoint) == targetMount
      }
    }
  }

  private func path(_ path: String, belongsToMount mount: String) -> Bool {
    if mount == "/" { return path.hasPrefix("/") }
    return path == mount || path.hasPrefix(mount + "/")
  }

  private func valueAfterColon(_ line: String, key: String) -> String? {
    var field = line[...]
    while let first = field.first,
      first == " " || first == "\t" || first == "|" || first == "+" || first == "-"
        || first == ">" || first == "*"
    {
      field.removeFirst()
    }

    let prefix = key + ":"
    guard field.hasPrefix(prefix) else { return nil }
    return field.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
  }

  private func normalizedMountPath(_ path: String?) -> String? {
    guard var value = path?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    while value.count > 1, value.hasSuffix("/") { value.removeLast() }
    return value
  }

  private func byteValueAfterColon(_ line: String, key: String) -> Int64? {
    guard let value = valueAfterColon(line, key: key) else { return nil }
    return Int64(value.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? "")
  }

  private func stripCaseSensitivitySuffix(_ value: String) -> String {
    if let range = value.range(of: " (Case-", options: .backwards) {
      return String(value[..<range.lowerBound])
    }
    return value
  }

  private func parseKeyValue(_ line: String) -> (String, String)? {
    guard let equals = line.firstIndex(of: "=") else { return nil }
    let key = line[..<equals].trimmingCharacters(in: .whitespaces)
    let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { return nil }
    return (key, value)
  }

  private func parseSnapshotName(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("Name:") {
      let value = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
      return value.hasPrefix("com.apple.") ? value : nil
    }
    if trimmed.hasPrefix("com.apple.TimeMachine.") {
      return trimmed
    }
    return nil
  }

  private func parseRootSummaryRow(_ line: String) -> RootScanSummary? {
    guard line.hasPrefix("| `") else { return nil }
    let columns = line.split(separator: "|", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard columns.count >= 10 else { return nil }
    let root = columns[1].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
    guard root.hasPrefix("/") else { return nil }
    return RootScanSummary(
      root: root,
      duKiB: Int64(columns[2]) ?? 0,
      directoryNodes: Int(columns[5]) ?? 0,
      errorLines: Int(columns[6]) ?? 0,
      permissionErrors: Int(columns[7]) ?? 0,
      exitStatus: Int(columns[8]) ?? 0,
      seconds: Int(columns[9]) ?? 0
    )
  }

  private func parseTreeLineComponents(
    _ line: String
  ) -> (allocatedKiB: Int64, pathRange: Range<String.Index>)? {
    guard let marker = line.range(of: " KiB  /") else { return nil }
    let prefix = line[..<marker.lowerBound]
    guard let numberToken = prefix.split(whereSeparator: { $0 == " " || $0 == "\t" }).last,
      let kiB = Int64(numberToken)
    else { return nil }
    let slash = line.index(before: marker.upperBound)
    return (kiB, slash..<line.endIndex)
  }

  private func renderedTreeDepth(_ line: String, maximum: Int? = nil) -> Int? {
    let maximum = maximum.map { max(0, $0) }
    var cursor = line.startIndex
    var ancestorGroups = 0

    while cursor < line.endIndex {
      let remainder = line[cursor...]
      if remainder.hasPrefix("│   ") || remainder.hasPrefix("    ") {
        ancestorGroups += 1
        if let maximum, ancestorGroups + 1 > maximum { return nil }
        cursor = line.index(cursor, offsetBy: 4)
        continue
      }
      break
    }

    let remainder = line[cursor...]
    if remainder.hasPrefix("├── ") || remainder.hasPrefix("└── ") {
      let depth = ancestorGroups + 1
      if let maximum, depth > maximum { return nil }
      return depth
    }

    // The root row has no tree branch prefix. Requiring the KiB/path marker keeps
    // ordinary Markdown text from being mistaken for a depth-zero tree record.
    guard ancestorGroups == 0, line.range(of: " KiB  /") != nil else { return nil }
    return 0
  }

  /// Scanner 2.5.x emits visual tree prefixes, but older imported fixtures can
  /// contain flat path rows. Prefer the O(prefix-length) visual depth for modern
  /// reports and fall back to relative path components only for those legacy rows.
  private func treeDepth(
    _ line: String,
    path: String,
    rootPath: String,
    maximum: Int?
  ) -> Int? {
    if let visualDepth = renderedTreeDepth(line, maximum: maximum) {
      if visualDepth > 0 || path == rootPath { return visualDepth }
    }

    guard path == rootPath || rootPath == "/" || path.hasPrefix(rootPath + "/") else {
      return nil
    }
    if path == rootPath { return 0 }

    let relative: Substring
    if rootPath == "/" {
      relative = path.drop(while: { $0 == "/" })
    } else {
      let start = path.index(path.startIndex, offsetBy: rootPath.count + 1)
      relative = path[start...]
    }
    let depth =
      1
      + relative.reduce(into: 0) { count, character in
        if character == "/" { count += 1 }
      }
    if let maximum, depth > maximum { return nil }
    return depth
  }
}
