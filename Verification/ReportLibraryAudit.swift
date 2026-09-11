import Foundation

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

@main
struct ReportLibraryAudit {
  private static var checks: [[String: Any]] = []
  private static var failures = 0

  static func main() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent(
        "MacStorageLens-ReportLibraryAudit-\(UUID().uuidString)",
        isDirectory: true
      )
    defer { try? fileManager.removeItem(at: root) }

    let library = try ReportLibrary(rootURL: root, fileManager: fileManager)
    check(
      "cleanup_indexes_directory_created",
      fileManager.fileExists(atPath: library.cleanupIndexesURL.path)
    )
    let now = Date()

    let systemOld = try writeReport(
      at: library.scansURL.appendingPathComponent("system-old.md"),
      target: .systemStorage,
      modifiedAt: now.addingTimeInterval(-800),
      fileManager: fileManager
    )
    let systemNew = try writeReport(
      at: library.scansURL.appendingPathComponent("system-new.md"),
      target: .systemStorage,
      modifiedAt: now.addingTimeInterval(-100),
      fileManager: fileManager
    )

    let folderA = ScanTarget(
      kind: .folder,
      displayName: "專案 A",
      path: "/Users/test/Documents/專案 A",
      volumeUUID: nil
    )
    let folderAOld = try writeReport(
      at: library.scansURL.appendingPathComponent("folder-a-old.md"),
      target: folderA,
      modifiedAt: now.addingTimeInterval(-700),
      fileManager: fileManager
    )
    let folderANew = try writeReport(
      at: library.scansURL.appendingPathComponent("folder-a-new.md"),
      target: folderA,
      modifiedAt: now.addingTimeInterval(-90),
      fileManager: fileManager
    )

    let folderB = ScanTarget(
      kind: .folder,
      displayName: "素材 B",
      path: "/Users/test/Pictures/素材 B",
      volumeUUID: nil
    )
    let folderBReport = try writeReport(
      at: library.scansURL.appendingPathComponent("folder-b.md"),
      target: folderB,
      modifiedAt: now.addingTimeInterval(-80),
      fileManager: fileManager
    )

    let volumeOldTarget = ScanTarget(
      kind: .volume,
      displayName: "Archive",
      path: "/Volumes/Archive",
      volumeUUID: "A1B2-C3D4"
    )
    let volumeNewTarget = ScanTarget(
      kind: .volume,
      displayName: "Archive Renamed",
      path: "/Volumes/Archive Renamed",
      volumeUUID: "A1B2-C3D4"
    )
    let volumeOld = try writeReport(
      at: library.scansURL.appendingPathComponent("volume-old.md"),
      target: volumeOldTarget,
      modifiedAt: now.addingTimeInterval(-600),
      fileManager: fileManager
    )
    let volumeNew = try writeReport(
      at: library.scansURL.appendingPathComponent("volume-new.md"),
      target: volumeNewTarget,
      modifiedAt: now.addingTimeInterval(-70),
      fileManager: fileManager
    )
    let legacyFolderAtVolumeRoot = try writeReport(
      at: library.scansURL.appendingPathComponent("legacy-folder-at-volume-root.md"),
      target: ScanTarget(
        kind: .folder,
        displayName: "Archive Renamed",
        path: "/Volumes/Archive Renamed",
        volumeUUID: nil
      ),
      modifiedAt: now.addingTimeInterval(-75),
      fileManager: fileManager
    )

    let secondVolume = ScanTarget(
      kind: .volume,
      displayName: "Backup",
      path: "/Volumes/Backup",
      volumeUUID: "E5F6-G7H8"
    )
    let secondVolumeReport = try writeReport(
      at: library.scansURL.appendingPathComponent("volume-second.md"),
      target: secondVolume,
      modifiedAt: now.addingTimeInterval(-60),
      fileManager: fileManager
    )

    let staleIncomplete = try writeReport(
      at: library.scansURL.appendingPathComponent("stale-incomplete.md"),
      target: folderA,
      modifiedAt: now.addingTimeInterval(-25 * 60 * 60),
      complete: false,
      fileManager: fileManager
    )
    let recentIncomplete = try writeReport(
      at: library.scansURL.appendingPathComponent("recent-incomplete.md"),
      target: folderB,
      modifiedAt: now.addingTimeInterval(-60),
      complete: false,
      fileManager: fileManager
    )

    try library.pruneReportCacheKeepingLatestPerTarget(fileManager: fileManager)
    let records = library.reportRecords(fileManager: fileManager)

    check("system_key_is_fixed", ScanTarget.systemStorage.reportRetentionKey == "system")
    check(
      "volume_uuid_is_stable_across_mount_names",
      volumeOldTarget.reportRetentionKey == volumeNewTarget.reportRetentionKey
    )
    check(
      "folder_paths_are_distinct",
      folderA.reportRetentionKey != folderB.reportRetentionKey
    )
    let folderAWithTrailingSlash = ScanTarget(
      kind: .folder,
      displayName: "專案 A",
      path: "/Users/test/Documents/專案 A/",
      volumeUUID: nil
    )
    check(
      "folder_trailing_slash_is_normalized",
      folderA.reportRetentionKey == folderAWithTrailingSlash.reportRetentionKey
    )
    let volumeLowercaseUUID = ScanTarget(
      kind: .volume,
      displayName: "Archive",
      path: "/Volumes/Archive",
      volumeUUID: "a1b2-c3d4"
    )
    check(
      "volume_uuid_is_case_insensitive",
      volumeOldTarget.reportRetentionKey == volumeLowercaseUUID.reportRetentionKey
    )
    let folderPickerAtVolumeRoot = ScanTarget(
      kind: .folder,
      displayName: "Archive",
      path: "/Volumes/Archive",
      volumeUUID: "A1B2-C3D4"
    )
    check(
      "folder_picker_volume_root_uses_volume_identity",
      folderPickerAtVolumeRoot.reportRetentionKey == volumeOldTarget.reportRetentionKey
    )
    let nestedFolderOnVolume = ScanTarget(
      kind: .folder,
      displayName: "Projects",
      path: "/Volumes/Archive/Projects",
      volumeUUID: "A1B2-C3D4"
    )
    check(
      "nested_folder_on_volume_remains_path_specific",
      nestedFolderOnVolume.reportRetentionKey != volumeOldTarget.reportRetentionKey
    )
    check("one_record_per_location", records.count == 5, detail: "records=\(records.count)")
    check("newest_system_kept", fileManager.fileExists(atPath: systemNew.path))
    check("older_system_removed", !fileManager.fileExists(atPath: systemOld.path))
    check("newest_folder_a_kept", fileManager.fileExists(atPath: folderANew.path))
    check("older_folder_a_removed", !fileManager.fileExists(atPath: folderAOld.path))
    check("folder_b_kept", fileManager.fileExists(atPath: folderBReport.path))
    check("newest_uuid_volume_kept", fileManager.fileExists(atPath: volumeNew.path))
    check("older_uuid_volume_removed", !fileManager.fileExists(atPath: volumeOld.path))
    check(
      "legacy_folder_scan_at_volume_root_is_merged",
      !fileManager.fileExists(atPath: legacyFolderAtVolumeRoot.path)
    )
    check("different_volume_kept", fileManager.fileExists(atPath: secondVolumeReport.path))
    check("stale_incomplete_removed", !fileManager.fileExists(atPath: staleIncomplete.path))
    check("recent_incomplete_not_raced", fileManager.fileExists(atPath: recentIncomplete.path))
    check(
      "recent_incomplete_not_indexed",
      !records.contains(where: {
        $0.url.standardizedFileURL == recentIncomplete.standardizedFileURL
      })
    )
    check(
      "latest_for_folder_a",
      library.latestReportURL(for: folderA, fileManager: fileManager)?.standardizedFileURL
        == folderANew.standardizedFileURL
    )
    check(
      "legacy_folder_root_lookup_resolves_to_volume_report",
      library.latestReportURL(
        for: ScanTarget(
          kind: .folder,
          displayName: "Archive Renamed",
          path: "/Volumes/Archive Renamed",
          volumeUUID: nil
        ),
        fileManager: fileManager
      )?.standardizedFileURL == volumeNew.standardizedFileURL
    )
    check(
      "metadata_indexed_without_full_parse",
      records.first(where: { $0.url.standardizedFileURL == folderANew.standardizedFileURL })?
        .scannerVersion == "2.5.1"
    )
    check(
      "record_lookup_uses_owned_url",
      library.record(for: folderANew, fileManager: fileManager)?.targetKey
        == folderA.reportRetentionKey
    )

    let externalRoot = fileManager.temporaryDirectory
      .appendingPathComponent("MacStorageLens-External-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: externalRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: externalRoot) }
    let external = try writeReport(
      at: externalRoot.appendingPathComponent("folder-b-import.md"),
      target: folderB,
      modifiedAt: now,
      fileManager: fileManager
    )

    let externalLink = library.scansURL.appendingPathComponent("external-link.md")
    try fileManager.createSymbolicLink(at: externalLink, withDestinationURL: external)
    check(
      "external_symlink_not_indexed",
      !library.reportURLs(fileManager: fileManager).contains(externalLink)
    )
    try library.pruneReportCacheKeepingLatestPerTarget(fileManager: fileManager)
    check("external_symlink_target_preserved", fileManager.fileExists(atPath: external.path))
    check("external_symlink_entry_preserved", fileManager.fileExists(atPath: externalLink.path))

    let imported = try library.importReport(from: external, fileManager: fileManager)
    let afterImport = library.reportRecords(fileManager: fileManager)
    check("external_import_source_preserved", fileManager.fileExists(atPath: external.path))
    check("import_copy_created", fileManager.fileExists(atPath: imported.path))
    check("same_location_old_scan_replaced", !fileManager.fileExists(atPath: folderBReport.path))
    check(
      "other_locations_survive_import",
      afterImport.count == 5,
      detail: "records=\(afterImport.count)"
    )
    check(
      "import_origin_recorded",
      afterImport.first(where: { $0.url.standardizedFileURL == imported.standardizedFileURL })?
        .isImported == true
    )

    let recentTargets = (0..<20).map { index in
      ScanTarget(
        kind: .folder,
        displayName: "Recent \(index)",
        path: "/Users/test/Recent/\(index)",
        volumeUUID: nil
      )
    }
    let normalizedRecents = RecentScanTargetPolicy.normalized(
      [.systemStorage, recentTargets[0], recentTargets[0]] + recentTargets
    )
    check(
      "recent_targets_are_capped",
      normalizedRecents.count == ReportRetentionPolicy.maximumRecentUnscannedLocations,
      detail: "recents=\(normalizedRecents.count)"
    )
    check(
      "recent_targets_drop_system_and_duplicates",
      normalizedRecents.allSatisfy { $0.kind != .system }
        && Set(normalizedRecents.map(\.reportRetentionKey)).count == normalizedRecents.count
    )
    let promotedRecent = RecentScanTargetPolicy.inserting(
      recentTargets[15],
      into: normalizedRecents
    )
    check(
      "reselecting_recent_promotes_to_front",
      promotedRecent.first?.reportRetentionKey == recentTargets[15].reportRetentionKey
    )
    let pendingRecents = RecentScanTargetPolicy.pending(
      from: promotedRecent,
      savedKeys: [recentTargets[15].reportRetentionKey]
    )
    check(
      "saved_target_leaves_pending_list",
      !pendingRecents.contains { $0.reportRetentionKey == recentTargets[15].reportRetentionKey }
    )

    var limitTargets: [ScanTarget] = []
    var limitURLs: [URL] = []
    for index in 0..<14 {
      let target = ScanTarget(
        kind: .folder,
        displayName: "Limit \(index)",
        path: "/Users/test/Limit/\(index)",
        volumeUUID: nil
      )
      limitTargets.append(target)
      limitURLs.append(
        try writeReport(
          at: library.scansURL.appendingPathComponent("limit-\(index).md"),
          target: target,
          modifiedAt: index == 0
            ? now.addingTimeInterval(-20_000)
            : now.addingTimeInterval(Double(index)),
          fileManager: fileManager
        )
      )
    }
    try library.pruneReportCacheKeepingLatestPerTarget(
      preservingTargets: [limitTargets[0]],
      fileManager: fileManager
    )
    let limitedRecords = library.reportRecords(fileManager: fileManager)
    let limitedNonSystem = limitedRecords.filter { $0.target.kind != .system }
    check(
      "non_system_report_locations_are_capped",
      limitedNonSystem.count == ReportRetentionPolicy.maximumNonSystemLocations,
      detail: "nonSystem=\(limitedNonSystem.count)"
    )
    check(
      "system_report_does_not_consume_non_system_slot",
      limitedRecords.contains { $0.target.kind == .system }
    )
    check(
      "explicitly_preserved_target_survives_cap",
      limitedRecords.contains { $0.targetKey == limitTargets[0].reportRetentionKey }
        && fileManager.fileExists(atPath: limitURLs[0].path)
    )
    check(
      "old_unpreserved_locations_are_pruned",
      limitURLs.dropFirst().contains { !fileManager.fileExists(atPath: $0.path) }
    )

    var diagnosticDirectories: [URL] = []
    for index in 0..<14 {
      let directory = library.scanWorkURL.appendingPathComponent(
        "diagnostic-\(index)", isDirectory: true)
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("{}".utf8).write(
        to: directory.appendingPathComponent("session-summary.json"), options: .atomic)
      try fileManager.setAttributes(
        [.modificationDate: now.addingTimeInterval(Double(index))],
        ofItemAtPath: directory.path
      )
      diagnosticDirectories.append(directory)
    }
    let staleDiagnostic = library.scanWorkURL.appendingPathComponent(
      "diagnostic-stale", isDirectory: true)
    try fileManager.createDirectory(at: staleDiagnostic, withIntermediateDirectories: true)
    try fileManager.setAttributes(
      [.modificationDate: now.addingTimeInterval(-25 * 60 * 60)],
      ofItemAtPath: staleDiagnostic.path
    )

    let externalDiagnosticTarget = root.appendingPathComponent(
      "external-diagnostic-target", isDirectory: true)
    try fileManager.createDirectory(
      at: externalDiagnosticTarget, withIntermediateDirectories: true)
    let diagnosticLink = library.scanWorkURL.appendingPathComponent(
      "diagnostic-external-link", isDirectory: true)
    try fileManager.createSymbolicLink(
      at: diagnosticLink, withDestinationURL: externalDiagnosticTarget)

    try library.pruneScanDiagnostics(fileManager: fileManager)
    let survivingDiagnostics = diagnosticDirectories.filter {
      fileManager.fileExists(atPath: $0.path)
    }
    check(
      "scan_diagnostics_are_capped",
      survivingDiagnostics.count == 12,
      detail: "diagnostics=\(survivingDiagnostics.count)"
    )
    check(
      "oldest_excess_diagnostics_are_pruned",
      !fileManager.fileExists(atPath: diagnosticDirectories[0].path)
        && !fileManager.fileExists(atPath: diagnosticDirectories[1].path)
    )
    check(
      "diagnostics_older_than_24_hours_are_pruned",
      !fileManager.fileExists(atPath: staleDiagnostic.path)
    )
    check(
      "diagnostic_symlink_target_is_preserved",
      fileManager.fileExists(atPath: externalDiagnosticTarget.path)
    )
    check(
      "diagnostic_symlink_is_not_followed_or_removed",
      (try? fileManager.destinationOfSymbolicLink(atPath: diagnosticLink.path)) != nil
    )

    let ambiguousRoot = fileManager.temporaryDirectory.appendingPathComponent(
      "MacStorageLens-AmbiguousVolumeAlias-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? fileManager.removeItem(at: ambiguousRoot) }
    let ambiguousLibrary = try ReportLibrary(rootURL: ambiguousRoot, fileManager: fileManager)
    let reusedMountPath = "/Volumes/Shared Name"
    _ = try writeReport(
      at: ambiguousLibrary.scansURL.appendingPathComponent("volume-one.md"),
      target: ScanTarget(
        kind: .volume,
        displayName: "First Card",
        path: reusedMountPath,
        volumeUUID: "UUID-ONE"
      ),
      modifiedAt: now.addingTimeInterval(-3),
      fileManager: fileManager
    )
    _ = try writeReport(
      at: ambiguousLibrary.scansURL.appendingPathComponent("volume-two.md"),
      target: ScanTarget(
        kind: .volume,
        displayName: "Second Card",
        path: reusedMountPath,
        volumeUUID: "UUID-TWO"
      ),
      modifiedAt: now.addingTimeInterval(-2),
      fileManager: fileManager
    )
    let ambiguousFolder = try writeReport(
      at: ambiguousLibrary.scansURL.appendingPathComponent("folder-shared-name.md"),
      target: ScanTarget(
        kind: .folder,
        displayName: "Shared Name",
        path: reusedMountPath,
        volumeUUID: nil
      ),
      modifiedAt: now.addingTimeInterval(-1),
      fileManager: fileManager
    )
    try ambiguousLibrary.pruneReportCacheKeepingLatestPerTarget(fileManager: fileManager)
    let ambiguousRecords = ambiguousLibrary.reportRecords(fileManager: fileManager)
    check(
      "ambiguous_reused_mount_name_is_not_merged",
      ambiguousRecords.count == 3,
      detail: "records=\(ambiguousRecords.count)"
    )
    check(
      "ambiguous_folder_report_is_preserved",
      fileManager.fileExists(atPath: ambiguousFolder.path)
    )

    let output: [String: Any] = [
      "version": "1.6.8",
      "build": 25,
      "checks": checks,
      "passed": checks.count - failures,
      "failed": failures,
      "reportRetentionRule":
        "one latest complete report per logical scan target; 12 non-system reports and 12 pending targets",
    ]
    let data = try JSONSerialization.data(
      withJSONObject: output,
      options: [.prettyPrinted, .sortedKeys]
    )

    if CommandLine.arguments.count > 1 {
      try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))

    if failures > 0 { exit(1) }
  }

  @discardableResult
  private static func writeReport(
    at url: URL,
    target: ScanTarget,
    modifiedAt: Date,
    complete: Bool = true,
    fileManager: FileManager
  ) throws -> URL {
    let uuid = target.volumeUUID ?? "NONE"
    var text = """
      # MacStorageLens report fixture

      scanner_version=2.5.1
      generated_at=2026-08-17 22:00:00 +0800
      scan_target_kind=\(target.kind.rawValue)
      scan_target_path=\(target.path)
      scan_target_display_name=\(target.displayName)
      scan_target_volume_uuid=\(uuid)
      target_mount_point=\(target.path)

      ### DIRECTORY_TREE (\(target.path))

      ```text
      1 KiB \(target.path)
      ```
      """
    if complete { text += "\nreport_complete=true\n" }
    try text.write(to: url, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    return url
  }

  private static func check(_ name: String, _ passed: Bool, detail: String = "") {
    if !passed { failures += 1 }
    checks.append([
      "name": name,
      "passed": passed,
      "detail": detail,
    ])
  }
}
