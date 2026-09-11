import Foundation

private enum AuditFailure: LocalizedError {
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .failed(let message): return message
    }
  }
}

private struct AuditOutput: Codable {
  let version: String
  let build: Int
  let scanner: String
  let passed: Int
  let checks: [String]
  let parsed: ParsedValues

  struct ParsedValues: Codable {
    let filesystemType: String
    let spotlightStatus: String
    let fseventsStatus: String
    let trashStatus: String
    let preflightSeconds: Int
    let prepareSeconds: Int
    let pathSeconds: Int
    let metadataSeconds: Int
    let reportWriteSeconds: Int
    let totalSeconds: Int
    let fullDiskAccessProbe: String
    let accountingGapBytes: Int64
  }
}

@main
struct ExternalVolumeRescanAudit {
  static func main() throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("MacStorageLens-rescan-audit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let root = "/Volumes/PAPER S3"
    let report = """
      # PAPER S3 - 唯讀儲存空間資料樹

      ## RUN_METADATA
      ````text
      scanner_version=2.5.3
      generated_at=2026-08-19 03:00:00 +0800
      data_collection_duration_seconds=4
      scanner_process_started_epoch=1787079600
      preflight_duration_seconds=0
      prepare_duration_seconds=1
      path_scan_duration_seconds=1
      metadata_duration_seconds=1
      scan_target_kind=volume
      scan_target_path=\(root)
      scan_target_display_name=PAPER S3
      scan_target_volume_uuid=TEST-UUID
      target_mount_point=\(root)
      target_filesystem_type=msdos
      target_is_apfs=false
      target_spotlight_root_status=PRESENT
      target_fsevents_root_status=ABSENT
      target_trash_root_status=PRESENT
      target_volatile_status_is_recursive=false
      launcher_mode=app
      scanner_privilege_channel=app_direct
      administrator_read_access=false
      full_disk_access_probe=NOT_APPLICABLE
      full_disk_access_probe_path=NONE
      full_disk_access_source=selected_location
      app_full_disk_access_probe=NOT_APPLICABLE
      app_full_disk_access_probe_path=NONE
      scanner_full_disk_access_probe=NOT_APPLICABLE
      scanner_full_disk_access_probe_path=NONE
      tcc_overlay_status=NOT_REQUESTED
      tcc_overlay_applied=false
      scan_root_count=1
      path_scan_status=NO_REPORTED_DU_ERRORS
      du_error_line_count=0
      permission_or_tcc_error_count=0
      volume_scan_profile=fast_stable_volume_tree
      volume_volatile_metadata_excluded=true
      volume_volatile_metadata_names=.Trashes,.Trash,.Spotlight-V100,.fseventsd
      ````

      ## TARGET_VOLUME_ACCOUNTING_DIFFERENCE
      ````text
      accounting_scope=selected_volume
      accounting_gap_applicable=true
      target_path=\(root)
      target_mount_point=\(root)
      target_tree_du_kib=3534912
      target_volume_capacity_kib=30357008
      target_volume_used_kib_pre_scan=3536960
      target_volume_available_kib_pre_scan=26820048
      target_volume_used_kib_post_scan_before_report=3536960
      target_post_minus_pre_kib=0
      target_accounting_gap_kib=2048
      ````

      ## ROOT_SCAN_SUMMARY
      | Root | du KiB | GiB | GB | Directory nodes | Diagnostic lines | Permission/TCC restrictions | du exit | Seconds |
      |---|---:|---:|---:|---:|---:|---:|---:|---:|
      | `\(root)` | 3534912 | 3.371 | 3.620 | 17 | 0 | 0 | 0 | 1 |

      ## ROOT \(root)
      ### DIRECTORY_TREE (\(root))
      ````text
      3534912 KiB  \(root)
      2000000 KiB  \(root)/DCIM
      1534912 KiB  \(root)/Projects
      ````

      ## COMPLETION
      ````text
      completed_at=2026-08-19 03:00:04 +0800
      total_duration_seconds=4
      report_write_duration_seconds=1
      report_complete=true
      ````
      """

    let reportURL = temp.appendingPathComponent("volume-storage-tree-fixture.md")
    try Data(report.utf8).write(to: reportURL, options: Data.WritingOptions.atomic)

    let document = try ReportParser().parse(url: reportURL)
    let summary = document.summary
    var checks: [String] = []

    try require(summary.scannerVersion == "2.5.3", "Scanner version was not parsed")
    checks.append("scanner_version")
    try require(summary.targetKind == .volume, "Target kind was not parsed as volume")
    checks.append("target_kind")
    try require(summary.targetFilesystemType == "msdos", "Filesystem type was not parsed")
    checks.append("filesystem_type")
    try require(summary.targetSpotlightRootStatus == "PRESENT", "Spotlight status was not parsed")
    checks.append("spotlight_status")
    try require(summary.targetFSEventsRootStatus == "ABSENT", "FSEvents status was not parsed")
    checks.append("fsevents_status")
    try require(summary.targetTrashRootStatus == "PRESENT", "Trash status was not parsed")
    checks.append("trash_status")
    try require(
      summary.fullDiskAccessProbe == "NOT_APPLICABLE",
      "External target FDA should be not applicable")
    checks.append("fda_not_applicable")
    try require(summary.preflightDurationSeconds == 0, "Preflight timing was not parsed")
    try require(summary.prepareDurationSeconds == 1, "Prepare timing was not parsed")
    try require(summary.pathScanDurationSeconds == 1, "Path timing was not parsed")
    try require(summary.metadataDurationSeconds == 1, "Metadata timing was not parsed")
    try require(summary.reportWriteDurationSeconds == 1, "Report timing was not parsed")
    try require(summary.totalDurationSeconds == 4, "Total timing was not parsed")
    checks.append("phase_timings")
    try require(summary.targetAccountingGapBytes == 2_097_152, "Accounting gap conversion is wrong")
    checks.append("accounting_gap")
    try require(document.sections.count == 1, "Expected one directory-tree section")
    checks.append("directory_tree")

    let staleTarget = ScanTarget(
      kind: .volume,
      displayName: "PAPER S3",
      path: "/Volumes/PAPER S3 OLD",
      volumeUUID: "3A595B23-3892-38BE-88C2-770741A343BD"
    )
    let remountedTarget = ScanTarget(
      kind: .volume,
      displayName: "PAPER S3",
      path: "/Volumes/PAPER S3",
      volumeUUID: "3a595b23-3892-38be-88c2-770741a343bd"
    )
    let otherTarget = ScanTarget(
      kind: .volume,
      displayName: "OTHER",
      path: "/Volumes/OTHER",
      volumeUUID: "OTHER-UUID"
    )
    try require(
      ScanTargetResolver.resolveMountedTarget(
        staleTarget,
        mountedVolumes: [otherTarget, remountedTarget]
      ) == remountedTarget,
      "A stale mount path did not resolve by Volume UUID"
    )
    checks.append("volume_uuid_remount_resolution")

    let pathOnlyTarget = ScanTarget(
      kind: .volume,
      displayName: "Legacy",
      path: "/Volumes/Legacy",
      volumeUUID: nil
    )
    let pathOnlyMounted = ScanTarget(
      kind: .volume,
      displayName: "Legacy Renamed",
      path: "/Volumes/Legacy",
      volumeUUID: "DISCOVERED-UUID"
    )
    try require(
      ScanTargetResolver.resolveMountedTarget(
        pathOnlyTarget,
        mountedVolumes: [pathOnlyMounted]
      ) == pathOnlyMounted,
      "A legacy target without UUID did not resolve by its exact path"
    )
    checks.append("legacy_path_resolution")

    let reusedPathTarget = ScanTarget(
      kind: .volume,
      displayName: "Old Card",
      path: "/Volumes/Legacy",
      volumeUUID: "OLD-UUID"
    )
    try require(
      ScanTargetResolver.resolveMountedTarget(
        reusedPathTarget,
        mountedVolumes: [pathOnlyMounted]
      ) == nil,
      "A reused mount path with a different UUID was accepted"
    )
    checks.append("uuid_mismatch_rejects_reused_path")

    let output = AuditOutput(
      version: "1.6.8",
      build: 25,
      scanner: "2.5.3",
      passed: checks.count,
      checks: checks,
      parsed: .init(
        filesystemType: summary.targetFilesystemType,
        spotlightStatus: summary.targetSpotlightRootStatus,
        fseventsStatus: summary.targetFSEventsRootStatus,
        trashStatus: summary.targetTrashRootStatus,
        preflightSeconds: summary.preflightDurationSeconds,
        prepareSeconds: summary.prepareDurationSeconds,
        pathSeconds: summary.pathScanDurationSeconds,
        metadataSeconds: summary.metadataDurationSeconds,
        reportWriteSeconds: summary.reportWriteDurationSeconds,
        totalSeconds: summary.totalDurationSeconds,
        fullDiskAccessProbe: summary.fullDiskAccessProbe,
        accountingGapBytes: summary.targetAccountingGapBytes
      )
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(output)
    if CommandLine.arguments.count >= 2 {
      try data.write(
        to: URL(fileURLWithPath: CommandLine.arguments[1]), options: Data.WritingOptions.atomic)
    } else {
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
    }
  }

  private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AuditFailure.failed(message) }
  }
}
