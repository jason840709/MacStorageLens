import Foundation

private struct AuditResult: Encodable {
  let profile: String
  let scannerVersion: String
  let generatedAt: String
  let targetKind: String
  let targetPath: String
  let launcherMode: String
  let scanChannel: String
  let reportComplete: Bool
  let administratorReadAccess: Bool
  let fullDiskAccessProbe: String
  let fullDiskAccessSource: String
  let appFullDiskAccessProbe: String
  let scannerFullDiskAccessProbe: String
  let legacyAdministratorProbeIsAmbiguous: Bool
  let tccOverlayApplied: Bool
  let tccOverlayTreeBytes: Int64
  let tccOverlayReplacedBytes: Int64
  let tccOverlayDeltaBytes: Int64
  let pathScanStatus: String
  let diagnosticLines: Int
  let permissionOrTCCErrors: Int
  let rootSectionCount: Int
  let snapshotCount: Int
  let systemSnapshotCount: Int
  let timeMachineSnapshotCount: Int
  let containerTotalBytes: Int64
  let containerUsedBytes: Int64
  let containerFreeBytes: Int64
  let dataAPFSBytes: Int64
  let dataDFPreBytes: Int64
  let dataDFPostBytes: Int64
  let mappedTreeBytes: Int64
  let unresolvedGapBytes: Int64
  let dataSamplingRemainderBytes: Int64
  let apfsContainerRemainderBytes: Int64
  let overviewRootBytes: Int64
  let overviewChildrenBytes: Int64
  let trueFreeNodeBytes: Int64
  let selectedVolumeNodeCount: Int
  let mappedTreeNodeCount: Int
  let mappedTreeChildCount: Int
  let accountingCloses: Bool
  let assertions: [String]
}

private enum AuditFailure: LocalizedError {
  case failed(String)
  var errorDescription: String? {
    switch self {
    case .failed(let message): return message
    }
  }
}

@main
struct ReportAudit {
  static func main() throws {
    guard CommandLine.arguments.count >= 2 else {
      throw AuditFailure.failed("Usage: ReportAudit REPORT.md [OUTPUT.json]")
    }

    let reportURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let parser = ReportParser()
    let document = try parser.parse(url: reportURL)
    let summary = document.summary
    let targetPath =
      document.sections[summary.targetPath] != nil
      ? summary.targetPath
      : (document.sections["/System/Volumes/Data"] != nil
        ? "/System/Volumes/Data"
        : (document.sections.keys.sorted().first ?? summary.targetPath))
    let (_, presentation) = try parser.loadPresentation(
      document: document,
      parentPath: targetPath,
      maximumDepth: 4,
      maximumChildren: 12
    )
    let overview = CapacityMapBuilder.buildOverview(
      summary: summary,
      presentation: presentation,
      targetPath: targetPath
    )

    var assertions: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
      guard condition() else { throw AuditFailure.failed("Assertion failed: \(name)") }
      assertions.append(name)
    }

    try check(summary.reportComplete, "report_complete")
    try check(summary.targetKind == .system, "system_target")
    try check(summary.targetPath == "/System/Volumes/Data", "target_path_data")
    try check(!document.sections.isEmpty, "directory_tree_sections_present")
    try check(summary.capacityBytes > 0, "container_capacity_positive")
    try check(summary.containerUsedBytes >= 0, "container_used_nonnegative")
    try check(summary.availableBytes >= 0, "container_free_nonnegative")
    try check(
      summary.containerUsedBytes + summary.availableBytes == summary.capacityBytes,
      "container_used_plus_free_equals_capacity"
    )
    try check(summary.dataVisibleBytes > 0, "mapped_tree_positive")
    try check(summary.dataUsedBytes >= summary.dataVisibleBytes, "df_used_not_below_tree")
    try check(summary.accountingGapBytes >= 0, "unresolved_gap_nonnegative")
    try check(CapacityMapBuilder.accountingCloses(overview), "overview_accounting_closes")

    let overviewChildrenBytes = overview.children.reduce(Int64(0)) { $0 + $1.bytes }
    let trueFreeNodeBytes = overview.children.first(where: { $0.kind == .freeSpace })?.bytes ?? 0
    let selectedVolumeNodes = overview.children.filter { $0.colorHint == .selectedVolume }
    let mappedTreeNodes = selectedVolumeNodes.flatMap(\.children).filter {
      $0.colorHint == .mappedTree
    }
    let mappedTreeChildCount = mappedTreeNodes.reduce(0) { $0 + $1.children.count }
    try check(overviewChildrenBytes == overview.bytes, "overview_children_equal_root")
    try check(trueFreeNodeBytes == summary.availableBytes, "true_free_visible_in_overview")
    try check(selectedVolumeNodes.count == 1, "overview_has_one_selected_volume_color_layer")
    try check(mappedTreeNodes.count == 1, "overview_has_one_mapped_tree_color_bridge")
    try check(mappedTreeChildCount >= 6, "mapped_tree_exposes_diverse_folder_families")

    let profile: String
    if summary.scannerVersion == "2.5.1",
      summary.generatedAt == "2026-08-16 01:21:37 +0800"
    {
      profile = "user-runtime-20260816-012018"
      try check(summary.administratorReadAccess, "runtime_2_5_1_admin_access_true")
      try check(
        summary.appFullDiskAccessProbe == "LIKELY_AVAILABLE",
        "runtime_2_5_1_app_fda_available"
      )
      try check(
        summary.scannerFullDiskAccessProbe == "LIKELY_MISSING_OR_TCC_BLOCKED",
        "runtime_2_5_1_scanner_child_tcc_blocked"
      )
      try check(
        summary.fullDiskAccessProbe == "LIKELY_AVAILABLE",
        "runtime_2_5_1_effective_fda_available"
      )
      try check(
        summary.fullDiskAccessSource == "app_tcc_overlay",
        "runtime_2_5_1_effective_source_overlay"
      )
      try check(summary.tccOverlayApplied, "runtime_2_5_1_overlay_applied")
      try check(
        summary.tccOverlayTreeBytes == 92_508_844_032,
        "runtime_2_5_1_overlay_tree_exact"
      )
      try check(
        summary.tccOverlayReplacedBytes == 66_768_920_576,
        "runtime_2_5_1_overlay_replaced_exact"
      )
      try check(
        summary.tccOverlayDeltaBytes == 25_739_923_456,
        "runtime_2_5_1_overlay_delta_exact"
      )
      try check(summary.errorCount == 186, "runtime_2_5_1_permission_tcc_186")
      try check(summary.duErrorLineCount == 186, "runtime_2_5_1_diagnostic_186")
      try check(
        summary.pathScanStatus == "PARTIAL_UNREADABLE_PATHS",
        "runtime_2_5_1_partial_coverage"
      )
      try check(document.sections.count == 16, "runtime_2_5_1_root_sections_16")
      try check(summary.capacityBytes == 494_384_795_648, "runtime_2_5_1_capacity_exact")
      try check(summary.containerUsedBytes == 360_916_660_224, "runtime_2_5_1_used_exact")
      try check(summary.availableBytes == 133_468_135_424, "runtime_2_5_1_free_exact")
      try check(
        summary.dataAPFSVolumeUsedBytes == 329_187_446_784,
        "runtime_2_5_1_data_apfs_exact"
      )
      try check(summary.dataUsedBytes == 329_099_976_704, "runtime_2_5_1_data_df_pre_exact")
      try check(
        summary.dataUsedPostBytes == 329_188_515_840,
        "runtime_2_5_1_data_df_post_exact"
      )
      try check(summary.dataVisibleBytes == 314_150_921_216, "runtime_2_5_1_tree_exact")
      try check(summary.accountingGapBytes == 14_949_055_488, "runtime_2_5_1_gap_exact")
      try check(
        summary.dataSamplingRemainderBytes == 87_470_080,
        "runtime_2_5_1_sampling_remainder_exact"
      )
      try check(
        summary.otherContainerBytes == 161_996_800,
        "runtime_2_5_1_container_remainder_exact"
      )
      try check(summary.systemSnapshotCount == 1, "runtime_2_5_1_system_snapshot_1")
      try check(summary.timeMachineSnapshotCount == 1, "runtime_2_5_1_tm_snapshot_1")
      try check(
        !summary.hasAmbiguousLegacyAdministratorProbe,
        "runtime_2_5_1_not_legacy_ambiguous"
      )
      try check(
        summary.scanChannelDisplayName == "App TCC + 管理員",
        "runtime_2_5_1_channel_display"
      )
    } else if summary.scannerVersion == "2.5.0",
      summary.generatedAt == "2026-08-15 21:19:31 +0800"
    {
      profile = "user-runtime-20260815-211815"
      try check(summary.administratorReadAccess, "runtime_admin_access_true")
      try check(summary.errorCount == 636, "runtime_permission_tcc_636")
      try check(summary.duErrorLineCount == 636, "runtime_diagnostic_636")
      try check(summary.pathScanStatus == "PARTIAL_UNREADABLE_PATHS", "runtime_partial_coverage")
      try check(document.sections.count == 16, "runtime_root_sections_16")
      try check(summary.capacityBytes == 494_384_795_648, "runtime_capacity_exact")
      try check(summary.containerUsedBytes == 360_221_478_912, "runtime_used_exact")
      try check(summary.availableBytes == 134_163_316_736, "runtime_free_exact")
      try check(summary.dataAPFSVolumeUsedBytes == 328_491_356_160, "runtime_data_apfs_exact")
      try check(summary.dataUsedBytes == 328_403_537_920, "runtime_data_df_pre_exact")
      try check(summary.dataUsedPostBytes == 328_491_356_160, "runtime_data_df_post_exact")
      try check(summary.dataVisibleBytes == 288_148_546_560, "runtime_tree_exact")
      try check(summary.accountingGapBytes == 40_254_991_360, "runtime_gap_exact")
      try check(
        summary.dataSamplingRemainderBytes == 87_818_240, "runtime_sampling_remainder_exact")
      try check(summary.otherContainerBytes == 162_906_112, "runtime_container_remainder_exact")
      try check(summary.systemSnapshotCount == 1, "runtime_system_snapshot_1")
      try check(summary.timeMachineSnapshotCount == 1, "runtime_tm_snapshot_1")
      try check(summary.hasAmbiguousLegacyAdministratorProbe, "runtime_legacy_probe_ambiguous")
      try check(summary.appFullDiskAccessProbe == "UNKNOWN", "runtime_app_probe_not_invented")
      try check(
        summary.scannerFullDiskAccessProbe == "LIKELY_MISSING_OR_TCC_BLOCKED",
        "runtime_probe_attributed_to_scanner_child"
      )
    } else if summary.scannerVersion == "2.4.1",
      summary.capacityBytes == 494_384_795_648,
      summary.errorCount == 632
    {
      profile = "legacy-user-runtime-20260815-151305"
      try check(document.sections.count == 16, "legacy_root_sections_16")
      try check(summary.availableBytes == 122_067_009_536, "legacy_free_exact")
      try check(summary.dataVisibleBytes == 287_940_842_496, "legacy_tree_exact")
      try check(summary.accountingGapBytes == 52_543_253_504, "legacy_gap_exact")
    } else {
      profile = "generic-system-report"
    }

    let result = AuditResult(
      profile: profile,
      scannerVersion: summary.scannerVersion,
      generatedAt: summary.generatedAt,
      targetKind: summary.targetKind.rawValue,
      targetPath: summary.targetPath,
      launcherMode: summary.launcherMode,
      scanChannel: summary.scanChannelDisplayName,
      reportComplete: summary.reportComplete,
      administratorReadAccess: summary.administratorReadAccess,
      fullDiskAccessProbe: summary.fullDiskAccessProbe,
      fullDiskAccessSource: summary.fullDiskAccessSource,
      appFullDiskAccessProbe: summary.appFullDiskAccessProbe,
      scannerFullDiskAccessProbe: summary.scannerFullDiskAccessProbe,
      legacyAdministratorProbeIsAmbiguous: summary.hasAmbiguousLegacyAdministratorProbe,
      tccOverlayApplied: summary.tccOverlayApplied,
      tccOverlayTreeBytes: summary.tccOverlayTreeBytes,
      tccOverlayReplacedBytes: summary.tccOverlayReplacedBytes,
      tccOverlayDeltaBytes: summary.tccOverlayDeltaBytes,
      pathScanStatus: summary.pathScanStatus,
      diagnosticLines: summary.duErrorLineCount,
      permissionOrTCCErrors: summary.errorCount,
      rootSectionCount: document.sections.count,
      snapshotCount: summary.snapshotNames.count,
      systemSnapshotCount: summary.systemSnapshotCount,
      timeMachineSnapshotCount: summary.timeMachineSnapshotCount,
      containerTotalBytes: summary.capacityBytes,
      containerUsedBytes: summary.containerUsedBytes,
      containerFreeBytes: summary.availableBytes,
      dataAPFSBytes: summary.dataAPFSVolumeUsedBytes,
      dataDFPreBytes: summary.dataUsedBytes,
      dataDFPostBytes: summary.dataUsedPostBytes,
      mappedTreeBytes: summary.dataVisibleBytes,
      unresolvedGapBytes: summary.accountingGapBytes,
      dataSamplingRemainderBytes: summary.dataSamplingRemainderBytes,
      apfsContainerRemainderBytes: summary.otherContainerBytes,
      overviewRootBytes: overview.bytes,
      overviewChildrenBytes: overviewChildrenBytes,
      trueFreeNodeBytes: trueFreeNodeBytes,
      selectedVolumeNodeCount: selectedVolumeNodes.count,
      mappedTreeNodeCount: mappedTreeNodes.count,
      mappedTreeChildCount: mappedTreeChildCount,
      accountingCloses: CapacityMapBuilder.accountingCloses(overview),
      assertions: assertions
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)
    if CommandLine.arguments.count >= 3 {
      try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}
