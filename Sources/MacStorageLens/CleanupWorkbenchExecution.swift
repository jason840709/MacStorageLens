import Foundation

extension CleanupWorkbenchEngine {
  func executeManual(
    _ selected: [CleanupWorkbenchItem],
    cancellation: CleanupWorkCancellation = CleanupWorkCancellation(),
    progress: Progress? = nil,
    recycle: (URL) throws -> FinderVisibleTrashReceipt = { try FinderVisibleTrash.recycle($0) }
  ) throws -> CleanupWorkbenchExecution {
    try cancellation.check()
    guard selected.allSatisfy({ $0.revision == CleanupWorkbenchCoordinator.shared.revision }),
      CleanupWorkbenchCoordinator.shared.claimExecution(
        expectedRevision: selected.first?.revision ?? CleanupWorkbenchCoordinator.shared.revision)
    else {
      throw CleanupWorkbenchError.rejected("另一個清理操作正在執行，或這份預覽已過期；請重新掃描再整理。")
    }
    defer { CleanupWorkbenchCoordinator.shared.releaseExecution() }
    guard !selected.isEmpty, selected.allSatisfy(\.canSelect) else {
      throw CleanupWorkbenchError.rejected("請先選擇要整理的項目；已保護與讀取受限的項目會保留。")
    }
    // One execution plan owns aliases, ancestors and duplicate keepers. A keeper
    // inside any selected subtree invalidates the plan before the first move.
    for item in selected where item.rule == "duplicate-content" {
      guard let keeper = item.referencePath,
        !selected.contains(where: { CleanupWorkbenchFileSafety.isWithin(keeper, root: $0.path) })
      else { throw CleanupWorkbenchError.rejected("保留的原檔也在選取範圍內，請先取消它或其上層資料夾。") }
    }
    var seen: Set<String> = []
    let plan = selected.sorted {
      if ($0.rule == "application-bundle") != ($1.rule == "application-bundle") {
        return $0.rule == "application-bundle"
      }
      return $0.path.count < $1.path.count
    }.filter { item in
      guard seen.insert(item.path).inserted else { return false }
      return !selected.contains {
        $0.path != item.path && CleanupWorkbenchFileSafety.isWithin(item.path, root: $0.path)
      }
    }
    var approvedData: Set<String> = []
    var preflightFailures: [String: String] = [:]
    for item in plan where item.rule == "application-data" {
      do {
        try validateManualItem(item, selected: plan, cancellation: cancellation)
        approvedData.insert(item.id)
      } catch { preflightFailures[item.id] = error.localizedDescription }
    }
    var removedApplications: Set<String> = []
    let before = availableBytes()
    var entries: [CleanupWorkbenchExecution.Entry] = []
    for (index, item) in plan.enumerated() {
      if cancellation.isCancelled { break }
      progress?(
        CleanupWorkbenchProgress(
          message: "移到垃圾桶：\(item.name)", path: item.path, completed: index, total: plan.count))
      do {
        if let reason = preflightFailures[item.id] { throw CleanupWorkbenchError.rejected(reason) }
        if item.rule == "application-data", let reference = item.referencePath,
          plan.contains(where: { $0.rule == "application-bundle" && $0.path == reference }),
          !removedApplications.contains(reference)
        {
          throw CleanupWorkbenchError.rejected("同批選取的程式尚未成功移到垃圾桶，關聯資料先保留。")
        }
        try validateManualItem(
          item, selected: plan, cancellation: cancellation,
          removedApplicationPaths: approvedData.contains(item.id) ? removedApplications : [])
        let measuredBytes =
          item.bytes
          ?? (try? measureSizes(
            [URL(fileURLWithPath: item.path)], cancellation: cancellation))?.bytesByPath[item.path]
        if item.bytes == nil {
          try validateManualItem(
            item, selected: plan, cancellation: cancellation,
            removedApplicationPaths: approvedData.contains(item.id) ? removedApplications : [])
        }
        try cancellation.check()
        let receipt = try recycle(URL(fileURLWithPath: item.path))
        if item.rule == "application-bundle" { removedApplications.insert(item.path) }
        entries.append(
          CleanupWorkbenchExecution.Entry(
            itemID: item.id, name: item.name, path: item.path,
            removedFiles: 1, processedBytes: measuredBytes ?? 0, failures: [], receipts: [receipt],
            sizeKnown: measuredBytes != nil))
      } catch CleanupWorkbenchError.cancelled { break } catch {
        entries.append(
          CleanupWorkbenchExecution.Entry(
            itemID: item.id, name: item.name, path: item.path,
            removedFiles: 0, processedBytes: 0, failures: [error.localizedDescription], receipts: []
          ))
      }
    }
    var result = CleanupWorkbenchExecution(
      id: UUID(), createdAt: Date(), tool: selected[0].tool,
      automatic: false, entries: entries, cancelled: cancellation.isCancelled,
      availableBytesBefore: before, availableBytesAfter: availableBytes())
    do { try saveExecution(result) } catch {
      result.persistenceWarning = "本次結果未能保存，請先保留畫面上的處理結果：\(error.localizedDescription)"
    }
    return result
  }

  func validateManualItem(
    _ item: CleanupWorkbenchItem, selected: [CleanupWorkbenchItem],
    cancellation: CleanupWorkCancellation, removedApplicationPaths: Set<String> = []
  ) throws {
    try cancellation.check()
    let allowedRules: [CleanupWorkbenchTool: Set<String>] = [
      .smart: ["known-generated-cache", "unclassified-cache"],
      .projects: ["project-artifact"], .installers: ["old-installer", "stale-partial"],
      .largeFiles: ["personal-file"], .duplicates: ["duplicate-content"],
      .applications: ["application-bundle", "application-data"],
    ]
    guard allowedRules[item.tool]?.contains(item.rule) == true else {
      throw CleanupWorkbenchError.rejected("這個項目的整理方式與來源不符。")
    }
    let policy = CleanupProtectionPolicy(
      home: home, activeBundleIDs: activeIdentifiers.map(Array.init))
    if let reason = policy.reason(for: item.path) { throw CleanupWorkbenchError.rejected(reason) }
    let current = try CleanupWorkbenchFileSafety.snapshot(URL(fileURLWithPath: item.path))
    guard let previous = item.snapshot, CleanupWorkbenchFileSafety.sameFile(previous, current)
    else {
      throw CleanupWorkbenchError.rejected("這個項目在掃描後已變更，請重新掃描確認。")
    }
    let capability = CleanupTargetCapabilityResolver.resolve(
      target: ScanTarget(
        kind: .folder,
        displayName: item.name, path: item.rootPath, volumeUUID: nil))
    guard capability.supportsFinderVisibleTrash else {
      throw CleanupWorkbenchError.rejected("此位置無法移到 Finder 垃圾桶，項目已保留。")
    }
    if item.tool != .smart && item.tool != .applications {
      let root = try CleanupWorkbenchFileSafety.safeUserRoot(
        URL(fileURLWithPath: item.rootPath), home: home)
      guard root == item.rootPath, current.path != root,
        CleanupWorkbenchFileSafety.isWithin(current.path, root: root)
      else { throw CleanupWorkbenchError.rejected("項目不在這次選取的資料夾內。") }
    }
    switch item.rule {
    case "project-artifact":
      guard current.isDirectory,
        ProjectArtifactPolicy.kind(at: URL(fileURLWithPath: item.path)) != nil
      else {
        throw CleanupWorkbenchError.rejected("專案設定或建置資料已變更，先保留。")
      }
      if let concern = try ProjectArtifactPolicy.concern(
        at: URL(fileURLWithPath: item.path), cancellation: cancellation)
      {
        throw CleanupWorkbenchError.rejected(concern)
      }
      try rejectBusyProject(
        URL(fileURLWithPath: item.path).deletingLastPathComponent(), cancellation: cancellation)
    case "old-installer", "stale-partial":
      let ext = URL(fileURLWithPath: item.path).pathExtension.lowercased()
      let installer = ["dmg", "iso", "pkg", "mpkg", "xip", "ipsw", "sparseimage"].contains(ext)
      let partial = ["crdownload", "part", "partial", "download"].contains(ext)
      guard current.isRegularFile,
        (item.rule == "old-installer" && installer
          && current.modifiedAt < Date().addingTimeInterval(-7 * 86_400))
          || (item.rule == "stale-partial" && partial
            && current.modifiedAt < Date().addingTimeInterval(-86_400))
      else { throw CleanupWorkbenchError.rejected("檔案類型或最近使用時間不再符合原條件。") }
    case "personal-file":
      guard current.isRegularFile,
        current.logicalBytes >= 100 * 1024 * 1024
          || current.modifiedAt < Date().addingTimeInterval(-180 * 86_400)
      else { throw CleanupWorkbenchError.rejected("這個檔案不再符合原先的大型或舊檔案條件。") }
    case "duplicate-content":
      guard let reference = item.referencePath, let hash = item.contentHash,
        CleanupWorkbenchFileSafety.isWithin(reference, root: item.rootPath), reference != item.path,
        !selected.contains(where: { CleanupWorkbenchFileSafety.isWithin(reference, root: $0.path) })
      else { throw CleanupWorkbenchError.rejected("無法確認要保留的原檔，已保留此副本。") }
      let keeper = try CleanupWorkbenchFileSafety.snapshot(URL(fileURLWithPath: reference))
      guard keeper.fileIdentity != current.fileIdentity,
        try contentHash(keeper, cancellation: cancellation) == hash,
        try contentHash(current, cancellation: cancellation) == hash
      else { throw CleanupWorkbenchError.rejected("保留檔或副本內容已變更，請重新比對。") }
    case "application-bundle", "application-data":
      let catalog = applicationCatalog(includeEmbedded: true, cancellation: cancellation)
      guard let id = item.applicationID, CleanupApplicationCatalog.validIdentifier(id),
        id != "local.macstoragelens.app",
        !id.hasPrefix("com.apple."), !catalog.isRunning(id)
      else {
        throw CleanupWorkbenchError.rejected("程式仍在執行或屬於系統程式，已保留。")
      }
      if item.rule == "application-bundle" {
        guard catalog.applications.contains(where: { $0.path == item.path && $0.identifier == id })
        else {
          throw CleanupWorkbenchError.rejected("程式本體或識別名稱已改變。")
        }
      } else {
        let homePath = try CleanupWorkbenchFileSafety.physicalPath(home)
        guard CleanupWorkbenchFileSafety.isWithin(current.path, root: homePath),
          current.path != homePath,
          catalog.supportOwners(at: current.path, home: home).subtracting([id]).isEmpty,
          catalog.embeddedOwners[id]?.contains(where: { $0 != item.referencePath }) != true
        else { throw CleanupWorkbenchError.rejected("資料超出程式可確認的範圍，或仍被其他程式副本使用。") }
        if let reference = item.referencePath, removedApplicationPaths.contains(reference) {
          guard catalog.complete, !catalog.applications.contains(where: { $0.identifier == id })
          else {
            throw CleanupWorkbenchError.rejected("仍有其他程式副本，先保留關聯資料。")
          }
          return
        }
        guard catalog.complete, let reference = item.referencePath,
          catalog.applications.filter({ $0.identifier == id }).count == 1,
          catalog.applications.contains(where: { $0.path == reference && $0.identifier == id })
        else { throw CleanupWorkbenchError.rejected("目前仍有其他副本或無法確認資料歸屬，先保留關聯資料。") }
        let refreshed = try scanApplications(cancellation: cancellation)
        guard
          refreshed.items.contains(where: {
            $0.path == item.path && $0.rule == "application-data" && $0.applicationID == id
              && $0.canSelect
          })
        else {
          throw CleanupWorkbenchError.rejected("關聯資料的位置或保護設定已改變。")
        }
      }
    case "known-generated-cache", "unclassified-cache":
      let caches = try CleanupWorkbenchFileSafety.physicalPath(
        home.appendingPathComponent("Library/Caches"))
      let catalog = applicationCatalog()
      let known = cacheRecipes(catalog: catalog).first {
        (try? CleanupWorkbenchFileSafety.physicalPath(URL(fileURLWithPath: $0.path))) == item.path
      }
      let directCache = URL(fileURLWithPath: item.path).deletingLastPathComponent().path == caches
      guard current.isDirectory, directCache || known != nil,
        !(known.map { recipe in
          CleanupApplicationCatalog.identifiersSharingSupport(with: recipe.applicationID)
            .contains(where: { catalog.isRunning($0) })
        } ?? false)
      else { throw CleanupWorkbenchError.rejected("快取位置或程式執行狀態已改變。") }
    default: throw CleanupWorkbenchError.rejected("這個項目不支援手動整理。")
    }
  }

  func rejectBusyProject(_ project: URL, cancellation: CleanupWorkCancellation) throws {
    let result = try ProcessRunner.run(
      "/usr/sbin/lsof", ["-a", "-u", String(getuid()), "-d", "cwd", "-F", "pn"], timeout: 15,
      cancellationCheck: { cancellation.isCancelled })
    try cancellation.check()
    guard result.status == 0,
      result.stdoutString.split(separator: "\n").contains(where: {
        $0.hasPrefix("n/")
      })
    else {
      throw CleanupWorkbenchError.rejected("目前無法確認專案是否正在使用，先保留。")
    }
    let root = try CleanupWorkbenchFileSafety.physicalPath(project)
    for line in result.stdoutString.split(separator: "\n") where line.hasPrefix("n") {
      let path = String(line.dropFirst())
      if CleanupWorkbenchFileSafety.isWithin(path, root: root) {
        throw CleanupWorkbenchError.rejected("有程式正在這個專案內工作，請先結束相關工作再整理。")
      }
    }
  }
}
