import Foundation

struct Check: Codable {
  let name: String
  let passed: Bool
  let detail: String
}

@main
struct CleanupIncrementalIndexAudit {
  static func main() throws {
    let outputURL = URL(
      fileURLWithPath: CommandLine.arguments.dropFirst().first
        ?? "/tmp/cleanup-incremental-index-audit.json")
    let fileManager = FileManager.default
    let fixture = fileManager.temporaryDirectory
      .appendingPathComponent(
        "MacStorageLens-CleanupIncrementalIndexAudit-\(UUID().uuidString)", isDirectory: true)
    let home = fixture.appendingPathComponent("home", isDirectory: true)
    let root = home.appendingPathComponent("Documents/IncrementalTarget", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: fixture) }

    let folderA = root.appendingPathComponent("A", isDirectory: true)
    let folderB = root.appendingPathComponent("B", isDirectory: true)
    try fileManager.createDirectory(at: folderA, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: folderB, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 7).write(to: folderA.appendingPathComponent(".DS_Store"))
    try Data(repeating: 0x42, count: 11).write(to: folderB.appendingPathComponent(".DS_Store"))
    try Data(repeating: 0x57, count: 13).write(to: folderA.appendingPathComponent("Thumbs.db"))

    let target = ScanTarget(
      kind: .folder, displayName: "Index Fixture", path: root.path, volumeUUID: nil)
    let finderScope: Set<CleanupScope> = [.folderFinderMetadata]
    let windowsScope: Set<CleanupScope> = [.folderWindowsMetadata]
    let finderConfiguration = CleanupScanConfiguration.indexScan(scopes: finderScope)
    let windowsConfiguration = CleanupScanConfiguration.indexScan(scopes: windowsScope)
    let folderEngine = FolderCleanupEngine(fileManager: fileManager, homeURL: home)

    var checks: [Check] = []
    func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: String = "") {
      checks.append(Check(name: name, passed: condition(), detail: detail))
    }

    var index = CleanupIncrementalIndex(
      target: target,
      scanSource: .liveFilesystem,
      sourceReportURL: nil,
      sourceReportSignature: nil
    )

    let ultra = CleanupScanConfiguration(
      profile: .ultraConservative, customScopes: [], customMinimumBytes: 0)
    let conservative = CleanupScanConfiguration(
      profile: .conservative, customScopes: [], customMinimumBytes: 0)
    let balanced = CleanupScanConfiguration(
      profile: .balanced, customScopes: [], customMinimumBytes: 0)
    check("cleanup_index_schema_is_6", CleanupIncrementalIndex.currentSchemaVersion == 6)

    let legacyConfigurationData = Data(
      #"{"profile":"超激進","customScopes":[],"customMinimumBytes":0}"#.utf8
    )
    let legacyConfiguration = try JSONDecoder().decode(
      CleanupScanConfiguration.self,
      from: legacyConfigurationData
    )
    check(
      "legacy_configuration_defaults_optional_scopes_off",
      legacyConfiguration.presetOptionalScopes.isEmpty
    )

    let explicitConfiguration = CleanupScanConfiguration(
      profile: .ultraAggressive,
      customScopes: [],
      customMinimumBytes: 0,
      presetOptionalScopes: [.trashBins, .standardCaches]
    )
    let explicitRoundTrip = try JSONDecoder().decode(
      CleanupScanConfiguration.self,
      from: JSONEncoder().encode(explicitConfiguration)
    )
    check(
      "configuration_round_trip_keeps_only_supported_optional_scopes",
      explicitRoundTrip.presetOptionalScopes == [.trashBins]
    )

    let emptySystemIndex = CleanupIncrementalIndex(
      target: .systemStorage,
      scanSource: .liveFilesystem,
      sourceReportURL: nil,
      sourceReportSignature: nil
    )
    let baseSystemScopes = Set(
      CleanupScope.cases(for: .system).filter { !$0.requiresExplicitPresetOptIn }
    )
    let defaultL5 = CleanupScanConfiguration(
      profile: .ultraAggressive,
      customScopes: [],
      customMinimumBytes: 0
    )
    check(
      "l5_index_default_requires_only_base_scopes",
      emptySystemIndex.missingScopes(for: defaultL5) == baseSystemScopes
    )
    check(
      "l5_index_explicit_trash_adds_only_trash_scope",
      emptySystemIndex.missingScopes(for: explicitRoundTrip)
        == baseSystemScopes.union([.trashBins])
    )

    check("initial_ultra_requires_only_finder", index.missingScopes(for: ultra) == finderScope)
    check(
      "external_conservative_adds_orphan_appledouble_scope",
      index.missingScopes(
        for: conservative, prioritizingExternalAppleDouble: true)
        == finderScope.union(windowsScope).union([.folderAppleDoubleRemnants]))
    check(
      "external_balanced_adds_paired_appledouble_scope",
      index.missingScopes(
        for: balanced, prioritizingExternalAppleDouble: true)
        == finderScope.union(windowsScope).union([
          .folderArchiveMetadata, .folderAppleDoubleRemnants, .folderAppleDouble,
        ]))

    let finderResult = try folderEngine.scanCandidates(
      configuration: finderConfiguration, target: target)
    index.merge(scanResult: finderResult, coveredScopes: finderScope)
    check("finder_scope_recorded", index.coveredScopes == finderScope)
    check("ultra_now_fully_covered", index.missingScopes(for: ultra).isEmpty)
    check(
      "conservative_only_missing_windows", index.missingScopes(for: conservative) == windowsScope)

    let windowsResult = try folderEngine.scanCandidates(
      configuration: windowsConfiguration, target: target)
    index.merge(scanResult: windowsResult, coveredScopes: windowsScope)
    check(
      "conservative_covered_without_rescanning_finder",
      index.missingScopes(for: conservative).isEmpty)

    let rebuiltAt = Date(timeIntervalSince1970: 1_787_500_000)
    let rebuilt = index.resettingDiscovery(at: rebuiltAt)
    check("full_rebuild_drops_covered_scopes", rebuilt.coveredScopes.isEmpty)
    check("full_rebuild_drops_old_candidates", rebuilt.candidates.isEmpty)
    check("full_rebuild_drops_dirty_directories", rebuilt.dirtyDirectoryPaths.isEmpty)
    check(
      "full_rebuild_preserves_scan_identity",
      rebuilt.target == index.target && rebuilt.scanSource == index.scanSource
        && rebuilt.sourceReportPath == index.sourceReportPath
        && rebuilt.sourceReportSignature == index.sourceReportSignature
        && rebuilt.createdAt == rebuiltAt)
    check(
      "full_rebuild_requires_current_profile_from_scratch",
      rebuilt.missingScopes(for: conservative) == finderScope.union(windowsScope))

    guard let finderCandidate = index.candidates.first(where: { $0.ruleID == .folderDSStore })
    else {
      throw NSError(
        domain: "CleanupIncrementalIndexAudit", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Finder candidate missing"])
    }
    let pathA = folderA.appendingPathComponent(".DS_Store").path
    let pathB = folderB.appendingPathComponent(".DS_Store").path
    check(
      "finder_group_contains_both_paths", Set(finderCandidate.matchedPaths) == Set([pathA, pathB]))
    check(
      "finder_group_keeps_exact_path_bytes",
      finderCandidate.matchedPathBytes[pathA] != nil
        && finderCandidate.matchedPathBytes[pathB] != nil)

    var selectedFinder = finderCandidate
    selectedFinder.selected = true
    let log = CleanupLog(
      createdAt: Date(),
      mode: CleanupMode.generalLocation.rawValue,
      removalMode: CleanupExecutionMode.moveToTrash.rawValue,
      profile: CleanupProfile.conservative.rawValue,
      targetKind: target.kind.rawValue,
      targetPath: target.path,
      entries: [
        CleanupLog.Entry(
          ruleID: selectedFinder.ruleID.rawValue,
          sourcePath: selectedFinder.path,
          action: selectedFinder.action.rawValue,
          movedItems: [pathA],
          permanentlyDeletedItems: [],
          recreatedItems: [],
          failures: [pathB],
          notes: [],
          estimatedBytes: selectedFinder.bytes,
          command: nil,
          commandExitStatus: nil,
          commandStandardOutput: nil,
          commandStandardError: nil
        )
      ]
    )
    index.markCleanupResult(selected: [selectedFinder], log: log)

    let afterCleanupFinder = index.candidates.first(where: { $0.ruleID == .folderDSStore })
    check(
      "successful_path_removed_but_failed_path_retained",
      afterCleanupFinder?.matchedPaths == [pathB])
    check("only_success_parent_marked_dirty", index.dirtyDirectoryPaths == Set([folderA.path]))
    check(
      "unrelated_windows_candidate_preserved",
      index.candidates.contains(where: { $0.ruleID == .folderWindowsMetadata }))

    // Simulate the post-cleanup filesystem: the successful Finder metadata is gone,
    // while a previously covered Windows candidate in the same parent still exists.
    try? fileManager.removeItem(atPath: pathA)
    let dirty = index.dirtyDirectoryPaths
    index.removeCandidatesInDirtyDirectories(dirty)
    let targetedRefresh = try folderEngine.scanCandidateDirectories(
      configuration: CleanupScanConfiguration.indexScan(scopes: index.coveredScopes),
      target: target,
      directoryPaths: dirty,
      scanSource: .liveFilesystem
    )
    index.merge(scanResult: targetedRefresh, coveredScopes: [])
    index.clearDirtyDirectories(dirty)

    check(
      "targeted_refresh_does_not_resurrect_deleted_finder_item",
      !(index.candidates.first(where: { $0.ruleID == .folderDSStore })?.matchedPaths.contains(pathA)
        ?? false))
    check(
      "targeted_refresh_restores_other_rule_in_dirty_parent",
      index.candidates.first(where: { $0.ruleID == .folderWindowsMetadata })?.matchedPaths.contains(
        folderA.appendingPathComponent("Thumbs.db").path) == true)
    check("dirty_marker_cleared_after_targeted_refresh", index.dirtyDirectoryPaths.isEmpty)

    // Persistent reuse is intentionally tied to an unchanged capacity report.
    let reportURL = root.appendingPathComponent("fixture-storage-tree.md")
    try "## DIRECTORY_TREE\nfixture\n".write(to: reportURL, atomically: true, encoding: .utf8)
    let signature = try ReportFileSignature.read(from: reportURL, fileManager: fileManager)
    var persistent = CleanupIncrementalIndex(
      target: target,
      scanSource: .existingStorageReport,
      sourceReportURL: reportURL,
      sourceReportSignature: signature
    )
    persistent.merge(scanResult: finderResult, coveredScopes: finderScope)
    persistent.merge(scanResult: windowsResult, coveredScopes: windowsScope)

    let storeURL = root.appendingPathComponent("indexes", isDirectory: true)
    let store = try CleanupIncrementalIndexStore(directoryURL: storeURL, fileManager: fileManager)
    let savedURL = try store.save(persistent, fileManager: fileManager)
    check(
      "report_guided_index_persisted",
      savedURL != nil && fileManager.fileExists(atPath: savedURL!.path))
    let loaded = store.load(
      target: target, scanSource: .existingStorageReport, sourceReportURL: reportURL,
      fileManager: fileManager)
    check("unchanged_report_index_reloads", loaded?.coveredScopes == persistent.coveredScopes)

    try "## DIRECTORY_TREE\nfixture changed\n".write(
      to: reportURL, atomically: true, encoding: .utf8)
    let staleLoad = store.load(
      target: target, scanSource: .existingStorageReport, sourceReportURL: reportURL,
      fileManager: fileManager)
    check("changed_report_invalidates_persisted_index", staleLoad == nil)

    // System Trash Bins live outside the storage-tree root, so schema 6 keeps a
    // dedicated structural contract. The serialized match list is navigation
    // state only; execution still revalidates the real ~/.Trash or
    // /Volumes/<name>/.Trashes/<UID> root immediately before deletion.
    let trashRoot = home.appendingPathComponent(".Trash", isDirectory: true)
    let trashItem = trashRoot.appendingPathComponent("deleted.txt")
    let trashCandidate = CleanupCandidate(
      ruleID: .trashBinContents,
      scope: .trashBins,
      tier: .ultraAggressive,
      category: .trashBins,
      action: .permanentDeleteMatchedItems,
      path: trashRoot.path,
      displayName: "目前使用者廢紙簍",
      bytes: 64,
      risk: .high,
      reason: "fixture",
      impact: "fixture",
      recovery: "fixture",
      matchedPaths: [trashItem.path],
      matchedPathBytes: [trashItem.path: 64],
      cleanupRootPath: trashRoot.path
    )
    let systemConfiguration = CleanupScanConfiguration.indexScan(scopes: [.trashBins])
    let systemResult = CleanupScanResult(
      configuration: systemConfiguration,
      candidates: [trashCandidate],
      startedAt: Date(),
      finishedAt: Date(),
      notices: [],
      mode: .system,
      target: .systemStorage
    )
    var systemIndex = CleanupIncrementalIndex(
      target: .systemStorage,
      scanSource: .liveFilesystem,
      sourceReportURL: nil,
      sourceReportSignature: nil
    )
    systemIndex.merge(scanResult: systemResult, coveredScopes: [.trashBins])
    check(
      "trash_candidate_valid_outside_storage_tree_root",
      systemIndex.isValid(
        for: .systemStorage,
        scanSource: .liveFilesystem,
        sourceReportURL: nil,
        sourceReportSignature: nil
      )
    )

    var selectedTrash = trashCandidate
    selectedTrash.selected = true
    let trashLog = CleanupLog(
      createdAt: Date(),
      mode: CleanupMode.system.rawValue,
      removalMode: CleanupExecutionMode.forceDelete.rawValue,
      profile: CleanupProfile.ultraAggressive.rawValue,
      targetKind: ScanTarget.systemStorage.kind.rawValue,
      targetPath: ScanTarget.systemStorage.path,
      entries: [
        CleanupLog.Entry(
          ruleID: selectedTrash.ruleID.rawValue,
          sourcePath: selectedTrash.path,
          action: selectedTrash.action.rawValue,
          movedItems: [],
          permanentlyDeletedItems: [trashItem.path],
          recreatedItems: [],
          failures: [],
          notes: [],
          estimatedBytes: selectedTrash.bytes,
          command: nil,
          commandExitStatus: nil,
          commandStandardOutput: nil,
          commandStandardError: nil
        )
      ]
    )
    systemIndex.markCleanupResult(selected: [selectedTrash], log: trashLog)
    check(
      "trash_scope_invalidated_after_execution",
      !systemIndex.coveredScopes.contains(.trashBins)
    )
    check(
      "deleted_trash_match_removed_from_index",
      !systemIndex.candidates.contains(where: { $0.ruleID == .trashBinContents })
    )

    let passed = checks.filter(\.passed).count
    let payload: [String: Any] = [
      "version": "1.7.5",
      "build": 33,
      "passed": passed,
      "total": checks.count,
      "checks": checks.map { ["name": $0.name, "passed": $0.passed, "detail": $0.detail] },
    ]
    let data = try JSONSerialization.data(
      withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: outputURL)
    guard passed == checks.count else { exit(1) }
  }
}
