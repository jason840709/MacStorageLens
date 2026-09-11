import Foundation

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

@main
struct FolderCleanupAudit {
  private static var checks: [[String: Any]] = []
  private static var failures = 0

  static func main() throws {
    let fileManager = FileManager.default
    let fixture = fileManager.temporaryDirectory
      .appendingPathComponent(
        "MacStorageLens-FolderCleanupAudit-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: fixture) }

    let home = fixture.appendingPathComponent("home", isDirectory: true)
    let root = home.appendingPathComponent("Documents/Transfer", isDirectory: true)
    let outside = fixture.appendingPathComponent("outside", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)

    // Finder and Windows display metadata.
    try writeFile(root.appendingPathComponent(".DS_Store"), bytes: 128)
    try writeFile(root.appendingPathComponent("Nested/.DS_Store"), bytes: 192)
    let finderSidecar = root.appendingPathComponent("._.DS_Store")
    try writeAppleDouble(finderSidecar, entries: [(9, Data(repeating: 0x30, count: 32))])

    try writeFile(root.appendingPathComponent("Thumbs.db"), bytes: 96)
    try writeFile(root.appendingPathComponent("Nested/ehthumbs.db"), bytes: 97)
    try writeFile(root.appendingPathComponent("Desktop.ini"), bytes: 98)
    let windowsSidecar = root.appendingPathComponent("._Thumbs.db")
    try writeAppleDouble(windowsSidecar, entries: [(9, Data(repeating: 0x31, count: 32))])

    // Archive metadata.
    try writeFile(root.appendingPathComponent("__MACOSX/metadata.bin"), bytes: 256)

    // Generic AppleDouble classifications.
    let orphanedSidecar = root.appendingPathComponent("._orphaned.jpg")
    try writeAppleDouble(orphanedSidecar, entries: [(9, Data(repeating: 0x32, count: 32))])

    let pairedMain = root.appendingPathComponent("photo.jpg")
    let pairedSidecar = root.appendingPathComponent("._photo.jpg")
    try writeFile(pairedMain, bytes: 512)
    try writeAppleDouble(pairedSidecar, entries: [(9, Data(repeating: 0x33, count: 32))])

    let orphanResourceSidecar = root.appendingPathComponent("._orphan-resource")
    try writeAppleDouble(
      orphanResourceSidecar,
      entries: [
        (9, Data(repeating: 0x34, count: 32)),
        (2, Data(repeating: 0x52, count: 12)),
      ]
    )

    let pairedResourceMain = root.appendingPathComponent("legacy-document")
    let pairedResourceSidecar = root.appendingPathComponent("._legacy-document")
    try writeFile(pairedResourceMain, bytes: 512)
    try writeAppleDouble(
      pairedResourceSidecar,
      entries: [
        (9, Data(repeating: 0x35, count: 32)),
        (2, Data(repeating: 0x52, count: 16)),
      ]
    )

    let unknownMain = root.appendingPathComponent("unknown-format")
    let unknownSidecar = root.appendingPathComponent("._unknown-format")
    try writeFile(unknownMain, bytes: 256)
    try writeAppleDouble(
      unknownSidecar,
      entries: [(0x8000_0001, Data(repeating: 0x55, count: 4))]
    )

    let malformedSidecar = root.appendingPathComponent("._ordinary-user-file")
    try Data("not-an-appledouble-header".utf8).write(to: malformedSidecar)

    let linkedCompanionSidecar = root.appendingPathComponent("._linked-companion")
    try writeAppleDouble(
      linkedCompanionSidecar,
      entries: [(9, Data(repeating: 0x36, count: 32))]
    )
    try writeFile(outside.appendingPathComponent("linked-target"), bytes: 64)
    try fileManager.createSymbolicLink(
      at: root.appendingPathComponent("linked-companion"),
      withDestinationURL: outside.appendingPathComponent("linked-target")
    )

    let packageCompanion = root.appendingPathComponent("Archive.app", isDirectory: true)
    try fileManager.createDirectory(at: packageCompanion, withIntermediateDirectories: true)
    let packageSidecar = root.appendingPathComponent("._Archive.app")
    try writeAppleDouble(packageSidecar, entries: [(9, Data(repeating: 0x37, count: 32))])

    // Root-level Spotlight/FSEvents metadata is manually executable at L5.
    // Trash, versioning and other markers remain review-only.
    try writeFile(root.appendingPathComponent(".Spotlight-V100/index"), bytes: 128)
    try writeFile(root.appendingPathComponent(".fseventsd/log"), bytes: 128)
    try writeFile(root.appendingPathComponent("Nested/.Spotlight-V100/index"), bytes: 128)
    try writeFile(root.appendingPathComponent(".Trashes/501/deleted.txt"), bytes: 128)
    try writeFile(root.appendingPathComponent(".Trash/deleted.txt"), bytes: 128)
    try writeFile(root.appendingPathComponent(".DocumentRevisions-V100/db"), bytes: 128)
    try writeFile(root.appendingPathComponent(".TemporaryItems/work"), bytes: 128)
    try writeFile(root.appendingPathComponent(".MobileBackups/state"), bytes: 128)
    try writeFile(root.appendingPathComponent(".VolumeIcon.icns"), bytes: 128)
    try writeFile(root.appendingPathComponent(".metadata_never_index"), bytes: 8)
    try writeFile(root.appendingPathComponent(".localized"), bytes: 8)
    try writeFile(root.appendingPathComponent(".hidden"), bytes: 8)
    try writeFile(root.appendingPathComponent("Icon\r"), bytes: 8)
    try writeFile(root.appendingPathComponent(".com.apple.timemachine.supported"), bytes: 8)
    let managedSidecar = root.appendingPathComponent("._.Spotlight-V100")
    try writeAppleDouble(managedSidecar, entries: [(9, Data(repeating: 0x38, count: 32))])

    // Legacy Apple/AFP metadata remains review-only.
    try writeFile(root.appendingPathComponent(".AppleDouble/index"), bytes: 128)
    try writeFile(root.appendingPathComponent(".AppleDB/index"), bytes: 128)
    try writeFile(root.appendingPathComponent(".AppleDesktop/index"), bytes: 128)

    // These are intentionally not cleanup candidates.
    try writeFile(root.appendingPathComponent(".env"), bytes: 80)
    try writeFile(root.appendingPathComponent(".gitignore"), bytes: 80)
    try writeFile(root.appendingPathComponent(".git/.DS_Store"), bytes: 80)
    try writeFile(root.appendingPathComponent("Example.app/Contents/.DS_Store"), bytes: 80)
    try writeFile(outside.appendingPathComponent(".DS_Store"), bytes: 80)
    try fileManager.createSymbolicLink(
      at: root.appendingPathComponent("LinkedOutside", isDirectory: true),
      withDestinationURL: outside
    )
    try fileManager.createSymbolicLink(
      at: root.appendingPathComponent("._linked-sidecar"),
      withDestinationURL: outside.appendingPathComponent(".DS_Store")
    )

    let target = ScanTarget(
      kind: .folder,
      displayName: "Transfer",
      path: root.path,
      volumeUUID: nil
    )
    let library = try ReportLibrary(
      rootURL: fixture.appendingPathComponent("support", isDirectory: true),
      fileManager: fileManager
    )
    let engine = CleanupEngine(
      library: library,
      fileManager: fileManager,
      homeURL: home,
      localLibraryURL: fixture.appendingPathComponent("Library", isDirectory: true),
      privateRootURL: fixture.appendingPathComponent("private", isDirectory: true)
    )

    var results: [CleanupProfile: CleanupScanResult] = [:]
    for profile in CleanupProfile.allCases where profile != .custom {
      let configuration = CleanupScanConfiguration(
        profile: profile,
        customScopes: [],
        customMinimumBytes: 0
      )
      results[profile] = try engine.scanCandidates(configuration: configuration, target: target)
    }

    check("folder_mode_selected", results.values.allSatisfy { $0.mode == .generalLocation })
    check(
      "folder_target_preserved",
      results.values.allSatisfy { $0.target.reportRetentionKey == target.reportRetentionKey }
    )
    check(
      "predefined_folder_profiles_ignore_system_size_threshold",
      results[.ultraConservative]?.configuration.effectiveMinimumBytes(for: .generalLocation) == 0
    )

    check(
      "level_1_finder_metadata_and_verified_sidecar",
      rules(in: results[.ultraConservative])
        == [.folderDSStore, .folderDSStoreAppleDoubleSidecar]
    )
    check(
      "level_1_counts_finder_items",
      candidate(.folderDSStore, in: results[.ultraConservative])?.itemCount == 2
        && candidate(.folderDSStoreAppleDoubleSidecar, in: results[.ultraConservative])?.itemCount
          == 1
    )

    check(
      "level_2_adds_windows_metadata_and_verified_sidecar",
      rules(in: results[.conservative])
        == [
          .folderDSStore, .folderDSStoreAppleDoubleSidecar,
          .folderWindowsMetadata, .folderWindowsAppleDoubleSidecar,
        ]
    )
    check(
      "level_2_counts_windows_items",
      candidate(.folderWindowsMetadata, in: results[.conservative])?.itemCount == 3
        && candidate(.folderWindowsAppleDoubleSidecar, in: results[.conservative])?.itemCount == 1
    )

    check(
      "level_3_adds_archive_and_safe_orphaned_appledouble",
      rules(in: results[.balanced])
        == [
          .folderDSStore, .folderDSStoreAppleDoubleSidecar,
          .folderWindowsMetadata, .folderWindowsAppleDoubleSidecar,
          .folderMacOSXDirectory, .folderOrphanedAppleDoubleSidecar,
        ]
    )
    check(
      "level_3_orphan_is_executable_and_grouped",
      candidate(.folderOrphanedAppleDoubleSidecar, in: results[.balanced])?.itemCount == 1
        && candidate(.folderOrphanedAppleDoubleSidecar, in: results[.balanced])?.isSelectable
          == true
    )

    check(
      "level_4_adds_only_paired_metadata_appledouble",
      rules(in: results[.aggressive])
        == [
          .folderDSStore, .folderDSStoreAppleDoubleSidecar,
          .folderWindowsMetadata, .folderWindowsAppleDoubleSidecar,
          .folderMacOSXDirectory, .folderOrphanedAppleDoubleSidecar,
          .folderAppleDoubleSidecar,
        ]
    )
    check(
      "paired_metadata_requires_stronger_confirmation",
      candidate(.folderAppleDoubleSidecar, in: results[.aggressive])?.itemCount == 1
        && candidate(.folderAppleDoubleSidecar, in: results[.aggressive])?.isSelectable == true
        && candidate(.folderAppleDoubleSidecar, in: results[.aggressive])?
          .requiresElevatedConfirmation == true
    )

    let level5Rules: Set<CleanupRuleID> = [
      .folderDSStore, .folderDSStoreAppleDoubleSidecar,
      .folderWindowsMetadata, .folderWindowsAppleDoubleSidecar,
      .folderMacOSXDirectory, .folderOrphanedAppleDoubleSidecar,
      .folderAppleDoubleSidecar, .folderSensitiveAppleDoubleSidecar,
      .folderUnrecognizedDotUnderscore, .folderSpotlightMetadata,
      .folderFSEventsMetadata, .folderTrashMetadata,
      .folderMacVolumeMarkerMetadata, .folderLegacyAppleMetadata,
    ]
    check(
      "level_5_exposes_complete_review_catalog", rules(in: results[.ultraAggressive]) == level5Rules
    )
    check(
      "level_5_sensitive_appledouble_is_review_only",
      candidate(.folderSensitiveAppleDoubleSidecar, in: results[.ultraAggressive])?.itemCount == 6
        && candidate(.folderSensitiveAppleDoubleSidecar, in: results[.ultraAggressive])?
          .isSelectable
          == false
    )
    check(
      "level_5_unrecognized_dot_underscore_is_review_only",
      candidate(.folderUnrecognizedDotUnderscore, in: results[.ultraAggressive])?.itemCount == 1
        && candidate(.folderUnrecognizedDotUnderscore, in: results[.ultraAggressive])?.isSelectable
          == false
    )
    check(
      "level_5_spotlight_and_fsevents_are_manual_only",
      candidate(.folderSpotlightMetadata, in: results[.ultraAggressive])?.itemCount == 1
        && candidate(.folderFSEventsMetadata, in: results[.ultraAggressive])?.itemCount == 1
        && [CleanupRuleID.folderSpotlightMetadata, .folderFSEventsMetadata].allSatisfy {
          candidate($0, in: results[.ultraAggressive])?.isSelectable == true
            && candidate($0, in: results[.ultraAggressive])?.isBulkSelectable == false
            && candidate($0, in: results[.ultraAggressive])?.requiresManualSelection == true
            && candidate($0, in: results[.ultraAggressive])?.action
              == .moveMatchedItemsToTrash
        }
    )
    check(
      "managed_volume_metadata_uses_unknown_size_to_avoid_duplicate_traversal",
      candidate(.folderSpotlightMetadata, in: results[.ultraAggressive])?.bytes == 0
        && candidate(.folderFSEventsMetadata, in: results[.ultraAggressive])?.bytes == 0
    )
    check(
      "ordinary_folder_candidates_do_not_offer_force_delete",
      candidate(.folderSpotlightMetadata, in: results[.ultraAggressive])?.supportsForcedDeletion
        == false
        && candidate(.folderFSEventsMetadata, in: results[.ultraAggressive])?
          .supportsForcedDeletion == false
    )

    check(
      "level_5_trash_and_volume_markers_remain_review_only",
      candidate(.folderTrashMetadata, in: results[.ultraAggressive])?.itemCount == 2
        && candidate(.folderMacVolumeMarkerMetadata, in: results[.ultraAggressive])?.itemCount == 9
        && [
          CleanupRuleID.folderTrashMetadata,
          .folderMacVolumeMarkerMetadata,
        ].allSatisfy { candidate($0, in: results[.ultraAggressive])?.isSelectable == false }
    )
    check(
      "level_5_legacy_directories_are_review_only",
      candidate(.folderLegacyAppleMetadata, in: results[.ultraAggressive])?.itemCount == 3
        && candidate(.folderLegacyAppleMetadata, in: results[.ultraAggressive])?.isSelectable
          == false
    )
    check(
      "scan_notice_reports_appledouble_classification",
      results[.ultraAggressive]?.notices.contains(where: {
        $0.contains("Finder／Windows 伴隨 2")
          && $0.contains("孤立 metadata 1")
          && $0.contains("配對 metadata 1")
          && $0.contains("敏感內容 6")
          && $0.contains("無法驗證 1")
      }) == true
    )

    let allCandidates = results.values.flatMap(\.candidates)
    let allMatchedPaths = allCandidates.flatMap(\.matchedPaths)
    check("all_candidates_default_unselected", allCandidates.allSatisfy { !$0.selected })
    check(
      "all_matches_stay_inside_root",
      allMatchedPaths.allSatisfy { $0.hasPrefix(root.path + "/") }
    )
    check("git_metadata_skipped", !allMatchedPaths.contains { $0.contains("/.git/") })
    check("app_package_contents_skipped", !allMatchedPaths.contains { $0.contains("Example.app/") })
    check(
      "package_companion_reviewed_not_executed",
      candidate(
        .folderSensitiveAppleDoubleSidecar,
        in: results[.ultraAggressive]
      )?.matchedPaths.contains(packageSidecar.path) == true)
    check(
      "symlink_targets_not_followed", !allMatchedPaths.contains { $0.contains("LinkedOutside") })
    check(
      "symlink_sidecar_not_selected",
      !allMatchedPaths.contains { $0.hasSuffix("/._linked-sidecar") })
    check(
      "ordinary_dotfiles_not_selected",
      !allMatchedPaths.contains { $0.hasSuffix("/.env") || $0.hasSuffix("/.gitignore") }
    )

    let customFinder = try scanCustom(
      engine: engine,
      target: target,
      scopes: [.folderFinderMetadata]
    )
    check(
      "custom_finder_scope_includes_ds_store_and_companion",
      rules(in: customFinder) == [.folderDSStore, .folderDSStoreAppleDoubleSidecar]
    )

    let customRemnants = try scanCustom(
      engine: engine,
      target: target,
      scopes: [.folderAppleDoubleRemnants]
    )
    check(
      "custom_orphan_scope_isolated",
      rules(in: customRemnants) == [.folderOrphanedAppleDoubleSidecar]
    )

    let customPaired = try scanCustom(
      engine: engine,
      target: target,
      scopes: [.folderAppleDouble]
    )
    check("custom_paired_scope_isolated", rules(in: customPaired) == [.folderAppleDoubleSidecar])

    let customReview = try scanCustom(
      engine: engine,
      target: target,
      scopes: [.folderAppleDoubleReview]
    )
    check(
      "custom_appledouble_review_scope_isolated",
      rules(in: customReview)
        == [.folderSensitiveAppleDoubleSidecar, .folderUnrecognizedDotUnderscore]
    )

    let customManagedReview = try scanCustom(
      engine: engine,
      target: target,
      scopes: [.folderMacManagedReview]
    )
    check(
      "custom_managed_review_scope_isolated",
      rules(in: customManagedReview)
        == [
          .folderSpotlightMetadata, .folderFSEventsMetadata,
          .folderTrashMetadata, .folderMacVolumeMarkerMetadata,
        ]
    )

    let customHighThreshold = try engine.scanCandidates(
      configuration: CleanupScanConfiguration(
        profile: .custom,
        customScopes: [
          .folderAppleDoubleRemnants, .folderAppleDouble, .folderAppleDoubleReview,
        ],
        customMinimumBytes: 1_048_576
      ),
      target: target
    )
    check(
      "custom_threshold_hides_small_executable_items_but_keeps_review_only",
      !hasRule(.folderOrphanedAppleDoubleSidecar, in: customHighThreshold)
        && !hasRule(.folderAppleDoubleSidecar, in: customHighThreshold)
        && hasRule(.folderSensitiveAppleDoubleSidecar, in: customHighThreshold)
        && hasRule(.folderUnrecognizedDotUnderscore, in: customHighThreshold)
    )

    let customManagedHighThreshold = try engine.scanCandidates(
      configuration: CleanupScanConfiguration(
        profile: .custom,
        customScopes: [.folderMacManagedReview],
        customMinimumBytes: 1_048_576
      ),
      target: target
    )
    check(
      "manual_volume_metadata_ignores_size_threshold_when_directory_size_is_unknown",
      hasRule(.folderSpotlightMetadata, in: customManagedHighThreshold)
        && hasRule(.folderFSEventsMetadata, in: customManagedHighThreshold)
    )

    let noLogRoot = home.appendingPathComponent("Documents/NoLogVolume", isDirectory: true)
    try writeFile(noLogRoot.appendingPathComponent(".fseventsd/no_log"), bytes: 0)
    let noLogResult = try engine.scanCandidates(
      configuration: CleanupScanConfiguration(
        profile: .ultraAggressive,
        customScopes: [],
        customMinimumBytes: 0
      ),
      target: ScanTarget(
        kind: .folder,
        displayName: "NoLogVolume",
        path: noLogRoot.path,
        volumeUUID: nil
      )
    )
    check(
      "fsevents_no_log_only_directory_is_still_explicitly_offered",
      candidate(.folderFSEventsMetadata, in: noLogResult)?.itemCount == 1
        && candidate(.folderFSEventsMetadata, in: noLogResult)?.isSelectable == true
        && candidate(.folderFSEventsMetadata, in: noLogResult)?.isBulkSelectable == false
    )
    check(
      "fsevents_no_log_does_not_create_a_hidden_policy_exception",
      !noLogResult.notices.contains { $0.contains("持續抑制") }
    )
    let noLogFolderEngine = FolderCleanupEngine(fileManager: fileManager, homeURL: home)
    check(
      "fsevents_no_log_only_directory_is_revalidated_normally",
      (try? noLogFolderEngine.validateMatchedPath(
        noLogRoot.appendingPathComponent(".fseventsd").path,
        rule: .folderFSEventsMetadata,
        rootPath: noLogRoot.path
      ))?.lastPathComponent == ".fseventsd"
    )

    let inspector = AppleDoubleInspector(fileManager: fileManager)
    check(
      "inspector_classifies_orphaned_metadata",
      inspector.inspect(orphanedSidecar).kind == .orphanedMetadataOnly
    )
    check(
      "inspector_classifies_paired_metadata",
      inspector.inspect(pairedSidecar).kind == .pairedMetadataOnly
    )
    check(
      "inspector_classifies_orphaned_resource_fork_sensitive",
      inspector.inspect(orphanResourceSidecar).kind == .orphanedSensitive
        && inspector.inspect(orphanResourceSidecar).resourceForkBytes == 12
    )
    check(
      "inspector_classifies_paired_resource_fork_sensitive",
      inspector.inspect(pairedResourceSidecar).kind == .pairedSensitive
        && inspector.inspect(pairedResourceSidecar).resourceForkBytes == 16
    )
    check(
      "inspector_classifies_unknown_entry_sensitive",
      inspector.inspect(unknownSidecar).kind == .pairedSensitive
        && inspector.inspect(unknownSidecar).unknownEntryIDs == [0x8000_0001]
    )
    check(
      "inspector_rejects_malformed_header",
      inspector.inspect(malformedSidecar).kind == .unrecognized
    )
    let brokenSidecar = outside.appendingPathComponent("._broken-companion")
    try writeAppleDouble(brokenSidecar, entries: [(9, Data(repeating: 0x39, count: 32))])
    try fileManager.createSymbolicLink(
      at: outside.appendingPathComponent("broken-companion"),
      withDestinationURL: outside.appendingPathComponent("missing-target")
    )
    check(
      "inspector_treats_symlink_package_and_broken_symlink_companions_as_sensitive",
      inspector.inspect(linkedCompanionSidecar).kind == .pairedSensitive
        && inspector.inspect(packageSidecar).kind == .pairedSensitive
        && inspector.inspect(brokenSidecar).kind == .pairedSensitive
    )

    let invalidMagic = root.appendingPathComponent("._invalid-magic")
    try writeAppleDouble(invalidMagic, entries: [(9, Data(repeating: 0x41, count: 4))])
    try overwriteUInt32BE(invalidMagic, at: 0, value: 0xDEAD_BEEF)
    let invalidVersion = root.appendingPathComponent("._invalid-version")
    try writeAppleDouble(
      invalidVersion,
      entries: [(9, Data(repeating: 0x41, count: 4))],
      version: 0x0003_0000
    )
    let dataForkEntry = root.appendingPathComponent("._data-fork-entry")
    try writeAppleDouble(dataForkEntry, entries: [(1, Data(repeating: 0x41, count: 4))])
    let duplicateEntry = root.appendingPathComponent("._duplicate-entry")
    try writeAppleDouble(
      duplicateEntry,
      entries: [
        (9, Data(repeating: 0x41, count: 4)),
        (9, Data(repeating: 0x42, count: 4)),
      ]
    )
    let invalidBounds = root.appendingPathComponent("._invalid-bounds")
    try writeAppleDouble(invalidBounds, entries: [(9, Data(repeating: 0x41, count: 4))])
    try overwriteUInt32BE(invalidBounds, at: 30, value: UInt32.max)
    let overlappingEntries = outside.appendingPathComponent("._overlapping-entries")
    try writeAppleDouble(
      overlappingEntries,
      entries: [
        (9, Data(repeating: 0x41, count: 4)),
        (2, Data(repeating: 0x42, count: 4)),
      ]
    )
    try overwriteUInt32BE(overlappingEntries, at: 42, value: 50)
    check(
      "inspector_rejects_invalid_magic_version_and_data_fork_entry",
      inspector.inspect(invalidMagic).kind == .unrecognized
        && inspector.inspect(invalidVersion).kind == .unrecognized
        && inspector.inspect(dataForkEntry).kind == .unrecognized
    )
    check(
      "inspector_rejects_duplicate_out_of_bounds_and_overlapping_entries",
      inspector.inspect(duplicateEntry).kind == .unrecognized
        && inspector.inspect(invalidBounds).kind == .unrecognized
        && inspector.inspect(overlappingEntries).kind == .unrecognized
    )

    let folderEngine = FolderCleanupEngine(fileManager: fileManager, homeURL: home)
    let validDSStore = root.appendingPathComponent(".DS_Store")
    check(
      "exact_match_revalidation_accepts_valid_ds_store",
      (try? folderEngine.validateMatchedPath(
        validDSStore.path,
        rule: .folderDSStore,
        rootPath: root.path
      ))?.standardizedFileURL == validDSStore.standardizedFileURL
    )
    check(
      "finder_sidecar_revalidation_requires_verified_companion",
      (try? folderEngine.validateMatchedPath(
        finderSidecar.path,
        rule: .folderDSStoreAppleDoubleSidecar,
        rootPath: root.path
      ))?.standardizedFileURL == finderSidecar.standardizedFileURL
    )
    check(
      "windows_sidecar_revalidation_requires_verified_companion",
      (try? folderEngine.validateMatchedPath(
        windowsSidecar.path,
        rule: .folderWindowsAppleDoubleSidecar,
        rootPath: root.path
      ))?.standardizedFileURL == windowsSidecar.standardizedFileURL
    )
    check(
      "orphan_revalidation_accepts_only_orphan_rule",
      (try? folderEngine.validateMatchedPath(
        orphanedSidecar.path,
        rule: .folderOrphanedAppleDoubleSidecar,
        rootPath: root.path
      ))?.standardizedFileURL == orphanedSidecar.standardizedFileURL
        && throwsError {
          _ = try folderEngine.validateMatchedPath(
            orphanedSidecar.path,
            rule: .folderAppleDoubleSidecar,
            rootPath: root.path
          )
        }
    )
    check(
      "paired_metadata_revalidation_accepts_only_paired_rule",
      (try? folderEngine.validateMatchedPath(
        pairedSidecar.path,
        rule: .folderAppleDoubleSidecar,
        rootPath: root.path
      ))?.standardizedFileURL == pairedSidecar.standardizedFileURL
        && throwsError {
          _ = try folderEngine.validateMatchedPath(
            pairedSidecar.path,
            rule: .folderOrphanedAppleDoubleSidecar,
            rootPath: root.path
          )
        }
    )
    check(
      "sensitive_review_rules_are_non_executable",
      throwsError {
        _ = try folderEngine.validateMatchedPath(
          pairedResourceSidecar.path,
          rule: .folderSensitiveAppleDoubleSidecar,
          rootPath: root.path
        )
      }
        && throwsError {
          _ = try folderEngine.validateMatchedPath(
            malformedSidecar.path,
            rule: .folderUnrecognizedDotUnderscore,
            rootPath: root.path
          )
        }
    )
    check(
      "spotlight_and_fsevents_revalidation_accepts_exact_root_directories",
      (try? folderEngine.validateMatchedPath(
        root.appendingPathComponent(".Spotlight-V100").path,
        rule: .folderSpotlightMetadata,
        rootPath: root.path
      ))?.lastPathComponent == ".Spotlight-V100"
        && (try? folderEngine.validateMatchedPath(
          root.appendingPathComponent(".fseventsd").path,
          rule: .folderFSEventsMetadata,
          rootPath: root.path
        ))?.lastPathComponent == ".fseventsd"
    )
    check(
      "nested_spotlight_directory_is_not_a_candidate_or_executable",
      candidate(.folderSpotlightMetadata, in: results[.ultraAggressive])?.matchedPaths
        == [root.appendingPathComponent(".Spotlight-V100").path]
        && throwsError {
          _ = try folderEngine.validateMatchedPath(
            root.appendingPathComponent("Nested/.Spotlight-V100").path,
            rule: .folderSpotlightMetadata,
            rootPath: root.path
          )
        }
    )
    check(
      "rule_mismatch_is_rejected",
      throwsError {
        _ = try folderEngine.validateMatchedPath(
          validDSStore.path,
          rule: .folderAppleDoubleSidecar,
          rootPath: root.path
        )
      }
    )
    check(
      "outside_path_is_rejected",
      throwsError {
        _ = try folderEngine.validateMatchedPath(
          outside.appendingPathComponent(".DS_Store").path,
          rule: .folderDSStore,
          rootPath: root.path
        )
      }
    )
    check(
      "symlink_parent_swap_is_rejected",
      throwsError {
        _ = try folderEngine.validateMatchedPath(
          root.appendingPathComponent("LinkedOutside/.DS_Store").path,
          rule: .folderDSStore,
          rootPath: root.path
        )
      }
    )
    check(
      "package_ancestor_is_rejected_at_execution",
      throwsError {
        _ = try folderEngine.validateMatchedPath(
          root.appendingPathComponent("Example.app/Contents/.DS_Store").path,
          rule: .folderDSStore,
          rootPath: root.path
        )
      }
    )

    try writeFile(root.appendingPathComponent("orphaned.jpg"), bytes: 32)
    check(
      "orphan_rule_revalidates_companion_state",
      throwsError {
        _ = try folderEngine.validateMatchedPath(
          orphanedSidecar.path,
          rule: .folderOrphanedAppleDoubleSidecar,
          rootPath: root.path
        )
      }
    )
    try fileManager.removeItem(at: pairedMain)
    check(
      "paired_rule_revalidates_companion_state",
      throwsError {
        _ = try folderEngine.validateMatchedPath(
          pairedSidecar.path,
          rule: .folderAppleDoubleSidecar,
          rootPath: root.path
        )
      }
    )
    try overwriteUInt32BE(finderSidecar, at: 0, value: 0)
    check(
      "finder_sidecar_rule_revalidates_binary_header",
      throwsError {
        _ = try folderEngine.validateMatchedPath(
          finderSidecar.path,
          rule: .folderDSStoreAppleDoubleSidecar,
          rootPath: root.path
        )
      }
    )

    let protectedLibrary = home.appendingPathComponent("Library", isDirectory: true)
    try fileManager.createDirectory(at: protectedLibrary, withIntermediateDirectories: true)
    check(
      "user_library_root_is_rejected",
      throwsError {
        _ = try folderEngine.validatedRoot(
          for: ScanTarget(
            kind: .folder,
            displayName: "Library",
            path: protectedLibrary.path,
            volumeUUID: nil
          ))
      }
    )
    check(
      "home_root_is_rejected",
      throwsError {
        _ = try folderEngine.validatedRoot(
          for: ScanTarget(kind: .folder, displayName: "Home", path: home.path, volumeUUID: nil))
      }
    )
    check(
      "system_root_is_rejected",
      throwsError {
        _ = try folderEngine.validatedRoot(
          for: ScanTarget(kind: .folder, displayName: "Root", path: "/", volumeUUID: nil)
        )
      }
    )

    // Version 1.6.8 explicitly exposes dot-named Spotlight/FSEvents copies
    // left in a volume's Finder-managed hidden Trash by older releases. They
    // are never moved into another Trash and can only be directly deleted.
    let legacyVolumeRoot = fixture.appendingPathComponent("LegacyVolume", isDirectory: true)
    let legacyTrashRoot =
      legacyVolumeRoot
      .appendingPathComponent(".Trashes", isDirectory: true)
      .appendingPathComponent(String(getuid()), isDirectory: true)
    try writeFile(legacyTrashRoot.appendingPathComponent(".Spotlight-V100/index"), bytes: 32)
    try writeFile(
      legacyTrashRoot.appendingPathComponent(".Spotlight-V100 11-51-05-732/index"), bytes: 32)
    try writeFile(legacyTrashRoot.appendingPathComponent(".fseventsd/log"), bytes: 32)
    try writeFile(
      legacyTrashRoot.appendingPathComponent("MacStorageLens 回收－Spotlight/index"), bytes: 32)
    let legacyVolumeTarget = ScanTarget(
      kind: .volume,
      displayName: "LegacyVolume",
      path: legacyVolumeRoot.path,
      volumeUUID: "fixture-volume"
    )
    let legacyVolumeResult = try engine.scanCandidates(
      configuration: CleanupScanConfiguration(
        profile: .ultraAggressive,
        customScopes: [],
        customMinimumBytes: 0
      ),
      target: legacyVolumeTarget
    )
    let legacySpotlight = candidate(
      .folderLegacySpotlightTrashResidue,
      in: legacyVolumeResult
    )
    let legacyFSEvents = candidate(
      .folderLegacyFSEventsTrashResidue,
      in: legacyVolumeResult
    )
    check(
      "legacy_hidden_trash_spotlight_residues_are_surfaced",
      legacySpotlight?.itemCount == 2
        && legacySpotlight?.matchedPaths.allSatisfy { $0.contains("/.Trashes/") } == true
    )
    check(
      "legacy_hidden_trash_fsevents_residue_is_surfaced",
      legacyFSEvents?.itemCount == 1
    )
    check(
      "legacy_hidden_trash_residues_are_direct_only",
      [legacySpotlight, legacyFSEvents].allSatisfy {
        $0?.action == .permanentDeleteMatchedItems
          && $0?.requiresDirectDeletion == true
          && $0?.supportsFinderVisibleTrash == false
      }
    )
    check(
      "legacy_hidden_trash_residues_never_bulk_select",
      [legacySpotlight, legacyFSEvents].allSatisfy { $0?.isBulkSelectable == false }
    )
    check(
      "finder_visible_recycled_name_is_not_misclassified_as_legacy_hidden_residue",
      legacyVolumeResult.candidates.flatMap(\.matchedPaths).allSatisfy {
        !$0.contains("MacStorageLens 回收－Spotlight")
      }
    )
    check(
      "legacy_residue_notice_is_explicit",
      legacyVolumeResult.notices.contains {
        $0.contains("舊版") && $0.contains("只能直接徹底刪除")
      }
    )

    precondition(checks.count == 71, "Folder cleanup audit contract changed")
    let output: [String: Any] = [
      "version": "1.6.8",
      "build": 25,
      "checks": checks,
      "passed": checks.count - failures,
      "failed": failures,
      "rules": [
        ".DS_Store and verified ._.DS_Store",
        "Thumbs.db / ehthumbs.db / Desktop.ini and verified sidecars",
        "__MACOSX",
        "orphaned metadata-only AppleDouble",
        "paired metadata-only AppleDouble",
        "resource-fork / unknown-entry / package / symlink AppleDouble review-only",
        "unrecognized ._ review-only",
        ".Spotlight-V100 / .fseventsd manual-only; exact external-volume roots may offer direct deletion",
        "FSEvents no_log has no hidden policy exception",
        "legacy dot-named Spotlight/FSEvents Trash residues are direct-delete-only",
        ".Trashes / volume markers review-only",
        ".AppleDouble / .AppleDB / .AppleDesktop review-only",
      ],
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

  private static func scanCustom(
    engine: CleanupEngine,
    target: ScanTarget,
    scopes: Set<CleanupScope>
  ) throws -> CleanupScanResult {
    try engine.scanCandidates(
      configuration: CleanupScanConfiguration(
        profile: .custom,
        customScopes: scopes,
        customMinimumBytes: 0
      ),
      target: target
    )
  }

  private static func writeFile(_ url: URL, bytes: Int) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(repeating: 0x41, count: bytes).write(to: url)
  }

  private static func writeAppleDouble(
    _ url: URL,
    entries: [(UInt32, Data)],
    version: UInt32 = 0x0002_0000
  ) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var data = Data()
    appendUInt32BE(0x0005_1607, to: &data)
    appendUInt32BE(version, to: &data)
    data.append(Data("Mac OS X        ".utf8).prefix(16))
    appendUInt16BE(UInt16(entries.count), to: &data)

    var offset = UInt32(26 + entries.count * 12)
    for entry in entries {
      appendUInt32BE(entry.0, to: &data)
      appendUInt32BE(offset, to: &data)
      appendUInt32BE(UInt32(entry.1.count), to: &data)
      offset += UInt32(entry.1.count)
    }
    for entry in entries { data.append(entry.1) }
    try data.write(to: url)
  }

  private static func overwriteUInt32BE(
    _ url: URL,
    at offset: Int,
    value: UInt32
  ) throws {
    var data = try Data(contentsOf: url)
    guard offset >= 0, offset + 4 <= data.count else {
      throw NSError(domain: "FolderCleanupAudit", code: 1)
    }
    data[offset] = UInt8((value >> 24) & 0xff)
    data[offset + 1] = UInt8((value >> 16) & 0xff)
    data[offset + 2] = UInt8((value >> 8) & 0xff)
    data[offset + 3] = UInt8(value & 0xff)
    try data.write(to: url)
  }

  private static func appendUInt16BE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
  }

  private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
  }

  private static func rules(in result: CleanupScanResult?) -> Set<CleanupRuleID> {
    Set(result?.candidates.map(\.ruleID) ?? [])
  }

  private static func candidate(
    _ rule: CleanupRuleID,
    in result: CleanupScanResult?
  ) -> CleanupCandidate? {
    result?.candidates.first { $0.ruleID == rule }
  }

  private static func hasRule(_ rule: CleanupRuleID, in result: CleanupScanResult?) -> Bool {
    candidate(rule, in: result) != nil
  }

  private static func throwsError(_ operation: () throws -> Void) -> Bool {
    do {
      try operation()
      return false
    } catch {
      return true
    }
  }

  private static func check(_ name: String, _ passed: Bool, detail: String = "") {
    if !passed { failures += 1 }
    checks.append(["name": name, "passed": passed, "detail": detail])
  }
}
