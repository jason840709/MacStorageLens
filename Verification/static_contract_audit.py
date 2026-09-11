#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.7.5"
BUILD = 33
SCANNER = "2.5.3"

checks: list[dict[str, object]] = []


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def digest(path: str) -> str:
    h = hashlib.sha256()
    with (ROOT / path).open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def check(name: str, condition: bool, detail: str = "") -> None:
    checks.append({"name": name, "passed": bool(condition), "detail": detail})


required = [
    "Package.swift",
    "Sources/MacStorageLens/AppMetadata.swift",
    "Sources/MacStorageLens/AppModel.swift",
    "Sources/MacStorageLens/Models.swift",
    "Sources/MacStorageLens/ReportParser.swift",
    "Sources/MacStorageLens/ReportPresentationIndex.swift",
    "Sources/MacStorageLens/CapacityMapBuilder.swift",
    "Sources/MacStorageLens/OverviewView.swift",
    "Sources/MacStorageLens/CleanerView.swift",
    "Sources/MacStorageLens/CleanupEngine.swift",
    "Sources/MacStorageLens/CleanupIncrementalIndex.swift",
    "Sources/MacStorageLens/SystemJunkKnowledge.swift",
    "Sources/MacStorageLens/CleanupTargetCapabilities.swift",
    "Sources/MacStorageLens/FolderCleanupEngine.swift",
    "Sources/MacStorageLens/AppleDoubleInspector.swift",
    "Sources/MacStorageLens/FinderVisibleTrash.swift",
    "Sources/MacStorageLens/ExternalVolumeCleanupExecutor.swift",
    "Sources/MacStorageLens/ScannerLauncher.swift",
    "Sources/MacStorageLens/ScanProgressParser.swift",
    "Verification/ScanActivityTimeoutAudit.swift",
    "Sources/MacStorageLens/FullDiskAccessProbe.swift",
    "Sources/MacStorageLens/ReportLibrary.swift",
    "Sources/MacStorageLens/ScanFlowSheet.swift",
    "Sources/MacStorageLens/ScanTargetResolver.swift",
    "Resources/mac-system-storage-tree-v2.5.3.command",
    "Resources/mac-system-storage-tree-core-v2.5.3.command",
    "scripts/建立並啟動.command",
    "scripts/驗證原始碼.command",
    "Verification/ExternalVolumeCleanupAudit.swift",
    "Verification/ExternalVolumeRescanAudit.swift",
    "Verification/FolderCleanupAudit.swift",
    "Verification/ReportGuidedCleanupAudit.swift",
    "Verification/CleanupTargetCapabilityAudit.swift",
    "Verification/CleanupIncrementalIndexAudit.swift",
    "Verification/ExternalAppleDoubleCleanupAudit.swift",
    "Verification/ApplicationCacheCanonicalPathAudit.swift",
    "Verification/TargetFixtureAudit.swift",
    "Verification/ReportLibraryAudit.swift",
    "Verification/ReportPresentationIndexAudit.swift",
    "Verification/TrashBinsCleanupAudit.swift",
    "Verification/system_junk_integration_audit.py",
    "Verification/ui_enum_context_audit.py",
]
for path in required:
    check(f"exists:{path}", (ROOT / path).is_file(), path)

texts = {path: read(path) for path in required if (ROOT / path).is_file()}
metadata = texts["Sources/MacStorageLens/AppMetadata.swift"]
models = texts["Sources/MacStorageLens/Models.swift"]
parser = texts["Sources/MacStorageLens/ReportParser.swift"]
report_index = texts["Sources/MacStorageLens/ReportPresentationIndex.swift"]
capacity = texts["Sources/MacStorageLens/CapacityMapBuilder.swift"]
overview = texts["Sources/MacStorageLens/OverviewView.swift"]
cleaner = texts["Sources/MacStorageLens/CleanerView.swift"]
cleanup = texts["Sources/MacStorageLens/CleanupEngine.swift"]
capabilities = texts["Sources/MacStorageLens/CleanupTargetCapabilities.swift"]
folder = texts["Sources/MacStorageLens/FolderCleanupEngine.swift"]
cleanup_index = texts["Sources/MacStorageLens/CleanupIncrementalIndex.swift"]
system_junk_knowledge = texts["Sources/MacStorageLens/SystemJunkKnowledge.swift"]
finder_trash = texts["Sources/MacStorageLens/FinderVisibleTrash.swift"]
executor = texts["Sources/MacStorageLens/ExternalVolumeCleanupExecutor.swift"]
launcher = texts["Sources/MacStorageLens/ScannerLauncher.swift"]
progress_parser = texts["Sources/MacStorageLens/ScanProgressParser.swift"]
probe = texts["Sources/MacStorageLens/FullDiskAccessProbe.swift"]
report_library = texts["Sources/MacStorageLens/ReportLibrary.swift"]
scan_sheet = texts["Sources/MacStorageLens/ScanFlowSheet.swift"]
target_resolver = texts["Sources/MacStorageLens/ScanTargetResolver.swift"]
app_model = texts["Sources/MacStorageLens/AppModel.swift"]
wrapper = texts["Resources/mac-system-storage-tree-v2.5.3.command"]
core = texts["Resources/mac-system-storage-tree-core-v2.5.3.command"]
build = texts["scripts/建立並啟動.command"]
verify = texts["scripts/驗證原始碼.command"]

# Release identity.
check("metadata_version", 'fallbackVersion = "1.7.5"' in metadata)
check("metadata_build", 'fallbackBuild = "33"' in metadata)
check("metadata_scanner", 'scannerVersion = "2.5.3"' in metadata)
check("build_version", 'APP_VERSION="1.7.5"' in build)
check("build_number", 'APP_BUILD="33"' in build)
check("release_history_has_1_7_5", 'version: "1.7.5"' in metadata)
check("build_scanner", 'SCANNER_VERSION="2.5.3"' in build)
check("wrapper_version", 'VERSION="2.5.3"' in wrapper)
check("core_version", 'VERSION="2.5.3"' in core)
check("launcher_wrapper_name", "mac-system-storage-tree-v2.5.3.command" in launcher)
check("launcher_core_name", "mac-system-storage-tree-core-v2.5.3.command" in launcher)
check(
    "old_scanner_not_referenced_by_launcher",
    "v2.5.1.command" not in launcher and "v2.5.2.command" not in launcher,
)
check("developer_metadata", 'developer = "Jason Chen"' in metadata)
check("developer_build_info", "Jason Chen" in build)
check("removed_30_minute_hard_limit", "maximumRunSeconds" not in launcher)
check(
    "meaningful_progress_timeout_10m",
    "meaningfulProgressTimeoutSeconds = 10 * 60" in launcher,
)
check("meaningful_activity_token_used", "event.meaningfulActivityToken" in launcher)
check("core_output_timeout_10m", '"--command-timeout-seconds", "600"' in launcher)
activity_token_block = progress_parser.split("var meaningfulActivityToken", 1)[1].split(
    "struct ScanProgressParseResult", 1
)[0]
check(
    "heartbeat_elapsed_excluded_from_activity",
    "epochSeconds" not in activity_token_block and "elapsedSeconds" not in activity_token_block,
)

# Stable external-volume scan profile.
check("stable_profile_declared", 'VOLUME_SCAN_PROFILE="complete_path_tree"' in core)
check("stable_profile_enabled_for_volume", 'VOLUME_SCAN_PROFILE="fast_stable_volume_tree"' in core)
check("volume_only_gate", 'if [[ "$TARGET_KIND" == "volume" ]]' in core)
check("du_ignore_capability_probe", 'DU_IGNORE_SUPPORTED="false"' in core and '/usr/bin/du -sk -I' in core)
for name in [
    ".Trashes", ".Trash", ".Spotlight-V100", ".fseventsd", ".TemporaryItems",
    ".DocumentRevisions-V100", ".MobileBackups",
]:
    check(f"volume_exclusion:{name}", name in core, name)
check("exclusions_added_to_du", 'DU_IGNORE_ARGS+=(-I "$volatile_name")' in core)
check("folder_scans_not_blanket_excluded", "Folder scans are intentionally left" in core)
check("df_accounting_preserved", "volume_volatile_metadata_accounted_by_df=true" in core)
check("scan_profile_written", "volume_scan_profile=" in core)
check("excluded_flag_written", "volume_volatile_metadata_excluded=" in core)
check("excluded_names_written", "volume_volatile_metadata_names=" in core)
check("stable_gap_interpretation", "stable_tree_excludes_volatile_volume_metadata" in core)
check("stable_gap_components", "volume_trash|spotlight_index|fsevents_history" in core)
check("stable_scan_console_disclosure", "快速穩定卷宗樹" in core)
check("scanner_remains_read_only_banner", "唯讀" in core and "不會刪除" in core)
for forbidden in ["find -delete", "diskutil erase", "diskutil apfs delete", "tmutil delete", "rm -rf /Volumes"]:
    check(f"scanner_forbids:{forbidden}", forbidden not in core, forbidden)

# Report model and UI semantics.
check("summary_has_scan_profile", "var volumeScanProfile" in models)
check("summary_has_excluded_flag", "var volumeVolatileMetadataExcluded" in models)
check("summary_has_excluded_names", "var volumeVolatileMetadataNames" in models)
check("parser_reads_scan_profile", 'case "volume_scan_profile"' in parser)
check("parser_reads_excluded_flag", 'case "volume_volatile_metadata_excluded"' in parser)
check("parser_reads_excluded_names", 'case "volume_volatile_metadata_names"' in parser)
check("capacity_uses_volume_gap_label", "volumeGapLabel" in capacity)
check("capacity_gap_label_mentions_trash", "卷宗中繼資料／垃圾桶（未展開）" in capacity)
check("overview_stable_tree_title", "可映射穩定資料樹" in overview)
check("overview_gap_title", "卷宗中繼資料／垃圾桶" in overview)
check("overview_explains_df_accounting", "完整 df 已用帳務" in overview)
check("overview_explains_rescan_speed", "避免重複清理後越掃越慢" in overview)
check("overview_names_scanner_253", "Scanner 2.5.3" in overview)
check("accounting_bar_titles_are_dynamic", "visibleTitle" in overview and "gapTitle" in overview)

# Report presentation index and first-map loading contracts.
check("report_index_schema", 'currentParserSchema = "report-presentation-1.7.0-v1"' in report_index)
check("report_index_signature_size", "let byteCount: UInt64" in report_index)
check("report_index_signature_mtime", "let modificationNanoseconds: Int64" in report_index)
check("report_index_signature_samples_head_middle_tail", all(token in report_index for token in [
    "headCount", "middleOffset", "tailCount", "sampledFNV1A64",
]))
check("report_index_rejects_symlink", "values.isSymbolicLink != true" in report_index)
check("report_index_size_cap", "16 * 1024 * 1024" in report_index)
check("report_index_owner_only", ".posixPermissions: 0o600" in report_index)
check("report_index_directory_owner_only", ".posixPermissions: 0o700" in report_index)
check("report_index_corruption_falls_back", "try? fileManager.removeItem(at: indexURL)" in report_index)
check("report_index_prune", "func prune(" in report_index and "keepingReportURLs" in report_index)
check("report_library_has_index_directory", 'appendingPathComponent("Report Indexes"' in report_library)
check("report_library_removes_associated_index", "ReportPresentationIndexStore" in report_library and "store.remove(for: url" in report_library)
check("report_library_merges_unique_volume_alias", "unambiguousVolumeAliases" in report_library and "canonicalRetentionKey" in report_library)
check("models_embed_initial_presentation", "let initialPresentation: ReportInitialPresentation?" in models)
check("parser_builds_initial_presentation_in_single_pass", "initialPresentationRecords" in parser and "建立初始容量地圖" in parser)
check("parser_reuses_embedded_presentation", "initial.rootPath == parentPath" in parser and "return (initial.children, initial.sunburst)" in parser)
check("app_loads_persistent_index_first", "reportPresentationIndexStore.load(for: url)" in app_model)
check("app_saves_index_after_markdown_parse", "reportPresentationIndexStore.save(document: document, for: url)" in app_model)
check("app_reports_index_source", "presentationIndexSource" in app_model and "compactTitle" in app_model)
check("scan_sheet_shows_index_timing", "建立容量索引" in scan_sheet and "索引寫入" in scan_sheet)
check("verify_runs_presentation_index_audit", "ReportPresentationIndexAudit.swift" in verify)
check("aggregation_threshold_is_thousands", "automaticAggregationThreshold = 2_048" in models)
check("aggregation_visible_budget", "visibleChildBudgetWhenAggregated = 512" in models)
check("aggregate_is_interactive", "isExpandableAggregate" in models and "isInteractive" in models)
check("parser_aggregates_only_after_threshold", "SunburstPresentationPolicy.visibleChildCount" in parser)
check("aggregate_preserves_parent_path", "path: node.path" in parser and "kind: .otherChildren" in parser)
check("app_expands_aggregate_from_report", "expandAggregatedChildren" in app_model and "parser.loadChildren" in app_model)
check("overview_discloses_expandable_aggregate", "超過 2,048" in overview and "點擊可展開完整清單" in overview)
check("verify_runs_sunburst_aggregation_audit", "SunburstAggregationAudit.swift" in verify)

# 1.7.1 report-guided cleanup: the Markdown is a navigation index, never deletion authority.
check("cleanup_scan_source_enum", "enum CleanupScanSource" in models)
check("cleanup_source_report_title", "使用既有容量報告（快速）" in models)
check("cleanup_source_live_title", "重新掃描目標（完整）" in models)
check("cleanup_result_records_source", "let scanSource: CleanupScanSource" in models and "let sourceReportURL: URL?" in models)
check("parser_streams_directory_nodes", "func forEachDirectoryNode(" in parser and "parseTreeLineComponents" in parser)
check("folder_has_report_guided_scan", "func scanCandidatesUsingReport(" in folder)
check("report_guided_requires_complete_report", "document.summary.reportComplete" in folder)
check("report_guided_checks_logical_target", "reportRetentionKey == target.reportRetentionKey" in folder)
check("report_guided_maps_remounted_root", "func liveURL(for reportPath: String)" in folder)
check("report_guided_low_risk_exact_probe", "windowsMetadataExactProbeNames" in folder and "fileExists(atPath: url.path)" in folder)
check("report_guided_live_candidate_metadata", "entry.resourceValues(forKeys: candidateKeys)" in folder)
check("report_guided_appledouble_live_inspection", "classifyAppleDouble(" in folder and "AppleDouble 判定沒有直接相信容量報告" in folder)
check("report_guided_discloses_snapshot_boundary", "新增但不在報告中的整個新資料夾" in folder)
check("cleanup_engine_keeps_two_sources", "case .existingStorageReport" in cleanup and "case .liveFilesystem" in cleanup)
check("appmodel_defaults_quick_cleanup_source", "cleanupScanSource: CleanupScanSource = .existingStorageReport" in app_model)
check("appmodel_resolves_reusable_report", "cleanupReusableReportURL(for target: ScanTarget)" in app_model)
check("appmodel_reuses_presentation_index", "reportPresentationIndexStore.load(for: reportURL)" in app_model)
check("appmodel_falls_back_to_markdown_parse", "parser.parse(url: reportURL)" in app_model)
check("cleaner_has_scan_source_selector", "CleanupScanSourceSelector" in cleaner)
check("cleaner_discloses_report_not_authority", "不會把 Markdown 當成刪除授權" in cleaner)
check("cleaner_discloses_full_rescan", "完整模式維持原本行為" in cleaner)
check("verify_runs_report_guided_cleanup_audit", "ReportGuidedCleanupAudit.swift" in verify)

# 1.7.4 external-media AppleDouble policy and server recycle exclusion remains intact.
check("cleanup_capability_tracks_internal_storage", "let isInternalStorage: Bool?" in capabilities)
check("cleanup_capability_external_storage_helper", "var isExternalStorage: Bool" in capabilities)
check(
    "cleanup_capability_external_appledouble_priority",
    "var prioritizesExternalAppleDoubleCleanup: Bool" in capabilities
    and "isExternalStorage && !isReadOnly" in capabilities,
)
check(
    "scope_external_orphan_tier_conservative",
    "prioritizingExternalAppleDouble ? .conservative : .balanced" in models,
)
check(
    "scope_external_paired_tier_balanced",
    "prioritizingExternalAppleDouble ? .balanced : .aggressive" in models,
)
check("cleanup_index_schema_6", "currentSchemaVersion = 6" in cleanup_index)
check(
    "folder_remote_recycle_skip",
    'caseInsensitiveCompare("#recycle")' in folder
    and "containsServerRecycleComponent" in folder,
)
check(
    "folder_remote_recycle_execution_reject",
    "遠端 #recycle 由 NAS／伺服器自行管理" in folder,
)
check(
    "folder_external_appledouble_resourcefork_redline",
    "resource fork、未知 entry、package／symlink companion" in folder,
)
check(
    "app_cache_uses_actual_directory_entries",
    "for candidate in baseChildren where isRenderCacheMarker(candidate.lastPathComponent)" in cleanup,
)
check(
    "app_cache_scanner_executor_share_marker_policy",
    "private func isRenderCacheMarker" in cleanup
    and "return isRenderCacheMarker(source.lastPathComponent)" in cleanup,
)
check(
    "remote_direct_delete_server_retention_truthful",
    "client_direct_delete_server_retention_unknown" in cleanup
    and "伺服器端政策決定" in cleanup,
)
check("verify_runs_external_appledouble_audit", "ExternalAppleDoubleCleanupAudit.swift" in verify)
check("verify_runs_application_cache_canonical_audit", "ApplicationCacheCanonicalPathAudit.swift" in verify)

# 1.7.1 mount-aware deletion semantics: remote shares never masquerade as Finder Trash.
check("cleanup_capability_known_remote_smb", '"smbfs"' in capabilities and '"cifs"' in capabilities)
check("cleanup_capability_known_remote_nfs", '"nfs"' in capabilities and '"nfs4"' in capabilities)
check("cleanup_capability_known_remote_webdav", '"webdav"' in capabilities and '"davfs"' in capabilities)
check("cleanup_capability_live_statfs", "statfsFacts" in capabilities and "MNT_LOCAL" in capabilities and "MNT_RDONLY" in capabilities)
check("cleanup_capability_remote_disables_finder_trash", "remote || readOnly" in capabilities and "finderTrashSupported = false" in capabilities)
check("cleanup_capability_readonly_disables_direct_delete", "supportsDirectDeletion: !readOnly" in capabilities)
check("cleanup_capability_unknown_is_conservative", "If the mount could not tell us whether it is local" in capabilities and "finderTrashSupported = false" in capabilities)
check("cleanup_capability_server_retention_disclosure", "recycle bin" in capabilities and "快照" in capabilities)
check("appmodel_refreshes_cleanup_capabilities", "refreshCleanupTargetCapabilities" in app_model and "cleanupCapabilityGeneration" in app_model)
check("cleaner_remote_trash_disabled_notice", "網路儲存空間：Finder 垃圾桶已停用" in cleaner)
check("cleaner_readonly_cleanup_disabled_notice", "唯讀儲存空間：清理已停用" in cleaner)
check("cleaner_disables_trash_when_target_cannot", "!model.cleanupFinderVisibleTrashAvailable" in cleaner)
check("cleanup_engine_revalidates_target_capabilities", "CleanupTargetCapabilityResolver.resolve(target: target)" in cleanup)
check("cleanup_engine_rejects_remote_finder_trash", "targetCapabilities.supportsFinderVisibleTrash" in cleanup)
check("cleanup_engine_remote_direct_delete_semantics", "client_direct_delete_server_retention_unknown" in cleanup)
check("cleanup_engine_remote_filemanager_method", "filemanager_remote_remove_validated_matches" in cleanup)
check("verify_runs_cleanup_target_capability_audit", "CleanupTargetCapabilityAudit.swift" in verify)

# 1.7.3 cleanup scan choice: incremental reuse remains available, but full rebuild is always user-selectable once an index exists.
check("cleanup_index_schema", "struct CleanupIncrementalIndex: Codable, Hashable" in cleanup_index)
check("cleanup_index_tracks_covered_scopes", "var coveredScopes: Set<CleanupScope>" in cleanup_index)
check("cleanup_index_tracks_dirty_directories", "var dirtyDirectoryPaths: Set<String>" in cleanup_index)
check("cleanup_index_report_signature_binding", "sourceReportSignature" in cleanup_index and "ReportFileSignature" in cleanup_index)
check("cleanup_index_persistent_only_for_report_guided_general", "Long-lived disk reuse is deliberately limited" in cleanup_index)
check("cleanup_index_never_persists_selected_state", "!candidate.selected" in cleanup_index)
check("cleanup_index_removes_success_paths_only", "successfulPaths.formUnion(entry.movedItems)" in cleanup_index and "permanentlyDeletedItems" in cleanup_index)
check("cleanup_index_marks_success_parents_dirty", "dirtyDirectoryPaths.insert(parent)" in cleanup_index)
check("cleanup_index_keeps_path_bytes", "matchedPathBytes" in cleanup_index and "bytesByPath" in folder)
check("folder_has_targeted_refresh", "func scanCandidateDirectories(" in folder)
check("targeted_refresh_does_not_recurse", "本次只刷新" in folder and "沒有重新遞迴整個目標" in folder)
check("appmodel_profile_preserves_index_and_offers_choice", "可用補充掃描只處理未覆蓋規則，也可完整重新掃描目前等級" in app_model)
check("appmodel_scans_only_missing_scopes", "let missing = index.missingScopes" in app_model and "CleanupScanConfiguration.indexScan(scopes: scopesToScan)" in app_model)
check("appmodel_eager_classifies_appledouble_family", "classify the full AppleDouble family in the same pass" in app_model)
check("appmodel_post_cleanup_marks_index", "index.markCleanupResult(selected: selected, log: value.0)" in app_model)
check("appmodel_post_cleanup_no_full_invalidation", "已成功處理的路徑已從清理索引扣除" in app_model)
check("appmodel_refreshes_only_dirty_dirs", "refreshGeneralLocationDirectories" in app_model and "directoryPaths: dirtyDirectories" in app_model)
check("appmodel_validates_index_against_current_report", "refreshCleanupIncrementalIndexContext" in app_model and "sourceReportSignature: reportSignature" in app_model)
check("cleaner_first_scan_single_action", 'Label("開始掃描"' in cleaner and "if model.cleanupHasReusableIndex" in cleaner)
check("cleaner_offers_supplemental_scan", 'Label("補充掃描"' in cleaner and "model.scanCleanupCandidates()" in cleaner)
check("cleaner_offers_full_rescan", 'Label("完整重新掃描"' in cleaner and "model.rescanCleanupCandidatesFully()" in cleaner)
check("cleanup_index_has_full_reset", "func resettingDiscovery(" in cleanup_index and "coveredScopes = []" in cleanup_index)
check("appmodel_full_rescan_starts_fresh", "rebuildFromScratch ? reusableIndex.resettingDiscovery() : reusableIndex" in app_model)
check("appmodel_full_rescan_ignores_dirty_state", "rebuildFromScratch ? []" in app_model and "dirtyDirectoryPaths" in app_model)
check("appmodel_full_rescan_transactional_restore", "self.cleanupIncrementalIndex = previousIndex" in app_model and "舊索引仍保留" in app_model)
check("cleaner_shows_incremental_index_notice", "CleanupIncrementalIndexNotice" in cleaner)
check("verify_runs_incremental_index_audit", "CleanupIncrementalIndexAudit.swift" in verify)

# Scanner 2.5.3 external-volume timing and status contracts.
check("non_system_app_probe_not_applicable", ".notApplicableToSelectedLocation" in launcher)
check("probe_has_selected_location_result", "notApplicableToSelectedLocation" in probe)
check("appmodel_skips_fda_for_non_system", "selectedScanTarget.kind == .system" in app_model and "notApplicableToSelectedLocation" in app_model)
check("scan_sheet_explains_selected_location", "不需要探測 Mac 的受保護使用者資料" in scan_sheet)
check("scanner_clock_starts_before_target_validation", core.find("PROCESS_START_EPOCH=") < core.find("case \"$TARGET_KIND\"") )
check("scanner_tcc_probe_system_only", 'if [[ "$TARGET_KIND" == "system" ]]; then' in core and 'SCANNER_FDA_STATUS="NOT_APPLICABLE"' in core)
check("scanner_detects_filesystem_type", "TARGET_FILESYSTEM_TYPE" in core and "TARGET_IS_APFS" in core)
check("scanner_does_not_use_stat_file_type_as_filesystem", "stat -f '%T'" not in core)
check(
    "scanner_filesystem_type_uses_mount_record",
    "TARGET_MOUNT_RECORD" in core
    and "TARGET_DEVICE_IDENTIFIER" in core
    and 'TARGET_FILESYSTEM_TYPE_SOURCE="mount_record"' in core,
)
check(
    "scanner_filesystem_type_has_plist_fallback",
    "FilesystemType raw" in core and "diskutil_plist_fallback" in core,
)
check("non_apfs_skips_global_apfs_inventory", "SKIPPED_NOT_REQUIRED_FOR_SELECTED_NON_APFS_TARGET" in core)
check(
    "non_apfs_skips_target_diskutil_info",
    "target_diskutil_info_text=SKIPPED_FOR_FAST_SELECTED_LOCATION_SCAN" in core
    and "target_diskutil_info_plist=SKIPPED_NOT_REQUIRED_FOR_SELECTED_NON_APFS_TARGET" in core,
)
check(
    "preflight_and_prepare_timing_are_separate",
    'PREFLIGHT_DURATION_SECONDS=$(( PREFLIGHT_END_EPOCH - PROCESS_START_EPOCH ))' in core
    and 'PREPARE_PHASE_START_EPOCH="$PREFLIGHT_END_EPOCH"' in core,
)
check(
    "metadata_timing_includes_volatile_status",
    core.find("TARGET_VOLATILE_STATUS_FILE") < core.find("METADATA_DURATION_SECONDS="),
)
check("non_apfs_skips_snapshot_preflight", 'elif [[ "$TARGET_KIND" == "volume" && "$TARGET_IS_APFS" == "true" ]]' in core)
check("scanner_phase_timing_fields", all(token in core for token in [
    "preflight_duration_seconds=", "prepare_duration_seconds=",
    "path_scan_duration_seconds=", "metadata_duration_seconds=",
    "report_write_duration_seconds=", "total_duration_seconds=",
]))
check("parser_reads_phase_timing", all(token in parser for token in [
    'case "preflight_duration_seconds"', 'case "prepare_duration_seconds"',
    'case "path_scan_duration_seconds"', 'case "metadata_duration_seconds"',
    'case "report_write_duration_seconds"', 'case "total_duration_seconds"',
]))
check("summary_models_preflight_timing", "var preflightDurationSeconds" in models)
check("end_to_end_timing_model", "struct ScanTimingSnapshot" in models and "requestToReadySeconds" in models)
check(
    "initial_report_presentation_built_once",
    app_model[app_model.find("func loadReport("):app_model.find("func loadPath(")].count(
        "let presentation = try self.parser.loadPresentation"
    ) == 1,
)
check(
    "scan_completion_waits_for_report_and_chart",
    "掃描器已完成，正在解析報告並建立容量地圖" in app_model
    and app_model.find("self.scanSheetPhase = .completed(url)")
    > app_model.find("self.overviewSunburst = bundle.overviewSunburst"),
)
check(
    "terminal_completion_waits_for_report_and_chart",
    "Terminal 掃描器已完成，正在解析報告並建立容量地圖" in app_model
    and "workflowRequestedAt: requestedAt" in app_model
    and "usedTerminalFallback: true" in app_model,
)
check(
    "scan_sheet_shows_timing_breakdown",
    "本次耗時拆解" in scan_sheet
    and "Scanner 外等待" in scan_sheet
    and "初始容量圖" in scan_sheet
    and "Scanner 2.5.3 階段" in scan_sheet,
)
check(
    "scan_sheet_locks_during_report_build",
    "interactiveDismissDisabled(model.isFullScanRunning || model.isLoadingReport)" in scan_sheet,
)
check("volatile_status_is_nonrecursive", "target_volatile_status_is_recursive=false" in core and "TARGET_VOLATILE_STATUS_FILE" in core)
check("volatile_status_fields_written", all(token in core for token in [
    "target_spotlight_root_status=", "target_fsevents_root_status=", "target_trash_root_status=",
]))
check("parser_reads_volatile_status", all(token in parser for token in [
    'case "target_spotlight_root_status"', 'case "target_fsevents_root_status"',
    'case "target_trash_root_status"',
]))
check("overview_shows_volatile_status", "Spotlight：" in overview and "FSEvents：" in overview and "卷宗垃圾桶：" in overview)
check("successful_sessions_preserved", "guard case .failure(let error) = result else { return true }" in launcher)
check("successful_session_summary_written", "session-summary.json" in launcher and "elapsed_seconds" in launcher)
check(
    "session_summary_preserves_report_phase_timings",
    "compactReportMetadata" in launcher
    and '"total_duration_seconds"' in launcher
    and 'payload["report_' in launcher
    and ("app_before_report_seconds" in launcher or "app_total_outside_scanner_seconds" in launcher),
)
check(
    "session_summary_preserves_root_status",
    "target_spotlight_root_status" in launcher
    and "target_fsevents_root_status" in launcher
    and "target_trash_root_status" in launcher,
)
check(
    "session_summary_records_launcher_milestones",
    '"target_resolution_seconds"' in launcher
    and '"scanner_installation_seconds"' in launcher
    and '"permission_probe_seconds"' in launcher
    and '"session_preparation_seconds"' in launcher,
)
check("session_summary_schema_3", '"schema_version": 3' in launcher)
check(
    "session_summary_records_postprocessing",
    "func recordPostProcessing" in launcher
    and 'payload["report_parse_seconds"]' in launcher
    and 'payload["report_index_seconds"]' in launcher
    and 'payload["initial_view_build_seconds"]' in launcher
    and 'payload["presentation_index_source"]' in launcher
    and 'payload["presentation_index_write_seconds"]' in launcher
    and 'payload["request_to_ready_seconds"]' in launcher,
)
check("session_heavy_overlay_removed", "compactSessionArtifacts" in launcher and "appOverlayRawURL" in launcher)
check(
    "session_overlay_errors_preserved",
    "for url in [appOverlayRawURL, appOverlayWrapperURL, wrapperURL]" in launcher
    and "appOverlayErrorURL" not in launcher[launcher.find("private func compactSessionArtifacts"):launcher.find("private func writeSessionSummary")],
)
check("scan_work_age_and_count_caps", "index >= 12" in report_library and "item.1 < cutoff" in report_library)
check(
    "scan_work_prune_rejects_symlinks",
    ".isSymbolicLinkKey" in report_library and "values?.isSymbolicLink != true" in report_library,
)
check("scanner_install_is_incremental", "installScannerResourceIfNeeded" in launcher and "destinationData != sourceData" in launcher)
check("launcher_resolves_current_mount", "ScanTargetResolver.resolveMountedTarget" in launcher)
check(
    "volume_resolver_prefers_uuid",
    "normalizedUUID(target.volumeUUID)" in target_resolver
    and "normalizedUUID($0.volumeUUID) == uuid" in target_resolver,
)
check(
    "volume_resolver_has_direct_fast_path",
    "mountedVolumeTarget(atPath: target.path)" in target_resolver
    and "identitiesMatch(target, direct)" in target_resolver,
)
check(
    "volume_resolver_only_enumerates_after_fast_path",
    target_resolver.find("mountedVolumeTarget(atPath: target.path)")
    < target_resolver.find("mountedVolumes: mountedVolumes()"),
)
check(
    "app_adopts_resolved_mount",
    "adoptResolvedScanTarget(session.target)" in app_model
    and "adoptResolvedScanTarget(resolvedTarget)" in app_model,
)
check(
    "cleanup_resolves_current_mount",
    "ScanTargetResolver.resolveMountedTarget(selectedScanTarget)" in app_model,
)
check("selected_location_probe_reports_not_applicable", 'case .notApplicable: return "NOT_APPLICABLE"' in probe)
check(
    "cleanup_does_not_auto_full_rescan_after_success",
    "index.markCleanupResult(selected: selected, log: value.0)" in app_model
    and "self.scanCleanupCandidates()" not in app_model[app_model.find("case .success(let value)"):app_model.find("case .failure(let error)", app_model.find("case .success(let value)"))],
)
check(
    "folder_cleanup_fetches_sizes_lazily",
    "allocatedBytes(at: url, fallback: values)" in folder
    and ".totalFileAllocatedSizeKey" not in folder[folder.find("let resourceKeys:"):folder.find("]", folder.find("let resourceKeys:"))],
)
check(
    "full_scan_blocks_cleanup_work",
    'guard !isScanningCleanup, !isCleaning, !isLoadingReport else' in app_model
    and "避免同時讀取同一個磁碟" in app_model,
)
check(
    "cleanup_scan_blocks_full_scan",
    'guard !isFullScanRunning, !isLoadingReport else' in app_model
    and "容量掃描或報告解析正在執行" in app_model,
)
check(
    "cleanup_execution_blocks_other_disk_work",
    'func executeSelectedCleanup' in app_model
    and 'guard !isFullScanRunning, !isLoadingReport, !isScanningCleanup, !isCleaning else' in app_model
    and "目前不會同時啟動清理" in app_model,
)
check(
    "terminal_scan_rejects_duplicate_or_cleanup_work",
    'func runFullScanInTerminal' in app_model
    and "另一個磁碟工作仍在執行；目前不會同時啟動 Terminal 容量掃描。" in app_model,
)
check(
    "cleanup_scan_duration_model",
    "var durationSeconds: TimeInterval" in models
    and "finishedAt.timeIntervalSince(startedAt)" in models,
)
check(
    "cleanup_scan_duration_visible",
    "候選掃描耗時" in cleaner and "不含完整容量掃描" in cleaner,
)
check(
    "session_finalization_prunes_diagnostics",
    "try? library.pruneScanDiagnostics()" in launcher,
)

# The only two cleanup semantics: Finder-visible Trash or direct deletion.
check("finder_trash_uses_nsworkspace_recycle", "NSWorkspace.shared.recycle" in finder_trash)
check("finder_trash_uses_finder_reveal", "activateFileViewerSelecting" in finder_trash)
check("finder_trash_never_uses_filemanager_trashitem", "trashItem(at:" not in finder_trash)
check("finder_trash_never_creates_private_trash", "createDirectory" not in finder_trash)
check("finder_trash_renames_hidden_sources", "prepareVisibleSource" in finder_trash and 'hasPrefix(".")' in finder_trash)
check("finder_trash_clears_hidden_flag", "values.isHidden = false" in finder_trash)
check("finder_trash_rejects_dot_destination", "isStructurallyVisibleName" in finder_trash)
check("finder_trash_requires_managed_trash_parent", "isFinderManagedTrashDestination" in finder_trash)
check("finder_trash_records_verified_receipt", "finderVisibilityVerified: true" in finder_trash)
check("finder_trash_has_rollback", "recoverAfterFailure" in finder_trash)

check("new_executor_used", "ExternalVolumeCleanupExecutor" in cleanup)
check("old_executor_absent", "PrivilegedCleanupExecutor" not in cleanup)
check("direct_executor_uses_remove_source", "try fileManager.removeItem(at: source)" in executor)
check("direct_executor_has_no_trash_intermediate", "trashItem" not in executor and "NSWorkspace.shared.recycle" not in executor)
check("direct_executor_has_no_hidden_marker_creation", "createFile(atPath" not in executor and 'no_log")' not in executor)
check("direct_executor_has_no_shell", all(token not in executor for token in ["osascript", "/bin/rm", "rm -rf", "administrator privileges"]))
check(
    "direct_executor_exact_volumes_root",
    'volumesRootURL: URL = URL(fileURLWithPath: "/Volumes"' in executor
    and "root.path != volumesRoot.path" in executor
    and "root.deletingLastPathComponent().standardizedFileURL.path == volumesRoot.path" in executor,
)
check("direct_executor_exact_names", ".Spotlight-V100" in executor and ".fseventsd" in executor)
check("direct_executor_revalidates_device", "expectedDevice" in executor and "rootDevice" in executor)
check("direct_executor_revalidates_inode", "expectedInode" in executor and "systemFileNumber" in executor)
check("direct_executor_rejects_symlinks_packages", "isSymbolicLink" in executor and "isPackage" in executor)
check("direct_executor_rejects_read_only", "volumeIsReadOnly" in executor)
check("direct_executor_requires_local", "volumeIsLocal" in executor)
check("direct_executor_rejects_internal", "volumeIsInternal" in executor)
check("direct_executor_rejects_time_machine", "Backups.backupdb" in executor)
check("direct_executor_tracks_recreation", "current != original" in executor and "recreated" in executor)
check("direct_executor_tracks_source_removed", "let sourceRemoved: Bool" in executor)
check("direct_executor_records_error_details", "errorDomain" in executor and "errorCode" in executor)
check("direct_executor_surfaces_legacy_residue", "validateLegacyTrashURL" in executor and "isAllowedLegacyTrashName" in executor)
check("direct_executor_no_implicit_history_purge", "cleanupHistoryURL" not in executor and "discoverMatchingTrashURLs" not in executor)
check("direct_executor_no_shell_wildcard", "/Volumes/*" not in executor and "find -delete" not in executor)

# Cleanup log truthfulness and backwards compatibility.
check("log_has_trash_paths", "let trashItemPaths: [String]?" in models)
check("log_has_visible_trash_receipts", "let finderVisibleTrashItems: [FinderVisibleTrashReceipt]?" in models)
check("log_has_space_release_semantics", "let spaceReleaseSemantics: String?" in models)
check("log_has_removal_method", "let removalMethod: String?" in models)
check("log_has_error_domain", "let errorDomain: String?" in models)
check("log_has_error_code", "let errorCode: Int?" in models)
check("direct_log_does_not_fabricate_command", "command: nil" in cleanup)
check("direct_log_does_not_fabricate_exit_status", "commandExitStatus: nil" in cleanup)
check("finder_trash_flow_records_receipts", "finderVisibleTrashItems: receipts" in cleanup)
check("direct_log_source_requires_source_removed", "if outcome.sourceRemoved" in cleanup)
check("direct_mode_records_immediate_semantics", "immediate_direct_delete" in cleanup)
check("trash_mode_records_pending_empty_semantics", "pending_finder_trash_empty" in cleanup)

# High-risk selection remains explicit and there is no mixed third mode.
check("manual_selection_model", "requiresManualSelection" in models)
check("bulk_selection_excludes_manual", "isBulkSelectable" in models)
check("direct_delete_rule_gate", "supportsDirectDeletion" in models)
check(
    "trash_bins_scope_and_rule",
    "case trashBins" in models and "case trashBinContents" in models,
)
check(
    "trash_bins_l5_only",
    "case .highImpactUserData, .trashBins, .systemManagedReview" in models
    and "case .trashBins:" in models,
)
check(
    "trash_bins_not_in_default_custom_scopes",
    ".applicationWebCaches, .developerCaches, .packageManagerCaches, .downloadResidue," in app_model
    and ".trashBins" not in app_model.split("@Published var cleanupFolderCustomScopes", 1)[0].split(
        "@Published var cleanupCustomScopes", 1
    )[1],
)
check(
    "trash_bins_scans_current_uid_roots_only",
    "home.appendingPathComponent(\".Trash\"" in cleanup
    and "String(currentUserID)" in cleanup
    and "private func isValidExternalTrashRoot" in cleanup,
)
check(
    "trash_bins_excludes_remote_and_readonly",
    "ExternalVolumeCleanupExecutor.validateExternalVolumeRoot" in cleanup
    and ".volumeIsReadOnlyKey" in executor
    and "volumeValues.volumeIsLocal == true" in executor
    and "volumeValues.volumeIsInternal != true" in executor,
)
check(
    "trash_bins_direct_children_only",
    "source.deletingLastPathComponent().standardizedFileURL.path == root.path" in cleanup
    and "private func validatedTrashBinChild" in cleanup,
)
check(
    "trash_bins_symlink_fail_closed",
    "拒絕永久刪除廢紙簍中的符號連結" in cleanup
    and "private func isSymbolicLink(at url: URL)" in cleanup,
)
check(
    "trash_bins_direct_delete_only",
    "action: .permanentDeleteMatchedItems" in cleanup
    and "filemanager_remove_validated_current_user_trash_matches" in cleanup,
)
check(
    "trash_bins_ui_contextual_integration",
    "CleanupRuleIntegrationMapCard" not in cleaner
    and "1.7.5 清理規則整併位置" not in cleaner
    and "CleanupProfileScopeGrid" in cleaner
    and "model.cleanupConfiguration.requiresScope" in cleaner
    and "UltraAggressiveOptionsStrip" in cleaner
    and "model.setPresetOptionalCleanupScope" in cleaner
    and "model.cleanupProfile == .ultraAggressive" in cleaner
    and "model.cleanupProfile == .custom" in cleaner
    and "CleanupResearchReferenceNote" in cleaner,
)
check(
    "l5_optional_scopes_default_off_and_persisted",
    "var requiresExplicitPresetOptIn" in models
    and "let presetOptionalScopes: Set<CleanupScope>" in models
    and "presetOptionalScopes.contains(scope)" in models
    and "@Published var cleanupPresetOptionalScopes: Set<CleanupScope> = []" in app_model
    and "MacStorageLens.cleanupPresetOptionalScopes" in app_model
    and "func setPresetOptionalCleanupScope" in app_model,
)
check(
    "scan_step_creation_uses_configuration_authority",
    "private func scopeCanAppear" in cleanup
    and "configuration.requiresScope(scope)" in cleanup
    and "case .highImpactUserData, .trashBins, .systemManagedReview:\n      return limit >= .ultraAggressive" not in cleanup,
)
check(
    "custom_ui_groups_advanced_scopes",
    "一般與可重建項目" in cleaner
    and "高影響與檢視項目" in cleaner
    and r"filter(\.requiresExplicitPresetOptIn)" in cleaner,
)
check(
    "trash_bins_confirmation_copy",
    "我了解『廢紙簍（永久清空）』" in cleaner
    and "其他 UID 與 NAS #recycle" in cleaner,
)
check("legacy_residue_direct_only", "requiresDirectDeletion" in models and "folderLegacySpotlightTrashResidue" in models)
check("cleaner_has_finder_visible_button", "移到 Finder 可見垃圾桶" in cleaner)
check("scope_tint_has_no_category_only_case", "case .folderLegacyTrashResidue: return LensTheme.clay" not in cleaner)
check("category_symbol_keeps_legacy_residue", 'case .folderLegacyTrashResidue: return "trash.slash"' in cleaner)
check("report_index_try_warning_consumed", "_ = try? self.reportPresentationIndexStore.save(document: document, for: url)" in app_model)
check("cleaner_has_direct_delete_button", "直接徹底刪除…" in cleaner)
check("cleaner_disables_trash_for_direct_only", r"selected.contains(where: \.requiresDirectDeletion)" in cleaner)
check("cleaner_requires_permanent_confirmation", "acknowledgedPermanentDeletion" in cleaner)
check("cleaner_discloses_no_trash", "不經任何垃圾桶" in cleaner)
check("cleaner_discloses_no_hidden_marker", "不建立 no_log 或其他隱藏" in cleaner)
check("appmodel_reveals_verified_receipts", "FinderVisibleTrash.reveal" in app_model)
check("appmodel_never_opens_hidden_volume_trash", "cleanupVolumeTrashURL" not in app_model and 'appendingPathComponent(".Trashes"' not in app_model)
check("folder_surfaces_legacy_hidden_trash_residue", "appendLegacyHiddenTrashResiduesIfIncluded" in folder)
check("folder_does_not_descend_into_trash", 'case ".Trashes", ".Trash"' in folder and "enumerator.skipDescendants()" in folder)

# Performance regression protection.
check("folder_service_candidates_unknown_size", "Keep the size" in folder and "explicitly unknown" in folder)
check("folder_service_candidates_zero_bytes", "case .folderSpotlightMetadata, .folderFSEventsMetadata:" in folder and "bytes = 0" in folder)
check("folder_fsevents_no_hidden_policy_exception", "containsOnlyFSEventsNoLogMarker" not in folder and "bytes = 0" in folder)
check("cleanup_scan_no_spotlight_recursive_size", "allocatedSizeRecursively(url)" not in "\n".join(
    line for line in folder.splitlines() if "Spotlight" in line or "FSEvents" in line
))

# Bundle permission declaration and source verifier.
check("removable_volume_usage_description", "NSRemovableVolumesUsageDescription" in build)
check("build_copies_scanner_253", "SCANNER_VERSION=\"2.5.3\"" in build and "mac-system-storage-tree-v${SCANNER_VERSION}.command" in build)
check("verify_uses_finder_visible_trash", "FinderVisibleTrash.swift" in verify)
check("verify_uses_external_executor", "ExternalVolumeCleanupExecutor.swift" in verify)
check("verify_uses_external_audit", "ExternalVolumeCleanupAudit.swift" in verify)
check("verify_uses_external_rescan_audit", "ExternalVolumeRescanAudit.swift" in verify)
check("verify_runs_static_contract", "static_contract_audit.py" in verify)
check("verify_runs_ui_enum_context", "ui_enum_context_audit.py" in verify)
check("verify_runs_system_junk_integration", "system_junk_integration_audit.py" in verify)
check("verify_runs_trash_bins_fixture", "TrashBinsCleanupAudit.swift" in verify)
check("verify_uses_1_7_5_provenance", "provenance_audit_1_7_5.py" in verify)
check("verify_runs_release_build_on_macos", "swift build -c release" in verify)

# No accidental network/telemetry additions in the changed core.
combined = "\n".join([executor, cleanup, capabilities, folder, system_junk_knowledge, core, wrapper])
for token in ["URLSession", "http://", "https://", "telemetry", "analytics endpoint"]:
    check(f"no_network_or_telemetry:{token}", token not in combined, token)

# Historical safety engines remain present.
check("appledouble_inspector_preserved", "AppleDouble" in texts["Sources/MacStorageLens/AppleDoubleInspector.swift"])
check("system_cleanup_engine_preserved", "CleanupEngine" in cleanup)
check("scanner_wrapper_points_to_core", "mac-system-storage-tree-core-v2.5.3.command" in wrapper)

failed = [item for item in checks if not item["passed"]]
result = {
    "version": VERSION,
    "build": BUILD,
    "scanner": SCANNER,
    "passed": len(checks) - len(failed),
    "failed": len(failed),
    "total": len(checks),
    "checks": checks,
    "file_sha256": {path: digest(path) for path in required if (ROOT / path).is_file()},
}
output = Path(sys.argv[1]) if len(sys.argv) > 1 else None
payload = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
if output:
    output.write_text(payload, encoding="utf-8")
else:
    sys.stdout.write(payload)
if failed:
    for item in failed:
        print(f"FAIL {item['name']}: {item['detail']}", file=sys.stderr)
    raise SystemExit(1)
