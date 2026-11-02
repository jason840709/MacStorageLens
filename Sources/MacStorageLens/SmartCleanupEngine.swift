import Foundation

#if canImport(Darwin)
  import Darwin
#endif

struct SmartCleanupRecipe {
  let path: String
  let applicationID: String
  let applicationName: String
  var minimumAge: TimeInterval = 86_400
}

final class CleanupWorkbenchEngine {
  let home: URL
  let applicationRoots: [URL]?
  let activeIdentifiers: Set<String>?
  let now: Date
  let historyURL: URL?
  let fileManager: FileManager
  typealias Progress = (CleanupWorkbenchProgress) -> Void

  init(
    homeURL: URL? = nil, applicationRoots: [URL]? = nil,
    activeIdentifiers: Set<String>? = nil, now: Date = Date(),
    historyURL: URL? = nil, fileManager: FileManager = .default
  ) {
    home = homeURL ?? fileManager.homeDirectoryForCurrentUser
    self.applicationRoots = applicationRoots
    self.activeIdentifiers = activeIdentifiers
    self.now = now
    self.historyURL = historyURL
    self.fileManager = fileManager
  }

  func applicationCatalog(
    includeEmbedded: Bool = false, cancellation: CleanupWorkCancellation? = nil
  ) -> CleanupApplicationCatalog {
    CleanupApplicationCatalog(
      home: home, roots: applicationRoots, activeIdentifiers: activeIdentifiers,
      includeEmbedded: includeEmbedded, cancellation: cancellation)
  }

  func scanSmart(
    cancellation: CleanupWorkCancellation = CleanupWorkCancellation(),
    progress: Progress? = nil
  ) throws -> CleanupWorkbenchScan {
    try cancellation.check()
    let catalog = applicationCatalog(cancellation: cancellation)
    let policy = CleanupProtectionPolicy(
      home: home, activeBundleIDs: activeIdentifiers.map(Array.init))
    var items: [CleanupWorkbenchItem] = []
    var notices = policy.notices
    var seen: Set<String> = []
    let recipes = cacheRecipes(catalog: catalog)
    for (index, recipe) in recipes.enumerated() {
      try cancellation.check()
      guard fileManager.fileExists(atPath: recipe.path) else { continue }
      guard
        let path = try? CleanupWorkbenchFileSafety.physicalPath(URL(fileURLWithPath: recipe.path)),
        seen.insert(path).inserted
      else { continue }
      progress?(
        CleanupWorkbenchProgress(
          message: "檢查 \(recipe.applicationName) 的暫存資料", path: path, completed: index,
          total: recipes.count))
      items.append(
        try inspectCache(recipe, catalog: catalog, policy: policy, cancellation: cancellation))
    }
    let cacheRoot = home.appendingPathComponent("Library/Caches")
    if let entries = try? NativeFileSystem.contentsOfDirectory(at: cacheRoot) {
      for entry in entries {
        try cancellation.check()
        guard let snapshot = try? CleanupWorkbenchFileSafety.snapshot(entry), snapshot.isDirectory,
          !seen.contains(where: { CleanupWorkbenchFileSafety.isWithin($0, root: snapshot.path) })
        else { continue }
        let reason = policy.reason(for: snapshot.path)
        items.append(
          CleanupWorkbenchItem(
            tool: .smart, rule: "unclassified-cache", path: snapshot.path,
            rootPath: (try? CleanupWorkbenchFileSafety.physicalPath(cacheRoot)) ?? cacheRoot.path,
            name: entry.lastPathComponent, decision: reason == nil ? .review : .protected,
            reason: reason ?? "位於快取目錄，但尚未確認內容都能重建，請先檢視。",
            impact: "不會加入一鍵清理；手動整理前請確認所屬程式。", snapshot: snapshot))
      }
    } else if fileManager.fileExists(atPath: cacheRoot.path) {
      notices.append("標準快取目錄無法完整讀取，未把受限部分當成空資料。")
    }
    let diagnostics = home.appendingPathComponent("Library/Logs/DiagnosticReports")
    let diagnosticsAccess = CleanupWorkbenchFileSafety.homeDirectoryAccess(diagnostics, home: home)
    let diagnosticsRedirected =
      fileManager.fileExists(atPath: diagnostics.path)
      && diagnosticsAccess != .direct
    if diagnosticsRedirected {
      items.append(
        CleanupWorkbenchItem(
          tool: .smart, rule: "redirected-diagnostics", path: diagnostics.path,
          rootPath: diagnostics.path, name: "舊診斷紀錄",
          decision: diagnosticsAccess == .redirected ? .protected : .unavailable,
          reason: diagnosticsAccess == .redirected
            ? "診斷位置經連結指向其他目錄，無法依原用途判斷，先保留。"
            : "診斷位置無法完整讀取或確認，先保留，未當成空資料。",
          impact: "這個位置不會加入一鍵清理。"))
    }
    if !diagnosticsRedirected,
      let entries = try? NativeFileSystem.contentsOfDirectory(at: diagnostics)
    {
      let root = (try? CleanupWorkbenchFileSafety.physicalPath(diagnostics)) ?? diagnostics.path
      for entry in entries {
        try cancellation.check()
        guard ["crash", "ips", "hang", "spin", "log"].contains(entry.pathExtension.lowercased()),
          let snapshot = try? CleanupWorkbenchFileSafety.snapshot(entry),
          CleanupWorkbenchFileSafety.isDownloadedRegularFile(snapshot),
          snapshot.owner == UInt32(getuid()), snapshot.linkCount == 1,
          snapshot.modifiedAt <= now.addingTimeInterval(-30 * 86_400)
        else { continue }
        let reason = policy.reason(for: snapshot.path)
        items.append(
          CleanupWorkbenchItem(
            tool: .smart, rule: "expired-diagnostic", path: snapshot.path,
            rootPath: root, name: entry.lastPathComponent,
            decision: reason == nil ? .automatic : .protected,
            reason: reason ?? "超過三十天的當機或診斷紀錄。", impact: "清除後無法回看這份舊診斷；不影響原始文件與程式設定。",
            bytes: snapshot.allocatedBytes, snapshot: snapshot, files: [snapshot]))
      }
    }
    if !diagnosticsRedirected, fileManager.fileExists(atPath: diagnostics.path),
      (try? NativeFileSystem.contentsOfDirectory(at: diagnostics)) == nil
    {
      items.append(
        CleanupWorkbenchItem(
          tool: .smart, rule: "unavailable-diagnostics",
          path: diagnostics.path, rootPath: diagnostics.path, name: "舊診斷紀錄", decision: .unavailable,
          reason: "診斷目錄讀取受限，這部分已保留，沒有當成空資料。", impact: "可清理的其他已確認暫存不受影響。"))
      notices.append("診斷目錄未能完整讀取，請查看讀取受限分類。")
    }
    try cancellation.check()
    progress?(
      CleanupWorkbenchProgress(
        message: "已完成判斷", path: nil, completed: recipes.count, total: recipes.count))
    return CleanupWorkbenchScan(
      tool: .smart, rootPath: home.path,
      items: items.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }, notices: notices,
      visitedCount: seen.count, complete: true, createdAt: now)
  }

  func cacheRecipes(catalog: CleanupApplicationCatalog) -> [SmartCleanupRecipe] {
    let conventionalCacheIDs: Set<String> = [
      "com.google.Chrome", "com.google.Chrome.canary", "org.mozilla.firefox", "com.brave.Browser",
      "com.microsoft.edgemac", "com.hnc.Discord", "com.tinyspeck.slackmacgap",
      "com.microsoft.teams2",
      "us.zoom.xos", "com.figma.Desktop", "com.bohemiancoding.sketch3", "com.linear",
      "com.raycast.macos", "com.todoist.mac.Todoist", "com.culturedcode.ThingsMac",
      "com.readdle.PDFExpert-Mac", "com.electron.readdle.spark", "md.obsidian",
    ]
    let markers = ["Cache", "Code Cache", "GPUCache", "DawnCache", "ShaderCache", "GrShaderCache"]
    var recipes: [SmartCleanupRecipe] = [
      SmartCleanupRecipe(
        path: home.appendingPathComponent(".npm/_cacache").path,
        applicationID: "builtin.npm-download-cache", applicationName: "npm 下載快取",
        minimumAge: 30 * 86_400),
      SmartCleanupRecipe(
        path: home.appendingPathComponent(".cache/pip/http-v2").path,
        applicationID: "builtin.pip-download-cache", applicationName: "pip 下載快取",
        minimumAge: 30 * 86_400),
      SmartCleanupRecipe(
        path: home.appendingPathComponent("Library/Caches/pip/http-v2").path,
        applicationID: "builtin.pip-download-cache", applicationName: "pip 下載快取",
        minimumAge: 30 * 86_400),
      SmartCleanupRecipe(
        path: home.appendingPathComponent("Library/Caches/pip/wheels").path,
        applicationID: "builtin.pip-wheel-cache", applicationName: "Python 套件下載檔",
        minimumAge: 30 * 86_400),
      SmartCleanupRecipe(
        path: home.appendingPathComponent(".cache/pip/wheels").path,
        applicationID: "builtin.pip-wheel-cache", applicationName: "Python 套件下載檔",
        minimumAge: 30 * 86_400),
    ]
    func append(_ relative: String, app: CleanupApplicationIdentity) {
      recipes.append(
        SmartCleanupRecipe(
          path: home.appendingPathComponent(relative).path,
          applicationID: app.identifier, applicationName: app.name))
    }
    for app in catalog.applications {
      guard app.identifier != "local.macstoragelens.app" else { continue }
      if conventionalCacheIDs.contains(app.identifier) {
        append("Library/Caches/" + app.identifier, app: app)
      }
      // Only fixed vendor folders or the exact bundle identifier are used.
      // A renamed .app or arbitrary CFBundleName cannot redirect this recipe.
      let folders = Set(
        CleanupApplicationCatalog.supportFolders(identifier: app.identifier) + [app.identifier])
      if conventionalCacheIDs.contains(app.identifier)
        || !CleanupApplicationCatalog.supportFolders(identifier: app.identifier).isEmpty
      {
        for folder in folders {
          for marker in markers {
            append("Library/Application Support/\(folder)/\(marker)", app: app)
          }
        }
      }
      let browserBase: String?
      switch app.identifier {
      case "com.google.Chrome": browserBase = "Google/Chrome"
      case "com.brave.Browser": browserBase = "BraveSoftware/Brave-Browser"
      case "com.microsoft.edgemac": browserBase = "Microsoft Edge"
      default: browserBase = nil
      }
      if let browserBase {
        let base = home.appendingPathComponent("Library/Application Support/" + browserBase)
        let profiles = (try? NativeFileSystem.contentsOfDirectory(at: base)) ?? []
        for profile in profiles
        where profile.lastPathComponent == "Default"
          || profile.lastPathComponent.hasPrefix("Profile ")
        {
          for marker in markers {
            recipes.append(
              SmartCleanupRecipe(
                path: profile.appendingPathComponent(marker).path,
                applicationID: app.identifier, applicationName: app.name))
          }
        }
      }
      if app.identifier == "org.mozilla.firefox" {
        let profiles = home.appendingPathComponent("Library/Caches/Firefox/Profiles")
        for profile in (try? NativeFileSystem.contentsOfDirectory(at: profiles)) ?? [] {
          recipes.append(
            SmartCleanupRecipe(
              path: profile.appendingPathComponent("cache2").path,
              applicationID: app.identifier, applicationName: app.name))
        }
      }
    }
    return recipes
  }

  private func inspectCache(
    _ recipe: SmartCleanupRecipe, catalog: CleanupApplicationCatalog,
    policy: CleanupProtectionPolicy, cancellation: CleanupWorkCancellation
  ) throws -> CleanupWorkbenchItem {
    let url = URL(fileURLWithPath: recipe.path)
    let initial = try? CleanupWorkbenchFileSafety.snapshot(url)
    let path = initial?.path ?? recipe.path
    func item(
      _ decision: CleanupWorkbenchDecision, _ reason: String,
      _ files: [CleanupFileSnapshot] = []
    ) -> CleanupWorkbenchItem {
      CleanupWorkbenchItem(
        tool: .smart, rule: "known-generated-cache", path: path, rootPath: path,
        name: recipe.applicationName + (recipe.applicationID.hasPrefix("builtin.") ? "" : " 快取"),
        ownerName: recipe.applicationName,
        decision: decision, reason: reason,
        impact: recipe.applicationID.hasPrefix("builtin.")
          ? "只直接清除下載副本，已安裝套件與執行環境會保留；之後安裝套件可能需要重新下載。"
          : "快取會直接移除；下次使用可能需要重新下載或建立，首次載入可能較慢。",
        bytes: files.isEmpty ? nil : files.reduce(0) { $0 + $1.allocatedBytes }, snapshot: initial,
        files: files, applicationID: recipe.applicationID)
    }
    if let reason = policy.reason(for: path) { return item(.protected, reason) }
    let access = CleanupWorkbenchFileSafety.homeDirectoryAccess(url, home: home)
    if access == .unavailable {
      return item(.unavailable, "暫存位置無法完整讀取或確認，先保留，未當成空資料。")
    }
    guard access == .direct else {
      return item(.protected, "暫存位置經連結指向其他目錄，無法依原用途判斷，先保留。")
    }
    guard let initial, initial.isDirectory, initial.owner == UInt32(getuid()) else {
      return item(.unavailable, "無法確認這個位置為目前帳號可處理的暫存資料夾。")
    }
    guard
      catalog.owner(identifier: recipe.applicationID) != nil
        || recipe.applicationID.hasPrefix("builtin.")
    else {
      return item(.review, "尚未確認所屬程式，先保留。")
    }
    if CleanupApplicationCatalog.identifiersSharingSupport(with: recipe.applicationID)
      .contains(where: { catalog.isRunning($0) })
    {
      return item(.protected, "\(recipe.applicationName) 仍在執行，先保留它的暫存資料。")
    }
    var readError = false
    guard
      let enumerator = NativeFileSystem.enumerator(
        at: URL(fileURLWithPath: path),
        errorHandler: { _, _ in
          readError = true
          return true
        })
    else {
      return item(.unavailable, "目前沒有足夠權限完整讀取，先保留。")
    }
    let sourceExtensions: Set<String> = [
      "swift", "py", "rs", "c", "cpp", "h", "ipynb", "tex", "csv", "safetensors", "gguf", "ckpt",
      "pth",
    ]
    let projectMarkers: Set<String> = [
      ".git", "Package.swift", "Cargo.toml", "pyproject.toml", "package.json", "pom.xml",
    ]
    let rootDepth = path.split(separator: "/").count
    var files: [CleanupFileSnapshot] = []
    var visited = 0
    var recent = 0
    while let child = enumerator.nextObject() as? URL {
      try cancellation.check()
      visited += 1
      if visited > 100_000 || child.path.split(separator: "/").count - rootDepth > 8 {
        return item(.review, "暫存內容較多，尚未完整確認；請先檢視再整理。")
      }
      if projectMarkers.contains(child.lastPathComponent)
        || sourceExtensions.contains(child.pathExtension.lowercased())
      {
        return item(.review, "這個位置含有專案、模型或原始資料的特徵，已退出一鍵清理。")
      }
      guard let value = try? CleanupWorkbenchFileSafety.snapshot(child) else {
        enumerator.skipDescendants()
        continue
      }
      if policy.reason(for: value.path, includingDescendants: false) != nil {
        enumerator.skipDescendants()
        continue
      }
      guard value.isRegularFile else { continue }
      guard value.owner == UInt32(getuid()), value.linkCount == 1,
        CleanupWorkbenchFileSafety.isDownloadedRegularFile(value)
      else { continue }
      if value.modifiedAt > now.addingTimeInterval(-recipe.minimumAge) {
        recent += 1
        continue
      }
      files.append(value)
    }
    if readError { return item(.unavailable, "這個目錄未能完整讀取，先保留並排除容量估計。") }
    guard !files.isEmpty else { return item(.protected, "沒有符合保留期限的舊暫存檔，保留最近使用的資料。") }
    return item(
      .automatic,
      "\(files.count) 個檔案已 \(Int(recipe.minimumAge / 86_400)) 天未修改；保留 \(recent) 個較新的檔案。",
      files)
  }

  func executeAutomatic(
    _ scan: CleanupWorkbenchScan,
    cancellation: CleanupWorkCancellation = CleanupWorkCancellation(),
    progress: Progress? = nil
  ) throws -> CleanupWorkbenchExecution {
    try cancellation.check()
    guard
      scan.items.filter({ $0.decision == .automatic }).allSatisfy({
        $0.revision == CleanupWorkbenchCoordinator.shared.revision
      }),
      CleanupWorkbenchCoordinator.shared.claimExecution(
        expectedRevision: scan.items.first(where: { $0.decision == .automatic })?.revision
          ?? CleanupWorkbenchCoordinator.shared.revision)
    else {
      throw CleanupWorkbenchError.rejected("另一個清理操作正在執行，或預覽已因其他清理而過期；請重新掃描。")
    }
    defer { CleanupWorkbenchCoordinator.shared.releaseExecution() }
    guard scan.tool == .smart, scan.complete else {
      throw CleanupWorkbenchError.rejected("請先完成智慧清理掃描。")
    }
    let freeBefore = availableBytes()
    var entries: [CleanupWorkbenchExecution.Entry] = []
    for item in scan.items where item.decision == .automatic {
      if cancellation.isCancelled { break }
      var removed = 0
      var bytes: Int64 = 0
      var failures: [String] = []
      do {
        let policy = CleanupProtectionPolicy(
          home: home, activeBundleIDs: activeIdentifiers.map(Array.init))
        guard policy.reason(for: item.path) == nil else {
          throw CleanupWorkbenchError.rejected("這個位置目前受到保護，已保留。")
        }
        var currentlyApproved: Set<CleanupFileSnapshot> = []
        if item.rule == "known-generated-cache" {
          let catalog = applicationCatalog(cancellation: cancellation)
          guard item.rootPath == item.path, let appID = item.applicationID,
            !catalog.isRunning(appID),
            let recipe = cacheRecipes(catalog: catalog).first(where: {
              $0.applicationID == appID
                && (try? CleanupWorkbenchFileSafety.physicalPath(URL(fileURLWithPath: $0.path)))
                  == item.path
            }), let expectedRoot = item.snapshot,
            let currentRoot = try? CleanupWorkbenchFileSafety.snapshot(
              URL(fileURLWithPath: item.path)),
            currentRoot.device == expectedRoot.device, currentRoot.inode == expectedRoot.inode,
            currentRoot.owner == expectedRoot.owner
          else { throw CleanupWorkbenchError.rejected("程式執行狀態或暫存位置已改變，已保留。") }
          let refreshed = try inspectCache(
            recipe, catalog: catalog, policy: policy, cancellation: cancellation)
          guard refreshed.decision == .automatic else {
            throw CleanupWorkbenchError.rejected(refreshed.reason)
          }
          currentlyApproved = Set(refreshed.files)
        } else if item.rule == "expired-diagnostic" {
          let allowed = try CleanupWorkbenchFileSafety.physicalPath(
            home.appendingPathComponent("Library/Logs/DiagnosticReports"))
          guard item.rootPath == allowed, item.files.count == 1,
            CleanupWorkbenchFileSafety.isUnredirectedHomeDirectory(
              home.appendingPathComponent("Library/Logs/DiagnosticReports"), home: home),
            item.path == item.files.first?.path,
            ["crash", "ips", "hang", "spin", "log"].contains(
              URL(fileURLWithPath: item.path).pathExtension.lowercased())
          else { throw CleanupWorkbenchError.rejected("診斷紀錄的位置或類型已變更。") }
          currentlyApproved = Set(item.files)
        } else {
          throw CleanupWorkbenchError.rejected("這個項目沒有通過一鍵清理規則。")
        }
        var seen: Set<String> = []
        var latestPolicy = policy
        for (index, file) in item.files.enumerated() {
          if cancellation.isCancelled { break }
          guard seen.insert(file.path).inserted else { continue }
          do {
            if index % 16 == 0 {
              latestPolicy = CleanupProtectionPolicy(
                home: home, activeBundleIDs: activeIdentifiers.map(Array.init))
              let active = CleanupApplicationCatalog(
                home: home, roots: [], activeIdentifiers: activeIdentifiers,
                cancellation: cancellation)
              if let appID = item.applicationID,
                CleanupApplicationCatalog.identifiersSharingSupport(with: appID)
                  .contains(where: { active.isRunning($0) })
              {
                failures.append("所屬程式已開始執行，剩餘暫存已保留。")
                break
              }
            }
            guard currentlyApproved.contains(file), latestPolicy.reason(for: file.path) == nil,
              file.modifiedAt
                <= Date().addingTimeInterval(
                  item.rule == "expired-diagnostic" ? -30 * 86_400 : -86_400)
            else { throw CleanupWorkbenchError.rejected("這個檔案仍在使用、較新或已受到保護。") }
            try CleanupWorkbenchFileSafety.unlinkPlannedFile(
              file, rootPath: item.rootPath,
              rootSnapshot: item.rule == "known-generated-cache" ? item.snapshot : nil)
            removed += 1
            bytes += file.allocatedBytes
            progress?(
              CleanupWorkbenchProgress(
                message: "清除可重建的暫存", path: file.path, completed: removed, total: item.files.count))
          } catch { failures.append(error.localizedDescription) }
        }
      } catch { failures.append(error.localizedDescription) }
      entries.append(
        CleanupWorkbenchExecution.Entry(
          itemID: item.id, name: item.name, path: item.path,
          removedFiles: removed, processedBytes: bytes, failures: Array(failures.prefix(30)),
          receipts: []))
    }
    var result = CleanupWorkbenchExecution(
      id: UUID(), createdAt: Date(), tool: .smart, automatic: true,
      entries: entries, cancelled: cancellation.isCancelled,
      availableBytesBefore: freeBefore, availableBytesAfter: availableBytes())
    do { try saveExecution(result) } catch {
      result.persistenceWarning = "本次結果未能保存，請先保留畫面上的處理結果：\(error.localizedDescription)"
    }
    return result
  }

  func measureSizes(_ urls: [URL], cancellation: CleanupWorkCancellation) throws
    -> AllocatedSizeMeasurement
  {
    try cancellation.check()
    let value = try AllocatedSizeReader.measure(urls) { arguments in
      try cancellation.check()
      return try ProcessRunner.run(
        "/usr/bin/env", arguments, timeout: 240,
        cancellationCheck: { cancellation.isCancelled })
    }
    try cancellation.check()
    return value
  }

  func availableBytes() -> Int64? {
    (try? fileManager.attributesOfFileSystem(forPath: home.path)[.systemFreeSize] as? NSNumber)?
      .int64Value
  }

  func saveExecution(_ result: CleanupWorkbenchExecution) throws {
    guard let historyURL else { return }
    try fileManager.createDirectory(
      at: historyURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let values = try historyURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw CleanupWorkbenchError.rejected("操作紀錄位置不安全。")
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let destination = historyURL.appendingPathComponent(result.id.uuidString + ".json")
    try encoder.encode(result).write(to: destination, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
  }
}
