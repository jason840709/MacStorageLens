import Foundation

@main
struct ExternalAppleDoubleCleanupAudit {
  private static var checks: [[String: Any]] = []
  private static var failures = 0

  static func main() throws {
    let fileManager = FileManager.default
    let fixture = fileManager.temporaryDirectory
      .appendingPathComponent(
        "MacStorageLens-ExternalAppleDoubleAudit-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: fixture) }

    let home = fixture.appendingPathComponent("home", isDirectory: true)
    let root = home.appendingPathComponent("ExternalMedia", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let orphan = root.appendingPathComponent("._orphan.txt")
    try writeAppleDouble(orphan, entries: [(9, Data(repeating: 0x31, count: 32))])

    let pairedMain = root.appendingPathComponent("paired.txt")
    let paired = root.appendingPathComponent("._paired.txt")
    try Data("main".utf8).write(to: pairedMain)
    try writeAppleDouble(paired, entries: [(9, Data(repeating: 0x32, count: 32))])

    let resourceMain = root.appendingPathComponent("resource.dat")
    let resource = root.appendingPathComponent("._resource.dat")
    try Data("resource-main".utf8).write(to: resourceMain)
    try writeAppleDouble(
      resource,
      entries: [
        (9, Data(repeating: 0x33, count: 32)),
        (2, Data(repeating: 0x52, count: 16)),
      ]
    )

    let unknown = root.appendingPathComponent("._ordinary-user-file")
    try Data("this is not appledouble".utf8).write(to: unknown)

    let target = ScanTarget(
      kind: .volume,
      displayName: "External Media",
      path: root.path,
      volumeUUID: "external-fixture"
    )
    let externalCapabilities = capabilities(
      filesystemType: "exfat", isRemote: false, isInternalStorage: false)
    let externalEngine = FolderCleanupEngine(
      fileManager: fileManager,
      homeURL: home,
      targetCapabilityResolver: { _ in externalCapabilities }
    )

    let conservative = try externalEngine.scanCandidates(
      configuration: configuration(.conservative), target: target)
    let balanced = try externalEngine.scanCandidates(
      configuration: configuration(.balanced), target: target)
    let ultraAggressive = try externalEngine.scanCandidates(
      configuration: configuration(.ultraAggressive), target: target)

    check(
      "external_conservative_surfaces_metadata_only_orphan",
      candidate(.folderOrphanedAppleDoubleSidecar, in: conservative)?.matchedPaths == [orphan.path])
    check(
      "external_orphan_is_low_risk_conservative",
      candidate(.folderOrphanedAppleDoubleSidecar, in: conservative)?.tier == .conservative
        && candidate(.folderOrphanedAppleDoubleSidecar, in: conservative)?.risk == .low)
    check(
      "external_conservative_does_not_yet_surface_paired_metadata",
      candidate(.folderAppleDoubleSidecar, in: conservative) == nil)
    check(
      "external_balanced_surfaces_paired_metadata",
      candidate(.folderAppleDoubleSidecar, in: balanced)?.matchedPaths == [paired.path])
    check(
      "external_paired_is_moderate_risk_balanced",
      candidate(.folderAppleDoubleSidecar, in: balanced)?.tier == .balanced
        && candidate(.folderAppleDoubleSidecar, in: balanced)?.risk == .moderate)
    check(
      "resource_fork_stays_review_only_even_on_external_media",
      candidate(.folderSensitiveAppleDoubleSidecar, in: ultraAggressive)?.matchedPaths.contains(
        resource.path) == true
        && candidate(.folderSensitiveAppleDoubleSidecar, in: ultraAggressive)?.isSelectable == false
    )
    check(
      "unrecognized_dot_underscore_stays_review_only",
      candidate(.folderUnrecognizedDotUnderscore, in: ultraAggressive)?.matchedPaths.contains(
        unknown.path) == true
        && candidate(.folderUnrecognizedDotUnderscore, in: ultraAggressive)?.isSelectable == false)
    check(
      "external_notice_explains_priority_without_weakening_red_line",
      balanced.notices.contains { $0.contains("AppleDouble") && $0.contains("resource fork") })

    let internalCapabilities = capabilities(
      filesystemType: "apfs", isRemote: false, isInternalStorage: true)
    let internalEngine = FolderCleanupEngine(
      fileManager: fileManager,
      homeURL: home,
      targetCapabilityResolver: { _ in internalCapabilities }
    )
    let internalConservative = try internalEngine.scanCandidates(
      configuration: configuration(.conservative), target: target)
    let internalBalanced = try internalEngine.scanCandidates(
      configuration: configuration(.balanced), target: target)
    let internalAggressive = try internalEngine.scanCandidates(
      configuration: configuration(.aggressive), target: target)

    check(
      "internal_policy_keeps_orphan_out_of_conservative",
      candidate(.folderOrphanedAppleDoubleSidecar, in: internalConservative) == nil)
    check(
      "internal_policy_keeps_orphan_at_balanced",
      candidate(.folderOrphanedAppleDoubleSidecar, in: internalBalanced)?.matchedPaths == [
        orphan.path
      ])
    check(
      "internal_policy_keeps_paired_at_aggressive",
      candidate(.folderAppleDoubleSidecar, in: internalAggressive)?.matchedPaths == [paired.path])

    // Remote NAS recycle directories are server-managed. Safe Cleanup must not
    // spend SMB directory-listing I/O inside them or produce second-generation
    // candidates for items already moved there by the NAS.
    let remoteRoot = home.appendingPathComponent("RemoteShare", isDirectory: true)
    let normal = remoteRoot.appendingPathComponent("Normal", isDirectory: true)
    let recycle = remoteRoot.appendingPathComponent("#recycle", isDirectory: true)
    let ordinaryNestedRecycle = normal.appendingPathComponent("#recycle", isDirectory: true)
    try fileManager.createDirectory(at: normal, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: recycle, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: ordinaryNestedRecycle, withIntermediateDirectories: true)
    let remoteOrphan = normal.appendingPathComponent("._remote-orphan")
    try writeAppleDouble(remoteOrphan, entries: [(9, Data(repeating: 0x41, count: 32))])
    let recycleDSStore = recycle.appendingPathComponent(".DS_Store")
    try Data("server trash".utf8).write(to: recycleDSStore)
    let recycleSidecar = recycle.appendingPathComponent("._trashed-file")
    try writeAppleDouble(recycleSidecar, entries: [(9, Data(repeating: 0x42, count: 32))])
    let ordinaryNestedDSStore = ordinaryNestedRecycle.appendingPathComponent(".DS_Store")
    try Data("ordinary folder".utf8).write(to: ordinaryNestedDSStore)

    let remoteTarget = ScanTarget(
      kind: .volume,
      displayName: "SMB Share",
      path: remoteRoot.path,
      volumeUUID: nil
    )
    let smbCapabilities = capabilities(
      filesystemType: "smbfs", isRemote: true, isInternalStorage: nil)
    let remoteEngine = FolderCleanupEngine(
      fileManager: fileManager,
      homeURL: home,
      targetCapabilityResolver: { _ in smbCapabilities }
    )
    let remoteResult = try remoteEngine.scanCandidates(
      configuration: configuration(.ultraAggressive), target: remoteTarget)
    let remotePaths = Set(remoteResult.candidates.flatMap(\.matchedPaths))

    check("remote_normal_appledouble_is_still_scanned", remotePaths.contains(remoteOrphan.path))
    check(
      "remote_recycle_subtree_produces_zero_candidates",
      !remotePaths.contains(recycleDSStore.path) && !remotePaths.contains(recycleSidecar.path)
        && remotePaths.allSatisfy { !$0.hasPrefix(recycle.path + "/") })
    check(
      "remote_recycle_skip_is_disclosed",
      remoteResult.notices.contains { $0.contains("#recycle") && $0.contains("略過") })
    check(
      "only_root_server_recycle_is_special",
      remotePaths.contains(ordinaryNestedDSStore.path))
    let recycleRefresh = try remoteEngine.scanCandidateDirectories(
      configuration: configuration(.ultraAggressive),
      target: remoteTarget,
      directoryPaths: [recycle.path],
      scanSource: .liveFilesystem
    )
    check(
      "incremental_dirty_refresh_skips_server_recycle",
      recycleRefresh.candidates.isEmpty)
    check(
      "execution_revalidation_rejects_remote_recycle_path",
      throwsError {
        _ = try remoteEngine.validateMatchedPath(
          recycleDSStore.path,
          rule: .folderDSStore,
          rootPath: remoteRoot.path
        )
      })

    let output: [String: Any] = [
      "version": "1.7.5",
      "build": 33,
      "checks": checks,
      "passed": checks.count - failures,
      "total": checks.count,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    if CommandLine.arguments.count > 1 {
      try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    if failures > 0 { exit(1) }
  }

  private static func capabilities(
    filesystemType: String,
    isRemote: Bool,
    isInternalStorage: Bool?
  ) -> CleanupTargetCapabilities {
    CleanupTargetCapabilities(
      filesystemType: filesystemType,
      isRemote: isRemote,
      isReadOnly: false,
      isInternalStorage: isInternalStorage,
      supportsFinderVisibleTrash: !isRemote,
      supportsDirectDeletion: true,
      detectionSource: "audit_fixture"
    )
  }

  private static func configuration(_ profile: CleanupProfile) -> CleanupScanConfiguration {
    CleanupScanConfiguration(profile: profile, customScopes: [], customMinimumBytes: 0)
  }

  private static func candidate(
    _ rule: CleanupRuleID,
    in result: CleanupScanResult
  ) -> CleanupCandidate? {
    result.candidates.first { $0.ruleID == rule }
  }

  private static func throwsError(_ operation: () throws -> Void) -> Bool {
    do {
      try operation()
      return false
    } catch {
      return true
    }
  }

  private static func writeAppleDouble(_ url: URL, entries: [(UInt32, Data)]) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var data = Data()
    appendUInt32BE(0x0005_1607, to: &data)
    appendUInt32BE(0x0002_0000, to: &data)
    data.append(Data("Mac OS X        ".utf8).prefix(16))
    appendUInt16BE(UInt16(entries.count), to: &data)
    var offset = UInt32(26 + entries.count * 12)
    for entry in entries {
      appendUInt32BE(entry.0, to: &data)
      appendUInt32BE(offset, to: &data)
      appendUInt32BE(UInt32(entry.1.count), to: &data)
      offset += UInt32(entry.1.count)
    }
    for entry in entries { data.append(entry.1) }
    try data.write(to: url)
  }

  private static func appendUInt16BE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
  }

  private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
  }

  private static func check(_ name: String, _ passed: Bool, detail: String = "") {
    checks.append(["name": name, "passed": passed, "detail": detail])
    if !passed { failures += 1 }
  }
}
