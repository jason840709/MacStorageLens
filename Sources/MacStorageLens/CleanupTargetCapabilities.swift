import Foundation

#if os(macOS)
  import Darwin
#endif

struct CleanupTargetCapabilities: Hashable {
  let filesystemType: String
  let isRemote: Bool
  let isReadOnly: Bool
  let isInternalStorage: Bool?
  let supportsFinderVisibleTrash: Bool
  let supportsDirectDeletion: Bool
  let detectionSource: String

  /// True for network mounts and for local removable/external storage. A folder
  /// selected on the Mac's internal disk stays false, so external-media cleanup
  /// policy never leaks into ordinary local folders.
  var isExternalStorage: Bool {
    isRemote || isInternalStorage == false
  }

  /// AppleDouble sidecars are disproportionately costly on SD cards, USB media
  /// and NAS shares. The scanner may surface proven metadata-only sidecars at
  /// lower cleanup tiers on these targets, while resource forks and unknown
  /// payloads remain review-only.
  var prioritizesExternalAppleDoubleCleanup: Bool {
    isExternalStorage && !isReadOnly
  }

  var filesystemDisplayName: String {
    let value = filesystemType.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty || value == "UNKNOWN" ? "未知檔案系統" : value.uppercased()
  }

  var finderTrashUnavailableReason: String? {
    guard !supportsFinderVisibleTrash else { return nil }
    if isReadOnly {
      return "目前目標是唯讀檔案系統，不能移到 Finder 垃圾桶，也不能直接刪除。"
    }
    if isRemote {
      return
        "目前目標是 \(filesystemDisplayName) 網路卷宗。macOS／Finder 對這類遠端掛載沒有可由 MacStorageLens 驗證的 Finder 垃圾桶流程，因此已停用『移到 Finder 可見垃圾桶』。"
    }
    return "無法確認目前檔案系統能安全使用 Finder 可見垃圾桶，因此此選項已停用。"
  }

  var cleanupNotice: String? {
    if isReadOnly {
      return "\(filesystemDisplayName) 目前以唯讀方式掛載。安全清理不會提供任何刪除動作。"
    }
    if isRemote {
      return
        "偵測到 \(filesystemDisplayName) 網路卷宗。Finder 垃圾桶不可用；MacStorageLens 只會提供直接刪除。這個動作不經 macOS 垃圾桶；NAS／伺服器是否另外啟用 recycle bin、快照或版本保護，取決於伺服器端設定。"
    }
    if !supportsFinderVisibleTrash {
      return
        "無法可靠確認目前掛載支援 Finder 可見垃圾桶，因此可逆清理會保持停用；重新掛載或改用完整重新掃描後可再次辨識。"
    }
    return nil
  }
}

struct CleanupMountFacts: Hashable {
  let filesystemType: String
  let isLocal: Bool?
  let isReadOnly: Bool?
  let isInternal: Bool?
  let detectionSource: String

  init(
    filesystemType: String,
    isLocal: Bool?,
    isReadOnly: Bool?,
    isInternal: Bool? = nil,
    detectionSource: String
  ) {
    self.filesystemType = filesystemType
    self.isLocal = isLocal
    self.isReadOnly = isReadOnly
    self.isInternal = isInternal
    self.detectionSource = detectionSource
  }
}

enum CleanupTargetCapabilityPolicy {
  private static let knownRemoteFilesystemTypes: Set<String> = [
    "afpfs", "cifs", "davfs", "fuse.sshfs", "nfs", "nfs4", "smbfs", "sshfs", "webdav",
  ]

  static func evaluate(
    target: ScanTarget,
    facts: CleanupMountFacts
  ) -> CleanupTargetCapabilities {
    let normalizedType = facts.filesystemType
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let knownRemote = knownRemoteFilesystemTypes.contains(normalizedType)
    let remote = facts.isLocal == false || knownRemote
    let readOnly = facts.isReadOnly == true

    let finderTrashSupported: Bool
    if target.kind == .system {
      finderTrashSupported = !readOnly
    } else if remote || readOnly {
      finderTrashSupported = false
    } else if facts.isLocal == true {
      finderTrashSupported = true
    } else {
      // If the mount could not tell us whether it is local, do not expose a
      // reversible-looking Finder action that we cannot prove is available.
      finderTrashSupported = false
    }

    return CleanupTargetCapabilities(
      filesystemType: normalizedType.isEmpty ? "UNKNOWN" : normalizedType,
      isRemote: remote,
      isReadOnly: readOnly,
      isInternalStorage: facts.isInternal,
      supportsFinderVisibleTrash: finderTrashSupported,
      supportsDirectDeletion: !readOnly,
      detectionSource: facts.detectionSource
    )
  }
}

enum CleanupTargetCapabilityResolver {
  static func resolve(target: ScanTarget) -> CleanupTargetCapabilities {
    if target.kind == .system {
      return CleanupTargetCapabilityPolicy.evaluate(
        target: target,
        facts: CleanupMountFacts(
          filesystemType: "apfs",
          isLocal: true,
          isReadOnly: false,
          isInternal: true,
          detectionSource: "system_target"
        )
      )
    }

    #if os(macOS)
      let url = URL(fileURLWithPath: target.path, isDirectory: true).standardizedFileURL
      let volumeValues = try? url.resourceValues(forKeys: [
        .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsInternalKey,
      ])

      if let facts = statfsFacts(path: target.path, isInternal: volumeValues?.volumeIsInternal) {
        return CleanupTargetCapabilityPolicy.evaluate(target: target, facts: facts)
      }

      if let values = volumeValues {
        return CleanupTargetCapabilityPolicy.evaluate(
          target: target,
          facts: CleanupMountFacts(
            filesystemType: "UNKNOWN",
            isLocal: values.volumeIsLocal,
            isReadOnly: values.volumeIsReadOnly,
            isInternal: values.volumeIsInternal,
            detectionSource: "url_resource_values"
          )
        )
      }

      return CleanupTargetCapabilityPolicy.evaluate(
        target: target,
        facts: CleanupMountFacts(
          filesystemType: "UNKNOWN",
          isLocal: nil,
          isReadOnly: nil,
          isInternal: nil,
          detectionSource: "unresolved"
        )
      )
    #else
      // Cross-platform verification does not model Finder. Treat ordinary test
      // fixtures as local and writable; macOS performs the real mount check.
      return CleanupTargetCapabilityPolicy.evaluate(
        target: target,
        facts: CleanupMountFacts(
          filesystemType: "testfs",
          isLocal: true,
          isReadOnly: false,
          isInternal: true,
          detectionSource: "non_macos_fixture"
        )
      )
    #endif
  }

  #if os(macOS)
    private static func statfsFacts(path: String, isInternal: Bool?) -> CleanupMountFacts? {
      var info = statfs()
      let result = path.withCString { statfs($0, &info) }
      guard result == 0 else { return nil }

      let filesystemType = withUnsafePointer(to: &info.f_fstypename) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) {
          String(cString: $0)
        }
      }
      let flags = UInt64(info.f_flags)
      let localFlag = UInt64(MNT_LOCAL)
      let readOnlyFlag = UInt64(MNT_RDONLY)
      return CleanupMountFacts(
        filesystemType: filesystemType,
        isLocal: (flags & localFlag) != 0,
        isReadOnly: (flags & readOnlyFlag) != 0,
        isInternal: isInternal,
        detectionSource: "statfs+volume_resource_values"
      )
    }
  #endif
}
