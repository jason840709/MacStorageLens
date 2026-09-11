import Foundation

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

@main
struct ReportGuidedCleanupAudit {
  private static var checks: [[String: Any]] = []
  private static var failures = 0

  static func main() throws {
    let fileManager = FileManager.default
    let temp = fileManager.temporaryDirectory
      .appendingPathComponent(
        "MacStorageLens-ReportGuidedCleanup-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: temp) }
    try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)

    let root = temp.appendingPathComponent("NAS Fixture", isDirectory: true)
    let known = root.appendingPathComponent("Known", isDirectory: true)
    let addedAfterReport = root.appendingPathComponent("Added After Report", isDirectory: true)
    let recycle = root.appendingPathComponent("#recycle", isDirectory: true)
    try fileManager.createDirectory(at: known, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: addedAfterReport, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: recycle, withIntermediateDirectories: true)
    try Data("root".utf8).write(to: root.appendingPathComponent(".DS_Store"))
    try Data("windows".utf8).write(to: root.appendingPathComponent("Thumbs.db"))
    try Data("known".utf8).write(to: known.appendingPathComponent(".DS_Store"))
    try Data("new".utf8).write(to: addedAfterReport.appendingPathComponent(".DS_Store"))
    try Data("server-trash".utf8).write(to: recycle.appendingPathComponent(".DS_Store"))
    try Data("ordinary".utf8).write(to: known.appendingPathComponent("movie.mov"))

    let reportURL = temp.appendingPathComponent("nas-storage-tree.md")
    try Data(report(rootPath: root.path, knownPath: known.path, recyclePath: recycle.path).utf8)
      .write(to: reportURL)
    let parser = ReportParser()
    let document = try parser.parse(url: reportURL)
    let target = ScanTarget(
      kind: .folder,
      displayName: "NAS Fixture",
      path: root.path,
      volumeUUID: nil
    )
    let configuration = CleanupScanConfiguration(
      profile: .conservative,
      customScopes: [],
      customMinimumBytes: 0
    )

    let smbCapabilities = CleanupTargetCapabilities(
      filesystemType: "smbfs",
      isRemote: true,
      isReadOnly: false,
      isInternalStorage: nil,
      supportsFinderVisibleTrash: false,
      supportsDirectDeletion: true,
      detectionSource: "audit_fixture"
    )
    let engine = FolderCleanupEngine(
      fileManager: fileManager,
      homeURL: temp,
      targetCapabilityResolver: { _ in smbCapabilities }
    )
    let quick = try engine.scanCandidatesUsingReport(
      configuration: configuration,
      target: target,
      document: document,
      parser: parser
    )
    let quickPaths = Set(quick.candidates.flatMap(\.matchedPaths))

    check("quick_source_recorded", quick.scanSource == .existingStorageReport)
    check("quick_report_url_recorded", quick.sourceReportURL == reportURL)
    check(
      "quick_finds_root_candidate",
      quickPaths.contains(root.appendingPathComponent(".DS_Store").path))
    check(
      "quick_finds_canonical_windows_candidate_on_case_sensitive_fs",
      quickPaths.contains(root.appendingPathComponent("Thumbs.db").path))
    check(
      "quick_finds_reported_directory_candidate",
      quickPaths.contains(known.appendingPathComponent(".DS_Store").path))
    check(
      "quick_does_not_invent_unreported_new_directory",
      !quickPaths.contains(addedAfterReport.appendingPathComponent(".DS_Store").path)
    )
    check(
      "quick_skips_reported_server_recycle_subtree",
      !quickPaths.contains(recycle.appendingPathComponent(".DS_Store").path)
    )
    check(
      "quick_notice_discloses_server_recycle_skip",
      quick.notices.contains { $0.contains("#recycle") && $0.contains("略過") }
    )
    let reportText = try String(contentsOf: reportURL, encoding: .utf8)
    check("markdown_tree_contains_no_file_rows", !reportText.contains(".DS_Store"))
    check(
      "quick_notice_discloses_snapshot_boundary",
      quick.notices.contains { $0.contains("新增但不在報告中的整個新資料夾") }
    )

    let full = try engine.scanCandidates(
      configuration: configuration,
      target: target
    )
    let fullPaths = Set(full.candidates.flatMap(\.matchedPaths))
    check("full_source_recorded", full.scanSource == .liveFilesystem)
    check(
      "full_scan_finds_new_directory_candidate",
      fullPaths.contains(addedAfterReport.appendingPathComponent(".DS_Store").path))
    check("full_scan_contains_quick_candidates", quickPaths.isSubset(of: fullPaths))
    check(
      "full_scan_skips_server_recycle_subtree",
      !fullPaths.contains(recycle.appendingPathComponent(".DS_Store").path)
    )

    let output: [String: Any] = [
      "version": "1.7.5",
      "build": 33,
      "checks": checks,
      "passed": checks.count - failures,
      "total": checks.count,
      "quickMatched": quickPaths.count,
      "fullMatched": fullPaths.count,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    if CommandLine.arguments.count > 1 {
      try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    if failures > 0 { exit(1) }
  }

  private static func report(rootPath: String, knownPath: String, recyclePath: String) -> String {
    """
    # MacStorageLens report-guided cleanup fixture

    ## RUN_METADATA
    ````text
    scanner_version=2.5.3
    generated_at=2026-08-22 14:20:00 -0700
    scan_target_kind=folder
    scan_target_path=\(rootPath)
    scan_target_display_name=NAS Fixture
    target_mount_point=\(rootPath)
    launcher_mode=app
    scanner_privilege_channel=app_direct
    full_disk_access_probe=NOT_APPLICABLE
    path_scan_status=NO_REPORTED_DU_ERRORS
    du_error_line_count=0
    permission_or_tcc_error_count=0
    ````

    ## TARGET_VOLUME_ACCOUNTING_DIFFERENCE
    ````text
    accounting_scope=folder_tree_only
    accounting_gap_applicable=false
    target_path=\(rootPath)
    target_mount_point=\(rootPath)
    target_tree_du_kib=2
    target_volume_capacity_kib=1000
    target_volume_used_kib_pre_scan=2
    target_volume_available_kib_pre_scan=998
    target_accounting_gap_kib=0
    ````

    ## ROOT_SCAN_SUMMARY
    | Root | du KiB | GiB | GB | Directory nodes | Diagnostic lines | Permission/TCC restrictions | du exit | Seconds |
    |---|---:|---:|---:|---:|---:|---:|---:|---:|
    | `\(rootPath)` | 2 | 0 | 0 | 3 | 0 | 0 | 0 | 1 |

    ### DIRECTORY_TREE (\(rootPath))
    ````text
    2 KiB  \(rootPath)
    ├── 1 KiB  \(knownPath)
    └── 1 KiB  \(recyclePath)
    ````

    report_complete=true
    """
  }

  private static func check(_ name: String, _ passed: Bool, detail: String = "") {
    checks.append(["name": name, "passed": passed, "detail": detail])
    if !passed { failures += 1 }
  }
}
