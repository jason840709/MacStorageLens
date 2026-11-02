import CryptoKit
import Foundation

extension CleanupWorkbenchEngine {
  func scanFiles(
    tool: CleanupWorkbenchTool, root: URL,
    cancellation: CleanupWorkCancellation = CleanupWorkCancellation(),
    progress: Progress? = nil
  ) throws -> CleanupWorkbenchScan {
    let rootPath = try CleanupWorkbenchFileSafety.safeUserRoot(root, home: home)
    let policy = CleanupProtectionPolicy(
      home: home, activeBundleIDs: activeIdentifiers.map(Array.init))
    if let reason = policy.reason(for: rootPath, includingDescendants: false) {
      return CleanupWorkbenchScan(
        tool: tool, rootPath: rootPath,
        items: [
          CleanupWorkbenchItem(
            tool: tool, rule: "protected-location", path: rootPath, rootPath: rootPath,
            name: root.lastPathComponent, decision: .protected, reason: reason, impact: "此位置不會加入清理。"
          )
        ],
        notices: policy.notices, visitedCount: 0, complete: true, createdAt: now)
    }
    var notices = policy.notices
    var complete = true
    var readErrors = 0
    guard
      let walker = NativeFileSystem.enumerator(
        at: URL(fileURLWithPath: rootPath),
        errorHandler: { _, _ in
          readErrors += 1
          return true
        })
    else {
      throw CleanupWorkbenchError.rejected("這個位置目前無法讀取。")
    }
    let depth = rootPath.split(separator: "/").count
    let skipDirectories: Set<String> = [
      "Library", "Applications", "System", ".Trash", ".Trashes", ".git", ".svn", ".hg", ".venv",
      "venv", "env", "node_modules", ".build", ".next", "Pods", "__pycache__",
    ]
    var items: [CleanupWorkbenchItem] = []
    var files: [CleanupFileSnapshot] = []
    var identities: Set<String> = []
    var visited = 0
    var placeholders = 0
    while let url = walker.nextObject() as? URL {
      try cancellation.check()
      visited += 1
      if visited > 200_000 {
        complete = false
        notices.append("本次已檢查二十萬個項目；可改選較小的資料夾繼續。未檢查的部分不列入容量。")
        break
      }
      if visited % 128 == 0 {
        progress?(
          CleanupWorkbenchProgress(
            message: "尋找\(tool.title)", path: url.path, completed: visited, total: nil))
      }
      let name = url.lastPathComponent
      guard let snapshot = try? CleanupWorkbenchFileSafety.snapshot(url) else {
        walker.skipDescendants()
        continue
      }
      if snapshot.path.split(separator: "/").count - depth > 12 {
        walker.skipDescendants()
        complete = false
        continue
      }
      if policy.reason(for: snapshot.path, includingDescendants: false) != nil {
        walker.skipDescendants()
        continue
      }
      if tool == .projects, snapshot.isDirectory, let kind = ProjectArtifactPolicy.kind(at: url) {
        walker.skipDescendants()
        let concern = try ProjectArtifactPolicy.concern(at: url, cancellation: cancellation)
        let protection = policy.reason(for: snapshot.path)
        let blocked = concern ?? protection
        let measured =
          blocked == nil
          ? try measureSizes([URL(fileURLWithPath: snapshot.path)], cancellation: cancellation)
          : AllocatedSizeMeasurement()
        items.append(
          CleanupWorkbenchItem(
            tool: tool, rule: "project-artifact", path: snapshot.path, rootPath: rootPath,
            name: url.deletingLastPathComponent().lastPathComponent + " · " + name,
            decision: blocked == nil && measured.incompletePaths.isEmpty ? .review : .protected,
            reason: blocked ?? (measured.incompletePaths.isEmpty ? kind : "容量未能完整讀取，先保留。"),
            impact: "移到垃圾桶後需重新安裝或建置；直接修改過這個資料夾的內容也會一起移走。",
            bytes: measured.bytesByPath[snapshot.path], snapshot: snapshot))
        continue
      }
      if snapshot.isDirectory {
        if skipDirectories.contains(name) || name.hasPrefix(".") {
          walker.skipDescendants()
          continue
        }
        if tool == .projects { continue }
      }
      if tool == .projects { continue }
      guard snapshot.isRegularFile, !name.hasPrefix("."), !name.hasPrefix("._") else { continue }
      guard CleanupWorkbenchFileSafety.isDownloadedRegularFile(snapshot) else {
        placeholders += 1
        continue
      }
      if tool == .installers {
        let ext = url.pathExtension.lowercased()
        let isInstaller = ["dmg", "iso", "pkg", "mpkg", "xip", "ipsw", "sparseimage"].contains(ext)
        let isPartial = ["crdownload", "part", "partial", "download"].contains(ext)
        let age = now.timeIntervalSince(snapshot.modifiedAt)
        guard (isInstaller && age >= 7 * 86_400) || (isPartial && age >= 86_400) else { continue }
        items.append(
          CleanupWorkbenchItem(
            tool: tool, rule: isInstaller ? "old-installer" : "stale-partial", path: snapshot.path,
            rootPath: rootPath, name: name, decision: .review,
            reason: isInstaller ? "至少七天未修改的安裝檔或磁碟映像。" : "至少一天未修改的未完成下載；可能仍可續傳。",
            impact: "移到垃圾桶；之後若要安裝或續傳，可能需要重新下載。", bytes: snapshot.allocatedBytes, snapshot: snapshot)
        )
      } else if tool == .largeFiles {
        guard
          snapshot.logicalBytes >= 100 * 1024 * 1024
            || now.timeIntervalSince(snapshot.modifiedAt) >= 180 * 86_400
        else { continue }
        items.append(
          CleanupWorkbenchItem(
            tool: tool, rule: "personal-file", path: snapshot.path, rootPath: rootPath,
            name: name, decision: .review,
            reason: snapshot.logicalBytes >= 100 * 1024 * 1024
              ? "檔案大小至少 100 MiB。" : "已一百八十天未修改。",
            impact: "移到垃圾桶；清空後需從自己的備份取回。", bytes: snapshot.allocatedBytes,
            snapshot: snapshot))
      } else if tool == .duplicates, snapshot.logicalBytes >= 1024,
        identities.insert(snapshot.fileIdentity).inserted
      {
        files.append(snapshot)
      }
    }
    if tool == .duplicates {
      let compared = try duplicateItems(
        files, rootPath: rootPath, cancellation: cancellation, progress: progress)
      items = compared.items
      if compared.skipped > 0 {
        complete = false
        notices.append("有 \(compared.skipped) 個檔案在比對時變動或無法讀取，已略過，未列為重複檔案。")
      }
    }
    if readErrors > 0 {
      complete = false
      notices.append("有 \(readErrors) 個目錄讀取受限；未讀取的內容不當成空資料。")
    }
    if placeholders > 0 { notices.append("已略過 \(placeholders) 個尚未下載或未配置內容的檔案，沒有為了掃描而下載雲端資料。") }
    if !complete { notices.append("這份結果只涵蓋已完成讀取的部分。") }
    try cancellation.check()
    return CleanupWorkbenchScan(
      tool: tool, rootPath: rootPath,
      items: items.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }, notices: notices,
      visitedCount: visited, complete: complete, createdAt: now)
  }

  private func duplicateItems(
    _ files: [CleanupFileSnapshot], rootPath: String,
    cancellation: CleanupWorkCancellation, progress: Progress?
  ) throws -> (items: [CleanupWorkbenchItem], skipped: Int) {
    var candidates: [CleanupWorkbenchItem] = []
    var skipped = 0
    let sizeGroups = Dictionary(grouping: files, by: \.logicalBytes).values.filter { $0.count > 1 }
    var processed = 0
    for group in sizeGroups {
      try cancellation.check()
      var sampled: [String: [CleanupFileSnapshot]] = [:]
      for file in group {
        do {
          sampled[try contentHash(file, sampleOnly: true, cancellation: cancellation), default: []]
            .append(file)
        } catch CleanupWorkbenchError.cancelled { throw CleanupWorkbenchError.cancelled } catch {
          skipped += 1
          continue
        }
      }
      for bucket in sampled.values where bucket.count > 1 {
        var full: [String: [CleanupFileSnapshot]] = [:]
        for file in bucket {
          try cancellation.check()
          processed += 1
          progress?(
            CleanupWorkbenchProgress(
              message: "完整比對檔案內容", path: file.path, completed: processed, total: nil))
          do {
            full[try contentHash(file, cancellation: cancellation), default: []].append(file)
          } catch CleanupWorkbenchError.cancelled { throw CleanupWorkbenchError.cancelled } catch {
            skipped += 1
            continue
          }
        }
        for (hash, identical) in full where identical.count > 1 {
          let sorted = identical.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
          }
          let keeper = sorted[0]
          for file in sorted.dropFirst() {
            candidates.append(
              CleanupWorkbenchItem(
                tool: .duplicates, rule: "duplicate-content", path: file.path,
                rootPath: rootPath, name: URL(fileURLWithPath: file.path).lastPathComponent,
                decision: .review,
                reason: "完整內容相同；保留修改時間較早的一份：\(keeper.path)",
                impact: "只移除此副本並移到垃圾桶；標籤與位置可能不同，請先檢視。容量是上限估計，共享磁碟區塊可能不會立即釋放。",
                bytes: file.allocatedBytes, snapshot: file, referencePath: keeper.path,
                contentHash: hash))
          }
        }
      }
    }
    return (candidates, skipped)
  }

  func contentHash(
    _ file: CleanupFileSnapshot, sampleOnly: Bool = false,
    cancellation: CleanupWorkCancellation
  ) throws -> String {
    try cancellation.check()
    let current = try CleanupWorkbenchFileSafety.snapshot(URL(fileURLWithPath: file.path))
    guard CleanupWorkbenchFileSafety.sameFile(file, current),
      CleanupWorkbenchFileSafety.isDownloadedRegularFile(current)
    else {
      throw CleanupWorkbenchError.rejected("檔案已變更或尚未下載，已略過內容比對。")
    }
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file.path))
    defer { try? handle.close() }
    var hash = SHA256()
    if sampleOnly {
      hash.update(data: try handle.read(upToCount: 65_536) ?? Data())
      if file.logicalBytes > 65_536 {
        try handle.seek(toOffset: UInt64(max(0, file.logicalBytes - 65_536)))
        hash.update(data: try handle.read(upToCount: 65_536) ?? Data())
      }
    } else {
      while true {
        try cancellation.check()
        let bytes = try handle.read(upToCount: 1024 * 1024) ?? Data()
        if bytes.isEmpty { break }
        hash.update(data: bytes)
      }
    }
    let after = try CleanupWorkbenchFileSafety.snapshot(URL(fileURLWithPath: file.path))
    guard CleanupWorkbenchFileSafety.sameFile(file, after) else {
      throw CleanupWorkbenchError.rejected("比對期間檔案已變更，已略過。")
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
