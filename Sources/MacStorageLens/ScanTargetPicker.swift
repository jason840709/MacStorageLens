import AppKit
import Foundation

enum ScanTargetPicker {
  static func chooseVolume() -> ScanTarget? {
    let panel = NSOpenPanel()
    panel.title = "選擇要掃描的磁碟"
    panel.prompt = "選擇磁碟"
    panel.message = "可選擇已掛載的外接 APFS、exFAT、NTFS 或其他磁碟。掃描只讀取檔案與容量 metadata。"
    panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    panel.treatsFilePackagesAsDirectories = false

    guard panel.runModal() == .OK, let selected = panel.url else { return nil }
    let volumeURL = mountedVolumeURL(containing: selected) ?? selected.standardizedFileURL
    guard volumeURL.path != "/" else { return .systemStorage }
    return makeTarget(url: volumeURL, kind: .volume)
  }

  static func chooseFolder() -> ScanTarget? {
    let panel = NSOpenPanel()
    panel.title = "選擇要掃描的資料夾"
    panel.prompt = "選擇資料夾"
    panel.message = "資料夾模式只把所選路徑畫成資料樹；所在磁碟的剩餘空間會另外顯示，不會冒充資料夾子項目。"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    panel.treatsFilePackagesAsDirectories = false

    guard panel.runModal() == .OK, let selected = panel.url else { return nil }
    return makeTarget(url: selected.standardizedFileURL, kind: .folder)
  }

  static func resolveMountedTarget(_ target: ScanTarget) -> ScanTarget? {
    ScanTargetResolver.resolveMountedTarget(target)
  }

  static func mountedVolumes() -> [ScanTarget] {
    let keys: Set<URLResourceKey> = [
      .volumeNameKey,
      .volumeUUIDStringKey,
    ]
    let urls =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: Array(keys),
        options: [.skipHiddenVolumes]
      ) ?? []

    var targets: [ScanTarget] = [.systemStorage]
    for url in urls where url.path != "/" && url.path != "/System/Volumes/Data" {
      guard url.path.hasPrefix("/Volumes/") else { continue }
      let target = makeTarget(url: url.standardizedFileURL, kind: .volume)
      if !targets.contains(where: { $0.path == target.path }) {
        targets.append(target)
      }
    }
    return targets.sorted { lhs, rhs in
      if lhs.kind != rhs.kind { return lhs.kind == .system }
      return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
  }

  private static func makeTarget(url: URL, kind: ScanTargetKind) -> ScanTarget {
    let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeUUIDStringKey])
    let displayName: String
    switch kind {
    case .system:
      displayName = "Macintosh HD"
    case .volume:
      let candidate = values?.volumeName ?? url.lastPathComponent
      displayName = candidate.isEmpty ? url.path : candidate
    case .folder:
      displayName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }
    return ScanTarget(
      kind: kind,
      displayName: displayName,
      path: url.path,
      volumeUUID: values?.volumeUUIDString
    )
  }

  private static func mountedVolumeURL(containing url: URL) -> URL? {
    (FileManager.default.mountedVolumeURLs(
      includingResourceValuesForKeys: nil,
      options: [.skipHiddenVolumes]
    ) ?? [])
    .map(\.standardizedFileURL)
    .filter { mount in
      mount.path == "/" || url.path == mount.path || url.path.hasPrefix(mount.path + "/")
    }
    .max { $0.path.count < $1.path.count }
  }
}
