import CryptoKit
import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Boundary checks use an injected home and a fixture-only recycle callback.
/// They never enumerate the real home, call Finder recycle, or run package tools.
@main
struct CleanupWorkbenchBoundaryAudit {
  struct Check: Codable {
    let name: String
    let passed: Bool
    let detail: String
  }

  struct Receipt: Codable {
    let createdAt: Date
    let fixtureRoot: String
    let passed: Int
    let failed: Int
    let checks: [Check]
    let sourceHashes: [String: String]
  }

  struct Fixture {
    let root: URL
    let home: URL
    let trash: URL
    let fm = FileManager.default

    init(_ root: URL) throws {
      self.root = root
      home = root.appendingPathComponent("Home")
      trash = root.appendingPathComponent("FixtureTrash")
      try fm.createDirectory(at: home, withIntermediateDirectories: true)
      try fm.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    func engine(active: Set<String> = []) -> CleanupWorkbenchEngine {
      CleanupWorkbenchEngine(homeURL: home, activeIdentifiers: active)
    }

    @discardableResult
    func put(_ path: String, data: Data = Data(repeating: 0x61, count: 8192), days: Int? = nil)
      throws -> URL
    {
      let url = home.appendingPathComponent(path)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
      if let days {
        try fm.setAttributes(
          [.modificationDate: Date().addingTimeInterval(-Double(days) * 86_400)],
          ofItemAtPath: url.path)
      }
      return url
    }

    @discardableResult
    func app(_ name: String, id: String, displayName: String? = nil) throws -> URL {
      let path = "Applications/" + name + ".app"
      try put(
        path + "/Contents/Info.plist",
        data: PropertyListSerialization.data(
          fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": displayName ?? name],
          format: .xml, options: 0))
      return home.appendingPathComponent(path)
    }

    func recycle(_ source: URL) throws -> FinderVisibleTrashReceipt {
      guard CleanupWorkbenchFileSafety.isWithin(source.path, root: home.path),
        source.path != home.path
      else { throw AuditError.missing("recycle callback received a non-fixture path") }
      let destination = trash.appendingPathComponent(
        UUID().uuidString + "-" + source.lastPathComponent)
      try fm.moveItem(at: source, to: destination)
      return FinderVisibleTrashReceipt(
        originalPath: source.path, destinationPath: destination.path,
        visibleName: destination.lastPathComponent, finderVisibilityVerified: true,
        sourcePathRecreated: false, removalMethod: "boundary-fixture-only")
    }
  }

  enum AuditError: LocalizedError {
    case missing(String)
    var errorDescription: String? {
      switch self {
      case .missing(let message): return message
      }
    }
  }

  static var checks: [Check] = []

  static func expect(_ passed: Bool, _ name: String, _ detail: String = "") {
    checks.append(Check(name: name, passed: passed, detail: detail))
    print("\(passed ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": " + detail)")
  }

  static func scenario(_ name: String, _ body: () throws -> Void) {
    do { try body() } catch { expect(false, name + " completed", error.localizedDescription) }
  }

  static func required<T>(_ value: T?, _ name: String) throws -> T {
    guard let value else { throw AuditError.missing("Missing fixture candidate: " + name) }
    return value
  }

  static func literalProtection(_ root: URL) throws {
    let fixture = try Fixture(root)
    let names = ["中文研究", "literal*cache", "literal$HOME", "literal[ab]?cache", "literal\\cache"]
    let paths = try names.map { name -> String in
      let file = try fixture.put("Documents/" + name + "/keep.txt")
      return file.deletingLastPathComponent().path
    }
    let store = CleanupUserProtectionStore(home: fixture.home)
    for path in paths { try store.add(path) }
    expect(
      Set(try store.load()) == Set(paths),
      "own protection preserves literal Unicode/glob/dollar paths")
    let policy = CleanupProtectionPolicy(home: fixture.home, activeBundleIDs: [])
    for path in paths {
      expect(
        policy.reason(for: path + "/keep.txt")?.contains("你已選擇") == true,
        "literal protection applies to " + URL(fileURLWithPath: path).lastPathComponent)
    }
    for name in ["literalZZcache", "literalacache", "literalHOME", "未保留"] {
      expect(
        policy.reason(
          for: fixture.home.appendingPathComponent("Documents/" + name + "/keep.txt").path)
          == nil, "literal protection does not expand to " + name)
    }
    try store.remove(paths[1])
    let refreshed = CleanupProtectionPolicy(home: fixture.home, activeBundleIDs: [])
    expect(
      refreshed.reason(for: paths[1] + "/keep.txt") == nil,
      "removing a literal entry removes its protection")
    expect(
      try store.load().count == paths.count - 1,
      "removing one protection preserves the other entries")
  }

  static func corruptProtection(_ root: URL) throws {
    let variants: [(String, Data?)] = [
      ("truncated-json", Data("{".utf8)),
      ("unknown-version", Data("{\"version\":2,\"paths\":[]}".utf8)),
      ("relative-path", Data("{\"version\":1,\"paths\":[\"relative/path\"]}".utf8)),
      ("oversized", Data(repeating: 0x20, count: 1024 * 1024 + 1)),
      ("directory", nil), ("symlink", nil),
    ]
    for (name, data) in variants {
      let fixture = try Fixture(root.appendingPathComponent(name))
      try fixture.app("Discord", id: "com.hnc.Discord")
      let old = try fixture.put("Library/Application Support/discord/Code Cache/old.bin", days: 3)
      let engine = fixture.engine()
      let previous = try engine.scanSmart()
      expect(
        previous.items.contains { $0.decision == .automatic }, name + " has eligible baseline cache"
      )
      let store = CleanupUserProtectionStore(home: fixture.home)
      try fixture.fm.createDirectory(
        at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if let data {
        try data.write(to: store.url)
      } else if name == "directory" {
        try fixture.fm.createDirectory(at: store.url, withIntermediateDirectories: false)
      } else {
        let target = fixture.root.appendingPathComponent("external-config.json")
        try Data("{\"version\":1,\"paths\":[]}".utf8).write(to: target)
        try fixture.fm.createSymbolicLink(at: store.url, withDestinationURL: target)
      }
      var rejected = false
      do { _ = try store.load() } catch { rejected = true }
      expect(rejected, name + " is rejected by protection store")
      let policy = CleanupProtectionPolicy(home: fixture.home, activeBundleIDs: [])
      expect(
        policy.reason(for: fixture.home.appendingPathComponent("Downloads/unrelated.bin").path)
          != nil,
        name + " fails closed for otherwise unprotected paths")
      expect(
        policy.notices.contains { $0.contains("保留清單") && $0.contains("暫停") },
        name + " explains suspended cleanup")
      let outcome = try engine.executeAutomatic(previous)
      expect(
        outcome.removedFiles == 0 && fixture.fm.fileExists(atPath: old.path)
          && outcome.entries.contains { !$0.failures.isEmpty },
        name + " blocks a previously approved automatic plan")
    }
  }

  static func applicationOrder(_ root: URL) throws {
    let fixture = try Fixture(root)
    let id = "com.boundary.Order"
    let app = try fixture.app(String(repeating: "LongApplicationName", count: 7), id: id)
    let data = try fixture.put("Library/Preferences/" + id + ".plist")
    let engine = fixture.engine()
    let scan = try engine.scanApplications()
    let bundle = try required(scan.items.first { $0.path == app.path }, "long-name application")
    let associated = try required(scan.items.first { $0.path == data.path }, "preferences")
    var moved: [String] = []
    let outcome = try engine.executeManual(
      [associated, bundle],
      recycle: { url in
        moved.append(url.path)
        return try fixture.recycle(url)
      })
    expect(moved == [app.path, data.path], "same-plan bundle moves before shorter-path data")
    expect(
      outcome.removedFiles == 2 && outcome.entries.allSatisfy { $0.failures.isEmpty },
      "same-plan data remains executable after its only application was moved")
    expect(
      !fixture.fm.fileExists(atPath: app.path) && !fixture.fm.fileExists(atPath: data.path),
      "same-plan fixture receipt corresponds to both actual moves")
  }

  static func failedApplication(_ root: URL) throws {
    let fixture = try Fixture(root)
    let id = "com.boundary.Failed"
    let app = try fixture.app("Failed", id: id)
    let data = try fixture.put("Library/Preferences/" + id + ".plist")
    let engine = fixture.engine()
    let scan = try engine.scanApplications()
    let selected = scan.items.filter { $0.path == app.path || $0.path == data.path }
    expect(selected.count == 2, "failed-bundle scenario has both review candidates")
    let outcome = try engine.executeManual(
      selected,
      recycle: { url in
        if url.path == app.path { throw AuditError.missing("simulated app move failure") }
        return try fixture.recycle(url)
      })
    expect(fixture.fm.fileExists(atPath: app.path), "failed bundle remains installed")
    expect(
      fixture.fm.fileExists(atPath: data.path) && outcome.removedFiles == 0,
      "failed bundle preserves its selected same-plan data",
      "removed=\(outcome.removedFiles); failures=\(outcome.entries.flatMap(\.failures))")
  }

  static func sharedApplication(_ root: URL) throws {
    let fixture = try Fixture(root)
    let id = "com.boundary.Shared"
    let app = try fixture.app("Shared", id: id)
    let data = try fixture.put("Library/Preferences/" + id + ".plist")
    let engine = fixture.engine()
    let earlier = try engine.scanApplications()
    let selected = earlier.items.filter { $0.path == app.path || $0.path == data.path }
    let other = try fixture.app("OtherCopy", id: id)
    let refreshed = try engine.scanApplications()
    expect(
      refreshed.items.contains { $0.path == data.path && $0.decision == .protected },
      "same-ID second installation protects shared data at discovery")
    var moved: [String] = []
    let outcome = try engine.executeManual(
      selected,
      recycle: { url in
        moved.append(url.path)
        return try fixture.recycle(url)
      })
    expect(
      moved == [app.path] && outcome.removedFiles == 1,
      "late second installation prevents shared-data recycle")
    expect(
      fixture.fm.fileExists(atPath: data.path) && fixture.fm.fileExists(atPath: other.path),
      "retained application still has its shared preferences")
  }

  static func sharedKnownFolder(_ root: URL) throws {
    let fixture = try Fixture(root)
    let legacyID = "com.lmstudio.LMStudio"
    let currentID = "ai.elementlabs.lmstudio"
    try fixture.app("Legacy", id: legacyID, displayName: "A Legacy")
    try fixture.app("Current", id: currentID, displayName: "Z Current")
    try fixture.put("Library/Application Support/LM Studio/settings.json")
    let cache = try fixture.put("Library/Application Support/LM Studio/Code Cache/old.bin", days: 3)
    let support = cache.deletingLastPathComponent().deletingLastPathComponent().path
    let engine = fixture.engine(active: [currentID])
    let apps = try engine.scanApplications()
    let related = apps.items.filter { $0.rule == "application-data" && $0.path == support }
    expect(
      !related.isEmpty && related.allSatisfy { $0.decision == .protected },
      "different known IDs sharing a Support folder protect the running owner's data",
      related.map { "\($0.applicationID ?? "nil")=\($0.decision.rawValue)" }.joined(separator: ", ")
    )
    let smart = try engine.scanSmart()
    let cacheItems = smart.items.filter { $0.path == cache.deletingLastPathComponent().path }
    expect(
      !cacheItems.contains { $0.decision == .automatic },
      "different known IDs sharing a cache do not bypass the running owner",
      cacheItems.map { "\($0.applicationID ?? "nil")=\($0.decision.rawValue)" }.joined(
        separator: ", "))
    expect(fixture.fm.fileExists(atPath: cache.path), "shared-folder checks are read only")
  }

  static func unknownCacheOwnership(_ root: URL) throws {
    let fixture = try Fixture(root)
    let id = "com.boundary.UnknownArchive"
    try fixture.app("Unknown Archive", id: id)
    let offline = try fixture.put(
      "Library/Application Support/" + id + "/Cache/offline-only.pdf", days: 3)
    let scan = try fixture.engine().scanSmart()
    let candidates = scan.items.filter { $0.path == offline.deletingLastPathComponent().path }
    expect(
      !candidates.contains { $0.decision == .automatic },
      "unknown application's exact-ID Support Cache is not proof of rebuildable data",
      candidates.map { "\($0.applicationID ?? "nil")=\($0.decision.rawValue)" }.joined(
        separator: ", "))
    expect(fixture.fm.fileExists(atPath: offline.path), "unknown-cache check is read only")
  }

  static func supportParentSymlink(_ root: URL) throws {
    let fixture = try Fixture(root)
    try fixture.app("Discord", id: "com.hnc.Discord")
    let privateFile = try fixture.put("Documents/PrivateNotes/Cache/unique.pdf", days: 3)
    let privateFolder = privateFile.deletingLastPathComponent().deletingLastPathComponent()
    let supportAlias = fixture.home.appendingPathComponent("Library/Application Support/discord")
    try fixture.fm.createDirectory(
      at: supportAlias.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fixture.fm.createSymbolicLink(at: supportAlias, withDestinationURL: privateFolder)
    let scan = try fixture.engine().scanSmart()
    expect(
      !scan.items.contains { item in
        item.decision == .automatic
          && (CleanupWorkbenchFileSafety.isWithin(item.path, root: privateFolder.path)
            || item.files.contains { $0.path == privateFile.path })
      },
      "known app's symlinked Support parent cannot authorize private Cache content")
    expect(
      fixture.fm.fileExists(atPath: privateFile.path),
      "Support-parent symlink check preserves unique PDF")
  }

  static func diagnosticsParentSymlink(_ root: URL) throws {
    let fixture = try Fixture(root)
    let privateFile = try fixture.put(
      "Documents/PersonalReports/DiagnosticReports/unique.ips", days: 40)
    let privateFolder = privateFile.deletingLastPathComponent().deletingLastPathComponent()
    let logsAlias = fixture.home.appendingPathComponent("Library/Logs")
    try fixture.fm.createDirectory(
      at: logsAlias.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fixture.fm.createSymbolicLink(at: logsAlias, withDestinationURL: privateFolder)
    let scan = try fixture.engine().scanSmart()
    expect(
      !scan.items.contains { item in
        item.decision == .automatic
          && (item.path == privateFile.path || item.files.contains { $0.path == privateFile.path })
      },
      "symlinked Logs parent cannot authorize a private old diagnostic file")
    expect(
      fixture.fm.fileExists(atPath: privateFile.path),
      "Logs-parent symlink check preserves unique IPS")
  }

  static func historyPersistence(_ root: URL, automatic: Bool) throws {
    let fixture = try Fixture(root)
    let label = automatic ? "automatic" : "manual"
    let blockedHistory = fixture.root.appendingPathComponent("history-is-a-file")
    let sentinel = Data("history sentinel must remain a regular file".utf8)
    try sentinel.write(to: blockedHistory)
    let target: URL
    if automatic {
      try fixture.app("Discord", id: "com.hnc.Discord")
      target = try fixture.put("Library/Application Support/discord/Code Cache/old.bin", days: 3)
    } else {
      target = try fixture.put("Downloads/old.dmg", days: 10)
    }
    let engine = CleanupWorkbenchEngine(
      homeURL: fixture.home, activeIdentifiers: [], historyURL: blockedHistory)
    let scan =
      automatic
      ? try engine.scanSmart()
      : try engine.scanFiles(tool: .installers, root: target.deletingLastPathComponent())
    let outcome: CleanupWorkbenchExecution
    do {
      outcome =
        automatic
        ? try engine.executeAutomatic(scan)
        : try engine.executeManual(scan.items, recycle: fixture.recycle)
    } catch {
      expect(
        false, label + " cleanup returns its actual result after history persistence fails",
        error.localizedDescription)
      expect(
        !fixture.fm.fileExists(atPath: target.path),
        label + " fixture operation happened before the lost-result error")
      return
    }
    expect(true, label + " cleanup returns its actual result after history persistence fails")
    expect(
      outcome.removedFiles == 1 && !fixture.fm.fileExists(atPath: target.path),
      label + " history failure preserves the actual successful operation count")
    expect(
      outcome.persistenceWarning?.isEmpty == false,
      label + " history failure is exposed as a nonempty persistenceWarning")
    expect(
      outcome.entries.count == 1 && outcome.entries[0].removedFiles == 1
        && outcome.entries[0].failures.isEmpty,
      label + " history failure does not replace a successful entry with an operation failure")
    if !automatic {
      let receipts = outcome.entries.flatMap(\.receipts)
      expect(
        receipts.count == 1
          && fixture.fm.fileExists(atPath: receipts[0].destinationPath),
        "manual history failure preserves the actual fixture recycle receipt")
    }
    expect(
      try Data(contentsOf: blockedHistory) == sentinel,
      label + " history failure does not overwrite the blocking ordinary file")
  }

  static func builtinCacheAgeAndScope(_ root: URL) throws {
    let fixture = try Fixture(root)
    let cachePaths = [
      ".npm/_cacache/content-v2/sha512/fixture",
      ".cache/pip/http-v2/fixture",
      "Library/Caches/pip/http-v2/fixture",
      ".cache/pip/wheels/fixture",
      "Library/Caches/pip/wheels/fixture",
    ]
    var oldFiles: [URL] = []
    var recentFiles: [URL] = []
    for path in cachePaths {
      oldFiles.append(try fixture.put(path + "/old.bin", days: 31))
      recentFiles.append(try fixture.put(path + "/new.bin", days: 29))
    }
    let protectedFiles = try [
      ".npm/_npx/fixture/node_modules/cli/index.js",
      ".cache/pip/venv/lib/python3.12/site-packages/keep.bin",
      "Projects/.venv/lib/python3.12/site-packages/keep.bin",
      "venv/lib/python3.12/site-packages/keep.bin",
    ].map { try fixture.put($0, days: 90) }
    let engine = fixture.engine()
    let scan = try engine.scanSmart()
    let planned = Set(scan.items.filter { $0.decision == .automatic }.flatMap(\.files).map(\.path))
    expect(
      planned == Set(oldFiles.map(\.path)),
      "builtin npm/pip recipes select only files older than thirty days",
      "planned=\(planned.count); expected=\(oldFiles.count)")
    expect(
      recentFiles.allSatisfy { !planned.contains($0.path) },
      "twenty-nine-day npm/pip downloads remain outside the frozen deletion plan")
    expect(
      protectedFiles.allSatisfy { !planned.contains($0.path) },
      "npm _npx and virtual environments remain outside builtin cache scope")
    let outcome = try engine.executeAutomatic(scan)
    expect(
      outcome.removedFiles == oldFiles.count
        && oldFiles.allSatisfy { !fixture.fm.fileExists(atPath: $0.path) },
      "builtin cleanup actually removes the five approved fixture downloads")
    expect(
      recentFiles.allSatisfy { fixture.fm.fileExists(atPath: $0.path) },
      "builtin cleanup retains newer npm/pip downloads")
    expect(
      protectedFiles.allSatisfy { fixture.fm.fileExists(atPath: $0.path) },
      "builtin cleanup retains _npx and every fixture virtual environment")
  }

  static func projectExecution(_ root: URL) throws {
    let fixture = try Fixture(root)
    let manifestData = Data("{\"name\":\"boundary-project\",\"version\":\"1.0.0\"}".utf8)
    let lockData = Data(
      "{\"name\":\"boundary-project\",\"lockfileVersion\":3,\"packages\":{}}".utf8)
    let moduleData = Data("module.exports = 'fixture dependency';\n".utf8)
    func project(_ name: String) throws -> (root: URL, manifest: URL, lock: URL, modules: URL) {
      let relative = "Projects/" + name
      let manifest = try fixture.put(relative + "/package.json", data: manifestData)
      let lock = try fixture.put(relative + "/package-lock.json", data: lockData)
      try fixture.put(relative + "/node_modules/pkg/index.js", data: moduleData)
      return (
        fixture.home.appendingPathComponent(relative), manifest, lock,
        fixture.home.appendingPathComponent(relative + "/node_modules")
      )
    }
    let idle = try project("Idle")
    let engine = fixture.engine()
    let idleScan = try engine.scanFiles(tool: .projects, root: idle.root)
    let idleCandidate = try required(
      idleScan.items.first { $0.path == idle.modules.path }, "idle project dependencies")
    expect(
      idleCandidate.rule == "project-artifact" && idleCandidate.decision == .review,
      "lockfile-backed idle project offers its dependencies for manual review")
    let idleOutcome = try engine.executeManual([idleCandidate], recycle: fixture.recycle)
    expect(
      idleOutcome.removedFiles == 1 && idleOutcome.entries.count == 1
        && idleOutcome.entries[0].failures.isEmpty,
      "idle project execution reports one successful directory move")
    expect(
      (try? Data(contentsOf: idle.manifest)) == manifestData
        && (try? Data(contentsOf: idle.lock)) == lockData,
      "project execution preserves the original package manifest and lockfile")
    let idleReceipts = idleOutcome.entries.flatMap(\.receipts)
    expect(
      idleReceipts.count == 1 && idleReceipts.first?.originalPath == idle.modules.path
        && idleReceipts.first?.removalMethod == "boundary-fixture-only",
      "project execution records the actual fixture recycle receipt")
    let movedModule = idleReceipts.first.flatMap { receipt in
      try? Data(
        contentsOf: URL(fileURLWithPath: receipt.destinationPath).appendingPathComponent(
          "pkg/index.js"))
    }
    expect(
      !fixture.fm.fileExists(atPath: idle.modules.path) && movedModule == moduleData,
      "project dependencies really move to the receipt destination")

    let busy = try project("Busy")
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["120"]
    child.currentDirectoryURL = busy.root
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try child.run()
    defer {
      if child.isRunning { child.terminate() }
      child.waitUntilExit()
    }
    expect(child.isRunning, "second project has this fixture's live sleep child")
    let busyScan = try engine.scanFiles(tool: .projects, root: busy.root)
    let busyCandidate = try required(
      busyScan.items.first { $0.path == busy.modules.path }, "busy project dependencies")
    expect(
      busyCandidate.rule == "project-artifact" && busyCandidate.decision == .review,
      "busy project can be previewed before execution rechecks its cwd usage")
    var recycleCalls = 0
    let busyOutcome = try engine.executeManual(
      [busyCandidate],
      recycle: { url in
        recycleCalls += 1
        return try fixture.recycle(url)
      })
    expect(
      busyOutcome.removedFiles == 0 && recycleCalls == 0 && busyOutcome.entries.count == 1
        && busyOutcome.entries.allSatisfy { $0.receipts.isEmpty },
      "live project cwd rejects execution before the recycle callback")
    expect(
      fixture.fm.fileExists(atPath: busy.modules.path)
        && (try? Data(contentsOf: busy.modules.appendingPathComponent("pkg/index.js")))
          == moduleData
        && (try? Data(contentsOf: busy.manifest)) == manifestData
        && (try? Data(contentsOf: busy.lock)) == lockData,
      "busy project retains its dependencies, manifest, and lockfile")
    expect(
      busyOutcome.entries.flatMap(\.failures).contains { $0.contains("有程式正在這個專案內工作") },
      "busy refusal identifies actual project cwd usage rather than a generic lsof failure")
  }

  static func processCancellation(_ root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sibling = Process()
    sibling.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sibling.arguments = ["30"]
    sibling.standardOutput = FileHandle.nullDevice
    sibling.standardError = FileHandle.nullDevice
    try sibling.run()
    defer {
      if sibling.isRunning { sibling.terminate() }
      sibling.waitUntilExit()
    }
    let marker = root.appendingPathComponent("owned-child.pid")
    var cancelled = false
    let began = Date()
    do {
      _ = try ProcessRunner.run(
        "/bin/sh", ["-c", "echo $$ > \"$1\"; exec /bin/sleep 30", "boundary-fixture", marker.path],
        timeout: 5,
        cancellationCheck: { FileManager.default.fileExists(atPath: marker.path) })
    } catch ProcessRunnerError.cancelled { cancelled = true }
    expect(cancelled, "ProcessRunner reports cancellation")
    expect(
      Date().timeIntervalSince(began) < 15,
      "ProcessRunner cancellation completes within its bounded stop waits")
    let text = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let ownedPID = try required(Int32(text), "owned child PID")
    errno = 0
    let ownExited = kill(ownedPID, 0) != 0 && errno == ESRCH
    expect(ownedPID > 1 && ownExited, "cancelled invocation's exact child has exited")
    expect(sibling.isRunning, "same-name sibling child survives cancellation")
  }

  static func unreadableDirectories(_ root: URL) throws {
    let fixture = try Fixture(root)
    _ = try fixture.app("Discord", id: "com.hnc.Discord")
    _ = try fixture.put("Library/Application Support/discord/Code Cache/old.bin", days: 3)
    _ = try fixture.put("Library/Logs/DiagnosticReports/old.ips", days: 40)
    let cache = fixture.home.appendingPathComponent(
      "Library/Application Support/discord/Code Cache")
    let diagnostics = fixture.home.appendingPathComponent("Library/Logs/DiagnosticReports")
    let caseAlias = fixture.home.appendingPathComponent(
      "Library/Application Support/DISCORD/Code Cache")
    if fixture.fm.fileExists(atPath: caseAlias.path) {
      expect(
        CleanupWorkbenchFileSafety.isUnredirectedHomeDirectory(caseAlias, home: fixture.home),
        "valid APFS case aliases remain unredirected")
    }
    guard getuid() != 0 else { return }
    try fixture.fm.setAttributes([.posixPermissions: 0], ofItemAtPath: cache.path)
    try fixture.fm.setAttributes([.posixPermissions: 0], ofItemAtPath: diagnostics.path)
    defer {
      try? fixture.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path)
      try? fixture.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: diagnostics.path)
    }
    let result = try fixture.engine().scanSmart()
    for location in [cache, diagnostics] {
      let item = result.items.first { $0.path == location.path }
      expect(
        item?.decision == .unavailable,
        "unreadable normal directory is reported unavailable: " + location.lastPathComponent)
      expect(
        item?.reason.contains("連結") == false,
        "permission errors are not reported as symlinks: " + location.lastPathComponent)
    }
  }

  static func main() throws {
    let root = URL(fileURLWithPath: "/private/tmp/LensBoundary-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    scenario("literal protection") { try literalProtection(root.appendingPathComponent("literal")) }
    scenario("corrupt protection") { try corruptProtection(root.appendingPathComponent("corrupt")) }
    scenario("application order") { try applicationOrder(root.appendingPathComponent("app-order")) }
    scenario("failed application") {
      try failedApplication(root.appendingPathComponent("failed-app"))
    }
    scenario("shared application") {
      try sharedApplication(root.appendingPathComponent("shared-app"))
    }
    scenario("shared known folder") {
      try sharedKnownFolder(root.appendingPathComponent("shared-known"))
    }
    scenario("unknown cache ownership") {
      try unknownCacheOwnership(root.appendingPathComponent("unknown-cache"))
    }
    scenario("Support parent symlink") {
      try supportParentSymlink(root.appendingPathComponent("support-symlink"))
    }
    scenario("diagnostics parent symlink") {
      try diagnosticsParentSymlink(root.appendingPathComponent("logs-symlink"))
    }
    scenario("automatic history persistence") {
      try historyPersistence(root.appendingPathComponent("automatic-history"), automatic: true)
    }
    scenario("manual history persistence") {
      try historyPersistence(root.appendingPathComponent("manual-history"), automatic: false)
    }
    scenario("builtin cache age and scope") {
      try builtinCacheAgeAndScope(root.appendingPathComponent("builtin-caches"))
    }
    scenario("project artifact execution") {
      try projectExecution(root.appendingPathComponent("project-execution"))
    }
    scenario("permission and case semantics") {
      try unreadableDirectories(root.appendingPathComponent("permissions"))
    }
    scenario("process cancellation") {
      try processCancellation(root.appendingPathComponent("process"))
    }
    let passed = checks.filter(\.passed).count
    let failed = checks.count - passed
    var sourceHashes: [String: String] = [:]
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    for name in [
      "CleanupProtectionPolicy", "CleanupWorkbenchApplications", "CleanupWorkbenchExecution",
      "CleanupApplicationCatalog", "CleanupWorkbenchCoordinator", "CleanupWorkbenchFileSafety",
      "CleanupWorkbenchModels", "SmartCleanupEngine", "ProcessRunner", "CleanupWorkbenchFiles",
    ] {
      let path = "Sources/MacStorageLens/" + name + ".swift"
      if let data = try? Data(contentsOf: repository.appendingPathComponent(path)) {
        sourceHashes[path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      }
    }
    if let destination = ProcessInfo.processInfo.arguments.dropFirst().first {
      let receipt = Receipt(
        createdAt: Date(), fixtureRoot: root.path, passed: passed, failed: failed,
        checks: checks, sourceHashes: sourceHashes)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(receipt).write(to: URL(fileURLWithPath: destination), options: .atomic)
    }
    print("CleanupWorkbenchBoundaryAudit: \(passed) / \(checks.count) passed; \(failed) failed")
    if failed > 0 { exit(1) }
  }
}
