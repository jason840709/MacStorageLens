import Foundation

private struct Check: Codable {
  let name: String
  let passed: Bool
  let detail: String
}

private struct AuditResult: Codable {
  let version: String
  let passed: Int
  let total: Int
  let checks: [Check]
}

@main
struct CleanupTargetCapabilityAudit {
  static func main() throws {
    var checks: [Check] = []

    func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: String) {
      checks.append(Check(name: name, passed: condition(), detail: detail))
    }

    let nas = ScanTarget(
      kind: .volume,
      displayName: "NAS",
      path: "/Volumes/NAS",
      volumeUUID: nil
    )
    let folder = ScanTarget(
      kind: .folder,
      displayName: "Share",
      path: "/Volumes/NAS/Share",
      volumeUUID: nil
    )
    let local = ScanTarget(
      kind: .volume,
      displayName: "USB",
      path: "/Volumes/USB",
      volumeUUID: "fixture"
    )

    let smb = CleanupTargetCapabilityPolicy.evaluate(
      target: nas,
      facts: CleanupMountFacts(
        filesystemType: "smbfs",
        isLocal: false,
        isReadOnly: false,
        detectionSource: "fixture"
      )
    )
    check("smb_is_remote", smb.isRemote, "SMB must be classified as remote")
    check(
      "smb_disables_finder_trash",
      !smb.supportsFinderVisibleTrash,
      "Finder Trash must not be offered on SMB"
    )
    check(
      "smb_keeps_direct_delete",
      smb.supportsDirectDeletion,
      "Writable SMB may still use direct client deletion"
    )
    check(
      "smb_is_external_storage",
      smb.isExternalStorage && smb.prioritizesExternalAppleDoubleCleanup,
      "Remote SMB should use the external-media AppleDouble policy"
    )
    check(
      "smb_notice_mentions_server_policy",
      smb.cleanupNotice?.contains("伺服器端設定") == true,
      "Remote notice must distinguish Finder Trash from server recycle/snapshots"
    )

    let disguisedSMB = CleanupTargetCapabilityPolicy.evaluate(
      target: folder,
      facts: CleanupMountFacts(
        filesystemType: "SMBFS",
        isLocal: true,
        isReadOnly: false,
        detectionSource: "fixture"
      )
    )
    check(
      "known_remote_type_wins_over_local_flag",
      disguisedSMB.isRemote && !disguisedSMB.supportsFinderVisibleTrash,
      "Known remote filesystem type must remain direct-only even with an inconsistent local flag"
    )

    for type in ["nfs", "webdav", "afpfs", "sshfs"] {
      let capabilities = CleanupTargetCapabilityPolicy.evaluate(
        target: nas,
        facts: CleanupMountFacts(
          filesystemType: type,
          isLocal: nil,
          isReadOnly: false,
          detectionSource: "fixture"
        )
      )
      check(
        "remote_type_\(type)",
        capabilities.isRemote && !capabilities.supportsFinderVisibleTrash,
        "\(type) should be treated as a remote direct-only filesystem"
      )
    }

    let exfat = CleanupTargetCapabilityPolicy.evaluate(
      target: local,
      facts: CleanupMountFacts(
        filesystemType: "exfat",
        isLocal: true,
        isReadOnly: false,
        isInternal: false,
        detectionSource: "fixture"
      )
    )
    check(
      "local_exfat_keeps_both_modes",
      !exfat.isRemote && exfat.supportsFinderVisibleTrash && exfat.supportsDirectDeletion,
      "Writable local removable media should keep Finder Trash and direct deletion"
    )
    check(
      "local_exfat_is_external_storage",
      exfat.isExternalStorage && exfat.prioritizesExternalAppleDoubleCleanup,
      "Removable local media should prioritize safe AppleDouble cleanup"
    )

    let internalFolder = CleanupTargetCapabilityPolicy.evaluate(
      target: folder,
      facts: CleanupMountFacts(
        filesystemType: "apfs",
        isLocal: true,
        isReadOnly: false,
        isInternal: true,
        detectionSource: "fixture"
      )
    )
    check(
      "internal_folder_does_not_use_external_policy",
      !internalFolder.isExternalStorage
        && !internalFolder.prioritizesExternalAppleDoubleCleanup,
      "A folder on the internal Mac disk must keep the conservative local AppleDouble tiers"
    )

    let readOnly = CleanupTargetCapabilityPolicy.evaluate(
      target: local,
      facts: CleanupMountFacts(
        filesystemType: "exfat",
        isLocal: true,
        isReadOnly: true,
        isInternal: false,
        detectionSource: "fixture"
      )
    )
    check(
      "read_only_disables_all_deletion",
      !readOnly.supportsFinderVisibleTrash && !readOnly.supportsDirectDeletion,
      "Read-only mounts must expose no deletion path"
    )

    let unknown = CleanupTargetCapabilityPolicy.evaluate(
      target: nas,
      facts: CleanupMountFacts(
        filesystemType: "UNKNOWN",
        isLocal: nil,
        isReadOnly: nil,
        detectionSource: "fixture"
      )
    )
    check(
      "unknown_mount_is_conservative_about_trash",
      !unknown.supportsFinderVisibleTrash,
      "Unknown mount capability must not expose a reversible-looking Finder Trash action"
    )

    let system = CleanupTargetCapabilityPolicy.evaluate(
      target: .systemStorage,
      facts: CleanupMountFacts(
        filesystemType: "apfs",
        isLocal: true,
        isReadOnly: false,
        isInternal: true,
        detectionSource: "fixture"
      )
    )
    check(
      "system_keeps_finder_trash",
      system.supportsFinderVisibleTrash && system.supportsDirectDeletion,
      "System target keeps existing two-mode behavior"
    )

    let passed = checks.filter(\.passed).count
    let result = AuditResult(version: "1.7.5", passed: passed, total: checks.count, checks: checks)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)

    if let output = CommandLine.arguments.dropFirst().first {
      try data.write(to: URL(fileURLWithPath: output), options: .atomic)
    } else {
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
    }

    if passed != checks.count { throw NSError(domain: "CleanupTargetCapabilityAudit", code: 1) }
  }
}
