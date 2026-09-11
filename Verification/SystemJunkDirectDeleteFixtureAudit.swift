import Foundation

@main
struct SystemJunkDirectDeleteFixtureAudit {
  static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else {
      fputs("FAIL: \(label)\n", stderr)
      exit(1)
    }
  }

  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
      "MacStorageLens-SystemJunkDelete-\(UUID().uuidString)",
      isDirectory: true
    )
    let home = root.appendingPathComponent("Home", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    func mkdir(_ relative: String) throws -> URL {
      let url = home.appendingPathComponent(relative, isDirectory: true)
      try fm.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }

    func write(_ relative: String, data: Data) throws -> URL {
      let url = home.appendingPathComponent(relative)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
      return url
    }

    let appContents = try mkdir("Applications/Baseline.app/Contents")
    let appPlist = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "com.example.Baseline"],
      format: .xml,
      options: 0
    )
    try appPlist.write(to: appContents.appendingPathComponent("Info.plist"))

    let leftover = try mkdir("Library/Caches/com.example.Removed")
    _ = try write(
      "Library/Caches/com.example.Removed/cache.bin", data: Data(repeating: 1, count: 32))
    let partial = try write("Downloads/stalled.partial", data: Data(repeating: 2, count: 64))
    try fm.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-26 * 60 * 60)],
      ofItemAtPath: partial.path
    )
    let corrupt = try write(
      "Library/Preferences/com.example.Corrupt.plist",
      data: Data([0xFF, 0x00, 0xFE, 0x01])
    )

    let library = try ReportLibrary(
      rootURL: root.appendingPathComponent("Reports"), fileManager: fm)
    let engine = CleanupEngine(library: library, fileManager: fm, homeURL: home)
    let configuration = CleanupScanConfiguration(
      profile: .custom,
      customScopes: [.downloadResidue, .appLeftovers, .brokenPreferences],
      customMinimumBytes: 0
    )
    let scan = try engine.scanCandidates(configuration: configuration)
    let wanted = Set([leftover.path, partial.path, corrupt.path])
    var selected = scan.candidates.filter { wanted.contains($0.path) }
    expect(selected.count == 3, "all three executable fixture candidates were found")
    for index in selected.indices { selected[index].selected = true }

    let (log, _) = try engine.executeSelected(
      selected,
      profile: .custom,
      removalMode: .forceDelete
    )
    expect(log.entries.count == 3, "three direct-delete log entries were written")
    expect(log.entries.allSatisfy { $0.failures.isEmpty }, "fixture deletions all succeeded")
    expect(!fm.fileExists(atPath: leftover.path), "leftover directory was deleted")
    expect(!fm.fileExists(atPath: partial.path), "regular partial-download file was deleted")
    expect(!fm.fileExists(atPath: corrupt.path), "regular corrupt-plist file was deleted")

    print("SystemJunkDirectDeleteFixtureAudit: 6 / 6 passed")
  }
}
