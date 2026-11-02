import Foundation

#if canImport(AppKit)
  import AppKit
#endif

struct CleanupApplicationIdentity: Hashable {
  let path: String
  let identifier: String
  let name: String
  let executable: String
}

struct CleanupApplicationCatalog {
  let applications: [CleanupApplicationIdentity]
  let complete: Bool
  let activeIdentifiers: Set<String>
  let activeNames: Set<String>
  let embeddedOwners: [String: Set<String>]

  init(
    home: URL, roots: [URL]? = nil, activeIdentifiers: Set<String>? = nil,
    includeEmbedded: Bool = false, cancellation: CleanupWorkCancellation? = nil
  ) {
    let isRealHome =
      home.resolvingSymlinksInPath()
      == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
    let roots =
      roots
      ?? (isRealHome
        ? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        : [home.appendingPathComponent("Applications")])
    var found: [CleanupApplicationIdentity] = []
    var complete = true
    for root in roots {
      if cancellation?.isCancelled == true {
        complete = false
        break
      }
      guard FileManager.default.fileExists(atPath: root.path) else { continue }
      guard
        let enumerator = NativeFileSystem.enumerator(
          at: root,
          errorHandler: { _, _ in
            complete = false
            return true
          })
      else {
        complete = false
        continue
      }
      let depth = root.path.split(separator: "/").count
      while let url = enumerator.nextObject() as? URL {
        if cancellation?.isCancelled == true {
          complete = false
          break
        }
        if url.path.split(separator: "/").count - depth > 4 {
          enumerator.skipDescendants()
          continue
        }
        if url.lastPathComponent.hasPrefix(".") {
          enumerator.skipDescendants()
          continue
        }
        guard url.pathExtension.lowercased() == "app" else { continue }
        enumerator.skipDescendants()
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let size = try? plist.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          size <= 2 * 1024 * 1024,
          let data = try? Data(contentsOf: plist),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any],
          let identifier = info["CFBundleIdentifier"] as? String, Self.validIdentifier(identifier),
          let path = try? CleanupWorkbenchFileSafety.physicalPath(url)
        else {
          complete = false
          continue
        }
        found.append(
          CleanupApplicationIdentity(
            path: path, identifier: identifier,
            name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
              ?? url.deletingPathExtension().lastPathComponent,
            executable: info["CFBundleExecutable"] as? String ?? ""))
      }
    }
    applications = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    var embedded: [String: Set<String>] = [:]
    if includeEmbedded {
      for app in found {
        if cancellation?.isCancelled == true {
          complete = false
          break
        }
        for relative in [
          "Contents/Applications", "Contents/Helpers", "Contents/Library/LoginItems",
          "Contents/MacOS",
        ] {
          let container = URL(fileURLWithPath: app.path).appendingPathComponent(relative)
          guard FileManager.default.fileExists(atPath: container.path) else { continue }
          guard
            let walker = NativeFileSystem.enumerator(
              at: container,
              errorHandler: { _, _ in
                complete = false
                return true
              })
          else {
            complete = false
            continue
          }
          var visited = 0
          while let child = walker.nextObject() as? URL {
            if cancellation?.isCancelled == true {
              complete = false
              break
            }
            visited += 1
            if visited > 20_000 {
              complete = false
              break
            }
            if child.pathExtension.lowercased() != "app" { continue }
            walker.skipDescendants()
            let plist = child.appendingPathComponent("Contents/Info.plist")
            guard let size = try? plist.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size < 2 * 1024 * 1024,
              let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let id = object["CFBundleIdentifier"] as? String, Self.validIdentifier(id)
            else {
              complete = false
              continue
            }
            embedded[id, default: []].insert(app.path)
          }
        }
      }
    }
    embeddedOwners = embedded
    self.complete = complete
    var runningIDs = activeIdentifiers ?? []
    var runningNames: Set<String> = []
    #if canImport(AppKit)
      if activeIdentifiers == nil && isRealHome {
        let running = NSWorkspace.shared.runningApplications
        runningIDs = Set(running.compactMap(\.bundleIdentifier))
        runningNames = Set(running.compactMap(\.localizedName))
      }
    #endif
    self.activeIdentifiers = runningIDs
    activeNames = runningNames
  }

  static func validIdentifier(_ value: String) -> Bool {
    let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    return pieces.count >= 2 && value.utf8.count <= 255
      && pieces.allSatisfy { piece in
        !piece.isEmpty && piece.unicodeScalars.allSatisfy { allowed.contains($0) }
      }
  }

  /// Vendor-known data locations; application display names and renamed .app
  /// filenames are never treated as proof of directory ownership.
  private static let knownSupportFolders: [String: [String]] = [
    "com.google.Chrome": ["Google/Chrome"], "com.brave.Browser": ["BraveSoftware/Brave-Browser"],
    "com.microsoft.edgemac": ["Microsoft Edge"], "org.mozilla.firefox": ["Firefox"],
    "com.hnc.Discord": ["discord"], "com.tinyspeck.slackmacgap": ["Slack"],
    "com.microsoft.teams2": ["Microsoft/MSTeams"], "us.zoom.xos": ["zoom.us"],
    "com.figma.Desktop": ["Figma"], "md.obsidian": ["obsidian"],
    "com.todesktop.230313mzl4w4u92": ["Cursor"], "com.microsoft.VSCode": ["Code"],
    "com.google.antigravity": ["Antigravity"], "com.anthropic.claudefordesktop": ["Claude"],
    "com.openai.chat": ["com.openai.chat"], "com.openai.codex": ["Codex"],
    "ai.elementlabs.lmstudio": ["LM Studio"], "com.lmstudio.LMStudio": ["LM Studio"],
  ]

  static func supportFolders(identifier: String) -> [String] {
    knownSupportFolders[identifier] ?? []
  }

  static func identifiersSharingSupport(with identifier: String) -> Set<String> {
    let folders = Set(supportFolders(identifier: identifier))
    return Set(
      knownSupportFolders.compactMap { id, paths in
        folders.isDisjoint(with: paths) ? nil : id
      }
    ).union([identifier])
  }

  func supportOwners(at path: String, home: URL) -> Set<String> {
    Set(
      applications.compactMap { app in
        let folders = Self.supportFolders(identifier: app.identifier) + [app.identifier]
        return folders.contains { folder in
          guard
            let root = try? CleanupWorkbenchFileSafety.physicalPath(
              home.appendingPathComponent("Library/Application Support/" + folder))
          else { return false }
          return CleanupWorkbenchFileSafety.isWithin(path, root: root)
        } ? app.identifier : nil
      })
  }

  func isRunning(_ identifier: String) -> Bool {
    activeIdentifiers.contains {
      $0 == identifier || $0.hasPrefix(identifier + ".") || identifier.hasPrefix($0 + ".")
    }
  }

  func owner(identifier: String) -> CleanupApplicationIdentity? {
    applications.first { $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame }
  }
}
