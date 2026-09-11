import Foundation

enum ScanTargetKind: String, Codable, CaseIterable, Hashable {
  case system = "system"
  case volume = "volume"
  case folder = "folder"

  var title: String {
    switch self {
    case .system: return "系統儲存空間"
    case .volume: return "磁碟"
    case .folder: return "資料夾"
    }
  }

  var symbol: String {
    switch self {
    case .system: return "internaldrive"
    case .volume: return "externaldrive"
    case .folder: return "folder"
    }
  }
}

struct ScanTarget: Identifiable, Codable, Hashable {
  let kind: ScanTargetKind
  let displayName: String
  let path: String
  let volumeUUID: String?

  var id: String { "\(kind.rawValue):\(path)" }

  var locationTitle: String {
    switch kind {
    case .system:
      return "Macintosh HD 系統儲存空間"
    case .volume:
      return "磁碟「\(displayName)」"
    case .folder:
      return "資料夾「\(displayName)」"
    }
  }

  var compactLocationTitle: String {
    switch kind {
    case .system: return "Macintosh HD"
    case .volume, .folder: return displayName
    }
  }

  static let systemStorage = ScanTarget(
    kind: .system,
    displayName: "Macintosh HD",
    path: "/System/Volumes/Data",
    volumeUUID: nil
  )
}

struct APFSVolumeRecord: Hashable, Codable {
  let deviceIdentifier: String
  let role: String
  let name: String
  let mountPoint: String?
  let consumedBytes: Int64

  var displayName: String {
    let trimmedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedRole.isEmpty || name.caseInsensitiveCompare(trimmedRole) == .orderedSame {
      return name
    }
    return "\(name)（\(trimmedRole)）"
  }
}

struct APFSContainerRecord: Hashable, Codable {
  let reference: String
  let totalBytes: Int64
  let usedBytes: Int64
  let freeBytes: Int64
  let volumes: [APFSVolumeRecord]

  var volumeTotalBytes: Int64 { volumes.reduce(0) { $0 + $1.consumedBytes } }
  var accountingRemainderBytes: Int64 { max(0, usedBytes - volumeTotalBytes) }
}

struct StorageNode: Identifiable, Hashable, Codable {
  let path: String
  let allocatedKiB: Int64
  let isVirtual: Bool
  let virtualKind: VirtualNodeKind?

  init(
    path: String, allocatedKiB: Int64, isVirtual: Bool = false, virtualKind: VirtualNodeKind? = nil
  ) {
    self.path = path
    self.allocatedKiB = max(0, allocatedKiB)
    self.isVirtual = isVirtual
    self.virtualKind = virtualKind
  }

  var id: String { path }
  var allocatedBytes: Int64 { allocatedKiB.multipliedReportingOverflow(by: 1024).partialValue }
  var name: String {
    if isVirtual { return path }
    guard path != "/", let slash = path.lastIndex(of: "/") else { return path }
    let start = path.index(after: slash)
    return start < path.endIndex ? String(path[start...]) : path
  }
  var parentPath: String {
    guard !isVirtual else { return "" }
    guard path != "/", let slash = path.lastIndex(of: "/") else { return "/" }
    return slash == path.startIndex ? "/" : String(path[..<slash])
  }
}

enum VirtualNodeKind: String, Hashable, Codable {
  case directFiles
  case otherChildren
  case accountingGap
  case containerAccounting
  case scanDelta
  case freeSpace
  case purgeable
  case otherVolume
}

struct RootScanSummary: Identifiable, Hashable, Codable {
  let root: String
  let duKiB: Int64
  let directoryNodes: Int
  let errorLines: Int
  let permissionErrors: Int
  let exitStatus: Int
  let seconds: Int

  var id: String { root }
  var bytes: Int64 { duKiB * 1024 }
}

struct SectionRange: Hashable, Codable {
  let root: String
  let startOffset: UInt64
  let endOffset: UInt64
}

struct ScanSummary: Hashable, Codable {
  var scannerVersion = "未知"
  var generatedAt = "未知"

  /// Effective TCC coverage used by this report. Scanner 2.5.3 can satisfy this
  /// either in the scanner process itself or through an App-owned overlay.
  var fullDiskAccessProbe = "UNKNOWN"
  var fullDiskAccessProbePath = "NONE"
  var fullDiskAccessSource = "unknown"

  /// The App and the elevated scanner are different TCC responsibility chains.
  /// Keep both probes so a failed root/AppleScript probe is never presented as
  /// proof that the user did not grant Full Disk Access to the App.
  var appFullDiskAccessProbe = "UNKNOWN"
  var appFullDiskAccessProbePath = "NONE"
  var scannerFullDiskAccessProbe = "UNKNOWN"
  var scannerFullDiskAccessProbePath = "NONE"
  var scannerPrivilegeChannel = "unknown"
  var tccOverlayStatus = "NOT_REQUESTED"
  var tccOverlayRoot = "NONE"
  var tccOverlayApplied = false
  var tccOverlayDeltaKiB: Int64 = 0
  var tccOverlayTreeKiB: Int64 = 0
  var tccOverlayReplacedKiB: Int64 = 0

  var administratorReadAccess = false
  var reportComplete = false
  var duErrorLineCount = 0
  var errorCount = 0
  var pathScanStatus = "UNKNOWN"

  var targetKind: ScanTargetKind = .system
  var targetPath = "/System/Volumes/Data"
  var targetDisplayName = "Macintosh HD"
  var targetVolumeUUID: String?
  var targetMountPoint = "/System/Volumes/Data"
  var launcherMode = "unknown"
  var accountingScope = "system"
  var accountingGapApplicable = true
  var volumeScanProfile = "complete_path_tree"
  var volumeVolatileMetadataExcluded = false
  var volumeVolatileMetadataNames: [String] = []
  var targetFilesystemType = "UNKNOWN"
  var targetSpotlightRootStatus = "NOT_APPLICABLE"
  var targetFSEventsRootStatus = "NOT_APPLICABLE"
  var targetTrashRootStatus = "NOT_APPLICABLE"
  var preflightDurationSeconds = 0
  var prepareDurationSeconds = 0
  var pathScanDurationSeconds = 0
  var metadataDurationSeconds = 0
  var reportWriteDurationSeconds = 0
  var totalDurationSeconds = 0

  var targetTreeDUKiB: Int64 = 0
  var targetVolumeCapacityKiB: Int64 = 0
  var targetVolumeUsedKiB: Int64 = 0
  var targetVolumeAvailableKiB: Int64 = 0
  var targetVolumeUsedPostKiB: Int64 = 0
  var targetAccountingGapKiB: Int64 = 0

  var dataVolumeDUKiB: Int64 = 0
  var dataVolumeDFUsedKiB: Int64 = 0
  var dataVolumeDFUsedPostKiB: Int64 = 0
  var dataVolumeScanDeltaKiB: Int64 = 0
  var accountingGapKiB: Int64 = 0
  var dataVolumeCapacityKiB: Int64 = 0
  var dataVolumeAvailableKiB: Int64 = 0
  var systemVolumeUsedKiB: Int64 = 0
  var vmVolumeUsedKiB: Int64 = 0
  var prebootVolumeUsedKiB: Int64 = 0
  var updateVolumeUsedKiB: Int64 = 0
  var recoveryVolumeUsedKiB: Int64 = 0
  var contentCacheKiB: Int64 = 0

  var primaryAPFSContainer: APFSContainerRecord?
  var rootSummaries: [RootScanSummary] = []
  var snapshotNames: [String] = []

  var target: ScanTarget {
    ScanTarget(
      kind: targetKind,
      displayName: targetDisplayName,
      path: targetPath,
      volumeUUID: targetVolumeUUID
    )
  }

  var targetTreeBytes: Int64 {
    let kiB = targetTreeDUKiB > 0 ? targetTreeDUKiB : dataVolumeDUKiB
    return max(0, kiB) * 1024
  }

  var targetAPFSVolume: APFSVolumeRecord? {
    guard let container = primaryAPFSContainer else { return nil }

    if targetKind == .system {
      if let exact = container.volumes.first(where: {
        normalizedMountPath($0.mountPoint) == "/System/Volumes/Data"
      }) {
        return exact
      }
      return container.volumes.first {
        $0.role.caseInsensitiveCompare("Data") == .orderedSame && $0.name == "Data"
      }
    }

    // A selected volume or folder must be matched to the exact filesystem mount
    // recorded by `df`. Lexical ancestry is not sufficient: every mounted disk is
    // also textually below `/`, which previously let an external FAT/exFAT volume
    // inherit the internal System APFS container.
    let candidateMount = normalizedMountPath(
      targetMountPoint.isEmpty ? targetPath : targetMountPoint)
    return container.volumes.first {
      normalizedMountPath($0.mountPoint) == candidateMount
    }
  }

  var targetVolumeCapacityBytes: Int64 {
    if targetKind != .folder, targetAPFSVolume != nil, let container = primaryAPFSContainer {
      return container.totalBytes
    }
    return max(0, targetVolumeCapacityKiB) * 1024
  }

  var targetVolumeUsedBytes: Int64 {
    if let volume = targetAPFSVolume { return volume.consumedBytes }
    return max(0, targetVolumeUsedKiB) * 1024
  }

  var targetVolumeAvailableBytes: Int64 {
    if targetKind != .folder, targetAPFSVolume != nil, let container = primaryAPFSContainer {
      return container.freeBytes
    }
    return max(0, targetVolumeAvailableKiB) * 1024
  }

  var targetAccountingGapBytes: Int64 {
    guard accountingGapApplicable else { return 0 }
    return max(0, targetAccountingGapKiB) * 1024
  }

  /// Signed `df` change during the scan. This is diagnostic metadata, not a chart filler.
  var targetVolumeScanDeltaBytes: Int64 {
    guard targetVolumeUsedKiB > 0, targetVolumeUsedPostKiB > 0 else { return 0 }
    return (targetVolumeUsedPostKiB - targetVolumeUsedKiB) * 1024
  }

  /// Unsigned remainder needed to reconcile the selected volume's current APFS/df usage
  /// with the scan-start tree and unresolved accounting difference.
  var targetSamplingRemainderBytes: Int64 {
    max(0, targetVolumeUsedBytes - targetTreeBytes - targetAccountingGapBytes)
  }

  private func normalizedMountPath(_ path: String?) -> String? {
    guard var value = path?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    while value.count > 1, value.hasSuffix("/") { value.removeLast() }
    return value
  }

  var systemSnapshotCount: Int {
    snapshotNames.filter { $0.contains("com.apple.os.update-") }.count
  }

  var timeMachineSnapshotCount: Int {
    snapshotNames.filter { $0.contains("com.apple.TimeMachine.") }.count
  }

  var otherSnapshotCount: Int {
    max(0, snapshotNames.count - systemSnapshotCount - timeMachineSnapshotCount)
  }

  var diagnosticLineCount: Int { max(errorCount, duErrorLineCount) }

  var hasPartialCoverage: Bool {
    diagnosticLineCount > 0 || pathScanStatus == "PARTIAL_UNREADABLE_PATHS"
  }

  var fullDiskAccessAvailable: Bool {
    fullDiskAccessProbe == "LIKELY_AVAILABLE"
  }

  var appFullDiskAccessAvailable: Bool {
    appFullDiskAccessProbe == "LIKELY_AVAILABLE"
  }

  var scannerFullDiskAccessAvailable: Bool {
    scannerFullDiskAccessProbe == "LIKELY_AVAILABLE"
  }

  var usedAppTCCOverlay: Bool {
    tccOverlayApplied || tccOverlayStatus == "APPLIED" || fullDiskAccessSource == "app_tcc_overlay"
  }

  var tccOverlayTreeBytes: Int64 { max(0, tccOverlayTreeKiB) * 1024 }
  var tccOverlayReplacedBytes: Int64 { max(0, tccOverlayReplacedKiB) * 1024 }
  var tccOverlayDeltaBytes: Int64 { tccOverlayDeltaKiB * 1024 }

  /// Scanner 2.5.0 only stored one probe. In an App-launched administrator scan
  /// that probe came from the detached elevated shell, not from the App itself.
  var hasAmbiguousLegacyAdministratorProbe: Bool {
    scannerVersion == "2.5.0"
      && launcherMode == "app"
      && administratorReadAccess
      && appFullDiskAccessProbe == "UNKNOWN"
      && scannerPrivilegeChannel == "unknown"
  }

  var scanChannelDisplayName: String {
    switch scannerPrivilegeChannel {
    case "app_tcc_overlay_plus_administrator": return "App TCC + 管理員"
    case "app_direct": return "App 直接"
    case "administrator_only": return "管理員子程序"
    case "terminal": return "Terminal"
    default:
      if launcherMode == "terminal" { return "Terminal" }
      if administratorReadAccess { return "管理員子程序（舊報告）" }
      if launcherMode == "app" { return "App 直接（舊報告）" }
      return "未知"
    }
  }

  var dataVisibleBytes: Int64 { max(0, dataVolumeDUKiB) * 1024 }
  var dataUsedBytes: Int64 { max(0, dataVolumeDFUsedKiB) * 1024 }
  var dataUsedPostBytes: Int64 { max(0, dataVolumeDFUsedPostKiB) * 1024 }
  var dataScanDeltaBytes: Int64 {
    if dataVolumeScanDeltaKiB != 0 { return dataVolumeScanDeltaKiB * 1024 }
    guard dataVolumeDFUsedKiB > 0, dataVolumeDFUsedPostKiB > 0 else { return 0 }
    return (dataVolumeDFUsedPostKiB - dataVolumeDFUsedKiB) * 1024
  }
  var accountingGapBytes: Int64 { max(0, accountingGapKiB) * 1024 }

  var capacityBytes: Int64 {
    primaryAPFSContainer?.totalBytes ?? max(0, dataVolumeCapacityKiB) * 1024
  }
  var availableBytes: Int64 {
    primaryAPFSContainer?.freeBytes ?? max(0, dataVolumeAvailableKiB) * 1024
  }
  var containerUsedBytes: Int64 {
    primaryAPFSContainer?.usedBytes ?? max(0, capacityBytes - availableBytes)
  }

  private func apfsVolumeBytes(role: String) -> Int64? {
    primaryAPFSContainer?.volumes.first {
      $0.role.caseInsensitiveCompare(role) == .orderedSame
    }?.consumedBytes
  }

  var systemVolumeUsedBytes: Int64 {
    apfsVolumeBytes(role: "System") ?? max(0, systemVolumeUsedKiB) * 1024
  }
  var vmVolumeUsedBytes: Int64 {
    apfsVolumeBytes(role: "VM") ?? max(0, vmVolumeUsedKiB) * 1024
  }
  var prebootVolumeUsedBytes: Int64 {
    apfsVolumeBytes(role: "Preboot") ?? max(0, prebootVolumeUsedKiB) * 1024
  }
  var recoveryVolumeUsedBytes: Int64 {
    apfsVolumeBytes(role: "Recovery") ?? max(0, recoveryVolumeUsedKiB) * 1024
  }
  var updateVolumeUsedBytes: Int64 { max(0, updateVolumeUsedKiB) * 1024 }
  var dataAPFSVolumeUsedBytes: Int64 {
    apfsVolumeBytes(role: "Data") ?? dataUsedBytes
  }
  var dataSamplingRemainderBytes: Int64 {
    max(0, dataAPFSVolumeUsedBytes - dataVisibleBytes - accountingGapBytes)
  }
  var otherContainerBytes: Int64 {
    if let container = primaryAPFSContainer { return container.accountingRemainderBytes }
    let known =
      dataUsedBytes + systemVolumeUsedBytes + vmVolumeUsedBytes
      + prebootVolumeUsedBytes + recoveryVolumeUsedBytes + updateVolumeUsedBytes
    return max(0, containerUsedBytes - known)
  }

}

enum ReportPresentationIndexSource: String, Codable, Hashable {
  case persistentCache = "persistent_cache"
  case markdownSinglePass = "markdown_single_pass"

  var title: String {
    switch self {
    case .persistentCache: return "本機容量索引"
    case .markdownSinglePass: return "Markdown 單次建立"
    }
  }

  var compactTitle: String {
    switch self {
    case .persistentCache: return "索引快取"
    case .markdownSinglePass: return "單次解析"
    }
  }
}

struct ReportInitialPresentation: Hashable, Codable {
  let rootPath: String
  let maximumDepth: Int
  let maximumChildren: Int
  let children: [StorageNode]
  let sunburst: SunburstItem
}

struct ReportDocument: Hashable {
  let url: URL
  let summary: ScanSummary
  let sections: [String: SectionRange]
  let topLevelNodes: [String: [StorageNode]]
  let initialPresentation: ReportInitialPresentation?

  func section(containing path: String) -> SectionRange? {
    sections.values
      .filter { path == $0.root || path.hasPrefix($0.root + "/") }
      .max { $0.root.count < $1.root.count }
  }
}

struct LiveCapacity: Hashable {
  let totalBytes: Int64
  let availableBytes: Int64
  let importantUsageAvailableBytes: Int64
  let opportunisticUsageAvailableBytes: Int64
  let updatedAt: Date

  var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
  var reclaimableEstimateBytes: Int64 { max(0, importantUsageAvailableBytes - availableBytes) }
}

enum SunburstColorHint: String, Hashable, Codable {
  /// The selected APFS/Data volume is a structural accounting layer, not a folder family.
  case selectedVolume
  /// A mapped-tree bridge keeps the structural volume color, then reseeds child folder families.
  case mappedTree
}

enum SunburstPresentationPolicy {
  /// The chart keeps ordinary sibling sets fully expanded. Aggregation is a last-resort
  /// density safeguard for folders with thousands of direct child directories.
  static let automaticAggregationThreshold = 2_048
  static let visibleChildBudgetWhenAggregated = 512
  static let maximumDepth = 4

  static func shouldAggregate(childCount: Int) -> Bool {
    childCount > automaticAggregationThreshold
  }

  static func visibleChildCount(childCount: Int, budget: Int? = nil) -> Int {
    guard shouldAggregate(childCount: childCount) else { return childCount }
    return min(max(1, budget ?? visibleChildBudgetWhenAggregated), childCount)
  }
}

struct SunburstItem: Identifiable, Hashable, Codable {
  let id: String
  let label: String
  /// Finder path for a real directory, or the containing directory for an inspectable virtual node.
  let path: String?
  let bytes: Int64
  let kind: VirtualNodeKind?
  let children: [SunburstItem]
  let colorHint: SunburstColorHint?

  init(
    id: String,
    label: String,
    path: String?,
    bytes: Int64,
    kind: VirtualNodeKind?,
    children: [SunburstItem],
    colorHint: SunburstColorHint? = nil
  ) {
    self.id = id
    self.label = label
    self.path = path
    self.bytes = bytes
    self.kind = kind
    self.children = children
    self.colorHint = colorHint
  }

  var isNavigable: Bool { path != nil && kind == nil }
  var isInspectable: Bool { path != nil && kind == .directFiles }
  var isExpandableAggregate: Bool { path != nil && kind == .otherChildren }
  var isInteractive: Bool { isNavigable || isInspectable || isExpandableAggregate }

  /// Real file-system path exposed to Finder actions. Capacity-accounting nodes
  /// never pretend to be folders. Aggregate/direct-file nodes use their parent path.
  var finderPath: String? {
    guard let path, path.hasPrefix("/") else { return nil }
    switch kind {
    case .accountingGap, .containerAccounting, .scanDelta, .freeSpace, .purgeable:
      return nil
    case .none, .directFiles, .otherChildren, .otherVolume:
      return path
    }
  }

  private var finderUsesParentPath: Bool {
    kind == .directFiles || kind == .otherChildren
  }

  var finderActionTitle: String {
    finderUsesParentPath ? "在 Finder 中顯示父資料夾" : "在 Finder 中顯示"
  }

  var finderOpenActionTitle: String {
    finderUsesParentPath ? "在 Finder 中打開父資料夾" : "在 Finder 中打開"
  }

  var finderCopyActionTitle: String {
    finderUsesParentPath ? "複製父資料夾路徑" : "複製完整路徑"
  }
}

struct DirectFileEntry: Identifiable, Hashable {
  let url: URL
  let logicalBytes: Int64
  let allocatedBytes: Int64
  let modifiedAt: Date?
  let isSymbolicLink: Bool

  var id: String { url.path }
  var name: String { url.lastPathComponent }
}

struct DirectFilesInspection: Hashable {
  let parentPath: String
  let expectedAllocatedBytes: Int64
  let entries: [DirectFileEntry]
  let scannedAt: Date
  let errorMessage: String?

  var liveAllocatedBytes: Int64 { entries.reduce(0) { $0 + $1.allocatedBytes } }
  var liveLogicalBytes: Int64 { entries.reduce(0) { $0 + $1.logicalBytes } }
}

enum ReportStatusKind: String, Hashable {
  case empty
  case loading
  case scanning
  case ready
  case cancelled
  case failed
}

enum ScanPrivilegeMode: String, Hashable {
  case administrator
  case currentUser
}

enum ScanSheetPhase: Hashable {
  case authorization
  case running
  case completed(URL)
  case cancelled(String)
  case failed(String)
}

enum ScanProgressHealth: String, Hashable {
  case waitingForAuthorization
  case active
  case delayed
  case stalled
  case cancelling
}

struct ScanProgressSnapshot: Hashable {
  let message: String
  let detail: String?
  let currentPath: String?
  let fraction: Double?
  let stage: String
  let currentStep: Int?
  let totalSteps: Int?
  let elapsedSeconds: Int
  let estimatedRemainingSeconds: Int?
  let secondsSinceUpdate: Int?
  let nodeCount: Int?
  let errorCount: Int?
  let health: ScanProgressHealth
  let recentMessages: [String]
  let isEstimated: Bool

  init(
    message: String,
    detail: String? = nil,
    currentPath: String? = nil,
    fraction: Double? = nil,
    stage: String = "準備掃描",
    currentStep: Int? = nil,
    totalSteps: Int? = nil,
    elapsedSeconds: Int = 0,
    estimatedRemainingSeconds: Int? = nil,
    secondsSinceUpdate: Int? = nil,
    nodeCount: Int? = nil,
    errorCount: Int? = nil,
    health: ScanProgressHealth = .active,
    recentMessages: [String] = [],
    isEstimated: Bool = true
  ) {
    self.message = message
    self.detail = detail
    self.currentPath = currentPath
    self.fraction = fraction.map { min(1, max(0, $0)) }
    self.stage = stage
    self.currentStep = currentStep
    self.totalSteps = totalSteps
    self.elapsedSeconds = max(0, elapsedSeconds)
    self.estimatedRemainingSeconds = estimatedRemainingSeconds.map { max(0, $0) }
    self.secondsSinceUpdate = secondsSinceUpdate.map { max(0, $0) }
    self.nodeCount = nodeCount
    self.errorCount = errorCount
    self.health = health
    self.recentMessages = recentMessages
    self.isEstimated = isEstimated
  }
}

/// End-to-end timing captured for one user-requested storage scan.
///
/// Scanner phase values come from the completed Markdown report. Launcher and
/// App-side values use workflow timestamps captured by MacStorageLens.
/// Keeping both prevents a two-second scanner core from being presented as the
/// entire user-visible wait when target resolution, authorization, parsing, or
/// initial chart construction took longer.
struct ScanTimingSnapshot: Hashable {
  let target: ScanTarget
  let reportURL: URL
  let diagnosticDirectoryURL: URL?
  let requestedAt: Date
  let scannerCompletedAt: Date
  let readyAt: Date
  let targetResolutionSeconds: TimeInterval?
  let scannerInstallationSeconds: TimeInterval?
  let permissionProbeSeconds: TimeInterval?
  let sessionPreparationSeconds: TimeInterval?
  let launchToScannerStartSeconds: TimeInterval?
  let requestToScannerCompletionSeconds: TimeInterval
  let scannerPreflightSeconds: Int
  let scannerPrepareSeconds: Int
  let scannerPathSeconds: Int
  let scannerMetadataSeconds: Int
  let scannerReportWriteSeconds: Int
  let scannerTotalSeconds: Int
  let reportParseSeconds: TimeInterval
  let initialViewBuildSeconds: TimeInterval
  let presentationIndexSource: ReportPresentationIndexSource
  let presentationIndexWriteSeconds: TimeInterval
  let usedTerminalFallback: Bool

  var requestToReadySeconds: TimeInterval {
    max(0, readyAt.timeIntervalSince(requestedAt))
  }

  var appOutsideScannerSeconds: TimeInterval {
    max(0, requestToScannerCompletionSeconds - Double(scannerTotalSeconds))
  }

  var scannerPhaseAccountedSeconds: Int {
    scannerPreflightSeconds + scannerPrepareSeconds + scannerPathSeconds
      + scannerMetadataSeconds + scannerReportWriteSeconds
  }

  var scannerUnattributedSeconds: Int {
    max(0, scannerTotalSeconds - scannerPhaseAccountedSeconds)
  }
}

enum CleanupMode: String, Codable, Hashable {
  case system
  case generalLocation

  static func forTarget(_ target: ScanTarget) -> CleanupMode {
    target.kind == .system ? .system : .generalLocation
  }

  var title: String {
    switch self {
    case .system: return "macOS 六級安全清理"
    case .generalLocation: return "一般位置隱藏中繼資料整理"
    }
  }

  var symbol: String {
    switch self {
    case .system: return "internaldrive"
    case .generalLocation: return "folder.badge.gearshape"
    }
  }
}

enum CleanupScanSource: String, CaseIterable, Identifiable, Codable, Hashable {
  case existingStorageReport
  case liveFilesystem

  var id: String { rawValue }

  var title: String {
    switch self {
    case .existingStorageReport: return "使用既有容量報告（快速）"
    case .liveFilesystem: return "重新掃描目標（完整）"
    }
  }

  var shortTitle: String {
    switch self {
    case .existingStorageReport: return "既有容量報告"
    case .liveFilesystem: return "完整重新掃描"
    }
  }

  var symbol: String {
    switch self {
    case .existingStorageReport: return "doc.text.magnifyingglass"
    case .liveFilesystem: return "arrow.triangle.2.circlepath"
    }
  }
}

enum CleanupProfile: String, CaseIterable, Identifiable, Codable {
  case ultraConservative = "超級保守"
  case conservative = "保守"
  case balanced = "平衡"
  case aggressive = "激進"
  case ultraAggressive = "超激進"
  case custom = "自定義"

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .ultraConservative: return "shield.lefthalf.filled"
    case .conservative: return "shield"
    case .balanced: return "scale.3d"
    case .aggressive: return "bolt.shield"
    case .ultraAggressive: return "exclamationmark.triangle"
    case .custom: return "slider.horizontal.3"
    }
  }

  var tierLimit: CleanupTier? {
    switch self {
    case .ultraConservative: return .ultraConservative
    case .conservative: return .conservative
    case .balanced: return .balanced
    case .aggressive: return .aggressive
    case .ultraAggressive: return .ultraAggressive
    case .custom: return nil
    }
  }

  var defaultMinimumBytes: Int64 {
    switch self {
    case .ultraConservative: return 20 * 1_048_576
    case .conservative: return 10 * 1_048_576
    case .balanced: return 5 * 1_048_576
    case .aggressive: return 1 * 1_048_576
    case .ultraAggressive, .custom: return 0
    }
  }

  var summary: String {
    switch self {
    case .ultraConservative:
      return "只找第三方標準快取；不碰 Apple 服務、App Support、日誌或個人資料。"
    case .conservative:
      return "加入 Apple／群組容器快取、跨裝置剪貼簿、純繪圖快取與已停滯的未完成下載。"
    case .balanced:
      return "再加入開發工具、套件下載快取與受支援的 Conda／Homebrew 清理。"
    case .aggressive:
      return "再顯示離線網頁快取、使用者診斷日誌、已卸載 App 的可重建殘留與可證明損壞的第三方 plist。"
    case .ultraAggressive:
      return "再檢查舊安裝檔與磁碟映像；高影響資料、目前使用者垃圾桶與系統管理檢視項目必須在下方另外開啟。"
    case .custom:
      return "自行選擇要檢查的資料類型與最低容量；所有結果仍需逐項勾選。"
    }
  }

  func summary(
    for mode: CleanupMode,
    prioritizingExternalAppleDouble: Bool = false
  ) -> String {
    guard mode == .generalLocation else { return summary }
    if prioritizingExternalAppleDouble {
      switch self {
      case .ultraConservative:
        return "只找 .DS_Store 與可驗證的 ._.DS_Store；清除後只會重設 Finder 顯示偏好。"
      case .conservative:
        return "加入 Windows 顯示中繼資料，以及主檔已不存在且不含資源分支／未知 entry 的 ._ 孤立殘留。"
      case .balanced:
        return "再加入 __MACOSX，以及仍有同名主檔但不含資源分支／未知 entry 的 ._ metadata；外部媒體上提高其清理優先級。"
      case .aggressive:
        return "沿用外部媒體的 metadata-only AppleDouble 清理範圍；真正含資源分支、未知 payload 或格式不明的 ._ 仍不會自動刪除。"
      case .ultraAggressive:
        return "再顯示資源分支、不明 ._ 檔、舊式 metadata 與 macOS 卷宗資料；敏感 AppleDouble 仍只供檢視。"
      case .custom:
        return "自行選擇要檢查的隱藏中繼資料類型；外部媒體仍維持 resource fork／未知 payload 的不可自動刪除紅線。"
      }
    }

    switch self {
    case .ultraConservative:
      return "只找 .DS_Store 與可驗證的 ._.DS_Store；清除後只會重設 Finder 顯示偏好。"
    case .conservative:
      return "加入 Windows 顯示中繼資料及其可驗證的 AppleDouble 側邊檔。"
    case .balanced:
      return "再加入 __MACOSX，以及主檔已不存在且不含資源分支的 AppleDouble 殘留。"
    case .aggressive:
      return "再加入仍有同名主檔、但沒有資源分支或未知 entry 的 ._ metadata；需逐項確認。"
    case .ultraAggressive:
      return "再顯示資源分支、不明 ._ 檔、舊式 metadata 與 macOS 卷宗資料；Spotlight／FSEvents 可在警告後逐項選取，其餘只供檢視。"
    case .custom:
      return "自行選擇要檢查的隱藏中繼資料類型；所有可執行項目仍需逐項勾選。"
    }
  }
}

enum CleanupTier: Int, CaseIterable, Codable, Comparable, Hashable {
  case ultraConservative = 1
  case conservative = 2
  case balanced = 3
  case aggressive = 4
  case ultraAggressive = 5

  static func < (lhs: CleanupTier, rhs: CleanupTier) -> Bool { lhs.rawValue < rhs.rawValue }

  var title: String {
    switch self {
    case .ultraConservative: return "超級保守"
    case .conservative: return "保守"
    case .balanced: return "平衡"
    case .aggressive: return "激進"
    case .ultraAggressive: return "超激進"
    }
  }
}

enum CleanupScope: String, CaseIterable, Identifiable, Codable, Hashable {
  case standardCaches
  case sandboxAndGroupCaches
  case clipboardTemporary
  case applicationWebCaches
  case developerCaches
  case packageManagerCaches
  case downloadResidue
  case appLeftovers
  case brokenPreferences
  case diagnosticsAndLogs
  case highImpactUserData
  case trashBins
  case systemManagedReview
  case folderFinderMetadata
  case folderWindowsMetadata
  case folderArchiveMetadata
  case folderAppleDoubleRemnants
  case folderAppleDouble
  case folderAppleDoubleReview
  case folderMacManagedReview
  case folderLegacyReview

  var id: String { rawValue }

  var title: String {
    switch self {
    case .standardCaches: return "標準使用者快取"
    case .sandboxAndGroupCaches: return "沙盒與群組快取"
    case .clipboardTemporary: return "剪貼簿與特定暫存"
    case .applicationWebCaches: return "App 網頁／繪圖快取"
    case .developerCaches: return "開發工具快取"
    case .packageManagerCaches: return "套件管理器快取"
    case .downloadResidue: return "下載殘留與舊安裝檔"
    case .appLeftovers: return "已卸載 App 殘留"
    case .brokenPreferences: return "損壞的第三方偏好設定"
    case .diagnosticsAndLogs: return "診斷與使用者日誌"
    case .highImpactUserData: return "高影響可回收資料"
    case .trashBins: return "廢紙簍（永久清空）"
    case .systemManagedReview: return "系統管理項目（僅檢視）"
    case .folderFinderMetadata: return "Finder 顯示中繼資料"
    case .folderWindowsMetadata: return "Windows 顯示中繼資料"
    case .folderArchiveMetadata: return "Mac 壓縮封裝中繼資料"
    case .folderAppleDoubleRemnants: return "AppleDouble 孤立殘留"
    case .folderAppleDouble: return "AppleDouble 配對中繼資料"
    case .folderAppleDoubleReview: return "AppleDouble 敏感內容（僅檢視）"
    case .folderMacManagedReview: return "macOS 卷宗中繼資料（高風險）"
    case .folderLegacyReview: return "舊式 Apple metadata（僅檢視）"
    }
  }

  var summary: String {
    switch self {
    case .standardCaches:
      return "~/Library/Caches 中可重建的 App 快取。"
    case .sandboxAndGroupCaches:
      return "沙盒 App 與 Group Container 的標準 Caches 目錄。"
    case .clipboardTemporary:
      return "Universal Clipboard 封存等明確暫存。"
    case .applicationWebCaches:
      return "只辨識名稱明確的 Cache、Code Cache、GPUCache 與 CacheStorage；不碰 Cookie、資料庫或 Local Storage。"
    case .developerCaches:
      return "Xcode DerivedData、Simulator cache 與裝置支援檔等可重建開發資料。"
    case .packageManagerCaches:
      return "Homebrew、pip、npm、Conda 等下載或未使用套件快取。"
    case .downloadResidue:
      return "Downloads 中已停滯的未完成下載，以及久未使用的安裝映像／套件；高影響檔案不會自動勾選。"
    case .appLeftovers:
      return
        "只在 Caches、Logs、HTTPStorages、Saved Application State 與 WebKit 等可重建區域辨識已卸載 App 的 reverse-DNS 殘留。"
    case .brokenPreferences:
      return "只列出可證明無法解析、且非 Apple domain 的 ~/Library/Preferences plist；不以『找不到 App』推測偏好設定可刪。"
    case .diagnosticsAndLogs:
      return "使用者層 crash report 與 App logs；清除後會失去故障排查紀錄。"
    case .highImpactUserData:
      return "iOS 備份、Xcode Archives、Mail Downloads 等可回收但可能仍有價值的資料。"
    case .trashBins:
      return
        "清空目前使用者的 ~/.Trash，以及本機可寫外接卷宗 .Trashes/<目前 UID> 中掃描時已列出的直接子項；不碰其他使用者、NAS #recycle 或整棵 .Trashes。此操作不經另一個垃圾桶。"
    case .systemManagedReview:
      return "Time Machine snapshot、系統快取與系統診斷；App 只說明，不直接刪除。"
    case .folderFinderMetadata:
      return ".DS_Store 保存 Finder 排序、檢視方式與圖示位置；Finder 需要時會重新建立。"
    case .folderWindowsMetadata:
      return "Thumbs.db、ehthumbs.db 與 Desktop.ini 保存 Windows 縮圖或資料夾外觀。"
    case .folderArchiveMetadata:
      return "__MACOSX 是 macOS 壓縮工具用來保存 Finder metadata 的伴隨資料夾。"
    case .folderAppleDoubleRemnants:
      return "只列出 binary header 有效、同名主檔已不存在，而且不含資源分支或未知 entry 的 ._ 殘留。"
    case .folderAppleDouble:
      return "同名主檔仍存在的 AppleDouble metadata；主檔內容不會刪除，但標籤、Finder 資訊或延伸屬性可能消失。"
    case .folderAppleDoubleReview:
      return "含資源分支、未知 entry、package／symlink companion 或無法驗證格式的 ._ 項目；只供人工檢查。"
    case .folderMacManagedReview:
      return
        ".Spotlight-V100 與 .fseventsd 可逐項選擇 Finder 可見垃圾桶或直接徹底刪除；它們不會被批次勾選。舊版不可見垃圾桶殘留會另列成只能直接刪除的候選；文件版本與其他 marker 仍只供檢視。"
    case .folderLegacyReview:
      return ".AppleDouble、.AppleDB 與 .AppleDesktop 可能屬於舊式檔案服務 metadata；只供人工檢查。"
    }
  }

  var symbol: String {
    switch self {
    case .standardCaches: return "shippingbox"
    case .sandboxAndGroupCaches: return "square.stack.3d.up"
    case .clipboardTemporary: return "doc.on.clipboard"
    case .applicationWebCaches: return "globe.badge.chevron.backward"
    case .developerCaches: return "hammer"
    case .packageManagerCaches: return "shippingbox.and.arrow.backward"
    case .downloadResidue: return "arrow.down.doc"
    case .appLeftovers: return "app.dashed"
    case .brokenPreferences: return "slider.horizontal.3"
    case .diagnosticsAndLogs: return "waveform.path.ecg"
    case .highImpactUserData: return "externaldrive.badge.exclamationmark"
    case .trashBins: return "trash.slash"
    case .systemManagedReview: return "gearshape.2"
    case .folderFinderMetadata: return "macwindow"
    case .folderWindowsMetadata: return "rectangle.on.rectangle"
    case .folderArchiveMetadata: return "archivebox"
    case .folderAppleDoubleRemnants: return "doc.badge.clock"
    case .folderAppleDouble: return "doc.badge.ellipsis"
    case .folderAppleDoubleReview: return "doc.badge.exclamationmark"
    case .folderMacManagedReview: return "externaldrive.badge.exclamationmark"
    case .folderLegacyReview: return "eye"
    }
  }

  var mode: CleanupMode {
    switch self {
    case .folderFinderMetadata, .folderWindowsMetadata, .folderArchiveMetadata,
      .folderAppleDoubleRemnants, .folderAppleDouble, .folderAppleDoubleReview,
      .folderMacManagedReview, .folderLegacyReview:
      return .generalLocation
    default:
      return .system
    }
  }

  var minimumTier: CleanupTier { minimumTier(prioritizingExternalAppleDouble: false) }

  func minimumTier(prioritizingExternalAppleDouble: Bool) -> CleanupTier {
    switch self {
    case .standardCaches, .sandboxAndGroupCaches, .folderFinderMetadata:
      return .ultraConservative
    case .clipboardTemporary, .applicationWebCaches, .downloadResidue, .folderWindowsMetadata:
      return .conservative
    case .folderAppleDoubleRemnants:
      return prioritizingExternalAppleDouble ? .conservative : .balanced
    case .developerCaches, .packageManagerCaches, .folderArchiveMetadata:
      return .balanced
    case .folderAppleDouble:
      return prioritizingExternalAppleDouble ? .balanced : .aggressive
    case .appLeftovers, .brokenPreferences, .diagnosticsAndLogs:
      return .aggressive
    case .highImpactUserData, .trashBins, .systemManagedReview, .folderAppleDoubleReview,
      .folderMacManagedReview, .folderLegacyReview:
      return .ultraAggressive
    }
  }

  var requiresExplicitPresetOptIn: Bool {
    switch self {
    case .highImpactUserData, .trashBins, .systemManagedReview:
      return true
    default:
      return false
    }
  }

  static var presetOptionalCases: [CleanupScope] {
    allCases.filter { $0.mode == .system && $0.requiresExplicitPresetOptIn }
  }

  static func cases(for mode: CleanupMode) -> [CleanupScope] {
    allCases.filter { $0.mode == mode }
  }
}

struct CleanupScanConfiguration: Codable, Hashable {
  let profile: CleanupProfile
  let customScopes: Set<CleanupScope>
  let customMinimumBytes: Int64
  let presetOptionalScopes: Set<CleanupScope>

  init(
    profile: CleanupProfile,
    customScopes: Set<CleanupScope>,
    customMinimumBytes: Int64,
    presetOptionalScopes: Set<CleanupScope> = []
  ) {
    self.profile = profile
    self.customScopes = customScopes
    self.customMinimumBytes = customMinimumBytes
    self.presetOptionalScopes = Set(
      presetOptionalScopes.filter(\.requiresExplicitPresetOptIn)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case profile
    case customScopes
    case customMinimumBytes
    case presetOptionalScopes
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    profile = try container.decode(CleanupProfile.self, forKey: .profile)
    customScopes = try container.decode(Set<CleanupScope>.self, forKey: .customScopes)
    customMinimumBytes = try container.decode(Int64.self, forKey: .customMinimumBytes)
    let decoded =
      try container.decodeIfPresent(
        Set<CleanupScope>.self,
        forKey: .presetOptionalScopes
      ) ?? []
    presetOptionalScopes = Set(decoded.filter(\.requiresExplicitPresetOptIn))
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(profile, forKey: .profile)
    try container.encode(customScopes, forKey: .customScopes)
    try container.encode(customMinimumBytes, forKey: .customMinimumBytes)
    try container.encode(presetOptionalScopes, forKey: .presetOptionalScopes)
  }

  var minimumBytes: Int64 {
    profile == .custom ? max(0, customMinimumBytes) : profile.defaultMinimumBytes
  }

  /// Folder metadata files are commonly only a few kilobytes. Applying the
  /// system-cleanup size thresholds to predefined folder profiles would hide the
  /// exact items that mode is meant to find. Custom mode still honours the
  /// user's explicit threshold.
  func effectiveMinimumBytes(for mode: CleanupMode) -> Int64 {
    if mode == .generalLocation, profile != .custom { return 0 }
    return minimumBytes
  }

  func includes(tier: CleanupTier, scope: CleanupScope) -> Bool {
    if profile == .custom { return customScopes.contains(scope) }
    guard let limit = profile.tierLimit, tier <= limit else { return false }
    if scope.requiresExplicitPresetOptIn {
      return limit == .ultraAggressive && presetOptionalScopes.contains(scope)
    }
    return true
  }

  func requiresScope(
    _ scope: CleanupScope,
    prioritizingExternalAppleDouble: Bool = false
  ) -> Bool {
    if profile == .custom { return customScopes.contains(scope) }
    guard let limit = profile.tierLimit else { return false }
    if scope.requiresExplicitPresetOptIn {
      return limit == .ultraAggressive && presetOptionalScopes.contains(scope)
    }
    return limit
      >= scope.minimumTier(
        prioritizingExternalAppleDouble: prioritizingExternalAppleDouble)
  }

  static func indexScan(scopes: Set<CleanupScope>) -> CleanupScanConfiguration {
    CleanupScanConfiguration(
      profile: .custom,
      customScopes: scopes,
      customMinimumBytes: 0
    )
  }

  var displayName: String { profile.rawValue }
}

enum CleanupRisk: String, Codable, CaseIterable {
  case minimal = "極低風險"
  case low = "低風險"
  case moderate = "中等影響"
  case high = "高影響"
  case reviewOnly = "僅檢視"
}

enum CleanupExecutionMode: String, Codable, CaseIterable, Identifiable {
  case moveToTrash = "move_to_finder_visible_trash"
  case forceDelete = "direct_delete"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .moveToTrash: return "移到 Finder 可見垃圾桶"
    case .forceDelete: return "直接徹底刪除"
    }
  }

  var symbol: String {
    switch self {
    case .moveToTrash: return "trash"
    case .forceDelete: return "trash.slash"
    }
  }
}

enum CleanupActionKind: String, Codable, CaseIterable {
  case moveContentsToTrash = "移動內容到 Finder 可見垃圾桶"
  case moveItemToTrash = "移動項目到 Finder 可見垃圾桶"
  case moveMatchedItemsToTrash = "移動匹配項目到 Finder 可見垃圾桶"
  case permanentDeleteMatchedItems = "直接徹底刪除匹配項目"
  case managedCommand = "受管理清理（直接刪除）"
  case reviewOnly = "只提供檢視與建議"

  var isExecutable: Bool { self != .reviewOnly }
}

enum CleanupCategory: String, Codable, CaseIterable {
  case standardCache = "標準使用者快取"
  case sandboxCache = "沙盒與群組快取"
  case clipboardArchive = "跨裝置剪貼簿暫存"
  case applicationCache = "App 網頁與繪圖快取"
  case developerCache = "開發工具快取"
  case packageManagerCache = "套件管理器快取"
  case downloadResidue = "下載殘留與舊安裝檔"
  case appLeftovers = "已卸載 App 殘留"
  case brokenPreferences = "損壞的第三方偏好設定"
  case diagnosticsAndLogs = "診斷與使用者日誌"
  case highImpactUserData = "高影響可回收資料"
  case trashBins = "廢紙簍（永久清空）"
  case systemManagedReview = "系統管理項目（僅檢視）"
  case folderFinderMetadata = "Finder 顯示中繼資料"
  case folderWindowsMetadata = "Windows 顯示中繼資料"
  case folderArchiveMetadata = "Mac 壓縮封裝中繼資料"
  case folderAppleDoubleRemnants = "AppleDouble 孤立殘留"
  case folderAppleDouble = "AppleDouble 配對中繼資料"
  case folderAppleDoubleReview = "AppleDouble 敏感內容（僅檢視）"
  case folderMacManagedReview = "macOS 卷宗中繼資料（高風險）"
  case folderLegacyTrashResidue = "舊版隱藏垃圾桶殘留（直接刪除）"
  case folderLegacyReview = "舊式 Apple metadata（僅檢視）"
}

enum CleanupRuleID: String, Codable, CaseIterable {
  case standardUserCache
  case sandboxCache
  case groupContainerCache
  case clipboardArchive
  case applicationRenderCache
  case applicationOfflineCache
  case xcodeDerivedData
  case xcodePreviewsCache
  case coreSimulatorCache
  case xcodeDeviceSupport
  case developerToolCacheDirectory
  case packageCacheDirectory
  case homebrewCleanup
  case condaCleanup
  case incompleteDownload
  case staleInstallerPackage
  case staleDiskImage
  case appLeftoverEntry
  case corruptPreferencePlist
  case userLogDirectory
  case diagnosticReports
  case mobileDeviceBackup
  case xcodeArchive
  case mailDownloads
  case trashBinContents
  case systemManagedReview
  case folderDSStore
  case folderDSStoreAppleDoubleSidecar
  case folderWindowsMetadata
  case folderWindowsAppleDoubleSidecar
  case folderMacOSXDirectory
  case folderOrphanedAppleDoubleSidecar
  case folderAppleDoubleSidecar
  case folderSensitiveAppleDoubleSidecar
  case folderUnrecognizedDotUnderscore
  case folderSpotlightMetadata
  case folderFSEventsMetadata
  case folderTrashMetadata
  case folderLegacySpotlightTrashResidue
  case folderLegacyFSEventsTrashResidue
  case folderMacVolumeMarkerMetadata
  case folderLegacyAppleMetadata
}

struct ManagedCleanupCommand: Codable, Hashable {
  let executable: String
  let arguments: [String]
  let displayCommand: String
  let timeoutSeconds: TimeInterval
}

struct CleanupCandidate: Identifiable, Codable, Hashable {
  let id: UUID
  let ruleID: CleanupRuleID
  let scope: CleanupScope
  let tier: CleanupTier
  let category: CleanupCategory
  let action: CleanupActionKind
  let path: String
  let displayName: String
  let bytes: Int64
  let risk: CleanupRisk
  let reason: String
  let impact: String
  let recovery: String
  let managedCommand: ManagedCleanupCommand?
  let matchedPaths: [String]
  let matchedPathBytes: [String: Int64]
  let cleanupRootPath: String?
  var selected: Bool

  init(
    id: UUID = UUID(),
    ruleID: CleanupRuleID,
    scope: CleanupScope,
    tier: CleanupTier,
    category: CleanupCategory,
    action: CleanupActionKind,
    path: String,
    displayName: String,
    bytes: Int64,
    risk: CleanupRisk,
    reason: String,
    impact: String,
    recovery: String,
    managedCommand: ManagedCleanupCommand? = nil,
    matchedPaths: [String] = [],
    matchedPathBytes: [String: Int64] = [:],
    cleanupRootPath: String? = nil,
    selected: Bool = false
  ) {
    self.id = id
    self.ruleID = ruleID
    self.scope = scope
    self.tier = tier
    self.category = category
    self.action = action
    self.path = path
    self.displayName = displayName
    self.bytes = max(0, bytes)
    self.risk = risk
    self.reason = reason
    self.impact = impact
    self.recovery = recovery
    self.managedCommand = managedCommand
    self.matchedPaths = matchedPaths
    self.matchedPathBytes = matchedPathBytes.filter { matchedPaths.contains($0.key) }
    self.cleanupRootPath = cleanupRootPath
    self.selected = selected && action.isExecutable
  }

  var isSelectable: Bool { action.isExecutable }

  /// `true` only when Finder can be the reversible owner of the operation.
  /// Managed commands and legacy hidden-Trash residues are intentionally direct-only.
  var supportsFinderVisibleTrash: Bool {
    switch action {
    case .moveContentsToTrash, .moveItemToTrash, .moveMatchedItemsToTrash:
      return true
    case .permanentDeleteMatchedItems, .managedCommand, .reviewOnly:
      return false
    }
  }

  /// Every executable candidate may be explicitly removed without using Trash.
  /// Rule-specific path validation still runs immediately before removal.
  var supportsDirectDeletion: Bool { isSelectable }

  /// Narrow external-volume subset handled by ExternalVolumeCleanupExecutor.
  var supportsExternalVolumeDirectDeletion: Bool {
    guard let rootPath = cleanupRootPath, !matchedPaths.isEmpty else { return false }
    let supported: Bool
    switch ruleID {
    case .folderSpotlightMetadata, .folderFSEventsMetadata:
      supported = action == .moveMatchedItemsToTrash && matchedPaths.count == 1
    case .folderLegacySpotlightTrashResidue, .folderLegacyFSEventsTrashResidue:
      supported = action == .permanentDeleteMatchedItems && !matchedPaths.isEmpty
    default:
      supported = false
    }
    guard supported else { return false }

    let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
    return root.path != "/Volumes"
      && root.deletingLastPathComponent().standardizedFileURL.path == "/Volumes"
  }

  /// Backward-compatible alias used by older verification fixtures.
  var supportsForcedDeletion: Bool { supportsExternalVolumeDirectDeletion }

  var requiresDirectDeletion: Bool {
    action == .permanentDeleteMatchedItems || action == .managedCommand
  }
  var requiresManualSelection: Bool {
    isSelectable && (action == .managedCommand || tier >= .aggressive || risk == .high)
  }
  var isBulkSelectable: Bool { isSelectable && !requiresManualSelection }
  var itemCount: Int { matchedPaths.isEmpty ? 1 : matchedPaths.count }
  var requiresElevatedConfirmation: Bool {
    requiresManualSelection
  }
}

struct CleanupScanProgress: Hashable {
  let message: String
  let currentPath: String?
  let currentStep: Int
  let totalSteps: Int

  var fraction: Double {
    guard totalSteps > 0 else { return 0 }
    return min(1, max(0, Double(currentStep) / Double(totalSteps)))
  }
}

struct CleanupScanResult: Hashable {
  let configuration: CleanupScanConfiguration
  let candidates: [CleanupCandidate]
  let startedAt: Date
  let finishedAt: Date
  let notices: [String]
  let mode: CleanupMode
  let target: ScanTarget
  let scanSource: CleanupScanSource
  let sourceReportURL: URL?

  init(
    configuration: CleanupScanConfiguration,
    candidates: [CleanupCandidate],
    startedAt: Date,
    finishedAt: Date,
    notices: [String],
    mode: CleanupMode = .system,
    target: ScanTarget = .systemStorage,
    scanSource: CleanupScanSource = .liveFilesystem,
    sourceReportURL: URL? = nil
  ) {
    self.configuration = configuration
    self.candidates = candidates
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.notices = notices
    self.mode = mode
    self.target = target
    self.scanSource = scanSource
    self.sourceReportURL = sourceReportURL
  }

  var durationSeconds: TimeInterval { max(0, finishedAt.timeIntervalSince(startedAt)) }
  var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
  var selectableCount: Int { candidates.filter(\.isSelectable).count }
  var reviewOnlyCount: Int { candidates.filter { !$0.isSelectable }.count }
  var matchedItemCount: Int { candidates.reduce(0) { $0 + $1.itemCount } }
}

struct FinderVisibleTrashReceipt: Codable, Hashable {
  let originalPath: String
  let destinationPath: String
  let visibleName: String
  /// Structural verification: non-dot name, hidden flag cleared, and a direct
  /// child of a Finder-managed Trash location. AppKit does not provide a Finder
  /// window-render callback, so this field never pretends to be a screenshot.
  let finderVisibilityVerified: Bool
  /// True when the old source was moved successfully but macOS or another
  /// process immediately created a different file-system object at the same path.
  let sourcePathRecreated: Bool
  let removalMethod: String
}

struct CleanupLog: Codable {
  struct Entry: Codable {
    let ruleID: String
    let sourcePath: String
    let action: String
    let movedItems: [String]
    let permanentlyDeletedItems: [String]
    let recreatedItems: [String]
    let failures: [String]
    let notes: [String]
    let estimatedBytes: Int64
    let command: String?
    let commandExitStatus: Int32?
    let commandStandardOutput: String?
    let commandStandardError: String?
    /// Exact Trash destinations returned by the legacy or Finder-style recycle path.
    /// Older logs encode these in notes only; keeping the field optional preserves compatibility.
    let trashItemPaths: [String]?
    /// Finder-style Trash receipts. A successful modern Trash operation is not
    /// accepted unless the destination is a non-hidden, non-dot direct child of
    /// a Finder-managed Trash; AppModel then asks Finder to reveal the exact URL.
    let finderVisibleTrashItems: [FinderVisibleTrashReceipt]?
    /// `pending_finder_trash_empty`, `immediate_direct_delete`, or a managed equivalent.
    let spaceReleaseSemantics: String?
    /// App-owned removal method used for irreversible cleanup.
    let removalMethod: String?
    let errorDomain: String?
    let errorCode: Int?

    init(
      ruleID: String,
      sourcePath: String,
      action: String,
      movedItems: [String],
      permanentlyDeletedItems: [String],
      recreatedItems: [String],
      failures: [String],
      notes: [String],
      estimatedBytes: Int64,
      command: String?,
      commandExitStatus: Int32?,
      commandStandardOutput: String?,
      commandStandardError: String?,
      trashItemPaths: [String]? = nil,
      finderVisibleTrashItems: [FinderVisibleTrashReceipt]? = nil,
      spaceReleaseSemantics: String? = nil,
      removalMethod: String? = nil,
      errorDomain: String? = nil,
      errorCode: Int? = nil
    ) {
      self.ruleID = ruleID
      self.sourcePath = sourcePath
      self.action = action
      self.movedItems = movedItems
      self.permanentlyDeletedItems = permanentlyDeletedItems
      self.recreatedItems = recreatedItems
      self.failures = failures
      self.notes = notes
      self.estimatedBytes = estimatedBytes
      self.command = command
      self.commandExitStatus = commandExitStatus
      self.commandStandardOutput = commandStandardOutput
      self.commandStandardError = commandStandardError
      self.trashItemPaths = trashItemPaths
      self.finderVisibleTrashItems = finderVisibleTrashItems
      self.spaceReleaseSemantics = spaceReleaseSemantics
      self.removalMethod = removalMethod
      self.errorDomain = errorDomain
      self.errorCode = errorCode
    }
  }

  let createdAt: Date
  let mode: String
  let removalMode: String
  let profile: String
  let targetKind: String
  let targetPath: String
  let entries: [Entry]
}

enum SidebarDestination: String, CaseIterable, Identifiable {
  case overview = "總覽"
  case browser = "資料樹"
  case cleaner = "安全清理"
  case history = "掃描紀錄"
  case settings = "設定"
  case about = "關於"

  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .overview: return "chart.pie"
    case .browser: return "folder"
    case .cleaner: return "trash.slash"
    case .history: return "clock.arrow.circlepath"
    case .settings: return "gearshape"
    case .about: return "info.circle"
    }
  }
}
