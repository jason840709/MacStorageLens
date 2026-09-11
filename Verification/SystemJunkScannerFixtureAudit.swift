import Foundation

@main
struct SystemJunkScannerFixtureAudit {
  static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else {
      fputs("FAIL: \(label)\n", stderr)
      exit(1)
    }
  }

  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
      "MacStorageLens-SystemJunkFixture-\(UUID().uuidString)",
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

    let app = try mkdir("Applications/Installed.app/Contents")
    let appPlist = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "com.example.Installed"],
      format: .xml,
      options: 0
    )
    try appPlist.write(to: app.appendingPathComponent("Info.plist"))

    _ = try mkdir("Library/Caches/com.example.Installed")
    _ = try mkdir("Library/Caches/com.example.OldApp")
    _ = try mkdir("Library/Caches/com.apple.Safari")
    _ = try mkdir("Library/Caches/org.chromium.Chromium")
    _ = try mkdir("Library/Caches/com.google.Keystone")
    _ = try mkdir("Library/Caches/org.qt-project.Qt")
    _ = try mkdir("Library/Caches/io.qt.runtime")
    _ = try mkdir("Library/Caches/com.github.Electron")
    _ = try mkdir("Library/Caches/com.electron.runtime")
    _ = try mkdir("Library/Caches/.com.foo.Hidden")
    _ = try mkdir("Library/Caches/com..foo.Malformed")
    _ = try mkdir("Library/Saved Application State/com.example.OldState.savedState")

    let oldPartial = try write("Downloads/video.crdownload", data: Data(repeating: 1, count: 1024))
    let freshPartial = try write("Downloads/current.part", data: Data(repeating: 2, count: 1024))
    let oldDMG = try write("Downloads/installer.dmg", data: Data(repeating: 3, count: 2048))
    let oldTMP = try write("Downloads/render.tmp", data: Data(repeating: 4, count: 512))
    let now = Date()
    try fm.setAttributes(
      [.modificationDate: now.addingTimeInterval(-26 * 60 * 60)],
      ofItemAtPath: oldPartial.path
    )
    try fm.setAttributes(
      [.modificationDate: now.addingTimeInterval(-2 * 60 * 60)],
      ofItemAtPath: freshPartial.path
    )
    try fm.setAttributes(
      [.modificationDate: now.addingTimeInterval(-8 * 24 * 60 * 60)],
      ofItemAtPath: oldDMG.path
    )
    try fm.setAttributes(
      [.modificationDate: now.addingTimeInterval(-26 * 60 * 60)],
      ofItemAtPath: oldTMP.path
    )

    _ = try write(
      "Library/Preferences/com.example.Broken.plist",
      data: Data([0xFF, 0x00, 0xFE, 0x01])
    )
    _ = try write(
      "Library/Preferences/com.apple.Broken.plist",
      data: Data([0xFF, 0x00, 0xFE, 0x01])
    )
    let validPreference = try PropertyListSerialization.data(
      fromPropertyList: ["enabled": true],
      format: .binary,
      options: 0
    )
    _ = try write("Library/Preferences/com.example.Valid.plist", data: validPreference)

    let library = try ReportLibrary(
      rootURL: root.appendingPathComponent("Reports"), fileManager: fm)
    let engine = CleanupEngine(library: library, fileManager: fm, homeURL: home)
    let configuration = CleanupScanConfiguration(
      profile: .custom,
      customScopes: [.downloadResidue, .appLeftovers, .brokenPreferences],
      customMinimumBytes: 0
    )
    let result = try engine.scanCandidates(configuration: configuration)

    let paths = Set(result.candidates.map(\.path))
    expect(
      paths.contains(home.appendingPathComponent("Library/Caches/com.example.OldApp").path),
      "orphan cache found")
    expect(
      !paths.contains(home.appendingPathComponent("Library/Caches/com.example.Installed").path),
      "installed app protected")
    expect(
      !paths.contains(home.appendingPathComponent("Library/Caches/com.apple.Safari").path),
      "Apple cache protected")
    for protected in [
      "org.chromium.Chromium", "com.google.Keystone", "org.qt-project.Qt", "io.qt.runtime",
      "com.github.Electron", "com.electron.runtime",
    ] {
      expect(
        !paths.contains(home.appendingPathComponent("Library/Caches/\(protected)").path),
        "shared runtime protected: \(protected)"
      )
    }
    expect(
      !paths.contains(home.appendingPathComponent("Library/Caches/.com.foo.Hidden").path),
      "leading-dot pseudo bundle id protected")
    expect(
      !paths.contains(home.appendingPathComponent("Library/Caches/com..foo.Malformed").path),
      "empty-component pseudo bundle id protected")
    expect(
      paths.contains(
        home.appendingPathComponent(
          "Library/Saved Application State/com.example.OldState.savedState"
        ).path), "saved-state leftover found")
    expect(paths.contains(oldPartial.path), "old partial download found")
    expect(!paths.contains(freshPartial.path), "fresh partial download protected")
    expect(paths.contains(oldDMG.path), "old disk image found")
    expect(paths.contains(oldTMP.path), "old .tmp incomplete download found")
    expect(
      paths.contains(
        home.appendingPathComponent("Library/Preferences/com.example.Broken.plist").path),
      "corrupt third-party plist found")
    expect(
      !paths.contains(
        home.appendingPathComponent("Library/Preferences/com.apple.Broken.plist").path),
      "corrupt Apple plist protected")
    expect(
      !paths.contains(
        home.appendingPathComponent("Library/Preferences/com.example.Valid.plist").path),
      "valid third-party plist protected")

    let rules = Set(result.candidates.map(\.ruleID))
    expect(rules.contains(.appLeftoverEntry), "app-leftover rule emitted")
    expect(rules.contains(.incompleteDownload), "incomplete-download rule emitted")
    expect(rules.contains(.staleDiskImage), "stale-disk-image rule emitted")
    expect(rules.contains(.corruptPreferencePlist), "corrupt-preference rule emitted")

    print("SystemJunkScannerFixtureAudit: 23 / 23 passed")
  }
}
