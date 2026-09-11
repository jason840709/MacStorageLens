import Foundation

private enum FixtureFailure: LocalizedError {
  case failed(String)
  var errorDescription: String? {
    switch self {
    case .failed(let message): return message
    }
  }
}

private struct FixtureResult: Codable {
  let name: String
  let targetKind: String
  let targetPath: String
  let targetMountPoint: String
  let treeBytes: Int64
  let capacityBytes: Int64
  let usedBytes: Int64
  let availableBytes: Int64
  let accountingGapBytes: Int64
  let scanDeltaBytes: Int64
  let overviewBytes: Int64
  let overviewChildrenBytes: Int64
  let freeNodeBytes: Int64
  let accountingCloses: Bool
  let assertions: [String]
}

private struct Output: Codable {
  let version: String
  let build: Int
  let volume: FixtureResult
  let folder: FixtureResult
  let standaloneVolumeAssertions: [String]
  let apfsCrossSampleAssertions: [String]
  let foreignAPFSInventoryAssertions: [String]
}

@main
struct TargetFixtureAudit {
  static func main() throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(
        "MacStorageLens-target-fixtures-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let volumePath = "/Volumes/External Disk"
    let volumeReport = """
      # External Disk - 唯讀儲存空間資料樹

      ## RUN_METADATA
      ````text
      scanner_version=2.5.2
      generated_at=2026-08-15 16:00:00 +0800
      scan_target_kind=volume
      scan_target_path=\(volumePath)
      scan_target_display_name=External Disk
      scan_target_volume_uuid=EXTERNAL-UUID
      target_mount_point=\(volumePath)
      launcher_mode=terminal
      scanner_privilege_channel=terminal
      volume_scan_profile=fast_stable_volume_tree
      volume_volatile_metadata_excluded=true
      volume_volatile_metadata_names=.Trashes,.Trash,.Spotlight-V100,.fseventsd,.TemporaryItems,.DocumentRevisions-V100,.MobileBackups
      administrator_read_access=false
      full_disk_access_probe=LIKELY_AVAILABLE
      full_disk_access_probe_path=/Users/test/Library/Mail
      full_disk_access_source=terminal
      app_full_disk_access_probe=UNKNOWN
      app_full_disk_access_probe_path=NONE
      scanner_full_disk_access_probe=LIKELY_AVAILABLE
      scanner_full_disk_access_probe_path=/Users/test/Library/Mail
      tcc_overlay_status=NOT_REQUESTED
      tcc_overlay_applied=false
      path_scan_status=NO_REPORTED_DU_ERRORS
      du_error_line_count=0
      permission_or_tcc_error_count=0
      ````

      ## TARGET_VOLUME_ACCOUNTING_DIFFERENCE
      ````text
      accounting_scope=selected_volume
      accounting_gap_applicable=true
      target_path=\(volumePath)
      target_mount_point=\(volumePath)
      target_tree_du_kib=300000
      target_volume_capacity_kib=1000000
      target_volume_used_kib_pre_scan=400000
      target_volume_available_kib_pre_scan=600000
      target_volume_used_kib_post_scan_before_report=401000
      target_post_minus_pre_kib=1000
      target_accounting_gap_kib=100000
      ````

      ## ROOT_SCAN_SUMMARY
      | Root | du KiB | GiB | GB | Directory nodes | Diagnostic lines | Permission/TCC restrictions | du exit | Seconds |
      |---|---:|---:|---:|---:|---:|---:|---:|---:|
      | `\(volumePath)` | 300000 | 0.286 | 0.307 | 3 | 0 | 0 | 0 | 1 |

      ## PRE_SCAN_ACCOUNTING_AND_SNAPSHOTS
      ````text
      --- 核對掃描根節點區塊帳務（df -kP） ---
      Filesystem 1024-blocks Used Available Capacity Mounted on
      /dev/disk4s1 1000000 400000 600000 40% \(volumePath)
      exit_status=0
      ````

      ## POST_SCAN_VOLUME_AND_APFS_STATUS
      ````text
      --- 核對掃描後區塊帳務（df -kP） ---
      Filesystem 1024-blocks Used Available Capacity Mounted on
      /dev/disk4s1 1000000 401000 599000 41% \(volumePath)
      exit_status=0

      --- 列出 APFS 容器與卷 ---
      APFS Container Reference:     disk4
      Size (Capacity Ceiling):      1024000000 B
      Capacity In Use By Volumes:   409600000 B
      Capacity Not Allocated:       614400000 B
      APFS Volume Disk (Role):      disk4s1 (No specific role)
      Name:                         External Disk (Case-sensitive)
      Mount Point:                  \(volumePath)
      Capacity Consumed:            409600000 B
      exit_status=0
      ````

      ## ROOT \(volumePath)
      ### DIRECTORY_TREE (\(volumePath))
      ````text
      300000 KiB  \(volumePath)
      180000 KiB  \(volumePath)/Photos
      120000 KiB  \(volumePath)/Projects
      ````

      report_complete=true
      """

    let folderPath = "/Volumes/External Disk/Projects/Demo"
    let folderReport = """
      # Demo - 唯讀儲存空間資料樹

      ## RUN_METADATA
      ````text
      scanner_version=2.5.2
      generated_at=2026-08-15 16:01:00 +0800
      scan_target_kind=folder
      scan_target_path=\(folderPath)
      scan_target_display_name=Demo
      scan_target_volume_uuid=EXTERNAL-UUID
      target_mount_point=\(volumePath)
      launcher_mode=app
      scanner_privilege_channel=app_direct
      administrator_read_access=false
      full_disk_access_probe=LIKELY_AVAILABLE
      full_disk_access_source=app_direct
      app_full_disk_access_probe=LIKELY_AVAILABLE
      app_full_disk_access_probe_path=/Users/test/Library/Mail
      scanner_full_disk_access_probe=LIKELY_AVAILABLE
      scanner_full_disk_access_probe_path=/Users/test/Library/Mail
      tcc_overlay_status=NOT_REQUESTED
      tcc_overlay_applied=false
      path_scan_status=NO_REPORTED_DU_ERRORS
      du_error_line_count=0
      permission_or_tcc_error_count=0
      ````

      ## TARGET_VOLUME_ACCOUNTING_DIFFERENCE
      ````text
      accounting_scope=folder_tree_only
      accounting_gap_applicable=false
      target_path=\(folderPath)
      target_mount_point=\(volumePath)
      target_tree_du_kib=120000
      target_volume_capacity_kib=1000000
      target_volume_used_kib_pre_scan=400000
      target_volume_available_kib_pre_scan=600000
      target_volume_used_kib_post_scan_before_report=401000
      target_post_minus_pre_kib=1000
      target_accounting_gap_kib=0
      ````

      ## ROOT_SCAN_SUMMARY
      | Root | du KiB | GiB | GB | Directory nodes | Diagnostic lines | Permission/TCC restrictions | du exit | Seconds |
      |---|---:|---:|---:|---:|---:|---:|---:|---:|
      | `\(folderPath)` | 120000 | 0.114 | 0.123 | 3 | 0 | 0 | 0 | 1 |

      ## PRE_SCAN_ACCOUNTING_AND_SNAPSHOTS
      ````text
      --- 核對掃描根節點區塊帳務（df -kP） ---
      Filesystem 1024-blocks Used Available Capacity Mounted on
      /dev/disk4s1 1000000 400000 600000 40% \(volumePath)
      exit_status=0
      ````

      ## POST_SCAN_VOLUME_AND_APFS_STATUS
      ````text
      --- 核對掃描後區塊帳務（df -kP） ---
      Filesystem 1024-blocks Used Available Capacity Mounted on
      /dev/disk4s1 1000000 401000 599000 41% \(volumePath)
      exit_status=0
      ````

      ## ROOT \(folderPath)
      ### DIRECTORY_TREE (\(folderPath))
      ````text
      120000 KiB  \(folderPath)
      70000 KiB  \(folderPath)/Sources
      50000 KiB  \(folderPath)/Build
      ````

      report_complete=true
      """

    let volumeURL = temp.appendingPathComponent("volume-storage-tree-fixture.md")
    let folderURL = temp.appendingPathComponent("folder-storage-tree-fixture.md")
    try Data(volumeReport.utf8).write(to: volumeURL)
    try Data(folderReport.utf8).write(to: folderURL)

    let volume = try audit(name: "volume", url: volumeURL)
    let folder = try audit(name: "folder", url: folderURL)
    let standaloneVolumeAssertions = try auditStandaloneVolumeModel()
    let apfsCrossSampleAssertions = try auditAPFSCrossSampleModel()
    let foreignAPFSInventoryAssertions = try auditForeignAPFSInventoryIsolation(temp: temp)

    let output = Output(
      version: "1.6.8",
      build: 25,
      volume: volume,
      folder: folder,
      standaloneVolumeAssertions: standaloneVolumeAssertions,
      apfsCrossSampleAssertions: apfsCrossSampleAssertions,
      foreignAPFSInventoryAssertions: foreignAPFSInventoryAssertions
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

  private static func auditForeignAPFSInventoryIsolation(temp: URL) throws -> [String] {
    let targetPath = "/Volumes/Portable FAT"
    let report = """
      # Portable FAT - 唯讀儲存空間資料樹

      ## RUN_METADATA
      ````text
      scanner_version=2.5.2
      generated_at=2026-08-18 12:41:16 +0800
      scan_target_kind=volume
      scan_target_path=\(targetPath)
      scan_target_display_name=Portable FAT
      scan_target_volume_uuid=PORTABLE-FAT-UUID
      target_mount_point=\(targetPath)
      launcher_mode=app
      scanner_privilege_channel=app_direct
      volume_scan_profile=fast_stable_volume_tree
      volume_volatile_metadata_excluded=true
      volume_volatile_metadata_names=.Trashes,.Trash,.Spotlight-V100,.fseventsd,.TemporaryItems,.DocumentRevisions-V100,.MobileBackups
      path_scan_status=NO_REPORTED_DU_ERRORS
      du_error_line_count=0
      permission_or_tcc_error_count=0
      ````

      ## TARGET_VOLUME_ACCOUNTING_DIFFERENCE
      ````text
      accounting_scope=selected_volume
      accounting_gap_applicable=true
      target_path=\(targetPath)
      target_mount_point=\(targetPath)
      target_tree_du_kib=4008176
      target_volume_capacity_kib=30357008
      target_volume_used_kib_pre_scan=4008192
      target_volume_available_kib_pre_scan=26348816
      target_volume_used_kib_post_scan_before_report=4008192
      target_post_minus_pre_kib=0
      target_accounting_gap_kib=16
      ````

      ## POST_SCAN_VOLUME_AND_APFS_STATUS
      ````text
      --- 列出 APFS 容器與卷 ---
          APFS Container Reference:     disk3
          Size (Capacity Ceiling):      494384795648 B
          Capacity In Use By Volumes:   371083096064 B
          Capacity Not Allocated:       123301699584 B
          +-> Volume disk3s1 INTERNAL-SYSTEM
          |   APFS Volume Disk (Role):   disk3s1 (System)
          |   Name:                      Macintosh HD (Case-insensitive)
          |   Mount Point:               Not Mounted
          |   Capacity Consumed:         12643553280 B
          |   Snapshot:                  SYSTEM-SNAPSHOT
          |   Snapshot Mount Point:      /
          +-> Volume disk3s5 INTERNAL-DATA
          |   APFS Volume Disk (Role):   disk3s5 (Data)
          |   Name:                      Data (Case-insensitive)
          |   Mount Point:               /System/Volumes/Data
          |   Capacity Consumed:         336132005888 B
          +-> Volume disk3s6 INTERNAL-VM
              APFS Volume Disk (Role):   disk3s6 (VM)
              Name:                      VM (Case-insensitive)
              Mount Point:               /System/Volumes/VM
              Capacity Consumed:         11811393536 B
      exit_status=0
      ````

      ## ROOT \(targetPath)
      ### DIRECTORY_TREE (\(targetPath))
      ````text
      4008176 KiB  \(targetPath)
      3474592 KiB  \(targetPath)/Books
      533584 KiB  \(targetPath)/Metadata
      ````

      report_complete=true
      """

    let reportURL = temp.appendingPathComponent("foreign-apfs-inventory-volume.md")
    try Data(report.utf8).write(to: reportURL)

    let parser = ReportParser()
    let document = try parser.parse(url: reportURL)
    let summary = document.summary
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
    func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
      guard condition() else { throw FixtureFailure.failed("foreign-apfs-inventory: \(label)") }
      assertions.append(label)
    }

    try check(summary.primaryAPFSContainer == nil, "foreign_internal_apfs_container_not_selected")
    try check(summary.targetAPFSVolume == nil, "foreign_internal_system_volume_not_selected")
    try check(
      summary.targetVolumeCapacityBytes == 30_357_008 * 1024,
      "standalone_capacity_comes_from_target_df"
    )
    try check(
      summary.targetVolumeUsedBytes == 4_008_192 * 1024,
      "standalone_used_comes_from_target_df"
    )
    try check(
      summary.targetVolumeAvailableBytes == 26_348_816 * 1024,
      "standalone_free_comes_from_target_df"
    )
    try check(overview.bytes == 30_357_008 * 1024, "overview_uses_external_volume_capacity")
    try check(CapacityMapBuilder.accountingCloses(overview), "overview_accounting_closes")
    try check(
      overview.children.first(where: { $0.kind == .freeSpace })?.bytes == 26_348_816 * 1024,
      "external_free_space_visible"
    )
    let forbiddenLabels = ["Data", "Macintosh HD（System）", "VM", "Preboot", "Recovery"]
    try check(
      overview.children.allSatisfy { !forbiddenLabels.contains($0.label) },
      "internal_apfs_siblings_absent_from_external_overview"
    )

    let systemReport = """
      # Macintosh HD - 唯讀儲存空間資料樹

      ## RUN_METADATA
      ````text
      scanner_version=2.5.2
      generated_at=2026-08-18 12:41:16 +0800
      scan_target_kind=system
      scan_target_path=/System/Volumes/Data
      scan_target_display_name=Macintosh HD
      target_mount_point=/System/Volumes/Data
      path_scan_status=NO_REPORTED_DU_ERRORS
      du_error_line_count=0
      permission_or_tcc_error_count=0
      ````

      ## DATA_VOLUME_ACCOUNTING_DIFFERENCE
      ````text
      data_volume_du_kib=328000000
      data_volume_df_used_kib_pre_scan=328253912
      data_volume_df_used_kib_post_scan_before_report=328254000
      post_minus_pre_kib=88
      df_pre_used_minus_du_kib=253912
      ````

      ## POST_SCAN_VOLUME_AND_APFS_STATUS
      ````text
      --- 列出 APFS 容器與卷 ---
          APFS Container Reference:     disk8
          Size (Capacity Ceiling):      64000000000 B
          Capacity In Use By Volumes:   32000000000 B
          Capacity Not Allocated:       32000000000 B
          +-> Volume disk8s1 FOREIGN-DATA
              APFS Volume Disk (Role):   disk8s1 (Data)
              Name:                      Data (Case-insensitive)
              Mount Point:               /Volumes/Data
              Capacity Consumed:         32000000000 B
          APFS Container Reference:     disk3
          Size (Capacity Ceiling):      494384795648 B
          Capacity In Use By Volumes:   371083096064 B
          Capacity Not Allocated:       123301699584 B
          +-> Volume disk3s1 INTERNAL-SYSTEM
          |   APFS Volume Disk (Role):   disk3s1 (System)
          |   Name:                      Macintosh HD (Case-insensitive)
          |   Mount Point:               Not Mounted
          |   Capacity Consumed:         12643553280 B
          |   Snapshot:                  SYSTEM-SNAPSHOT
          |   Snapshot Mount Point:      /
          +-> Volume disk3s5 INTERNAL-DATA
          |   APFS Volume Disk (Role):   disk3s5 (Data)
          |   Name:                      Data (Case-insensitive)
          |   Mount Point:               /System/Volumes/Data
          |   Capacity Consumed:         336132005888 B
      exit_status=0
      ````

      ## ROOT /System/Volumes/Data
      ### DIRECTORY_TREE (/System/Volumes/Data)
      ````text
      328000000 KiB  /System/Volumes/Data
      200000000 KiB  /System/Volumes/Data/Applications
      128000000 KiB  /System/Volumes/Data/Users
      ````

      report_complete=true
      """
    let systemURL = temp.appendingPathComponent("snapshot-mount-isolation-system.md")
    try Data(systemReport.utf8).write(to: systemURL)
    let systemSummary = try parser.parse(url: systemURL).summary
    let parsedSystemVolume = systemSummary.primaryAPFSContainer?.volumes.first {
      $0.role.caseInsensitiveCompare("System") == .orderedSame
    }
    try check(
      parsedSystemVolume?.mountPoint == nil,
      "snapshot_mount_does_not_override_volume_mount"
    )
    try check(
      systemSummary.primaryAPFSContainer?.reference == "disk3"
        && systemSummary.targetAPFSVolume?.deviceIdentifier == "disk3s5",
      "system_selects_exact_internal_data_volume"
    )

    return assertions
  }

  private static func auditAPFSCrossSampleModel() throws -> [String] {
    let targetPath = "/Volumes/APFS Sample"
    let presentation = SunburstItem(
      id: targetPath,
      label: "APFS Sample",
      path: targetPath,
      bytes: 750 * 1024,
      kind: nil,
      children: [
        SunburstItem(
          id: targetPath + "/Data",
          label: "Data",
          path: targetPath + "/Data",
          bytes: 750 * 1024,
          kind: nil,
          children: []
        )
      ]
    )

    let selectedVolume = APFSVolumeRecord(
      deviceIdentifier: "disk9s1",
      role: "Data",
      name: "APFS Sample",
      mountPoint: targetPath,
      consumedBytes: 700 * 1024
    )
    let otherVolume = APFSVolumeRecord(
      deviceIdentifier: "disk9s2",
      role: "Preboot",
      name: "Preboot",
      mountPoint: nil,
      consumedBytes: 100 * 1024
    )

    var summary = ScanSummary()
    summary.targetKind = .volume
    summary.targetPath = targetPath
    summary.targetMountPoint = targetPath
    summary.targetDisplayName = "APFS Sample"
    summary.targetTreeDUKiB = 750
    summary.targetAccountingGapKiB = 0
    summary.primaryAPFSContainer = APFSContainerRecord(
      reference: "disk9",
      totalBytes: 1_200 * 1024,
      usedBytes: 800 * 1024,
      freeBytes: 400 * 1024,
      volumes: [selectedVolume, otherVolume]
    )

    let overview = CapacityMapBuilder.buildOverview(
      summary: summary,
      presentation: presentation,
      targetPath: targetPath
    )

    var assertions: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
      guard condition() else { throw FixtureFailure.failed("apfs-cross-sample: \(label)") }
      assertions.append(label)
    }

    try check(overview.bytes == 1_200 * 1024, "container_capacity_stays_fixed")
    try check(CapacityMapBuilder.accountingCloses(overview), "accounting_closes")
    let selected = overview.children.first(where: { $0.path == targetPath })
    try check(selected?.bytes == 750 * 1024, "later_tree_sample_preserved")
    let free = overview.children.first(where: { $0.kind == .freeSpace })
    try check(free?.bytes == 350 * 1024, "free_slice_adjusted_by_cross_sample_delta")
    try check(free?.label.contains("取樣調整") == true, "adjustment_is_explicit")
    return assertions
  }

  private static func auditStandaloneVolumeModel() throws -> [String] {
    let presentation = SunburstItem(
      id: "/Volumes/Portable",
      label: "Portable",
      path: "/Volumes/Portable",
      bytes: 600 * 1024,
      kind: nil,
      children: [
        SunburstItem(
          id: "/Volumes/Portable/A",
          label: "A",
          path: "/Volumes/Portable/A",
          bytes: 400 * 1024,
          kind: nil,
          children: []
        ),
        SunburstItem(
          id: "/Volumes/Portable/B",
          label: "B",
          path: "/Volumes/Portable/B",
          bytes: 200 * 1024,
          kind: nil,
          children: []
        ),
      ]
    )

    var summary = ScanSummary()
    summary.targetKind = .volume
    summary.targetPath = "/Volumes/Portable"
    summary.targetMountPoint = "/Volumes/Portable"
    summary.targetDisplayName = "Portable"
    summary.targetTreeDUKiB = 600
    summary.targetVolumeCapacityKiB = 1_000
    summary.targetVolumeUsedKiB = 700
    summary.targetVolumeAvailableKiB = 300
    summary.targetAccountingGapKiB = 100
    summary.accountingGapApplicable = true
    summary.volumeScanProfile = "fast_stable_volume_tree"
    summary.volumeVolatileMetadataExcluded = true
    summary.volumeVolatileMetadataNames = [".Trashes", ".Spotlight-V100", ".fseventsd"]

    let overview = CapacityMapBuilder.buildOverview(
      summary: summary,
      presentation: presentation,
      targetPath: summary.targetPath
    )

    var assertions: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
      guard condition() else { throw FixtureFailure.failed("standalone-volume: \(label)") }
      assertions.append(label)
    }

    try check(overview.bytes == 1_000 * 1024, "capacity_root")
    try check(CapacityMapBuilder.accountingCloses(overview), "accounting_closes")
    try check(
      overview.children.contains { $0.kind == .freeSpace && $0.bytes == 300 * 1024 },
      "free_space_visible"
    )
    try check(
      overview.children.first(where: { $0.path == summary.targetPath })?.children.contains {
        $0.kind == .accountingGap && $0.bytes == 100 * 1024
      } == true,
      "unresolved_gap_visible"
    )
    try check(
      overview.children.first(where: { $0.path == summary.targetPath })?.children.contains {
        $0.kind == .accountingGap && $0.label == "卷宗中繼資料／垃圾桶（未展開）"
      } == true,
      "stable_volume_gap_label"
    )
    return assertions
  }

  private static func audit(name: String, url: URL) throws -> FixtureResult {
    let parser = ReportParser()
    let document = try parser.parse(url: url)
    let summary = document.summary
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

    var assertions: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
      guard condition() else { throw FixtureFailure.failed("\(name): \(label)") }
      assertions.append(label)
    }

    let expectedKind: ScanTargetKind = name == "volume" ? .volume : .folder
    try check(summary.reportComplete, "report_complete")
    try check(summary.scannerVersion == "2.5.2", "scanner_2_5_2")
    if name == "volume" {
      try check(
        summary.volumeScanProfile == "fast_stable_volume_tree", "stable_volume_scan_profile")
      try check(summary.volumeVolatileMetadataExcluded, "volatile_volume_metadata_excluded")
      try check(
        summary.volumeVolatileMetadataNames.contains(".Trashes"), "trash_exclusion_reported")
      try check(
        summary.volumeVolatileMetadataNames.contains(".Spotlight-V100"),
        "spotlight_exclusion_reported")
      try check(
        summary.volumeVolatileMetadataNames.contains(".fseventsd"), "fsevents_exclusion_reported")
    }
    try check(summary.targetKind == expectedKind, "target_kind")
    try check(summary.targetMountPoint == "/Volumes/External Disk", "mount_point_with_space")
    try check(
      summary.targetTreeBytes == (name == "volume" ? 300_000 : 120_000) * 1024, "tree_bytes")
    try check(summary.targetVolumeCapacityKiB == 1_000_000, "capacity_kib")
    try check(summary.targetVolumeUsedKiB == 400_000, "used_kib")
    try check(summary.targetVolumeAvailableKiB == 600_000, "available_kib")
    try check(summary.targetVolumeScanDeltaBytes == 1_000 * 1024, "scan_delta")
    try check(summary.accountingGapApplicable == (name == "volume"), "gap_applicability")
    try check(
      summary.targetAccountingGapBytes == (name == "volume" ? 100_000 : 0) * 1024, "gap_bytes")
    try check(CapacityMapBuilder.accountingCloses(overview), "accounting_closes")

    let childTotal = overview.children.reduce(Int64(0)) { $0 + $1.bytes }
    try check(overview.children.isEmpty || childTotal == overview.bytes, "root_children_equal_root")

    let freeNode = overview.children.first(where: { $0.kind == .freeSpace })?.bytes ?? 0
    if name == "volume" {
      try check(overview.bytes == 1_024_000_000, "volume_container_capacity")
      try check(freeNode == 614_400_000, "volume_free_visible")
    } else {
      try check(overview.bytes == 120_000 * 1024, "folder_root_is_tree_only")
      try check(freeNode == 0, "folder_has_no_fake_free_child")
    }

    return FixtureResult(
      name: name,
      targetKind: summary.targetKind.rawValue,
      targetPath: summary.targetPath,
      targetMountPoint: summary.targetMountPoint,
      treeBytes: summary.targetTreeBytes,
      capacityBytes: summary.targetVolumeCapacityBytes,
      usedBytes: summary.targetVolumeUsedBytes,
      availableBytes: summary.targetVolumeAvailableBytes,
      accountingGapBytes: summary.targetAccountingGapBytes,
      scanDeltaBytes: summary.targetVolumeScanDeltaBytes,
      overviewBytes: overview.bytes,
      overviewChildrenBytes: childTotal,
      freeNodeBytes: freeNode,
      accountingCloses: CapacityMapBuilder.accountingCloses(overview),
      assertions: assertions
    )
  }
}
