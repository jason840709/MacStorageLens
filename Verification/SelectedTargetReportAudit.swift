import Foundation

private struct AuditResult: Encodable {
  let version: String
  let build: Int
  let profile: String
  let scannerVersion: String
  let generatedAt: String
  let targetKind: String
  let targetMountMatchesPath: Bool
  let reportComplete: Bool
  let primaryAPFSContainerReference: String?
  let targetAPFSVolumeDevice: String?
  let capacityBytes: Int64
  let usedBytes: Int64
  let availableBytes: Int64
  let treeBytes: Int64
  let accountingGapBytes: Int64
  let overviewBytes: Int64
  let overviewChildrenBytes: Int64
  let overviewSemanticLabels: [String]
  let freeNodeBytes: Int64
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
struct SelectedTargetReportAudit {
  static func main() throws {
    guard CommandLine.arguments.count >= 2 else {
      throw AuditFailure.failed("Usage: SelectedTargetReportAudit REPORT.md [OUTPUT.json]")
    }

    let reportURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let parser = ReportParser()
    let document = try parser.parse(url: reportURL)
    let summary = document.summary

    var assertions: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
      guard condition() else { throw AuditFailure.failed("Assertion failed: \(name)") }
      assertions.append(name)
    }

    try check(summary.reportComplete, "report_complete")
    try check(summary.targetKind != .system, "non_system_target")
    try check(!summary.targetPath.isEmpty, "target_path_present")
    try check(document.sections[summary.targetPath] != nil, "target_tree_section_present")
    try check(summary.targetTreeBytes > 0, "target_tree_positive")

    let (_, presentation) = try parser.loadPresentation(
      document: document,
      parentPath: summary.targetPath,
      maximumDepth: 4,
      maximumChildren: 12
    )
    let overview = CapacityMapBuilder.buildOverview(
      summary: summary,
      presentation: presentation,
      targetPath: summary.targetPath
    )
    let overviewChildrenBytes = overview.children.reduce(Int64(0)) { $0 + $1.bytes }
    let freeNodeBytes = overview.children.first(where: { $0.kind == .freeSpace })?.bytes ?? 0

    try check(CapacityMapBuilder.accountingCloses(overview), "overview_accounting_closes")
    try check(overviewChildrenBytes == overview.bytes, "overview_children_equal_root")

    switch summary.targetKind {
    case .volume:
      try check(summary.targetVolumeCapacityBytes > 0, "volume_capacity_positive")
      try check(
        summary.targetVolumeUsedBytes >= summary.targetTreeBytes, "volume_used_not_below_tree")
      try check(summary.targetVolumeAvailableBytes >= 0, "volume_available_nonnegative")
      try check(
        summary.targetVolumeUsedBytes + summary.targetVolumeAvailableBytes
          == summary.targetVolumeCapacityBytes,
        "volume_used_plus_available_equals_capacity"
      )
      try check(
        overview.bytes == summary.targetVolumeCapacityBytes, "volume_overview_uses_capacity")
      try check(freeNodeBytes == summary.targetVolumeAvailableBytes, "volume_free_node_exact")

    case .folder:
      try check(overview.bytes == summary.targetTreeBytes, "folder_overview_uses_tree")
      try check(freeNodeBytes == 0, "folder_has_no_volume_free_node")

    case .system:
      throw AuditFailure.failed("System reports must use ReportAudit.swift")
    }

    let internalLabels = [
      "Data", "Macintosh HD（System）", "VM", "Preboot", "Recovery", "APFS 容器帳務／metadata",
    ]
    if summary.targetKind == .volume, summary.primaryAPFSContainer == nil {
      try check(
        overview.children.allSatisfy { !internalLabels.contains($0.label) },
        "standalone_volume_has_no_foreign_apfs_siblings"
      )
    }

    let profile: String
    if summary.scannerVersion == "2.5.1",
      summary.generatedAt == "2026-08-18 12:41:16 +0800",
      summary.targetKind == .volume,
      summary.targetVolumeCapacityKiB == 30_357_008,
      summary.targetVolumeUsedKiB == 4_008_192
    {
      profile = "external-fat-runtime-regression"
      try check(summary.targetMountPoint == summary.targetPath, "runtime_mount_matches_target")
      try check(summary.primaryAPFSContainer == nil, "runtime_foreign_apfs_container_rejected")
      try check(summary.targetAPFSVolume == nil, "runtime_foreign_apfs_volume_rejected")
      try check(summary.targetVolumeCapacityBytes == 31_085_576_192, "runtime_capacity_exact")
      try check(summary.targetVolumeUsedBytes == 4_104_388_608, "runtime_used_exact")
      try check(summary.targetVolumeAvailableBytes == 26_981_187_584, "runtime_available_exact")
      try check(summary.targetTreeBytes == 4_104_372_224, "runtime_tree_exact")
      try check(summary.targetAccountingGapBytes == 16_384, "runtime_gap_exact")
      try check(
        Set(overview.children.map(\.label)) == Set(["可用空間", summary.targetDisplayName]),
        "runtime_overview_labels_exact"
      )
    } else {
      profile = "generic-selected-target-report"
    }

    let result = AuditResult(
      version: "1.6.8",
      build: 25,
      profile: profile,
      scannerVersion: summary.scannerVersion,
      generatedAt: summary.generatedAt,
      targetKind: summary.targetKind.rawValue,
      targetMountMatchesPath: summary.targetMountPoint == summary.targetPath,
      reportComplete: summary.reportComplete,
      primaryAPFSContainerReference: summary.primaryAPFSContainer?.reference,
      targetAPFSVolumeDevice: summary.targetAPFSVolume?.deviceIdentifier,
      capacityBytes: summary.targetVolumeCapacityBytes,
      usedBytes: summary.targetVolumeUsedBytes,
      availableBytes: summary.targetVolumeAvailableBytes,
      treeBytes: summary.targetTreeBytes,
      accountingGapBytes: summary.targetAccountingGapBytes,
      overviewBytes: overview.bytes,
      overviewChildrenBytes: overviewChildrenBytes,
      overviewSemanticLabels: overview.children.map {
        $0.label == summary.targetDisplayName ? "<selected-volume>" : $0.label
      },
      freeNodeBytes: freeNodeBytes,
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
