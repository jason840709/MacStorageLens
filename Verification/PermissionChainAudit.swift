import Foundation

private enum PermissionAuditFailure: LocalizedError {
  case failed(String)
  var errorDescription: String? {
    switch self {
    case .failed(let message): return message
    }
  }
}

private struct PermissionAuditOutput: Codable {
  let overlayAssertions: [String]
  let legacyAssertions: [String]
  let overlayChannel: String
  let overlayStatus: String
  let overlayTreeBytes: Int64
  let overlayReplacedBytes: Int64
  let overlayDeltaBytes: Int64
  let legacyAmbiguous: Bool
}

@main
struct PermissionChainAudit {
  static func main() throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(
        "MacStorageLens-permission-audit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let overlayReport = """
      # Macintosh HD - 唯讀儲存空間資料樹

      ## RUN_METADATA
      ````text
      scanner_version=2.5.1
      generated_at=2026-08-15 22:00:00 +0800
      scan_target_kind=system
      scan_target_path=/System/Volumes/Data
      scan_target_display_name=Macintosh HD
      target_mount_point=/System/Volumes/Data
      launcher_mode=app
      scanner_privilege_channel=app_tcc_overlay_plus_administrator
      administrator_read_access=true
      full_disk_access_probe=LIKELY_AVAILABLE
      full_disk_access_probe_path=/Users/test/Library/Mail
      full_disk_access_source=app_tcc_overlay
      app_full_disk_access_probe=LIKELY_AVAILABLE
      app_full_disk_access_probe_path=/Users/test/Library/Mail
      scanner_full_disk_access_probe=LIKELY_MISSING_OR_TCC_BLOCKED
      scanner_full_disk_access_probe_path=/Users/test/Library/Mail
      tcc_overlay_status=APPLIED
      tcc_overlay_root=/System/Volumes/Data/Users/test
      tcc_overlay_applied=true
      tcc_overlay_delta_kib=23000
      tcc_overlay_tree_kib=123000
      tcc_overlay_replaced_kib=100000
      path_scan_status=PARTIAL_UNREADABLE_PATHS
      du_error_line_count=2
      permission_or_tcc_error_count=2
      ````

      ## DATA_VOLUME_ACCOUNTING_DIFFERENCE
      ````text
      data_volume_du_kib=123000
      data_volume_df_used_kib_pre_scan=130000
      data_volume_df_used_kib_post_scan_before_report=130100
      post_minus_pre_kib=100
      df_pre_used_minus_du_kib=7000
      ````

      ## ROOT_SCAN_SUMMARY
      | Root | du KiB | GiB | GB | Directory nodes | Diagnostic lines | Permission/TCC restrictions | du exit | Seconds |
      |---|---:|---:|---:|---:|---:|---:|---:|---:|
      | `/System/Volumes/Data` | 123000 | 0.117 | 0.126 | 3 | 2 | 2 | 1 | 2 |

      ## ROOT /System/Volumes/Data
      ### DIRECTORY_TREE (/System/Volumes/Data)
      ````text
      123000 KiB  /System/Volumes/Data
      123000 KiB  /System/Volumes/Data/Users
      123000 KiB  /System/Volumes/Data/Users/test
      ````

      report_complete=true
      """

    let legacyReport = """
      # Macintosh HD - 唯讀儲存空間資料樹

      ## RUN_METADATA
      ````text
      scanner_version=2.5.0
      generated_at=2026-08-15 21:00:00 +0800
      scan_target_kind=system
      scan_target_path=/System/Volumes/Data
      scan_target_display_name=Macintosh HD
      target_mount_point=/System/Volumes/Data
      launcher_mode=app
      administrator_read_access=true
      full_disk_access_probe=LIKELY_MISSING_OR_TCC_BLOCKED
      full_disk_access_probe_path=/Users/test/Library/Mail
      path_scan_status=PARTIAL_UNREADABLE_PATHS
      du_error_line_count=1
      permission_or_tcc_error_count=1
      ````

      ## DATA_VOLUME_ACCOUNTING_DIFFERENCE
      ````text
      data_volume_du_kib=1000
      data_volume_df_used_kib_pre_scan=1200
      data_volume_df_used_kib_post_scan_before_report=1200
      post_minus_pre_kib=0
      df_pre_used_minus_du_kib=200
      ````

      ## ROOT_SCAN_SUMMARY
      | Root | du KiB | GiB | GB | Directory nodes | Diagnostic lines | Permission/TCC restrictions | du exit | Seconds |
      |---|---:|---:|---:|---:|---:|---:|---:|---:|
      | `/System/Volumes/Data` | 1000 | 0.001 | 0.001 | 1 | 1 | 1 | 1 | 1 |

      ## ROOT /System/Volumes/Data
      ### DIRECTORY_TREE (/System/Volumes/Data)
      ````text
      1000 KiB  /System/Volumes/Data
      ````

      report_complete=true
      """

    let overlayURL = temp.appendingPathComponent("overlay.md")
    let legacyURL = temp.appendingPathComponent("legacy.md")
    try Data(overlayReport.utf8).write(to: overlayURL)
    try Data(legacyReport.utf8).write(to: legacyURL)

    let parser = ReportParser()
    let overlay = try parser.parse(url: overlayURL).summary
    let legacy = try parser.parse(url: legacyURL).summary

    var overlayAssertions: [String] = []
    var legacyAssertions: [String] = []

    func overlayCheck(_ condition: @autoclosure () -> Bool, _ name: String) throws {
      guard condition() else { throw PermissionAuditFailure.failed("overlay: \(name)") }
      overlayAssertions.append(name)
    }
    func legacyCheck(_ condition: @autoclosure () -> Bool, _ name: String) throws {
      guard condition() else { throw PermissionAuditFailure.failed("legacy: \(name)") }
      legacyAssertions.append(name)
    }

    try overlayCheck(overlay.scannerVersion == "2.5.1", "scanner_2_5_1")
    try overlayCheck(overlay.appFullDiskAccessAvailable, "app_probe_available")
    try overlayCheck(!overlay.scannerFullDiskAccessAvailable, "scanner_child_probe_blocked")
    try overlayCheck(overlay.fullDiskAccessAvailable, "effective_coverage_available")
    try overlayCheck(overlay.fullDiskAccessSource == "app_tcc_overlay", "effective_source_overlay")
    try overlayCheck(overlay.usedAppTCCOverlay, "overlay_used")
    try overlayCheck(overlay.tccOverlayApplied, "overlay_applied_boolean")
    try overlayCheck(overlay.tccOverlayTreeBytes == 123_000 * 1024, "overlay_tree_bytes")
    try overlayCheck(overlay.tccOverlayReplacedBytes == 100_000 * 1024, "overlay_replaced_bytes")
    try overlayCheck(overlay.tccOverlayDeltaBytes == 23_000 * 1024, "overlay_delta_bytes")
    try overlayCheck(
      overlay.scanChannelDisplayName == "App TCC + 管理員", "channel_display_name")
    try overlayCheck(!overlay.hasAmbiguousLegacyAdministratorProbe, "not_legacy_ambiguous")

    try legacyCheck(legacy.scannerVersion == "2.5.0", "scanner_2_5_0")
    try legacyCheck(legacy.appFullDiskAccessProbe == "UNKNOWN", "app_probe_not_invented")
    try legacyCheck(
      legacy.scannerFullDiskAccessProbe == "LIKELY_MISSING_OR_TCC_BLOCKED",
      "legacy_probe_attributed_to_scanner"
    )
    try legacyCheck(legacy.hasAmbiguousLegacyAdministratorProbe, "legacy_marked_ambiguous")
    try legacyCheck(
      legacy.scanChannelDisplayName == "管理員子程序（舊報告）", "legacy_channel_display")

    let output = PermissionAuditOutput(
      overlayAssertions: overlayAssertions,
      legacyAssertions: legacyAssertions,
      overlayChannel: overlay.scanChannelDisplayName,
      overlayStatus: overlay.tccOverlayStatus,
      overlayTreeBytes: overlay.tccOverlayTreeBytes,
      overlayReplacedBytes: overlay.tccOverlayReplacedBytes,
      overlayDeltaBytes: overlay.tccOverlayDeltaBytes,
      legacyAmbiguous: legacy.hasAmbiguousLegacyAdministratorProbe
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(output)
    if CommandLine.arguments.count >= 2 {
      try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}
