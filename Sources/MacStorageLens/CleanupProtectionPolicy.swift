import Foundation

#if canImport(AppKit)
  import AppKit
#endif
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// User configuration is data, never shell code. This is an independent policy
/// implementation; no Mole scripts or GPL components are embedded or executed.
enum CleanupProtectionError: LocalizedError {
  case rejected(String)
  var errorDescription: String? {
    switch self {
    case .rejected(let message): return message
    }
  }
}

struct CleanupProtectionPolicy {
  private struct Protection {
    let components: [String]
    let reason: String
  }

  private var protections: [Protection] = []
  private var protectsFinderMetadata = false
  private var unavailable = false
  private(set) var notices: [String] = []

  init(home: URL, activeBundleIDs: [String]? = nil) {
    let home = home.standardizedFileURL
    func expanded(_ value: String) -> String {
      for prefix in ["~/", "$HOME/", "${HOME}/"] where value.hasPrefix(prefix) {
        return home.path + "/" + value.dropFirst(prefix.count)
      }
      return value
    }
    for relative in [
      ".ssh", ".gnupg", ".aws", ".kube", ".config", ".netrc", ".npmrc", ".pypirc",
      ".cache/huggingface", ".cache/torch", ".ollama/models", ".lmstudio/models",
      ".cache/lm-studio/models", "Library/Caches/ms-playwright*",
      ".local/share/python-environments", "Library/Mobile Documents",
      "Library/CloudStorage",
    ] {
      add(home.path + "/" + relative, reason: "重要設定、模型、執行環境或同步資料受到保護")
    }
    // These are stable shared entry points, including an SDK whose physical
    // location may be an external volume. Resolving aliases protects both forms.
    for path in [
      "/opt/anaconda3", "/Library/Frameworks/Python.framework",
      "/opt/homebrew/share/android-commandlinetools",
    ] {
      add(path, reason: "共用開發環境受到保護")
    }

    let whitelist = home.appendingPathComponent(".config/mole/whitelist")
    if Self.entryExists(whitelist) {
      do {
        let text = try Self.readConfiguration(whitelist)
        for raw in text.components(separatedBy: .newlines) {
          let line = raw.trimmingCharacters(in: .whitespaces)
          if line.isEmpty || line.hasPrefix("#") { continue }
          if line == "FINDER_METADATA" {
            protectsFinderMetadata = true
            continue
          }
          let path = expanded(line)
          guard Self.validAbsolutePath(path) else {
            throw CleanupProtectionError.rejected("Mole 保護清單含無法辨識的路徑")
          }
          add(path, reason: "Mole 保護清單已排除此路徑")
        }
        notices.append("已套用本機 Mole 保護清單；受保護項目不列入可清理容量。")
      } catch {
        unavailable = true
        notices.append("無法完整讀取 Mole 保護清單，暫停可執行清理：\(error.localizedDescription)")
      }
    }

    do {
      let ownPaths = try CleanupUserProtectionStore(home: home).load()
      for path in ownPaths { addLiteral(path, reason: "你已選擇保留這個位置。") }
      if !ownPaths.isEmpty { notices.append("已套用你在磁碟透視保留的 \(ownPaths.count) 個位置。") }
    } catch {
      unavailable = true
      notices.append("保留清單無法完整讀取，暫停可執行清理：\(error.localizedDescription)")
    }

    let registry = home.appendingPathComponent(".config/python/environments.json")
    if Self.entryExists(registry) {
      do {
        let text = try Self.readConfiguration(registry)
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else {
          throw CleanupProtectionError.rejected("Python 環境登錄格式錯誤")
        }
        for key in ["user_managed", "software_managed"] {
          for item in object[key] as? [[String: Any]] ?? [] {
            if let prefix = item["prefix"] as? String {
              guard Self.validAbsolutePath(prefix) else {
                throw CleanupProtectionError.rejected("Python 環境登錄路徑錯誤")
              }
              add(prefix, reason: "已登錄的 Python 執行環境受到保護")
            }
          }
        }
      } catch {
        unavailable = true
        notices.append("無法完整讀取共用環境登錄，暫停可執行清理：\(error.localizedDescription)")
      }
    }

    var bundleIDs = activeBundleIDs ?? []
    #if canImport(AppKit)
      if activeBundleIDs == nil,
        home.resolvingSymlinksInPath()
          == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
      {
        bundleIDs = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
      }
    #endif
    if !bundleIDs.isEmpty { notices.append("已保留仍在執行程式的標準快取、容器與狀態。") }
    for id in bundleIDs where !id.isEmpty && !id.contains("/") {
      for base in [
        "Library/Caches", "Library/Containers", "Library/HTTPStorages",
        "Library/Saved Application State",
      ] {
        for suffix in ["", ".*"] {
          add(home.path + "/" + base + "/" + id + suffix, reason: "程式仍在執行，暫時保留其快取與狀態")
        }
      }
    }
  }

  func reason(for path: String, includingDescendants: Bool = true) -> String? {
    if unavailable { return "保護設定無法完整讀取，已暫停清理" }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let variants = Set([url.path, url.resolvingSymlinksInPath().standardizedFileURL.path])
    if protectsFinderMetadata
      && (url.lastPathComponent == ".DS_Store" || url.lastPathComponent.hasPrefix("._"))
    {
      return "Mole 的 FINDER_METADATA 設定保護 Finder／AppleDouble 中繼資料"
    }
    for variant in variants {
      let parts = variant.split(separator: "/").map(String.init)
      for protection in protections {
        if !includingDescendants && parts.count < protection.components.count { continue }
        if zip(parts, protection.components).allSatisfy({ path, pattern in
          pattern.withCString { patternPointer in
            path.withCString { fnmatch(patternPointer, $0, 0) == 0 }
          }
        }) {
          return protection.reason
        }
      }
    }
    return nil
  }

  func rejectionReason(for candidate: CleanupCandidate) -> String? {
    guard candidate.isSelectable else { return nil }
    let paths: [String]
    switch candidate.action {
    case .moveMatchedItemsToTrash, .permanentDeleteMatchedItems:
      paths = candidate.matchedPaths
    case .managedCommand:
      paths = candidate.path.components(separatedBy: " · ")
    default:
      paths = [candidate.path]
    }
    return paths.lazy.compactMap { reason(for: $0) }.first
  }

  func validate(_ candidate: CleanupCandidate) throws {
    if let reason = rejectionReason(for: candidate) {
      throw CleanupProtectionError.rejected(reason + "：" + candidate.displayName)
    }
  }

  private mutating func addLiteral(_ path: String, reason: String) {
    let url = URL(fileURLWithPath: path)
    for variant in Set([url.path, url.resolvingSymlinksInPath().path]) {
      let components = variant.split(separator: "/").map { component in
        component.reduce(into: "") { result, character in
          if "*?[]\\".contains(character) { result.append("\\") }
          result.append(character)
        }
      }
      protections.append(Protection(components: components, reason: reason))
    }
  }

  private mutating func add(_ pattern: String, reason: String) {
    let url = URL(fileURLWithPath: pattern).standardizedFileURL
    for path in Set([url.path, url.resolvingSymlinksInPath().standardizedFileURL.path]) {
      protections.append(
        Protection(components: path.split(separator: "/").map(String.init), reason: reason))
    }
  }

  private static func validAbsolutePath(_ path: String) -> Bool {
    path.hasPrefix("/") && path.utf8.count <= 16_384
      && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      && !path.split(separator: "/").contains("..")
      && !path.contains("$") && !path.contains("`")
  }

  private static func entryExists(_ url: URL) -> Bool {
    var metadata = stat()
    return url.path.withCString { lstat($0, &metadata) == 0 } || errno != ENOENT
  }

  private static func readConfiguration(_ url: URL) throws -> String {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 1024 * 1024 else {
      throw CleanupProtectionError.rejected("保護設定不是有效的小型文字檔")
    }
    return try String(contentsOf: url, encoding: .utf8)
  }
}

struct CleanupUserProtectionStore {
  let home: URL
  var url: URL {
    home.appendingPathComponent(
      "Library/Application Support/MacStorageLens/cleanup-protection.json")
  }
  private struct Document: Codable {
    let version: Int
    let paths: [String]
  }

  func load() throws -> [String] {
    var value = stat()
    let exists = url.path.withCString { lstat($0, &value) }
    if exists != 0 && errno == ENOENT { return [] }
    guard exists == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      value.st_size <= 1024 * 1024
    else { throw CleanupProtectionError.rejected("磁碟透視的保留清單無法安全讀取。") }
    let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
    guard document.version == 1, document.paths.count <= 5000,
      document.paths.allSatisfy(Self.validPath)
    else { throw CleanupProtectionError.rejected("磁碟透視的保留清單格式有誤。") }
    return document.paths
  }

  func add(_ path: String) throws {
    guard Self.validPath(path) else { throw CleanupProtectionError.rejected("這個位置無法加入保留清單。") }
    try save(Array(Set(try load()).union([path])).sorted())
  }

  func remove(_ path: String) throws { try save(try load().filter { $0 != path }) }

  private static func validPath(_ path: String) -> Bool {
    path.hasPrefix("/") && path.utf8.count <= 16384 && !path.split(separator: "/").contains("..")
      && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }

  private func save(_ paths: [String]) throws {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw CleanupProtectionError.rejected("保留清單的儲存位置不安全。")
    }
    let data = try JSONEncoder().encode(Document(version: 1, paths: paths))
    guard data.count <= 1024 * 1024 else {
      throw CleanupProtectionError.rejected("保留清單過大，請先整理不需要的項目。")
    }
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
