import Foundation

@main
struct SystemJunkLiveRevalidationAudit {
  static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else {
      fputs("FAIL: \(label)\n", stderr)
      exit(1)
    }
  }

  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
      "MacStorageLens-SystemJunkRevalidation-\(UUID().uuidString)",
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

    func installApp(name: String, bundleID: String) throws {
      let contents = try mkdir("Applications/\(name).app/Contents")
      let plist = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": bundleID],
        format: .xml,
        options: 0
      )
      try plist.write(to: contents.appendingPathComponent("Info.plist"))
    }

    try installApp(name: "Baseline", bundleID: "com.example.Baseline")
    let leftover = try mkdir("Library/Caches/com.example.ReturningApp")
    let partial = try write("Downloads/archive.crdownload", data: Data(repeating: 1, count: 4096))
    try fm.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-26 * 60 * 60)],
      ofItemAtPath: partial.path
    )
    let corrupt = try write(
      "Library/Preferences/com.example.FixedLater.plist",
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

    guard var leftoverCandidate = scan.candidates.first(where: { $0.path == leftover.path }),
      var partialCandidate = scan.candidates.first(where: { $0.path == partial.path }),
      var preferenceCandidate = scan.candidates.first(where: { $0.path == corrupt.path })
    else {
      fputs("FAIL: preconditions did not produce all candidates\n", stderr)
      exit(1)
    }

    // Reinstall the app after scanning. Execution must rebuild the installed-app
    // catalogue and reject the formerly orphaned cache.
    try installApp(name: "Returning", bundleID: "com.example.ReturningApp")
    leftoverCandidate.selected = true
    let (leftoverLog, _) = try engine.executeSelected(
      [leftoverCandidate],
      profile: .aggressive,
      removalMode: .forceDelete
    )
    expect(fm.fileExists(atPath: leftover.path), "reinstalled app leftover is not deleted")
    expect(
      leftoverLog.entries.first?.failures.isEmpty == false, "reinstallation rejection is logged")

    // Resume/change the download after scanning. The 24-hour stale condition is
    // no longer true and must be rechecked before deletion.
    try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: partial.path)
    partialCandidate.selected = true
    let (partialLog, _) = try engine.executeSelected(
      [partialCandidate],
      profile: .conservative,
      removalMode: .forceDelete
    )
    expect(fm.fileExists(atPath: partial.path), "freshened partial download is not deleted")
    expect(
      partialLog.entries.first?.failures.isEmpty == false, "fresh download rejection is logged")

    // Repair the plist after scanning. Execution must parse the current bytes,
    // not trust the stale scan result.
    let validPlist = try PropertyListSerialization.data(
      fromPropertyList: ["fixed": true],
      format: .binary,
      options: 0
    )
    try validPlist.write(to: corrupt, options: .atomic)
    preferenceCandidate.selected = true
    let (preferenceLog, _) = try engine.executeSelected(
      [preferenceCandidate],
      profile: .aggressive,
      removalMode: .forceDelete
    )
    expect(fm.fileExists(atPath: corrupt.path), "repaired plist is not deleted")
    expect(
      preferenceLog.entries.first?.failures.isEmpty == false, "repaired plist rejection is logged")

    print("SystemJunkLiveRevalidationAudit: 6 / 6 passed")
  }
}
