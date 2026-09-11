import Foundation

struct ExternalCleanupAuditCheck: Codable {
  let name: String
  let passed: Bool
  let detail: String
}

struct ExternalCleanupAuditResult: Codable {
  let version: String
  let build: Int
  let passed: Int
  let failed: Int
  let checks: [ExternalCleanupAuditCheck]
}

@main
struct ExternalVolumeCleanupAudit {
  static func main() throws {
    var checks: [ExternalCleanupAuditCheck] = []

    func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: String = "") {
      checks.append(ExternalCleanupAuditCheck(name: name, passed: condition(), detail: detail))
    }

    func candidate(
      rule: CleanupRuleID,
      path: String,
      root: String?,
      action: CleanupActionKind = .moveMatchedItemsToTrash,
      matchedPaths: [String]? = nil,
      risk: CleanupRisk = .high,
      selected: Bool = true
    ) -> CleanupCandidate {
      CleanupCandidate(
        ruleID: rule,
        scope: .folderMacManagedReview,
        tier: .ultraAggressive,
        category: rule == .folderLegacySpotlightTrashResidue
          || rule == .folderLegacyFSEventsTrashResidue
          ? .folderLegacyTrashResidue : .folderMacManagedReview,
        action: action,
        path: path,
        displayName: rule.rawValue,
        bytes: 0,
        risk: risk,
        reason: "fixture",
        impact: "fixture",
        recovery: "fixture",
        matchedPaths: matchedPaths ?? [path],
        cleanupRootPath: root,
        selected: selected
      )
    }

    let root = "/Volumes/FixtureDisk"
    let spotlightPath = root + "/.Spotlight-V100"
    let fseventsPath = root + "/.fseventsd"
    let spotlight = candidate(rule: .folderSpotlightMetadata, path: spotlightPath, root: root)
    let fsevents = candidate(rule: .folderFSEventsMetadata, path: fseventsPath, root: root)
    let dsStore = candidate(
      rule: .folderDSStore,
      path: root + "/.DS_Store",
      root: root,
      risk: .minimal
    )
    let legacyPaths = [
      root + "/.Trashes/501/.Spotlight-V100",
      root + "/.Trashes/501/.Spotlight-V100 11-51-05-732",
    ]
    let legacy = candidate(
      rule: .folderLegacySpotlightTrashResidue,
      path: root,
      root: root,
      action: .permanentDeleteMatchedItems,
      matchedPaths: legacyPaths
    )
    let reviewOnly = candidate(
      rule: .folderTrashMetadata,
      path: root + "/.Trashes",
      root: root,
      action: .reviewOnly,
      risk: .reviewOnly
    )

    check(
      "execution_mode_titles",
      CleanupExecutionMode.moveToTrash.title == "移到 Finder 可見垃圾桶"
        && CleanupExecutionMode.forceDelete.title == "直接徹底刪除"
    )
    check("force_mode_symbol", CleanupExecutionMode.forceDelete.symbol == "trash.slash")
    check("spotlight_supports_finder_trash", spotlight.supportsFinderVisibleTrash)
    check("fsevents_supports_finder_trash", fsevents.supportsFinderVisibleTrash)
    check(
      "spotlight_supports_external_direct_delete", spotlight.supportsExternalVolumeDirectDeletion)
    check("fsevents_supports_external_direct_delete", fsevents.supportsExternalVolumeDirectDeletion)
    check("ds_store_supports_finder_trash", dsStore.supportsFinderVisibleTrash)
    check("ds_store_supports_explicit_direct_delete", dsStore.supportsDirectDeletion)
    check(
      "legacy_is_direct_only", legacy.requiresDirectDeletion && !legacy.supportsFinderVisibleTrash)
    check(
      "legacy_group_supports_external_direct_delete", legacy.supportsExternalVolumeDirectDeletion)
    check(
      "review_only_has_no_cleanup_mode",
      !reviewOnly.supportsFinderVisibleTrash && !reviewOnly.supportsDirectDeletion)
    check(
      "high_risk_never_bulk_selected",
      !spotlight.isBulkSelectable && !fsevents.isBulkSelectable && !legacy.isBulkSelectable
    )
    check(
      "visible_name_accepts_normal_name",
      FinderVisibleTrash.isStructurallyVisibleName("MacStorageLens 回收－Spotlight"))
    check(
      "visible_name_rejects_dot_name",
      !FinderVisibleTrash.isStructurallyVisibleName(".Spotlight-V100"))
    check(
      "visible_name_rejects_control_character",
      !FinderVisibleTrash.isStructurallyVisibleName("bad\nname"))

    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    func source(_ relative: String) throws -> String {
      try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    let finderTrash = try source("Sources/MacStorageLens/FinderVisibleTrash.swift")
    let executor = try source("Sources/MacStorageLens/ExternalVolumeCleanupExecutor.swift")
    let cleanupEngine = try source("Sources/MacStorageLens/CleanupEngine.swift")
    let folderEngine = try source("Sources/MacStorageLens/FolderCleanupEngine.swift")
    let models = try source("Sources/MacStorageLens/Models.swift")
    let appModel = try source("Sources/MacStorageLens/AppModel.swift")
    let cleaner = try source("Sources/MacStorageLens/CleanerView.swift")
    let scanner = try source("Resources/mac-system-storage-tree-core-v2.5.3.command")
    let build = try source("scripts/建立並啟動.command")

    check(
      "finder_trash_uses_nsworkspace_recycle", finderTrash.contains("NSWorkspace.shared.recycle"))
    check("finder_trash_uses_finder_reveal", finderTrash.contains("activateFileViewerSelecting"))
    check(
      "finder_trash_does_not_use_filemanager_trash_item", !finderTrash.contains("trashItem(at:"))
    check(
      "finder_trash_does_not_create_trashes",
      !finderTrash.contains("createDirectory")
        && !finderTrash.contains("withIntermediateDirectories"))
    check(
      "finder_trash_renames_dot_sources_before_recycle",
      finderTrash.contains("prepareVisibleSource")
        && finderTrash.contains("source.lastPathComponent.hasPrefix(\".\")"))
    check("finder_trash_clears_hidden_flag", finderTrash.contains("values.isHidden = false"))
    check(
      "finder_trash_requires_nondot_destination", finderTrash.contains("isStructurallyVisibleName"))
    check(
      "finder_trash_requires_finder_managed_parent",
      finderTrash.contains("isFinderManagedTrashDestination"))
    let verifyParentMarker = finderTrash.range(
      of: "// Verify the system-returned parent before renaming anything inside it."
    )
    let visibleRenameMarker = finderTrash.range(
      of: "let destination = try ensureVisibleTrashDestination")
    check(
      "finder_trash_verifies_parent_before_destination_rename",
      verifyParentMarker != nil && visibleRenameMarker != nil
        && verifyParentMarker!.lowerBound < visibleRenameMarker!.lowerBound)
    check(
      "finder_trash_rejects_symlinked_parent_or_destination",
      finderTrash.contains("parentValues.isSymbolicLink != true")
        && finderTrash.contains("destinationValues.isSymbolicLink != true")
        && finderTrash.contains("let resolvedParent = parent.resolvingSymlinksInPath()"))
    check(
      "finder_trash_requires_direct_child",
      finderTrash.contains("let parent = destination.deletingLastPathComponent"))
    check(
      "finder_trash_records_verified_receipt",
      finderTrash.contains("finderVisibilityVerified: true"))
    check("finder_trash_recovers_failed_visibility", finderTrash.contains("recoverAfterFailure"))

    check(
      "direct_executor_uses_remove_item_on_source",
      executor.contains("try fileManager.removeItem(at: source)"))
    check(
      "direct_executor_has_no_trash_intermediate",
      !executor.contains("trashItem") && !executor.contains("NSWorkspace.shared.recycle"))
    check(
      "direct_executor_has_no_no_log_creation",
      !executor.contains("createFile(atPath") && !executor.contains("no_log\")"))
    check(
      "direct_executor_has_no_shell",
      !executor.contains("osascript") && !executor.contains("/bin/rm")
        && !executor.contains("rm -rf"))
    check(
      "direct_executor_revalidates_device_inode",
      executor.contains("expectedDevice") && executor.contains("expectedInode"))
    check(
      "direct_executor_rejects_symlink_package",
      executor.contains("isSymbolicLink") && executor.contains("isPackage"))
    check(
      "direct_executor_restricts_external_root",
      executor.contains("/Volumes") && executor.contains("volumeIsInternal"))
    check(
      "direct_executor_rejects_read_only_nonlocal_timemachine",
      executor.contains("volumeIsReadOnly") && executor.contains("volumeIsLocal")
        && executor.contains("Backups.backupdb"))
    check(
      "direct_executor_supports_explicit_legacy_residues",
      executor.contains("validateLegacyTrashURL") && executor.contains("isAllowedLegacyTrashName"))
    check(
      "direct_executor_does_not_bulk_discover_history",
      !executor.contains("cleanupHistoryURL") && !executor.contains("discoverMatchingTrashURLs"))
    check("direct_executor_recreation_check", executor.contains("current != original"))

    check(
      "cleanup_engine_routes_all_reversible_actions_to_finder",
      cleanupEngine.components(separatedBy: "FinderVisibleTrash.recycle").count >= 4)
    check(
      "cleanup_engine_records_visible_receipts",
      cleanupEngine.contains("finderVisibleTrashItems: receipts"))
    check(
      "cleanup_engine_direct_delete_has_no_trash", cleanupEngine.contains("immediate_direct_delete")
    )
    check("cleanup_engine_rejects_direct_only_in_trash_mode", cleanupEngine.contains("不能假裝移到垃圾桶"))
    check(
      "folder_engine_surfaces_legacy_residues",
      folderEngine.contains("appendLegacyHiddenTrashResiduesIfIncluded"))
    check(
      "folder_engine_never_descends_into_trash",
      folderEngine.contains("case \".Trashes\", \".Trash\"")
        && folderEngine.contains("enumerator.skipDescendants()"))
    check("folder_engine_visible_trash_wording", folderEngine.contains("Finder 可見垃圾桶"))
    check(
      "app_never_opens_hidden_volume_trash",
      !appModel.contains(".Trashes/<uid>") && !appModel.contains("cleanupVolumeTrashURL"))
    check("app_reveals_verified_receipts", appModel.contains("FinderVisibleTrash.reveal"))
    check(
      "ui_has_exact_two_cleanup_modes",
      cleaner.contains("移到 Finder 可見垃圾桶") && cleaner.contains("直接徹底刪除…"))
    check(
      "ui_disables_finder_trash_for_direct_only",
      cleaner.contains("selected.contains(where: \\.requiresDirectDeletion)"))
    check(
      "ui_direct_mode_available_for_explicit_candidates",
      cleaner.contains("selected.allSatisfy(\\.supportsDirectDeletion)"))

    check(
      "cleanup_log_has_visible_receipts",
      models.contains("let finderVisibleTrashItems: [FinderVisibleTrashReceipt]?"))
    check("cleanup_log_has_space_semantics", models.contains("let spaceReleaseSemantics: String?"))
    check("cleanup_log_has_removal_method", models.contains("let removalMethod: String?"))
    check(
      "build_declares_removable_volume_usage", build.contains("NSRemovableVolumesUsageDescription"))
    check(
      "scanner_keeps_df_accounting",
      scanner.contains("volume_volatile_metadata_accounted_by_df=true"))
    check(
      "scanner_excludes_hidden_trash_from_deep_tree",
      scanner.contains(".Trashes") && scanner.contains("DU_IGNORE_ARGS+=(-I"))

    let legacyJSON = """
      {
        "createdAt":"2026-08-18T15:02:07Z",
        "mode":"folder_metadata_cleanup",
        "profile":"超激進",
        "removalMode":"move_to_trash",
        "targetKind":"volume",
        "targetPath":"/Volumes/PAPER S3",
        "entries":[{
          "action":"移動匹配項目到垃圾桶",
          "estimatedBytes":0,
          "failures":[],
          "movedItems":["/Volumes/PAPER S3/.Spotlight-V100"],
          "notes":["垃圾桶位置：/Volumes/PAPER S3/.Trashes/501/.Spotlight-V100"],
          "permanentlyDeletedItems":[],
          "recreatedItems":[],
          "ruleID":"folderSpotlightMetadata",
          "sourcePath":"/Volumes/PAPER S3"
        }]
      }
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decodedLegacy = try decoder.decode(CleanupLog.self, from: Data(legacyJSON.utf8))
    check("legacy_cleanup_log_still_decodes", decodedLegacy.entries.count == 1)
    check(
      "legacy_log_has_no_fabricated_visible_receipt",
      decodedLegacy.entries[0].finderVisibleTrashItems == nil)

    let receipt = FinderVisibleTrashReceipt(
      originalPath: spotlightPath,
      destinationPath: root + "/.Trashes/501/MacStorageLens 回收－Spotlight",
      visibleName: "MacStorageLens 回收－Spotlight",
      finderVisibilityVerified: true,
      sourcePathRecreated: false,
      removalMethod: "nsworkspace_recycle_finder_visible_verified"
    )
    let modernEntry = CleanupLog.Entry(
      ruleID: CleanupRuleID.folderSpotlightMetadata.rawValue,
      sourcePath: root,
      action: CleanupExecutionMode.moveToTrash.title,
      movedItems: [spotlightPath],
      permanentlyDeletedItems: [],
      recreatedItems: [],
      failures: [],
      notes: ["fixture"],
      estimatedBytes: 0,
      command: nil,
      commandExitStatus: nil,
      commandStandardOutput: nil,
      commandStandardError: nil,
      trashItemPaths: [receipt.destinationPath],
      finderVisibleTrashItems: [receipt],
      spaceReleaseSemantics: "pending_finder_trash_empty",
      removalMethod: receipt.removalMethod,
      errorDomain: nil,
      errorCode: nil
    )
    let modernData = try JSONEncoder().encode(modernEntry)
    let modernDecoded = try JSONDecoder().decode(CleanupLog.Entry.self, from: modernData)
    check("visible_receipt_round_trip", modernDecoded.finderVisibleTrashItems == [receipt])
    check(
      "visible_receipt_does_not_claim_space_released",
      modernDecoded.spaceReleaseSemantics == "pending_finder_trash_empty")
    check("modern_cleanup_log_no_false_shell_status", modernDecoded.commandExitStatus == nil)

    let temporaryHome = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "MacStorageLens-DirectDeleteAudit-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }
    let cacheRoot = temporaryHome.appendingPathComponent(
      "Library/Caches/TestApp", isDirectory: true)
    try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    let payload = cacheRoot.appendingPathComponent("cache.bin")
    try Data("fixture".utf8).write(to: payload)
    let libraryRoot = temporaryHome.appendingPathComponent("LibraryRoot", isDirectory: true)
    let library = try ReportLibrary(rootURL: libraryRoot)
    let systemCandidate = CleanupCandidate(
      ruleID: .standardUserCache,
      scope: .standardCaches,
      tier: .ultraConservative,
      category: .standardCache,
      action: .moveContentsToTrash,
      path: cacheRoot.path,
      displayName: "Test App cache",
      bytes: 7,
      risk: .minimal,
      reason: "fixture",
      impact: "fixture",
      recovery: "fixture",
      selected: true
    )
    let directLog = try CleanupEngine(
      library: library,
      homeURL: temporaryHome
    ).executeSelected(
      [systemCandidate],
      profile: .ultraConservative,
      target: .systemStorage,
      removalMode: .forceDelete
    ).0
    check(
      "system_direct_delete_is_explicit_mode",
      directLog.removalMode == CleanupExecutionMode.forceDelete.rawValue)
    check(
      "system_direct_delete_removed_payload", !FileManager.default.fileExists(atPath: payload.path))
    check(
      "system_direct_delete_records_permanent_item",
      directLog.entries.first?.permanentlyDeletedItems.contains(payload.path) == true)
    check(
      "system_direct_delete_has_no_trash_receipt",
      directLog.entries.first?.finderVisibleTrashItems == nil)

    let failed = checks.filter { !$0.passed }.count
    let result = ExternalCleanupAuditResult(
      version: "1.6.8",
      build: 25,
      passed: checks.count - failed,
      failed: failed,
      checks: checks
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)
    if let output = CommandLine.arguments.dropFirst().first.map(URL.init(fileURLWithPath:)) {
      try data.write(to: output, options: .atomic)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    if failed > 0 { exit(1) }
  }
}
