import Foundation

@main
struct CleanupProtectionRevalidationAudit {
  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("Home")
    let cache = home.appendingPathComponent("Library/Caches/com.example.Keep")
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 8192).write(to: cache.appendingPathComponent("data"))
    defer { try? fm.removeItem(at: root) }
    let library = try ReportLibrary(rootURL: root.appendingPathComponent("Reports"))
    let engine = CleanupEngine(library: library, homeURL: home)
    let config = CleanupScanConfiguration(
      profile: .custom, customScopes: [.standardCaches], customMinimumBytes: 0)
    var candidate = try engine.scanCandidates(configuration: config).candidates.first {
      $0.path == cache.path
    }!
    let whitelist = home.appendingPathComponent(".config/mole/whitelist")
    try fm.createDirectory(
      at: whitelist.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("~/Library/Caches/com.example.Keep\n".utf8).write(to: whitelist)
    func expect(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    expect(
      engine.visibleCandidates(from: [candidate], configuration: config, mode: .system).isEmpty,
      "old index honors new whitelist")
    candidate.selected = true
    let (log, _) = try engine.executeSelected(
      [candidate], profile: .custom, removalMode: .forceDelete)
    expect(
      log.entries.first?.failures.isEmpty == false
        && fm.fileExists(atPath: cache.appendingPathComponent("data").path),
      "late protection blocks deletion and logs reason")
    expect(
      try engine.scanCandidates(configuration: config).candidates.isEmpty,
      "reused engine reloads protection before scanning")
    print("CleanupProtectionRevalidationAudit: 3 / 3 passed")
  }
}
