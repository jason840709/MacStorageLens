import Foundation

@main
struct ApplicationCacheCanonicalPathAudit {
  private static var checks: [[String: Any]] = []
  private static var failures = 0

  static func main() throws {
    let fileManager = FileManager.default
    let fixture = fileManager.temporaryDirectory
      .appendingPathComponent(
        "MacStorageLens-ApplicationCacheCanonicalPathAudit-\(UUID().uuidString)",
        isDirectory: true
      )
    defer { try? fileManager.removeItem(at: fixture) }

    let home = fixture.appendingPathComponent("home", isDirectory: true)
    let appRoot = home.appendingPathComponent(
      "Library/Application Support/ExampleApp", isDirectory: true)
    let lowercaseCache = appRoot.appendingPathComponent("cache", isDirectory: true)
    let payload = lowercaseCache.appendingPathComponent("payload.bin")
    try fileManager.createDirectory(at: lowercaseCache, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 4096).write(to: payload)

    let supportRoot = fixture.appendingPathComponent("support", isDirectory: true)
    let library = try ReportLibrary(rootURL: supportRoot, fileManager: fileManager)
    let engine = CleanupEngine(
      library: library,
      fileManager: fileManager,
      homeURL: home,
      localLibraryURL: fixture.appendingPathComponent("Library", isDirectory: true),
      privateRootURL: fixture.appendingPathComponent("private", isDirectory: true)
    )
    let configuration = CleanupScanConfiguration.indexScan(scopes: [.applicationWebCaches])
    let result = try engine.scanCandidates(configuration: configuration, target: .systemStorage)
    guard
      var candidate = result.candidates.first(where: {
        $0.ruleID == .applicationRenderCache && $0.path == lowercaseCache.path
      })
    else {
      check("scanner_uses_actual_lowercase_cache_path", false)
      return try finish()
    }

    check("scanner_uses_actual_lowercase_cache_path", candidate.path == lowercaseCache.path)
    check(
      "scanner_does_not_synthesize_titlecase_cache_path",
      !result.candidates.contains {
        $0.ruleID == .applicationRenderCache
          && $0.path == appRoot.appendingPathComponent("Cache", isDirectory: true).path
      })

    candidate.selected = true
    let (log, _) = try engine.executeSelected(
      [candidate],
      profile: .conservative,
      target: .systemStorage,
      removalMode: .forceDelete
    )
    let entry = log.entries.first
    check("executor_accepts_same_canonical_cache_path", entry?.failures.isEmpty == true)
    check(
      "force_delete_removes_cache_contents",
      !fileManager.fileExists(atPath: payload.path)
        && fileManager.fileExists(atPath: lowercaseCache.path)
    )
    check(
      "cleanup_log_records_actual_case_path",
      entry?.permanentlyDeletedItems.contains(payload.path) == true)

    try finish()
  }

  private static func finish() throws {
    let output: [String: Any] = [
      "version": "1.7.5",
      "build": 33,
      "checks": checks,
      "passed": checks.count - failures,
      "total": checks.count,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    if CommandLine.arguments.count > 1 {
      try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    if failures > 0 { exit(1) }
  }

  private static func check(_ name: String, _ passed: Bool, detail: String = "") {
    checks.append(["name": name, "passed": passed, "detail": detail])
    if !passed { failures += 1 }
  }
}
