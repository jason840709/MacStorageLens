import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct ExternalVolumeDeletionPlan: Hashable {
  let candidateID: UUID
  let ruleID: CleanupRuleID
  let rootPath: String
  let sourcePath: String
  let expectedDevice: UInt64
  let expectedInode: UInt64
}

enum ExternalVolumeDeletionOutcomeKind: String, Hashable {
  case deleted
  case recreated
  case partial
  case missing
  case rejected
  case failed
}

struct ExternalVolumeDeletionOutcome: Hashable {
  let plan: ExternalVolumeDeletionPlan
  let kind: ExternalVolumeDeletionOutcomeKind
  let detail: String
  /// Kept for backward-compatible log aggregation. Version 1.6.6 never moves a
  /// direct-delete source through Trash, so this is always empty.
  let movedToTrashPaths: [String]
  /// Exact legacy hidden-Trash paths deleted by an explicitly selected legacy
  /// residue candidate. No unselected path is discovered or purged implicitly.
  let purgedTrashPaths: [String]
  let sourceRemoved: Bool
  let method: String
  let errorDomain: String?
  let errorCode: Int?
}

enum ExternalVolumeCleanupExecutorError: LocalizedError {
  case unsupportedPlatform
  case invalidSelection(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedPlatform:
      return "外接卷宗直接徹底刪除只支援 macOS。"
    case .invalidSelection(let message):
      return message
    }
  }
}

/// Performs irreversible deletion for the narrow external-volume rules that
/// need device/inode validation and recreation detection.
///
/// Version 1.6.6 has no Trash intermediate and no `no_log` marker. It removes
/// only paths represented by explicitly selected candidates. Older dot-named
/// Trash residues are not discovered as a hidden side effect; FolderCleanupEngine
/// must first expose each residue as a visible, direct-delete-only candidate.
enum ExternalVolumeCleanupExecutor {
  static func makePlans(
    for candidates: [CleanupCandidate],
    folderEngine: FolderCleanupEngine,
    fileManager: FileManager = .default
  ) throws -> [ExternalVolumeDeletionPlan] {
    guard !candidates.isEmpty else {
      throw ExternalVolumeCleanupExecutorError.invalidSelection("沒有選取可直接徹底刪除的項目。")
    }
    guard candidates.allSatisfy(\.supportsExternalVolumeDirectDeletion) else {
      throw ExternalVolumeCleanupExecutorError.invalidSelection(
        "此外接卷宗執行器只接受根目錄 Spotlight／FSEvents，或已明確列出的舊版隱藏垃圾桶殘留。"
      )
    }

    let roots = Set(candidates.compactMap(\.cleanupRootPath))
    guard roots.count == 1, let rootPath = roots.first else {
      throw ExternalVolumeCleanupExecutorError.invalidSelection(
        "一次直接徹底刪除只能處理同一個明確外接卷宗。"
      )
    }
    let root = try validateExternalVolumeRoot(rootPath, fileManager: fileManager)
    let rootAttributes = try fileManager.attributesOfItem(atPath: root.path)
    guard let rootDevice = uint64Attribute(rootAttributes[.systemNumber]) else {
      throw ExternalVolumeCleanupExecutorError.invalidSelection(
        "無法取得外接卷宗裝置身分：\(root.path)"
      )
    }

    return try candidates.flatMap { candidate -> [ExternalVolumeDeletionPlan] in
      guard let candidateRoot = candidate.cleanupRootPath,
        URL(fileURLWithPath: candidateRoot, isDirectory: true).standardizedFileURL.path
          == root.path,
        !candidate.matchedPaths.isEmpty
      else {
        throw ExternalVolumeCleanupExecutorError.invalidSelection(
          "候選缺少精確的外接卷宗路徑：\(candidate.displayName)"
        )
      }

      if !isLegacyTrashRule(candidate.ruleID), candidate.matchedPaths.count != 1 {
        throw ExternalVolumeCleanupExecutorError.invalidSelection(
          "卷宗根層 Spotlight／FSEvents 候選必須只有一個精確來源：\(candidate.displayName)"
        )
      }

      return try candidate.matchedPaths.map { path in
        let source: URL
        if isLegacyTrashRule(candidate.ruleID) {
          source = try validateLegacyTrashURL(
            URL(fileURLWithPath: path, isDirectory: true),
            ruleID: candidate.ruleID,
            root: root,
            fileManager: fileManager
          )
        } else {
          source = try folderEngine.validateMatchedPath(
            path,
            rule: candidate.ruleID,
            rootPath: root.path
          )
        }

        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        guard let device = uint64Attribute(attributes[.systemNumber]),
          let inode = uint64Attribute(attributes[.systemFileNumber]),
          device == rootDevice
        else {
          throw ExternalVolumeCleanupExecutorError.invalidSelection(
            "無法確認項目仍位於所選外接卷宗：\(source.path)"
          )
        }

        return ExternalVolumeDeletionPlan(
          candidateID: candidate.id,
          ruleID: candidate.ruleID,
          rootPath: root.path,
          sourcePath: source.path,
          expectedDevice: device,
          expectedInode: inode
        )
      }
    }
  }

  static func execute(
    _ plans: [ExternalVolumeDeletionPlan],
    fileManager: FileManager = .default,
    recreationDelays: [TimeInterval] = [0.20, 0.50, 1.00, 2.00]
  ) throws -> [ExternalVolumeDeletionOutcome] {
    guard !plans.isEmpty else {
      throw ExternalVolumeCleanupExecutorError.invalidSelection("沒有可執行的直接徹底刪除計畫。")
    }

    #if os(macOS)
      let roots = Set(plans.map(\.rootPath))
      guard roots.count == 1, let rootPath = roots.first else {
        throw ExternalVolumeCleanupExecutorError.invalidSelection(
          "一次直接徹底刪除只能處理同一個明確外接卷宗。"
        )
      }
      let root = try validateExternalVolumeRoot(rootPath, fileManager: fileManager)
      return plans.map {
        executeOne(
          $0,
          root: root,
          fileManager: fileManager,
          recreationDelays: recreationDelays
        )
      }
    #else
      throw ExternalVolumeCleanupExecutorError.unsupportedPlatform
    #endif
  }

  #if os(macOS)
    private static func executeOne(
      _ plan: ExternalVolumeDeletionPlan,
      root: URL,
      fileManager: FileManager,
      recreationDelays: [TimeInterval]
    ) -> ExternalVolumeDeletionOutcome {
      let source = URL(fileURLWithPath: plan.sourcePath, isDirectory: true).standardizedFileURL
      let legacy = isLegacyTrashRule(plan.ruleID)

      guard fileManager.fileExists(atPath: source.path) else {
        return outcome(
          plan,
          kind: .missing,
          detail: "來源在執行前已不存在。",
          purged: [],
          sourceRemoved: false,
          method: "none"
        )
      }

      do {
        try revalidate(plan, root: root, fileManager: fileManager)
        try fileManager.removeItem(at: source)
      } catch {
        let nsError = error as NSError
        return outcome(
          plan,
          kind: .failed,
          detail: "直接徹底刪除失敗：\(diagnostic(for: error))",
          purged: [],
          sourceRemoved: false,
          method: "app_direct_remove_failed",
          errorDomain: nsError.domain,
          errorCode: nsError.code
        )
      }

      if fileManager.fileExists(atPath: source.path) {
        let current = itemIdentity(at: source, fileManager: fileManager)
        let original = ItemIdentity(device: plan.expectedDevice, inode: plan.expectedInode)
        if current == original {
          let error = ExternalVolumeCleanupExecutorError.invalidSelection(
            "removeItem 回傳完成，但原路徑仍是相同 device／inode。"
          )
          let nsError = error as NSError
          return outcome(
            plan,
            kind: .failed,
            detail: diagnostic(for: error),
            purged: [],
            sourceRemoved: false,
            method: "app_direct_remove_unverified",
            errorDomain: nsError.domain,
            errorCode: nsError.code
          )
        }
      }

      var recreated = false
      if !legacy {
        let original = ItemIdentity(device: plan.expectedDevice, inode: plan.expectedInode)
        for delay in recreationDelays where delay >= 0 {
          Thread.sleep(forTimeInterval: delay)
          guard fileManager.fileExists(atPath: source.path) else { continue }
          if let current = itemIdentity(at: source, fileManager: fileManager), current != original {
            recreated = true
            break
          }
        }
      }

      let deletedPaths = legacy ? [source.path] : []
      let detail: String
      if legacy {
        detail = "已直接徹底刪除這個明確列出的舊版隱藏垃圾桶殘留；沒有建立另一個垃圾桶項目。"
      } else if recreated {
        detail = "舊目錄已直接徹底刪除；macOS 隨後以不同 inode 建立新的同名路徑，請重新掃描比較容量。"
      } else {
        detail = "已直接徹底刪除精確驗證的舊目錄；沒有先移入任何垃圾桶，也沒有建立 no_log 或其他隱藏標記。"
      }
      return outcome(
        plan,
        kind: recreated ? .recreated : .deleted,
        detail: detail,
        purged: deletedPaths,
        sourceRemoved: true,
        method: legacy
          ? "app_direct_remove_legacy_hidden_trash_residue"
          : "app_direct_remove_exact_external_volume"
      )
    }

    private static func revalidate(
      _ plan: ExternalVolumeDeletionPlan,
      root: URL,
      fileManager: FileManager
    ) throws {
      let source = URL(fileURLWithPath: plan.sourcePath, isDirectory: true).standardizedFileURL
      if isLegacyTrashRule(plan.ruleID) {
        _ = try validateLegacyTrashURL(
          source,
          ruleID: plan.ruleID,
          root: root,
          fileManager: fileManager
        )
      } else {
        let expectedName: String
        switch plan.ruleID {
        case .folderSpotlightMetadata: expectedName = ".Spotlight-V100"
        case .folderFSEventsMetadata: expectedName = ".fseventsd"
        default:
          throw ExternalVolumeCleanupExecutorError.invalidSelection(
            "規則不支援外接卷宗直接刪除。"
          )
        }
        guard source.lastPathComponent == expectedName,
          source.deletingLastPathComponent().standardizedFileURL.path == root.path,
          fileManager.fileExists(atPath: source.path)
        else {
          throw ExternalVolumeCleanupExecutorError.invalidSelection(
            "來源已不存在或不再是卷宗根層精確項目：\(source.path)"
          )
        }
        let values = try source.resourceValues(forKeys: [
          .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true,
          values.isPackage != true,
          source.resolvingSymlinksInPath().standardizedFileURL.path == source.path
        else {
          throw ExternalVolumeCleanupExecutorError.invalidSelection(
            "來源已變成符號連結、套件或非一般資料夾：\(source.path)"
          )
        }
      }

      guard let identity = itemIdentity(at: source, fileManager: fileManager),
        identity.device == plan.expectedDevice,
        identity.inode == plan.expectedInode
      else {
        throw ExternalVolumeCleanupExecutorError.invalidSelection(
          "來源 device／inode 已在掃描後改變：\(source.path)"
        )
      }
      let rootAttributes = try fileManager.attributesOfItem(atPath: root.path)
      guard let rootDevice = uint64Attribute(rootAttributes[.systemNumber]),
        rootDevice == identity.device
      else {
        throw ExternalVolumeCleanupExecutorError.invalidSelection(
          "來源不再位於所選外接卷宗裝置。"
        )
      }
    }

  #endif

  private static func validateLegacyTrashURL(
    _ candidate: URL,
    ruleID: CleanupRuleID,
    root: URL,
    fileManager: FileManager
  ) throws -> URL {
    let requiredBase: String
    switch ruleID {
    case .folderLegacySpotlightTrashResidue: requiredBase = ".Spotlight-V100"
    case .folderLegacyFSEventsTrashResidue: requiredBase = ".fseventsd"
    default:
      throw ExternalVolumeCleanupExecutorError.invalidSelection(
        "不是舊版隱藏垃圾桶殘留規則。"
      )
    }

    let url = candidate.standardizedFileURL
    let uid = String(getuid())
    let allowedParents = [
      root
        .appendingPathComponent(".Trashes", isDirectory: true)
        .appendingPathComponent(uid, isDirectory: true)
        .standardizedFileURL,
      root.appendingPathComponent(".Trash", isDirectory: true).standardizedFileURL,
    ]
    let parent = url.deletingLastPathComponent().standardizedFileURL
    guard allowedParents.contains(where: { $0.path == parent.path }) else {
      throw ExternalVolumeCleanupExecutorError.invalidSelection(
        "殘留不在所選卷宗的精確 Finder 管理垃圾桶直接子層：\(url.path)"
      )
    }
    guard isAllowedLegacyTrashName(url.lastPathComponent, requiredBase: requiredBase),
      !containsControlCharacters(url.path),
      fileManager.fileExists(atPath: url.path)
    else {
      throw ExternalVolumeCleanupExecutorError.invalidSelection(
        "殘留名稱或路徑不符合規則：\(url.path)"
      )
    }
    let values = try url.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
    ])
    guard values.isDirectory == true, values.isSymbolicLink != true,
      values.isPackage != true,
      url.resolvingSymlinksInPath().standardizedFileURL.path == url.path
    else {
      throw ExternalVolumeCleanupExecutorError.invalidSelection(
        "殘留不是可驗證的一般資料夾：\(url.path)"
      )
    }
    let rootAttributes = try fileManager.attributesOfItem(atPath: root.path)
    let itemAttributes = try fileManager.attributesOfItem(atPath: url.path)
    guard let rootDevice = uint64Attribute(rootAttributes[.systemNumber]),
      let itemDevice = uint64Attribute(itemAttributes[.systemNumber]),
      rootDevice == itemDevice
    else {
      throw ExternalVolumeCleanupExecutorError.invalidSelection(
        "殘留不在所選外接卷宗裝置上：\(url.path)"
      )
    }
    return url
  }

  static func isAllowedLegacyTrashName(_ name: String, requiredBase: String) -> Bool {
    if name == requiredBase { return true }
    let prefix = requiredBase + " "
    guard name.hasPrefix(prefix) else { return false }
    let suffix = name.dropFirst(prefix.count)
    return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber || $0 == "-" }
  }

  static func isLegacyTrashRule(_ ruleID: CleanupRuleID) -> Bool {
    ruleID == .folderLegacySpotlightTrashResidue
      || ruleID == .folderLegacyFSEventsTrashResidue
  }

  static func validateExternalVolumeRoot(
    _ path: String,
    fileManager: FileManager,
    volumesRootURL: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
  ) throws -> URL {
    let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let volumesRoot = volumesRootURL.standardizedFileURL
    guard root.path != volumesRoot.path,
      root.deletingLastPathComponent().standardizedFileURL.path == volumesRoot.path,
      !containsControlCharacters(root.path)
    else {
      throw ExternalVolumeCleanupExecutorError.invalidSelection(
        "直接徹底刪除只允許 \(volumesRoot.path) 下的一層外接卷宗根目錄：\(root.path)"
      )
    }

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw ExternalVolumeCleanupExecutorError.invalidSelection("外接卷宗已不存在：\(root.path)")
    }
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true,
      root.resolvingSymlinksInPath().standardizedFileURL.path == root.path
    else {
      throw ExternalVolumeCleanupExecutorError.invalidSelection(
        "外接卷宗根目錄已變更或是符號連結：\(root.path)"
      )
    }

    #if os(macOS)
      // Production always uses /Volumes. A non-standard root is an explicit
      // dependency-injection seam used by filesystem fixtures; it never occurs
      // in the App's normal initializer.
      guard volumesRoot.path == "/Volumes" else { return root }

      let volumeValues = try root.resourceValues(forKeys: [
        .isVolumeKey, .volumeURLKey, .volumeIsReadOnlyKey, .volumeIsLocalKey,
        .volumeIsInternalKey,
      ])
      guard volumeValues.isVolume == true else {
        throw ExternalVolumeCleanupExecutorError.invalidSelection(
          "所選位置不是卷宗掛載根目錄：\(root.path)"
        )
      }
      guard volumeValues.volumeIsReadOnly != true else {
        throw ExternalVolumeCleanupExecutorError.invalidSelection("外接卷宗是唯讀的：\(root.path)")
      }
      guard volumeValues.volumeIsLocal == true, volumeValues.volumeIsInternal != true else {
        throw ExternalVolumeCleanupExecutorError.invalidSelection(
          "直接徹底刪除只允許本機掛載、非內置的外接卷宗：\(root.path)"
        )
      }
      guard
        let volumeURL = volumeValues.volume?.resolvingSymlinksInPath().standardizedFileURL,
        volumeURL.path == root.path
      else {
        throw ExternalVolumeCleanupExecutorError.invalidSelection(
          "所選位置不是卷宗掛載根目錄：\(root.path)"
        )
      }
      if looksLikeTimeMachineDestination(root, fileManager: fileManager) {
        throw ExternalVolumeCleanupExecutorError.invalidSelection(
          "Time Machine 備份卷宗不允許直接刪除 Spotlight 或 FSEvents：\(root.path)"
        )
      }
    #endif
    return root
  }

  private struct ItemIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
  }

  private static func itemIdentity(
    at url: URL,
    fileManager: FileManager
  ) -> ItemIdentity? {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let device = uint64Attribute(attributes[.systemNumber]),
      let inode = uint64Attribute(attributes[.systemFileNumber])
    else { return nil }
    return ItemIdentity(device: device, inode: inode)
  }

  private static func looksLikeTimeMachineDestination(
    _ root: URL,
    fileManager: FileManager
  ) -> Bool {
    ["Backups.backupdb", ".com.apple.timemachine.donotpresent"].contains {
      fileManager.fileExists(atPath: root.appendingPathComponent($0).path)
    }
  }

  private static func containsControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }

  private static func uint64Attribute(_ value: Any?) -> UInt64? {
    if let number = value as? NSNumber { return number.uint64Value }
    if let value = value as? UInt64 { return value }
    if let value = value as? UInt { return UInt64(value) }
    if let value = value as? Int, value >= 0 { return UInt64(value) }
    return nil
  }

  private static func diagnostic(for error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain) \(nsError.code)：\(nsError.localizedDescription)"
  }

  private static func outcome(
    _ plan: ExternalVolumeDeletionPlan,
    kind: ExternalVolumeDeletionOutcomeKind,
    detail: String,
    purged: [String],
    sourceRemoved: Bool,
    method: String,
    errorDomain: String? = nil,
    errorCode: Int? = nil
  ) -> ExternalVolumeDeletionOutcome {
    ExternalVolumeDeletionOutcome(
      plan: plan,
      kind: kind,
      detail: detail,
      movedToTrashPaths: [],
      purgedTrashPaths: purged,
      sourceRemoved: sourceRemoved,
      method: method,
      errorDomain: errorDomain,
      errorCode: errorCode
    )
  }
}
