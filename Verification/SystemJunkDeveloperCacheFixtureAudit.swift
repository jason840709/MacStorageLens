import Foundation

@main
struct SystemJunkDeveloperCacheFixtureAudit {
  private static var checks = 0

  static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    guard condition() else {
      fputs("FAIL: \(label)\n", stderr)
      exit(1)
    }
  }

  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
      "MacStorageLens-DeveloperCache-\(UUID().uuidString)",
      isDirectory: true
    )
    let home = root.appendingPathComponent("Home", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    func write(_ relative: String, bytes: Int = 4096) throws -> URL {
      let url = home.appendingPathComponent(relative)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 0x41, count: bytes).write(to: url)
      return url
    }

    // Broad user-cache exclusions verified from MacSai's UserCacheCategory.
    let spotify = try write("Library/Caches/com.spotify.client/cache.bin")
    let gradleBroad = try write("Library/Caches/org.gradle/cache.bin")
    let ordinary = try write("Library/Caches/com.example.cache/cache.bin")

    // Exact IDE/AI cache allowlist.
    let cursorCache = try write("Library/Application Support/Cursor/Cache/cache.bin")
    let cursorCachedData = try write("Library/Application Support/Cursor/CachedData/cache.bin")
    let cursorUser = try write("Library/Application Support/Cursor/User/settings.json")
    let antigravityCache = try write("Library/Application Support/Antigravity/GPUCache/cache.bin")
    let antigravityUser = try write("Library/Application Support/Antigravity/User/settings.json")
    let claudeCache = try write(".claude/cache/cache.bin")
    let claudeProject = try write(".claude/projects/project.json")
    let codexCache = try write(".codex/cache/cache.bin")
    let codexSession = try write(".codex/sessions/session.json")

    // Source-reviewed package-manager expansion.
    _ = try write(".cargo/registry/src/index.crates.io-123/pkg/src.rs")
    let gradleDaemon = try write(".gradle/daemon/8.0/daemon.log")
    let gradleWrapper = try write(".gradle/wrapper/dists/gradle-8.0/bin.zip")
    let nonAllowlistedCargo = try write(".cargo/registry/index/index.bin")

    // Xcode Previews is an explicit cache target, not a recursive UserData wipe.
    let xcodePreview = try write("Library/Developer/Xcode/UserData/Previews/preview.bin")
    let xcodeUserDataOther = try write(
      "Library/Developer/Xcode/UserData/KeyBindings/custom.idekeybindings")

    let library = try ReportLibrary(
      rootURL: root.appendingPathComponent("Reports"), fileManager: fm)
    let engine = CleanupEngine(library: library, fileManager: fm, homeURL: home)
    let configuration = CleanupScanConfiguration(
      profile: .custom,
      customScopes: [.standardCaches, .developerCaches, .packageManagerCaches],
      customMinimumBytes: 0
    )
    let result = try engine.scanCandidates(configuration: configuration)
    let paths = Set(result.candidates.map(\.path))

    expect(
      !paths.contains(spotify.deletingLastPathComponent().path), "Spotify broad cache is excluded")
    expect(
      !paths.contains(gradleBroad.deletingLastPathComponent().path),
      "org.gradle broad cache is excluded")
    expect(
      paths.contains(ordinary.deletingLastPathComponent().path),
      "ordinary standard cache remains eligible")

    expect(paths.contains(cursorCache.deletingLastPathComponent().path), "Cursor Cache is found")
    expect(
      paths.contains(cursorCachedData.deletingLastPathComponent().path),
      "Cursor CachedData is found")
    expect(
      !paths.contains(cursorUser.deletingLastPathComponent().path),
      "Cursor User data is never targeted")
    expect(
      paths.contains(antigravityCache.deletingLastPathComponent().path),
      "Antigravity GPUCache is found")
    expect(
      !paths.contains(antigravityUser.deletingLastPathComponent().path),
      "Antigravity User data is never targeted")
    expect(paths.contains(claudeCache.deletingLastPathComponent().path), "Claude cache is found")
    expect(
      !paths.contains(claudeProject.deletingLastPathComponent().path),
      "Claude projects are never targeted")
    expect(paths.contains(codexCache.deletingLastPathComponent().path), "Codex cache is found")
    expect(
      !paths.contains(codexSession.deletingLastPathComponent().path),
      "Codex sessions are never targeted")

    expect(
      paths.contains(home.appendingPathComponent(".cargo/registry/src").path),
      "Cargo registry src is found"
    )
    expect(
      paths.contains(home.appendingPathComponent(".gradle/daemon").path),
      "Gradle daemon cache is found")
    expect(
      paths.contains(home.appendingPathComponent(".gradle/wrapper/dists").path),
      "Gradle wrapper dists are found")
    expect(
      !paths.contains(nonAllowlistedCargo.deletingLastPathComponent().path),
      "Cargo registry index is not inferred as cache")

    expect(
      paths.contains(home.appendingPathComponent("Library/Developer/Xcode/UserData/Previews").path),
      "Xcode Previews is found")
    expect(
      !paths.contains(xcodeUserDataOther.deletingLastPathComponent().path),
      "other Xcode UserData is not targeted")

    // Execute one exact AI cache candidate and verify adjacent user data survives.
    guard
      var claudeCandidate = result.candidates.first(where: {
        $0.path == claudeCache.deletingLastPathComponent().path
      })
    else {
      fputs("FAIL: Claude cache candidate missing\n", stderr)
      exit(1)
    }
    claudeCandidate.selected = true
    let (claudeLog, _) = try engine.executeSelected(
      [claudeCandidate], profile: .balanced, removalMode: .forceDelete)
    expect(claudeLog.entries.first?.failures.isEmpty == true, "exact Claude cache cleanup succeeds")
    expect(!fm.fileExists(atPath: claudeCache.path), "Claude cache contents are removed")
    expect(fm.fileExists(atPath: claudeProject.path), "Claude project data survives cleanup")

    // A forged/stale candidate outside the exact allowlist must still be rejected
    // immediately before deletion.
    var forgedCursorUser = CleanupCandidate(
      ruleID: .developerToolCacheDirectory,
      scope: .developerCaches,
      tier: .balanced,
      category: .developerCache,
      action: .moveContentsToTrash,
      path: cursorUser.deletingLastPathComponent().path,
      displayName: "forged Cursor User",
      bytes: 1,
      risk: .low,
      reason: "fixture",
      impact: "fixture",
      recovery: "fixture",
      selected: true
    )
    forgedCursorUser.selected = true
    let (forgedLog, _) = try engine.executeSelected(
      [forgedCursorUser], profile: .balanced, removalMode: .forceDelete)
    expect(
      forgedLog.entries.first?.failures.isEmpty == false, "forged Cursor User candidate is rejected"
    )
    expect(fm.fileExists(atPath: cursorUser.path), "Cursor settings survive forged candidate")

    var forgedCargoIndex = CleanupCandidate(
      ruleID: .packageCacheDirectory,
      scope: .packageManagerCaches,
      tier: .balanced,
      category: .packageManagerCache,
      action: .moveContentsToTrash,
      path: nonAllowlistedCargo.deletingLastPathComponent().path,
      displayName: "forged Cargo index",
      bytes: 1,
      risk: .low,
      reason: "fixture",
      impact: "fixture",
      recovery: "fixture",
      selected: true
    )
    forgedCargoIndex.selected = true
    let (cargoLog, _) = try engine.executeSelected(
      [forgedCargoIndex], profile: .balanced, removalMode: .forceDelete)
    expect(
      cargoLog.entries.first?.failures.isEmpty == false, "non-allowlisted Cargo path is rejected")
    expect(fm.fileExists(atPath: nonAllowlistedCargo.path), "Cargo index survives forged candidate")

    // Keep references alive and make fixture intent explicit.
    _ = gradleDaemon
    _ = gradleWrapper
    _ = xcodePreview

    print("SystemJunkDeveloperCacheFixtureAudit: \(checks) / \(checks) passed")
  }
}
