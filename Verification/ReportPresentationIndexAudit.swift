import Foundation

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

@main
struct ReportPresentationIndexAudit {
  private static var checks: [[String: Any]] = []
  private static var failures = 0

  static func main() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent(
        "MacStorageLens-PresentationIndexAudit-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let reportURL = root.appendingPathComponent("system-storage-tree-fixture.md")
    let report = fixtureReport()
    try Data(report.utf8).write(to: reportURL, options: .atomic)

    let parser = ReportParser()
    var progressFractions: [Double] = []
    let parseStartedAt = Date()
    let document = try parser.parse(url: reportURL) { progress in
      progressFractions.append(progress.fraction)
    }
    let parseSeconds = Date().timeIntervalSince(parseStartedAt)

    check("report_is_complete", document.summary.reportComplete)
    check("initial_presentation_is_embedded", document.initialPresentation != nil)
    check("parse_progress_starts_at_zero", progressFractions.first == 0)
    check("parse_progress_finishes_at_one", progressFractions.last == 1)
    check(
      "parse_progress_is_monotonic",
      zip(progressFractions, progressFractions.dropFirst()).allSatisfy { $0 <= $1 }
    )

    let rootPath = "/System/Volumes/Data"
    let embedded = try parser.loadPresentation(
      document: document,
      parentPath: rootPath,
      maximumDepth: SunburstPresentationPolicy.maximumDepth,
      maximumChildren: SunburstPresentationPolicy.visibleChildBudgetWhenAggregated
    )
    check("embedded_children_available", embedded.0.count == 3)
    check("embedded_chart_root_matches", embedded.1.path == rootPath)
    check("embedded_chart_has_four_level_data", flattenedCount(embedded.1) >= 8)

    let indexDirectory = root.appendingPathComponent("Report Indexes", isDirectory: true)
    let store = try ReportPresentationIndexStore(directoryURL: indexDirectory)
    let directoryPermissions =
      (try? fileManager.attributesOfItem(atPath: indexDirectory.path)[.posixPermissions]
      as? NSNumber)?
      .intValue
    check(
      "index_directory_is_owner_only",
      directoryPermissions == 0o700,
      detail: "mode=\(directoryPermissions ?? -1)"
    )
    let writeStartedAt = Date()
    guard let indexURL = try store.save(document: document, for: reportURL) else {
      throw ReportPresentationIndexError.invalidReport(
        "fixture did not produce an initial presentation")
    }
    let writeSeconds = Date().timeIntervalSince(writeStartedAt)
    check("index_file_created", fileManager.fileExists(atPath: indexURL.path))

    let permissions =
      (try? fileManager.attributesOfItem(atPath: indexURL.path)[.posixPermissions] as? NSNumber)?
      .intValue
    check("index_file_is_owner_only", permissions == 0o600, detail: "mode=\(permissions ?? -1)")

    let readStartedAt = Date()
    let payload = try store.load(for: reportURL)
    let readSeconds = Date().timeIntervalSince(readStartedAt)
    check("valid_index_loads", payload != nil)
    if let payload {
      let cachedDocument = payload.document(for: reportURL)
      check("cached_summary_matches", cachedDocument.summary == document.summary)
      check("cached_sections_match", cachedDocument.sections == document.sections)
      check("cached_top_level_matches", cachedDocument.topLevelNodes == document.topLevelNodes)
      check(
        "cached_presentation_matches",
        cachedDocument.initialPresentation == document.initialPresentation)
    }

    // Prove that the middle sample participates in invalidation even when size and
    // modification time are restored. This protects a large Markdown report whose
    // Data section changed without altering its first or last sample.
    let originalDate =
      try reportURL.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate ?? Date()
    var bytes = try Data(contentsOf: reportURL)
    let marker = Data("MIDDLE-SIGNATURE-SAMPLE-A".utf8)
    let replacement = Data("MIDDLE-SIGNATURE-SAMPLE-B".utf8)
    guard let markerRange = bytes.range(of: marker), marker.count == replacement.count else {
      fatalError("middle signature marker missing")
    }
    bytes.replaceSubrange(markerRange, with: replacement)
    try bytes.write(to: reportURL, options: .atomic)
    try fileManager.setAttributes([.modificationDate: originalDate], ofItemAtPath: reportURL.path)
    check("middle_change_invalidates_index", try store.load(for: reportURL) == nil)
    check("stale_index_is_removed", !fileManager.fileExists(atPath: indexURL.path))

    // Restore the report, recreate the index, then verify corrupt and orphan cache handling.
    try Data(report.utf8).write(to: reportURL, options: .atomic)
    let restoredDocument = try parser.parse(url: reportURL)
    _ = try store.save(document: restoredDocument, for: reportURL)
    try Data("not-json".utf8).write(to: indexURL, options: .atomic)
    check("corrupt_index_is_ignored", try store.load(for: reportURL) == nil)
    check("corrupt_index_is_removed", !fileManager.fileExists(atPath: indexURL.path))

    let externalTarget = root.appendingPathComponent("outside-index.json")
    try Data("outside".utf8).write(to: externalTarget, options: .atomic)
    try fileManager.createSymbolicLink(at: indexURL, withDestinationURL: externalTarget)
    check("symbolic_link_index_is_ignored", try store.load(for: reportURL) == nil)
    check("symbolic_link_index_is_removed", !fileManager.fileExists(atPath: indexURL.path))
    check("symbolic_link_target_is_untouched", fileManager.fileExists(atPath: externalTarget.path))

    let realDirectory = root.appendingPathComponent("real-index-directory", isDirectory: true)
    let linkedDirectory = root.appendingPathComponent("linked-index-directory", isDirectory: true)
    try fileManager.createDirectory(at: realDirectory, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(at: linkedDirectory, withDestinationURL: realDirectory)
    let linkedDirectoryRejected: Bool
    do {
      _ = try ReportPresentationIndexStore(directoryURL: linkedDirectory)
      linkedDirectoryRejected = false
    } catch {
      linkedDirectoryRejected = true
    }
    check("symbolic_link_index_directory_is_rejected", linkedDirectoryRejected)

    let signature = try ReportFileSignature.read(from: reportURL)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]

    var invalidSections = restoredDocument.sections
    if let section = invalidSections[rootPath] {
      invalidSections[rootPath] = SectionRange(
        root: section.root,
        startOffset: section.startOffset,
        endOffset: signature.byteCount + 1
      )
    }
    let invalidSectionDocument = ReportDocument(
      url: reportURL,
      summary: restoredDocument.summary,
      sections: invalidSections,
      topLevelNodes: restoredDocument.topLevelNodes,
      initialPresentation: restoredDocument.initialPresentation
    )
    let invalidSectionPayload = ReportPresentationIndexPayload(
      reportURL: reportURL,
      reportSignature: signature,
      document: invalidSectionDocument,
      initialPresentation: restoredDocument.initialPresentation!
    )
    try encoder.encode(invalidSectionPayload).write(to: indexURL, options: .atomic)
    check("out_of_range_section_index_is_rejected", try store.load(for: reportURL) == nil)

    let originalInitial = restoredDocument.initialPresentation!
    let escapedSunburst = SunburstItem(
      id: originalInitial.sunburst.id,
      label: originalInitial.sunburst.label,
      path: "/tmp/outside-report-root",
      bytes: originalInitial.sunburst.bytes,
      kind: originalInitial.sunburst.kind,
      children: originalInitial.sunburst.children,
      colorHint: originalInitial.sunburst.colorHint
    )
    let escapedInitial = ReportInitialPresentation(
      rootPath: originalInitial.rootPath,
      maximumDepth: originalInitial.maximumDepth,
      maximumChildren: originalInitial.maximumChildren,
      children: originalInitial.children,
      sunburst: escapedSunburst
    )
    let escapedDocument = ReportDocument(
      url: reportURL,
      summary: restoredDocument.summary,
      sections: restoredDocument.sections,
      topLevelNodes: restoredDocument.topLevelNodes,
      initialPresentation: escapedInitial
    )
    let escapedPayload = ReportPresentationIndexPayload(
      reportURL: reportURL,
      reportSignature: signature,
      document: escapedDocument,
      initialPresentation: escapedInitial
    )
    try encoder.encode(escapedPayload).write(to: indexURL, options: .atomic)
    check("out_of_root_presentation_is_rejected", try store.load(for: reportURL) == nil)

    _ = try store.save(document: restoredDocument, for: reportURL)
    let orphanReport = root.appendingPathComponent("orphan.md")
    try Data(report.utf8).write(to: orphanReport, options: .atomic)
    let orphanDocument = try parser.parse(url: orphanReport)
    guard let orphanIndex = try store.save(document: orphanDocument, for: orphanReport) else {
      fatalError("orphan fixture did not produce an index")
    }
    try fileManager.removeItem(at: orphanReport)
    store.prune(keepingReportURLs: [reportURL])
    check("live_index_survives_prune", fileManager.fileExists(atPath: indexURL.path))
    check("orphan_index_is_pruned", !fileManager.fileExists(atPath: orphanIndex.path))

    let output: [String: Any] = [
      "version": "1.7.0",
      "build": 27,
      "schemaVersion": ReportPresentationIndexPayload.currentSchemaVersion,
      "parserSchema": ReportPresentationIndexPayload.currentParserSchema,
      "parseSeconds": parseSeconds,
      "indexWriteSeconds": writeSeconds,
      "indexReadSeconds": readSeconds,
      "checks": checks,
      "passed": checks.count - failures,
      "failed": failures,
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

  private static func fixtureReport() -> String {
    let padding = String(repeating: "P", count: 220_000)
    return """
      # MacStorageLens presentation index fixture

      ## RUN_METADATA
      ````text
      scanner_version=2.5.3
      generated_at=2026-08-19 10:00:00 +0800
      scan_target_kind=system
      scan_target_path=/System/Volumes/Data
      scan_target_display_name=Macintosh HD
      scan_target_volume_uuid=SYSTEM
      target_mount_point=/System/Volumes/Data
      launcher_mode=app
      scanner_privilege_channel=app_tcc_overlay_plus_administrator
      full_disk_access_probe=LIKELY_AVAILABLE
      report_fixture_padding=\(padding)MIDDLE-SIGNATURE-SAMPLE-A\(padding)
      ````

      ## TARGET_VOLUME_ACCOUNTING_DIFFERENCE
      ````text
      accounting_scope=system
      accounting_gap_applicable=true
      target_path=/System/Volumes/Data
      target_mount_point=/System/Volumes/Data
      target_tree_du_kib=900
      target_volume_capacity_kib=2000
      target_volume_used_kib_pre_scan=1000
      target_volume_available_kib_pre_scan=1000
      target_accounting_gap_kib=100
      ````

      ## ROOT_SCAN_SUMMARY
      | Root | du KiB | GiB | GB | Directory nodes | Diagnostic lines | Permission/TCC restrictions | du exit | Seconds |
      |---|---:|---:|---:|---:|---:|---:|---:|---:|
      | `/System/Volumes/Data` | 900 | 0.001 | 0.001 | 9 | 0 | 0 | 0 | 1 |

      ### DIRECTORY_TREE (/System/Volumes/Data)

      ````text
      900 KiB  /System/Volumes/Data
      ├── 500 KiB  /System/Volumes/Data/Applications
      │   ├── 300 KiB  /System/Volumes/Data/Applications/App A.app
      │   │   ├── 200 KiB  /System/Volumes/Data/Applications/App A.app/Contents
      │   │   │   ├── 100 KiB  /System/Volumes/Data/Applications/App A.app/Contents/Resources
      │   └── 200 KiB  /System/Volumes/Data/Applications/App B.app
      ├── 300 KiB  /System/Volumes/Data/Users
      │   ├── 250 KiB  /System/Volumes/Data/Users/test
      │   │   ├── 150 KiB  /System/Volumes/Data/Users/test/Documents
      └── 100 KiB  /System/Volumes/Data/private
      ````

      report_complete=true
      """
  }

  private static func flattenedCount(_ item: SunburstItem) -> Int {
    1 + item.children.reduce(0) { $0 + flattenedCount($1) }
  }

  private static func check(_ name: String, _ passed: Bool, detail: String = "") {
    checks.append(["name": name, "passed": passed, "detail": detail])
    if !passed { failures += 1 }
  }
}
