import Foundation

@main
struct CleanupWorkbenchFixtureAudit {
  static var count = 0
  static func expect(_ yes: Bool, _ message: String) {
    count += 1
    if !yes { fatalError(message) }
  }
  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("LensWorkbench-\(UUID().uuidString)")
    let home = root.appendingPathComponent("Home")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func put(
      _ relative: String, _ bytes: Data = Data(repeating: 9, count: 8192), age: TimeInterval? = nil
    ) throws -> URL {
      let url = home.appendingPathComponent(relative)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try bytes.write(to: url)
      if let age {
        try fm.setAttributes(
          [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
      }
      return url
    }
    func app(_ relative: String, _ id: String, _ name: String) throws {
      _ = try put(
        relative + "/Contents/Info.plist",
        PropertyListSerialization.data(
          fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": name], format: .xml,
          options: 0))
    }
    try app("Applications/Renamed.app", "com.hnc.Discord", "Notebook")
    let privateNotes = try put(
      "Library/Application Support/Notebook/Code Cache/onlycopy.txt", age: 200000)
    try app("Applications/Traversal.app", "com.example.Traversal", "../../Documents")
    let docs = try put("Documents/important.txt")
    try app("Applications/BadID.app", "../../Documents", "BadID")
    let engine = CleanupWorkbenchEngine(homeURL: home, activeIdentifiers: [])
    let smart = try engine.scanSmart()
    expect(
      !smart.items.contains { $0.path.contains("Notebook") && $0.decision == .automatic },
      "renamed app cannot claim unrelated Support data")
    let applications = try engine.scanApplications()
    expect(
      !applications.items.contains {
        $0.rule == "application-data" && $0.path.hasSuffix("/Documents")
      }, "bundle path traversal cannot select Documents")
    expect(
      !CleanupApplicationCatalog(home: home, activeIdentifiers: []).applications.contains {
        $0.identifier == "../../Documents"
      }, "invalid bundle IDs rejected")
    expect(
      fm.fileExists(atPath: privateNotes.path) && fm.fileExists(atPath: docs.path),
      "read-only discovery preserves personal content")
    try fm.removeItem(at: home.appendingPathComponent("Applications/BadID.app"))
    try app("Applications/Writer.app", "com.example.Writer", "Writer")
    try app("Applications/Suite.app", "com.example.Suite", "Suite")
    try app(
      "Applications/Suite.app/Contents/Applications/Writer.app", "com.example.Writer", "Writer")
    let writerData = try put("Library/Preferences/com.example.Writer.plist")
    let shared = try engine.scanApplications()
    expect(shared.complete, "embedded ownership tested with complete catalogue")
    expect(
      shared.items.contains {
        $0.path.hasSuffix("com.example.Writer.plist") && $0.decision == .protected
          && $0.reason.contains("其他程式內")
      }, "embedded same-ID copy protects shared app data")
    _ = writerData
    let manifest = Data("plugins {}".utf8)
    _ = try put("Projects/A/build.gradle", manifest)
    let handwritten = try put("Projects/A/build/handwritten/notes.tex")
    let projects = try engine.scanFiles(
      tool: .projects, root: home.appendingPathComponent("Projects"))
    expect(
      projects.items.contains { $0.path.hasSuffix("/A/build") && $0.decision == .protected },
      "nested handwritten source is protected")
    expect(fm.fileExists(atPath: handwritten.path), "project preview preserves source")
    _ = try put(
      "Projects/NoEmit/package.json", Data("{\"scripts\":{\"build\":\"tsc --noEmit\"}}".utf8))
    _ = try put("Projects/NoEmit/dist/contract.pdf")
    expect(
      ProjectArtifactPolicy.kind(at: home.appendingPathComponent("Projects/NoEmit/dist")) == nil,
      "noEmit is not evidence for dist")
    _ = try put("Projects/Real/package.json", Data("{\"scripts\":{\"build\":\"tsc\"}}".utf8))
    _ = try put(
      "Projects/Real/tsconfig.json", Data("{\"compilerOptions\":{\"outDir\":\"dist\"}}".utf8))
    _ = try put("Projects/Real/dist/index.js")
    expect(
      ProjectArtifactPolicy.kind(at: home.appendingPathComponent("Projects/Real/dist")) != nil,
      "explicit output configuration is supported")
    _ = try put("Projects/Node/package.json", Data("{}".utf8))
    _ = try put("Projects/Node/package-lock.json", Data("{}".utf8))
    _ = try put("Projects/Node/node_modules/pkg/index.js")
    _ = try put("Projects/Node/.venv/pyvenv.cfg")
    let projectScan = try engine.scanFiles(
      tool: .projects, root: home.appendingPathComponent("Projects"))
    expect(
      projectScan.items.contains { $0.path.hasSuffix("node_modules") && $0.decision == .review },
      "lockfile-backed dependencies offered for review")
    expect(
      !projectScan.items.contains { $0.path.contains(".venv") },
      "virtual environments never treated as project junk")
    let oldInstaller = try put("Downloads/Nested/old.dmg", age: 10 * 86400)
    _ = try put("Downloads/Nested/new.pkg", age: 100)
    let installers = try engine.scanFiles(
      tool: .installers, root: home.appendingPathComponent("Downloads"))
    expect(
      installers.items.count == 1 && installers.items[0].path.hasSuffix("old.dmg"),
      "recursive installers use age evidence")
    let trash = root.appendingPathComponent("FixtureTrash")
    try fm.createDirectory(at: trash, withIntermediateDirectories: true)
    func recycle(_ url: URL) throws -> FinderVisibleTrashReceipt {
      let destination = trash.appendingPathComponent(
        UUID().uuidString + "-" + url.lastPathComponent)
      try fm.moveItem(at: url, to: destination)
      return FinderVisibleTrashReceipt(
        originalPath: url.path, destinationPath: destination.path,
        visibleName: destination.lastPathComponent, finderVisibilityVerified: true,
        sourcePathRecreated: false, removalMethod: "fixture-only")
    }
    let installerOutcome = try engine.executeManual(installers.items, recycle: recycle)
    expect(
      installerOutcome.removedFiles == 1 && !fm.fileExists(atPath: oldInstaller.path),
      "manual organizer really moves a validated fixture")
    let body = Data(repeating: 0x61, count: 200000)
    let a = try put("Files/a.bin", body, age: 5000)
    _ = try put("Files/b.bin", body, age: 4000)
    var other = body
    other[100000] = 0x62
    _ = try put("Files/same-edges-different-middle.bin", other, age: 3000)
    try fm.linkItem(at: a, to: home.appendingPathComponent("Files/hardlink.bin"))
    let duplicates = try engine.scanFiles(
      tool: .duplicates, root: home.appendingPathComponent("Files"))
    expect(duplicates.items.count == 1, "full hashing rejects middle differences and hardlinks")
    let duplicate = duplicates.items[0]
    expect(
      duplicate.referencePath?.hasSuffix("a.bin") == true, "one original is explicitly retained")
    try Data("changed keeper".utf8).write(to: a)
    let changedKeeper = try engine.executeManual([duplicate], recycle: recycle)
    expect(
      changedKeeper.removedFiles == 0 && fm.fileExists(atPath: duplicate.path),
      "changed keeper blocks duplicate removal")
    _ = try put("Files/a.bin", body, age: 5000)
    let refreshedDuplicates = try engine.scanFiles(
      tool: .duplicates, root: home.appendingPathComponent("Files"))
    let oldPreview = refreshedDuplicates.items
    let successful = try engine.executeManual(oldPreview, recycle: recycle)
    expect(
      successful.removedFiles == 1 && fm.fileExists(atPath: a.path),
      "duplicate cleanup preserves live original")
    do {
      _ = try engine.executeManual(oldPreview, recycle: recycle)
      fatalError("stale preview should reject")
    } catch CleanupWorkbenchError.rejected {
      expect(true, "other cleanup invalidates stale preview")
    }
    let coordinator = CleanupWorkbenchCoordinator()
    let ownerA = UUID()
    let ownerB = UUID()
    expect(coordinator.claim(ownerA) && !coordinator.claim(ownerB), "one window owns work")
    coordinator.release(ownerB)
    expect(coordinator.isBusy, "non-owner cannot unlock another window")
    coordinator.release(ownerA)
    expect(!coordinator.isBusy, "owner completion unlocks")
    let cancellation = CleanupWorkCancellation()
    cancellation.cancel()
    do {
      _ = try engine.scanFiles(
        tool: .duplicates, root: home.appendingPathComponent("Files"), cancellation: cancellation)
      fatalError("cancel should stop")
    } catch CleanupWorkbenchError.cancelled { expect(true, "cancelled scan never proceeds") }
    print("CleanupWorkbenchFixtureAudit: \(count) / \(count) passed")
  }
}
