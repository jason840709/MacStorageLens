import Foundation

@main
struct SmartCleanupAudit {
  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("LensSmart-\(UUID().uuidString)")
    let home = root.appendingPathComponent("Home")
    defer { try? fm.removeItem(at: root) }
    let info = home.appendingPathComponent("Applications/Discord.app/Contents/Info.plist")
    try fm.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "com.hnc.Discord", "CFBundleName": "Discord"],
      format: .xml, options: 0)
    try plist.write(to: info)
    let cache = home.appendingPathComponent("Library/Application Support/discord/Code Cache")
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    func write(_ name: String, age: TimeInterval = 172800) throws -> URL {
      let url = cache.appendingPathComponent(name)
      try Data(repeating: 7, count: 8192).write(to: url)
      try fm.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
      return url
    }
    let old = try write("old.bin")
    let recent = try write("recent.bin", age: 1)
    let engine = CleanupWorkbenchEngine(homeURL: home, activeIdentifiers: [])
    let scan = try engine.scanSmart()
    func expect(_ yes: Bool, _ message: String) { if !yes { fatalError(message) } }
    let auto = scan.items.filter { $0.decision == .automatic }
    expect(
      auto.count == 1 && auto[0].files.count == 1,
      "known stale cache automatically chosen, recent leaf retained")
    let later = try write("added-after-scan.bin")
    let outcome = try engine.executeAutomatic(scan)
    expect(!fm.fileExists(atPath: old.path), "one-click actually removes approved temporary file")
    expect(
      fm.fileExists(atPath: recent.path) && fm.fileExists(atPath: later.path),
      "recent and newly introduced files survive")
    expect(outcome.removedFiles == 1, "receipt records actual operation count")
    _ = try write("old.bin")
    let beforeBusy = try engine.scanSmart()
    let busy = CleanupWorkbenchEngine(homeURL: home, activeIdentifiers: ["com.hnc.Discord"])
    let busyOutcome = try busy.executeAutomatic(beforeBusy)
    expect(
      busyOutcome.removedFiles == 0 && fm.fileExists(atPath: old.path),
      "app launched after preview is protected")
    let beforeProtection = try engine.scanSmart()
    let whitelist = home.appendingPathComponent(".config/mole/whitelist")
    try fm.createDirectory(
      at: whitelist.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("~/Library/Application Support/discord/*\n".utf8).write(to: whitelist)
    expect(
      try engine.executeAutomatic(beforeProtection).removedFiles == 0,
      "late whitelist blocks automatic cleanup")
    try fm.removeItem(at: whitelist)
    let cancelled = CleanupWorkCancellation()
    cancelled.cancel()
    do {
      _ = try engine.scanSmart(cancellation: cancelled)
      fatalError("cancelled scan must throw")
    } catch CleanupWorkbenchError.cancelled {}
    let changedScan = try engine.scanSmart()
    try Data("changed after scan".utf8).write(to: old)
    expect(
      try engine.executeAutomatic(changedScan).removedFiles == 1 && fm.fileExists(atPath: old.path),
      "changed file remains; unchanged approved old file processed")
    _ = try write("old.bin")
    let markerScan = try engine.scanSmart()
    try Data("{}".utf8).write(to: cache.appendingPathComponent("package.json"))
    expect(
      try engine.executeAutomatic(markerScan).removedFiles == 0,
      "new project evidence revokes auto qualification")
    try fm.removeItem(at: cache.appendingPathComponent("package.json"))
    let forgedFile = home.appendingPathComponent("important.bin")
    try Data("private".utf8).write(to: forgedFile)
    try fm.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-200000)], ofItemAtPath: forgedFile.path)
    let template = try engine.scanSmart().items.first { $0.decision == .automatic }!
    let forged = CleanupWorkbenchItem(
      tool: .smart, rule: template.rule, path: template.path,
      rootPath: try CleanupWorkbenchFileSafety.physicalPath(home), name: template.name,
      decision: .automatic,
      reason: "forged", impact: "", snapshot: template.snapshot,
      files: [try CleanupWorkbenchFileSafety.snapshot(forgedFile)],
      applicationID: template.applicationID)
    let forgedScan = CleanupWorkbenchScan(
      tool: .smart, rootPath: home.path, items: [forged], notices: [], visitedCount: 0,
      complete: true, createdAt: Date())
    expect(
      try engine.executeAutomatic(forgedScan).removedFiles == 0
        && fm.fileExists(atPath: forgedFile.path),
      "forged root cannot delete arbitrary personal files")
    print("SmartCleanupAudit: 10 / 10 passed")
  }
}
