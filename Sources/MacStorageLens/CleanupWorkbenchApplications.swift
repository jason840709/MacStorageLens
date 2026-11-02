import Foundation

extension CleanupWorkbenchEngine {
  func scanApplications(
    cancellation: CleanupWorkCancellation = CleanupWorkCancellation(),
    progress: Progress? = nil
  ) throws -> CleanupWorkbenchScan {
    let catalog = applicationCatalog(includeEmbedded: true, cancellation: cancellation)
    let protection = CleanupProtectionPolicy(
      home: home, activeBundleIDs: activeIdentifiers.map(Array.init))
    var items: [CleanupWorkbenchItem] = []
    var notices = protection.notices
    if !catalog.complete { notices.append("部分程式資料無法確認；關聯資料先保留，程式本體仍可逐項檢視。") }
    let homePath = (try? CleanupWorkbenchFileSafety.physicalPath(home)) ?? home.path
    var associatedSeen: Set<String> = []
    for (index, app) in catalog.applications.enumerated() {
      try cancellation.check()
      progress?(
        CleanupWorkbenchProgress(
          message: "查看 \(app.name) 與關聯資料", path: app.path, completed: index,
          total: catalog.applications.count))
      guard let snapshot = try? CleanupWorkbenchFileSafety.snapshot(URL(fileURLWithPath: app.path))
      else { continue }
      let reason: String?
      if app.identifier == "local.macstoragelens.app" || app.identifier.hasPrefix("com.apple.") {
        reason = "保留系統程式與磁碟透視本身。"
      } else if catalog.isRunning(app.identifier) {
        reason = "\(app.name) 仍在執行，請完全退出後再整理。"
      } else {
        reason = protection.reason(for: app.path)
      }
      // Bundle sizes are measured on request in the item preview. Listing a
      // hundred large apps should not block discovery or make cancellation wait.
      items.append(
        CleanupWorkbenchItem(
          tool: .applications, rule: "application-bundle", path: app.path,
          rootPath: URL(fileURLWithPath: app.path).deletingLastPathComponent().path,
          name: app.name, ownerName: app.name, decision: reason == nil ? .review : .protected,
          reason: reason ?? "只移除程式本體；設定與離線資料需另外選取。",
          impact: "移到垃圾桶後無法從原位置開啟；可從垃圾桶還原或重新安裝。",
          snapshot: snapshot, applicationID: app.identifier))
      let sameIDCount = catalog.applications.filter { $0.identifier == app.identifier }.count
      let possible =
        [
          "Library/Caches/" + app.identifier,
          "Library/Preferences/" + app.identifier + ".plist",
          "Library/HTTPStorages/" + app.identifier,
          "Library/Saved Application State/" + app.identifier + ".savedState",
          "Library/Application Support/" + app.identifier,
          "Library/Containers/" + app.identifier,
        ]
        + CleanupApplicationCatalog.supportFolders(identifier: app.identifier).map {
          "Library/Application Support/" + $0
        }
      for relative in possible {
        let url = home.appendingPathComponent(relative)
        guard fileManager.fileExists(atPath: url.path),
          let value = try? CleanupWorkbenchFileSafety.snapshot(url),
          associatedSeen.insert(value.path).inserted
        else { continue }
        let protected =
          protection.reason(for: value.path)
          ?? (catalog.supportOwners(at: value.path, home: home).subtracting([app.identifier])
            .isEmpty
            ? nil : "其他程式版本仍使用這個資料位置，先保留共用資料。")
          ?? (!CleanupWorkbenchFileSafety.isWithin(value.path, root: homePath)
            ? "資料指向帳號以外的位置，先保留。" : nil)
          ?? (catalog.embeddedOwners[app.identifier]?.contains(where: { $0 != app.path }) == true
            ? "其他程式內仍有同一程式的副本，先保留共用資料。" : nil)
        let block =
          reason ?? protected
          ?? (!catalog.complete
            ? "程式清單未能完整確認，關聯資料先保留。" : sameIDCount > 1 ? "同一程式仍有其他安裝副本，先保留共用的資料。" : nil)
        items.append(
          CleanupWorkbenchItem(
            tool: .applications, rule: "application-data", path: value.path,
            rootPath: homePath,
            name: app.name + " · " + url.deletingLastPathComponent().lastPathComponent + "/"
              + url.lastPathComponent,
            ownerName: app.name, decision: block == nil ? .review : .protected,
            reason: block ?? "此程式的設定或使用資料。",
            impact: "可能包含設定、登入狀態、離線文件與專案資料。只有確定不需要時才選取，會移到垃圾桶。",
            snapshot: value, referencePath: app.path, applicationID: app.identifier))
      }
    }
    notices.append("共享群組容器、鑰匙圈與系統服務不在本工具的移除範圍。")
    try cancellation.check()
    return CleanupWorkbenchScan(
      tool: .applications, rootPath: homePath, items: items,
      notices: notices, visitedCount: catalog.applications.count, complete: catalog.complete,
      createdAt: now)
  }

  func inspectItem(
    _ item: CleanupWorkbenchItem, cancellation: CleanupWorkCancellation = CleanupWorkCancellation()
  ) throws -> (Int64?, [CleanupFileSnapshot]) {
    try cancellation.check()
    guard let snapshot = try? CleanupWorkbenchFileSafety.snapshot(URL(fileURLWithPath: item.path))
    else { return (nil, []) }
    if !snapshot.isDirectory { return (snapshot.allocatedBytes, [snapshot]) }
    var children: [CleanupFileSnapshot] = []
    for child in (try? NativeFileSystem.contentsOfDirectory(at: URL(fileURLWithPath: item.path)))
      ?? []
    {
      try cancellation.check()
      if let value = try? CleanupWorkbenchFileSafety.snapshot(child) { children.append(value) }
      if children.count >= 200 { break }
    }
    let measured = try measureSizes([URL(fileURLWithPath: item.path)], cancellation: cancellation)
    return (
      measured.bytesByPath[item.path], children.sorted { $0.allocatedBytes > $1.allocatedBytes }
    )
  }
}
