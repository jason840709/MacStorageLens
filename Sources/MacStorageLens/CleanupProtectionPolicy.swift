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
      ".cache/huggingface", ".cache/torch", ".ollama/models", ".lmstudio/models",
      ".cache/lm-studio/models", "Library/Caches/ms-playwright*",
      ".local/share/python-environments", "Library/Mobile Documents",
      "Library/CloudStorage",
    ] {
      add(home.path + "/" + relative, reason: "模型、執行環境或同步資料受到保護")
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
