import Foundation

struct CleanupPolicyAuditResult: Codable {
  let levelCounts: [String: Int]
  let levelBytes: [String: Int64]
  let customCount: Int
  let blockedCloudPaths: Int
  let allDefaultUnselected: Bool
  let reviewOnlySelectableCount: Int
  let passed: Bool
}

@main
struct CleanupPolicyAudit {
  static func main() throws {
    let outputURL =
      CommandLine.arguments.count > 1
      ? URL(fileURLWithPath: CommandLine.arguments[1])
      : URL(fileURLWithPath: "/tmp/cleanup-policy-audit.json")
    let fm = FileManager.default
    let fixture = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(
        "MacStorageLens-cleanup-fixture-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: fixture) }
    let home = fixture.appendingPathComponent("home", isDirectory: true)
    let localLibrary = fixture.appendingPathComponent("Library", isDirectory: true)
    let privateRoot = fixture.appendingPathComponent("private", isDirectory: true)
    let library = try ReportLibrary(
      rootURL: fixture.appendingPathComponent("support", isDirectory: true), fileManager: fm)

    try makeDirectory(home)
    try makeDirectory(localLibrary)
    try makeDirectory(privateRoot)

    try allocate(home, "Library/Caches/com.example.Editor", mebibytes: 24)
    try allocate(home, "Library/Caches/com.apple.mediaanalysisd", mebibytes: 15)
    try allocate(home, "Library/Caches/CloudKit", mebibytes: 30)
    try allocate(home, "Library/Containers/com.example.Sandbox/Data/Library/Caches", mebibytes: 22)
    try allocate(home, "Library/Containers/com.apple.wallpaper/Data/Library/Caches", mebibytes: 12)
    try allocate(
      home, "Library/Group Containers/group.com.example.shared/Library/Caches", mebibytes: 11)
    try allocate(
      home,
      "Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/archives",
      mebibytes: 12)
    try allocate(home, "Library/Application Support/Cursor/Code Cache", mebibytes: 11)
    try allocate(
      home, "Library/Application Support/Cursor/Service Worker/CacheStorage", mebibytes: 6)
    try allocate(
      home,
      "Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage",
      mebibytes: 7)
    try allocate(
      home, "Library/Application Support/Typeless/Partitions/session/Code Cache", mebibytes: 11)
    try allocate(home, "Library/Developer/Xcode/DerivedData", mebibytes: 6)
    try allocate(home, ".npm/_cacache", mebibytes: 6)
    try allocate(home, "Library/Logs/DiagnosticReports", mebibytes: 2)
    try allocate(home, "Library/Application Support/MobileSync/Backup/device-1", mebibytes: 1)
    try allocate(localLibrary, "Caches/com.apple.iconservices.store", mebibytes: 2)
    try allocate(privateRoot, "var/db/diagnostics", mebibytes: 2)

    let cacheRoot = home.appendingPathComponent("Library/Caches", isDirectory: true)
    let external = fixture.appendingPathComponent("external", isDirectory: true)
    try allocate(fixture, "external", mebibytes: 21)
    let symlink = cacheRoot.appendingPathComponent("com.example.Symlink")
    try fm.createSymbolicLink(at: symlink, withDestinationURL: external)

    let engine = CleanupEngine(
      library: library,
      fileManager: fm,
      homeURL: home,
      localLibraryURL: localLibrary,
      privateRootURL: privateRoot
    )

    let ultraAggressiveDefault = try engine.scanCandidates(
      configuration: CleanupScanConfiguration(
        profile: .ultraAggressive,
        customScopes: [],
        customMinimumBytes: 0
      ))

    var results: [CleanupProfile: CleanupScanResult] = [:]
    for profile in CleanupProfile.allCases where profile != .custom {
      let optionalScopes: Set<CleanupScope> =
        profile == .ultraAggressive ? [.highImpactUserData, .systemManagedReview] : []
      let config = CleanupScanConfiguration(
        profile: profile,
        customScopes: [],
        customMinimumBytes: 0,
        presetOptionalScopes: optionalScopes
      )
      results[profile] = try engine.scanCandidates(configuration: config)
    }

    let custom = try engine.scanCandidates(
      configuration: CleanupScanConfiguration(
        profile: .custom,
        customScopes: [.packageManagerCaches],
        customMinimumBytes: 1 * 1_048_576
      ))

    try require(
      hasRule(.standardUserCache, in: results[.ultraConservative]), "L1 missing third-party cache")
    try require(hasRule(.sandboxCache, in: results[.ultraConservative]), "L1 missing sandbox cache")
    try require(
      !(results[.ultraConservative]?.candidates.contains {
        $0.path.contains("com.apple.mediaanalysisd")
      } ?? true),
      "L1 included Apple cache")
    try require(hasRule(.groupContainerCache, in: results[.conservative]), "L2 missing group cache")
    try require(hasRule(.clipboardArchive, in: results[.conservative]), "L2 missing clipboard")
    try require(
      hasRule(.applicationRenderCache, in: results[.conservative]), "L2 missing render cache")
    try require(
      results[.conservative]?.candidates.contains {
        $0.path.contains("Typeless/Partitions/session/Code Cache")
      } == true,
      "L2 missed partition render cache")
    try require(
      !hasRule(.applicationOfflineCache, in: results[.conservative]),
      "L2 included offline cache")
    try require(hasRule(.xcodeDerivedData, in: results[.balanced]), "L3 missing DerivedData")
    try require(hasRule(.packageCacheDirectory, in: results[.balanced]), "L3 missing package cache")
    try require(
      hasRule(.applicationOfflineCache, in: results[.aggressive]), "L4 missing offline cache")
    try require(
      results[.aggressive]?.candidates.contains {
        $0.path.contains("Google/Chrome/Default/Service Worker/CacheStorage")
      } == true,
      "L4 missed vendor/app/profile CacheStorage")
    try require(hasRule(.diagnosticReports, in: results[.aggressive]), "L4 missing diagnostics")
    try require(
      !hasRule(.mobileDeviceBackup, in: ultraAggressiveDefault),
      "L5 default unexpectedly enabled high-impact user data"
    )
    try require(
      !hasRule(.systemManagedReview, in: ultraAggressiveDefault),
      "L5 default unexpectedly enabled system-managed review"
    )
    try require(
      hasRule(.mobileDeviceBackup, in: results[.ultraAggressive]),
      "L5 explicit high-impact option missing backup"
    )
    try require(
      hasRule(.systemManagedReview, in: results[.ultraAggressive]),
      "L5 explicit review option missing review"
    )
    try require(
      custom.candidates.allSatisfy { $0.scope == .packageManagerCaches },
      "Custom scan escaped selected scopes")

    let allCandidates = results.values.flatMap(\.candidates) + custom.candidates
    let blockedCloudPaths = allCandidates.filter {
      $0.path.localizedCaseInsensitiveContains("CloudKit")
        || $0.path.localizedCaseInsensitiveContains("iCloud")
    }.count
    let allDefaultUnselected = allCandidates.allSatisfy { !$0.selected }
    let reviewOnlySelectableCount = allCandidates.filter {
      $0.action == .reviewOnly && $0.isSelectable
    }.count
    try require(blockedCloudPaths == 0, "Cloud/iCloud path entered catalogue")
    try require(allDefaultUnselected, "A candidate was selected by default")
    try require(reviewOnlySelectableCount == 0, "Review-only candidate became selectable")
    try require(
      !allCandidates.contains { $0.path.contains("Symlink") }, "Symlink entered catalogue")

    let levelCounts = Dictionary(
      uniqueKeysWithValues: results.map {
        ($0.key.rawValue, $0.value.candidates.count)
      })
    let levelBytes = Dictionary(
      uniqueKeysWithValues: results.map {
        ($0.key.rawValue, $0.value.totalBytes)
      })
    let result = CleanupPolicyAuditResult(
      levelCounts: levelCounts,
      levelBytes: levelBytes,
      customCount: custom.candidates.count,
      blockedCloudPaths: blockedCloudPaths,
      allDefaultUnselected: allDefaultUnselected,
      reviewOnlySelectableCount: reviewOnlySelectableCount,
      passed: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(result).write(to: outputURL, options: .atomic)
    print(String(decoding: try Data(contentsOf: outputURL), as: UTF8.self))
  }

  private static func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  private static func allocate(_ root: URL, _ relative: String, mebibytes: Int) throws {
    let directory = root.appendingPathComponent(relative, isDirectory: true)
    try makeDirectory(directory)
    let file = directory.appendingPathComponent("fixture.bin")
    let chunk = Data(repeating: 0x5A, count: 1_048_576)
    _ = FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    for _ in 0..<mebibytes { try handle.write(contentsOf: chunk) }
  }

  private static func hasRule(_ rule: CleanupRuleID, in result: CleanupScanResult?) -> Bool {
    result?.candidates.contains { $0.ruleID == rule } ?? false
  }

  private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
      throw NSError(
        domain: "CleanupPolicyAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
  }
}
