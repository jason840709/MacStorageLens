import Foundation

@main
struct TrashBinsCleanupAudit {
  private static var passed = 0

  static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else {
      fputs("FAIL: \(label)\n", stderr)
      exit(1)
    }
    passed += 1
  }

  static func main() throws {
    let fm = FileManager.default
    let fixture = fm.temporaryDirectory.appendingPathComponent(
      "MacStorageLens-TrashBins-\(UUID().uuidString)",
      isDirectory: true
    )
    let home = fixture.appendingPathComponent("Home", isDirectory: true)
    let volumes = fixture.appendingPathComponent("Volumes", isDirectory: true)
    let userID: UInt32 = 501
    defer { try? fm.removeItem(at: fixture) }

    func mkdir(_ url: URL) throws {
      try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ url: URL, bytes: Int = 64) throws {
      try mkdir(url.deletingLastPathComponent())
      try Data(repeating: 0x5A, count: bytes).write(to: url)
    }

    try mkdir(home)
    try mkdir(volumes)

    let userTrash = home.appendingPathComponent(".Trash", isDirectory: true)
    let userFile = userTrash.appendingPathComponent("user-file.txt")
    let userDirectory = userTrash.appendingPathComponent("user-folder", isDirectory: true)
    let userNestedFile = userDirectory.appendingPathComponent("nested.bin")
    try write(userFile)
    try write(userNestedFile)

    let outside = home.appendingPathComponent("Documents/keep.txt")
    try write(outside)
    let linkedOutside = userTrash.appendingPathComponent("outside-link")
    try fm.createSymbolicLink(at: linkedOutside, withDestinationURL: outside)

    let externalVolume = volumes.appendingPathComponent("ExternalSSD", isDirectory: true)
    let externalTrash =
      externalVolume
      .appendingPathComponent(".Trashes", isDirectory: true)
      .appendingPathComponent(String(userID), isDirectory: true)
    let externalFile = externalTrash.appendingPathComponent("external-file.bin")
    try write(externalFile)

    let otherUserFile =
      externalVolume
      .appendingPathComponent(".Trashes", isDirectory: true)
      .appendingPathComponent("502", isDirectory: true)
      .appendingPathComponent("other-user.bin")
    try write(otherUserFile)

    let nasRecycleFile =
      externalVolume
      .appendingPathComponent("#recycle", isDirectory: true)
      .appendingPathComponent("server-retained.bin")
    try write(nasRecycleFile)

    let aggressive = CleanupScanConfiguration(
      profile: .aggressive,
      customScopes: [],
      customMinimumBytes: 0
    )
    let ultraAggressiveDefault = CleanupScanConfiguration(
      profile: .ultraAggressive,
      customScopes: [],
      customMinimumBytes: 0
    )
    let ultraAggressiveWithTrash = CleanupScanConfiguration(
      profile: .ultraAggressive,
      customScopes: [],
      customMinimumBytes: 0,
      presetOptionalScopes: [.trashBins]
    )
    expect(!aggressive.requiresScope(.trashBins), "L4 does not include Trash Bins")
    expect(
      !ultraAggressiveDefault.requiresScope(.trashBins),
      "L5 keeps Trash Bins off until explicitly enabled"
    )
    expect(
      ultraAggressiveWithTrash.requiresScope(.trashBins),
      "L5 includes Trash Bins after explicit opt-in"
    )
    expect(
      !ultraAggressiveWithTrash.requiresScope(.highImpactUserData),
      "enabling Trash Bins does not silently enable other L5 optional scopes"
    )

    let encodedConfiguration = try JSONEncoder().encode(ultraAggressiveWithTrash)
    var legacyPayload =
      try JSONSerialization.jsonObject(with: encodedConfiguration) as? [String: Any]
    legacyPayload?.removeValue(forKey: "presetOptionalScopes")
    let legacyConfiguration = try JSONDecoder().decode(
      CleanupScanConfiguration.self,
      from: JSONSerialization.data(withJSONObject: legacyPayload ?? [:])
    )
    expect(
      legacyConfiguration.presetOptionalScopes.isEmpty,
      "pre-Build-33 configuration decodes with optional L5 scopes disabled"
    )
    expect(
      !legacyConfiguration.requiresScope(.trashBins),
      "legacy configuration cannot silently activate Trash Bins"
    )

    let library = try ReportLibrary(
      rootURL: fixture.appendingPathComponent("Reports", isDirectory: true),
      fileManager: fm
    )
    let engine = CleanupEngine(
      library: library,
      fileManager: fm,
      homeURL: home,
      volumesRootURL: volumes,
      currentUserID: userID
    )
    var defaultL5ScannedPaths: [String] = []
    let defaultL5Scan = try engine.scanCandidates(
      configuration: ultraAggressiveDefault,
      progress: { progress in
        if let path = progress.currentPath { defaultL5ScannedPaths.append(path) }
      }
    )
    expect(
      defaultL5Scan.candidates.allSatisfy { $0.ruleID != .trashBinContents },
      "L5 without Trash opt-in produces no Trash candidates"
    )
    expect(
      !defaultL5ScannedPaths.contains(userTrash.path)
        && !defaultL5ScannedPaths.contains(externalTrash.path),
      "L5 without Trash opt-in does not enumerate Trash roots"
    )

    var optInL5ScannedPaths: [String] = []
    let optInL5Scan = try engine.scanCandidates(
      configuration: ultraAggressiveWithTrash,
      progress: { progress in
        if let path = progress.currentPath { optInL5ScannedPaths.append(path) }
      }
    )
    expect(
      optInL5ScannedPaths.contains(userTrash.path)
        && optInL5ScannedPaths.contains(externalTrash.path),
      "L5 with Trash opt-in enumerates only the approved Trash roots"
    )
    expect(
      optInL5Scan.candidates.filter { $0.ruleID == .trashBinContents }.count == 2,
      "L5 with Trash opt-in creates current-UID Trash candidates"
    )

    let configuration = CleanupScanConfiguration(
      profile: .custom,
      customScopes: [.trashBins],
      customMinimumBytes: 0
    )
    let scan = try engine.scanCandidates(configuration: configuration)
    let trashCandidates = scan.candidates.filter { $0.ruleID == .trashBinContents }

    expect(trashCandidates.count == 2, "user and external current-UID Trash roots are candidates")
    expect(
      trashCandidates.allSatisfy {
        $0.scope == .trashBins && $0.category == .trashBins
          && $0.tier == .ultraAggressive && $0.requiresDirectDeletion
      },
      "Trash candidates are L5 direct-only"
    )
    expect(
      trashCandidates.allSatisfy(\.requiresManualSelection),
      "Trash candidates require manual selection")
    expect(trashCandidates.allSatisfy { !$0.selected }, "Trash candidates are never preselected")

    let matched = Set(trashCandidates.flatMap(\.matchedPaths))
    expect(matched.contains(userFile.path), "user Trash file is listed")
    expect(
      matched.contains(userDirectory.path), "user Trash directory is listed as one direct child")
    expect(matched.contains(externalFile.path), "external current-UID Trash file is listed")
    expect(!matched.contains(linkedOutside.path), "Trash symlink is excluded")
    expect(!matched.contains(otherUserFile.path), "other UID Trash is excluded")
    expect(!matched.contains(nasRecycleFile.path), "NAS #recycle is excluded")

    var index = CleanupIncrementalIndex(
      target: .systemStorage,
      scanSource: .liveFilesystem,
      sourceReportURL: nil,
      sourceReportSignature: nil
    )
    index.merge(scanResult: scan, coveredScopes: [.trashBins])
    expect(index.coveredScopes.contains(.trashBins), "Trash scope is indexed after scanning")

    let postScanFile = userTrash.appendingPathComponent("added-after-scan.txt")
    try write(postScanFile)
    expect(
      !matched.contains(postScanFile.path), "post-scan Trash item is outside the operation snapshot"
    )

    var selected = trashCandidates
    for index in selected.indices { selected[index].selected = true }

    do {
      _ = try engine.executeSelected(
        selected,
        profile: .custom,
        removalMode: .moveToTrash
      )
      expect(false, "direct-only Trash candidates cannot move into Trash again")
    } catch {
      expect(true, "direct-only Trash candidates reject Finder Trash execution")
    }

    let (log, _) = try engine.executeSelected(
      selected,
      profile: .custom,
      removalMode: .forceDelete
    )
    expect(log.entries.count == 2, "two Trash root operations are logged")
    expect(log.entries.allSatisfy { $0.failures.isEmpty }, "validated Trash deletion succeeds")
    expect(!fm.fileExists(atPath: userFile.path), "user Trash file is permanently removed")
    expect(
      !fm.fileExists(atPath: userDirectory.path), "user Trash directory is permanently removed")
    expect(!fm.fileExists(atPath: externalFile.path), "external current-UID Trash file is removed")
    expect(fm.fileExists(atPath: userTrash.path), "user Trash root remains")
    expect(fm.fileExists(atPath: externalTrash.path), "external current-UID Trash root remains")
    expect(fm.fileExists(atPath: postScanFile.path), "post-scan Trash item remains")
    expect(fm.fileExists(atPath: linkedOutside.path), "excluded Trash symlink remains")
    expect(fm.fileExists(atPath: outside.path), "symlink target remains")
    expect(fm.fileExists(atPath: otherUserFile.path), "other UID item remains")
    expect(fm.fileExists(atPath: nasRecycleFile.path), "NAS #recycle item remains")

    index.markCleanupResult(selected: selected, log: log)
    expect(
      !index.coveredScopes.contains(.trashBins),
      "Trash scope is invalidated after cleanup so the next supplemental scan is live"
    )

    let malicious = CleanupCandidate(
      ruleID: .trashBinContents,
      scope: .trashBins,
      tier: .ultraAggressive,
      category: .trashBins,
      action: .permanentDeleteMatchedItems,
      path: userTrash.path,
      displayName: "malicious fixture",
      bytes: 64,
      risk: .high,
      reason: "fixture",
      impact: "fixture",
      recovery: "fixture",
      matchedPaths: [outside.path],
      matchedPathBytes: [outside.path: 64],
      cleanupRootPath: userTrash.path,
      selected: true
    )
    let (maliciousLog, _) = try engine.executeSelected(
      [malicious],
      profile: .custom,
      removalMode: .forceDelete
    )
    expect(!maliciousLog.entries[0].failures.isEmpty, "outside-root path is rejected at execution")
    expect(fm.fileExists(atPath: outside.path), "outside-root file survives malicious candidate")

    print("TrashBinsCleanupAudit: \(passed) / \(passed) passed")
  }
}
