import Foundation

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

@main
struct SunburstAggregationAudit {
  private static var checks: [[String: Any]] = []
  private static var failures = 0

  static func main() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent(
        "MacStorageLens-SunburstAggregationAudit-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let parser = ReportParser()
    let ordinaryCount = 13
    let ordinaryURL = root.appendingPathComponent("ordinary.md")
    try Data(fixtureReport(childCount: ordinaryCount).utf8).write(to: ordinaryURL)
    let ordinaryDocument = try parser.parse(url: ordinaryURL)
    let ordinary = try parser.loadPresentation(
      document: ordinaryDocument,
      parentPath: "/System/Volumes/Data",
      maximumDepth: SunburstPresentationPolicy.maximumDepth,
      maximumChildren: SunburstPresentationPolicy.visibleChildBudgetWhenAggregated
    )

    check("ordinary_children_all_loaded", ordinary.0.count == ordinaryCount)
    check("ordinary_chart_keeps_all_children", ordinary.1.children.count == ordinaryCount)
    check(
      "ordinary_chart_has_no_aggregate",
      ordinary.1.children.allSatisfy { $0.kind != .otherChildren }
    )

    let hugeCount = SunburstPresentationPolicy.automaticAggregationThreshold + 7
    let hugeURL = root.appendingPathComponent("huge.md")
    try Data(fixtureReport(childCount: hugeCount).utf8).write(to: hugeURL)
    let hugeDocument = try parser.parse(url: hugeURL)
    let huge = try parser.loadPresentation(
      document: hugeDocument,
      parentPath: "/System/Volumes/Data",
      maximumDepth: SunburstPresentationPolicy.maximumDepth,
      maximumChildren: SunburstPresentationPolicy.visibleChildBudgetWhenAggregated
    )

    let aggregates = huge.1.children.filter { $0.kind == .otherChildren }
    let expectedVisible = SunburstPresentationPolicy.visibleChildBudgetWhenAggregated
    let expectedOmitted = hugeCount - expectedVisible
    check("huge_report_keeps_complete_child_index", huge.0.count == hugeCount)
    check("huge_chart_uses_single_aggregate", aggregates.count == 1)
    check("huge_chart_respects_visible_budget", huge.1.children.count == expectedVisible + 1)
    check("aggregate_label_has_exact_count", aggregates.first?.label == "其他 \(expectedOmitted) 項")
    check("aggregate_keeps_parent_path", aggregates.first?.path == "/System/Volumes/Data")
    check("aggregate_is_expandable", aggregates.first?.isExpandableAggregate == true)
    check("aggregate_is_interactive", aggregates.first?.isInteractive == true)

    let allChildren = try parser.loadChildren(
      document: hugeDocument,
      parentPath: "/System/Volumes/Data"
    )
    let omitted = Array(allChildren.dropFirst(expectedVisible))
    check("aggregate_members_are_recoverable_from_report", omitted.count == expectedOmitted)
    check(
      "aggregate_members_have_real_paths",
      omitted.allSatisfy { $0.path.hasPrefix("/System/Volumes/Data/Folder-") }
    )

    let output: [String: Any] = [
      "version": "1.7.0",
      "build": 27,
      "automaticAggregationThreshold": SunburstPresentationPolicy.automaticAggregationThreshold,
      "visibleChildBudgetWhenAggregated": SunburstPresentationPolicy
        .visibleChildBudgetWhenAggregated,
      "checks": checks,
      "passed": checks.count - failures,
      "total": checks.count,
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

  private static func fixtureReport(childCount: Int) -> String {
    let rootPath = "/System/Volumes/Data"
    let rows = (0..<childCount).map { index in
      "├── 1 KiB  \(rootPath)/Folder-\(String(format: "%05d", index))"
    }.joined(separator: "\n")
    return """
      # MacStorageLens sunburst aggregation fixture

      ## RUN_METADATA
      ````text
      scanner_version=2.5.3
      generated_at=2026-08-22 14:20:00 -0700
      scan_target_kind=system
      scan_target_path=\(rootPath)
      scan_target_display_name=Macintosh HD
      scan_target_volume_uuid=SYSTEM
      target_mount_point=\(rootPath)
      launcher_mode=app
      scanner_privilege_channel=app_tcc_overlay_plus_administrator
      full_disk_access_probe=LIKELY_AVAILABLE
      ````

      ## TARGET_VOLUME_ACCOUNTING_DIFFERENCE
      ````text
      accounting_scope=system
      accounting_gap_applicable=true
      target_path=\(rootPath)
      target_mount_point=\(rootPath)
      target_tree_du_kib=\(childCount)
      target_volume_capacity_kib=\(childCount * 2)
      target_volume_used_kib_pre_scan=\(childCount)
      target_volume_available_kib_pre_scan=\(childCount)
      target_accounting_gap_kib=0
      ````

      ## ROOT_SCAN_SUMMARY
      | Root | du KiB | GiB | GB | Directory nodes | Diagnostic lines | Permission/TCC restrictions | du exit | Seconds |
      |---|---:|---:|---:|---:|---:|---:|---:|---:|
      | `\(rootPath)` | \(childCount) | 0 | 0 | \(childCount + 1) | 0 | 0 | 0 | 1 |

      ### DIRECTORY_TREE (\(rootPath))

      ````text
      \(childCount) KiB  \(rootPath)
      \(rows)
      ````

      report_complete=true
      """
  }

  private static func check(_ name: String, _ passed: Bool, detail: String = "") {
    checks.append(["name": name, "passed": passed, "detail": detail])
    if !passed { failures += 1 }
  }
}
