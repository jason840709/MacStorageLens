import Foundation

/// Small, pure policy layer for knowledge-based cleanup rules.
///
/// The important contract here is intentionally conservative: a path is only
/// considered disposable when its *location* and its *shape* both match a
/// narrow rule. Filesystem deletion is still revalidated by `CleanupEngine`
/// immediately before execution.
///
/// Several rules are independently implemented from safety patterns verified
/// in MacSai's source/tests. Keep filesystem discovery out of this type so the
/// policy can be tested without granting disk access.
enum SystemJunkKnowledge {
  enum LeftoverRootKind: String, CaseIterable {
    case caches
    case logs
    case httpStorages
    case savedApplicationState
    case webKit

    var relativePath: String {
      switch self {
      case .caches: return "Library/Caches"
      case .logs: return "Library/Logs"
      case .httpStorages: return "Library/HTTPStorages"
      case .savedApplicationState: return "Library/Saved Application State"
      case .webKit: return "Library/WebKit"
      }
    }

    var displayName: String {
      switch self {
      case .caches: return "Caches"
      case .logs: return "Logs"
      case .httpStorages: return "HTTPStorages"
      case .savedApplicationState: return "Saved Application State"
      case .webKit: return "WebKit"
      }
    }
  }

  enum DownloadResidueKind: Hashable {
    case incompleteDownload
    case staleInstaller
    case staleDiskImage

    var minimumAge: TimeInterval {
      switch self {
      // MacSai treats several partial extensions as incomplete immediately.
      // MacStorageLens deliberately adds a 24-hour quiet-period guard so an
      // active resumable download is less likely to be offered for cleanup.
      case .incompleteDownload: return 24 * 60 * 60
      case .staleInstaller, .staleDiskImage: return 7 * 24 * 60 * 60
      }
    }
  }

  enum KnownCacheSafety: Hashable {
    /// Cache/scratch content that is expected to be recreated or redownloaded.
    case rebuildable
    /// Still cache-like, but may affect offline/dev workflows enough to warrant
    /// an Aggressive-tier presentation in MacStorageLens.
    case cautious
  }

  struct KnownCacheSpec: Hashable {
    let relativePath: String
    let displayName: String
    let reason: String
    let safety: KnownCacheSafety
  }

  private static let incompleteExtensions: Set<String> = [
    "download", "crdownload", "part", "partial", "tmp",
  ]
  private static let installerExtensions: Set<String> = ["pkg", "mpkg"]
  private static let diskImageExtensions: Set<String> = ["dmg", "iso", "sparseimage"]

  /// Apple/system preference domains are never candidates even when the plist
  /// cannot be parsed. Valid third-party preferences are also never inferred
  /// to be junk merely because the app cannot be found.
  private static let protectedPreferencePrefixes = [
    "com.apple.", "group.com.apple.", "apple.", "system.",
  ]

  /// Bundle-id namespaces that must never be auto-classified as orphaned app
  /// data. In addition to Apple/system domains, the list covers shared runtimes
  /// and updaters that can legitimately remain while many different apps use
  /// them (Chromium/CEF, Google Keystone, Qt, Electron).
  private static let orphanNeverFlagPrefixes = [
    "com.apple.", "group.com.apple.", "apple.", "system.",
    "org.chromium.", "com.google.keystone", "org.qt-project.", "io.qt.",
    "com.github.electron", "com.electron.",
  ]

  /// Helper components commonly created underneath a parent application's
  /// bundle identifier. These are stripped only after the raw identifier shape
  /// has passed strict reverse-DNS validation.
  private static let helperSuffixes = [
    ".helper", ".agent", ".daemon", ".launcher", ".updater", ".framework",
    ".xpc", ".findersync", ".quicklook", ".shareextension", ".widget",
    ".loginitem", ".service",
  ]

  /// MacSai explicitly excludes these from its broad User Caches category.
  /// Preserve that negative knowledge rather than treating every top-level
  /// `~/Library/Caches` directory as equivalent.
  static let standardUserCacheExcludedNames: Set<String> = [
    "com.spotify.client", "org.gradle",
  ]

  /// Exact package-manager cache allowlist. This intentionally does not include
  /// Homebrew's cache because MacStorageLens already uses `brew cleanup` as the
  /// safer authoritative cleanup mechanism for Homebrew.
  static let packageManagerCacheSpecs: [KnownCacheSpec] = [
    KnownCacheSpec(
      relativePath: ".npm/_cacache", displayName: "npm 內容快取",
      reason: "npm 的 content-addressable 下載快取。", safety: .rebuildable),
    KnownCacheSpec(
      relativePath: ".npm/_npx", displayName: "npx 執行快取",
      reason: "npx 下載的臨時工具與套件。", safety: .cautious),
    KnownCacheSpec(
      relativePath: ".cache/pip", displayName: "pip 下載快取",
      reason: "pip wheel 與 HTTP cache。", safety: .rebuildable),
    KnownCacheSpec(
      relativePath: "Library/Caches/pip", displayName: "pip 下載快取",
      reason: "pip wheel 與 HTTP cache。", safety: .rebuildable),
    KnownCacheSpec(
      relativePath: ".cache/uv", displayName: "uv 套件快取",
      reason: "uv 下載與建置快取。", safety: .rebuildable),
    KnownCacheSpec(
      relativePath: ".cache/pypoetry", displayName: "Poetry 快取",
      reason: "Poetry 套件與 metadata 快取。", safety: .rebuildable),
    KnownCacheSpec(
      relativePath: ".gradle/caches", displayName: "Gradle caches",
      reason: "Gradle 相依套件與建置快取。", safety: .rebuildable),
    KnownCacheSpec(
      relativePath: ".gradle/daemon", displayName: "Gradle daemon cache",
      reason: "Gradle daemon 的可重建工作狀態；清理後 daemon 需要重新啟動。", safety: .cautious),
    KnownCacheSpec(
      relativePath: ".gradle/wrapper/dists", displayName: "Gradle wrapper distributions",
      reason: "Gradle Wrapper 下載的發行版本，可在需要時重新下載。", safety: .rebuildable),
    KnownCacheSpec(
      relativePath: ".cargo/registry/cache", displayName: "Cargo registry cache",
      reason: "Rust crates 下載封存。", safety: .rebuildable),
    KnownCacheSpec(
      relativePath: ".cargo/registry/src", displayName: "Cargo registry sources",
      reason: "由 crates 封存解出的 registry source cache，可重新展開或下載。", safety: .rebuildable),
    KnownCacheSpec(
      relativePath: ".cargo/git/db", displayName: "Cargo Git cache",
      reason: "Cargo 的 Git dependency cache。", safety: .rebuildable),
    KnownCacheSpec(
      relativePath: "Library/Caches/CocoaPods", displayName: "CocoaPods cache",
      reason: "CocoaPods 下載快取。", safety: .rebuildable),
    KnownCacheSpec(
      relativePath: "Library/Caches/org.swift.swiftpm", displayName: "SwiftPM cache",
      reason: "Swift Package Manager 下載與 metadata cache。", safety: .rebuildable),
    KnownCacheSpec(
      relativePath: "Library/Caches/Yarn", displayName: "Yarn cache",
      reason: "Yarn 套件下載快取。", safety: .rebuildable),
    KnownCacheSpec(
      relativePath: ".cache/yarn", displayName: "Yarn cache",
      reason: "Yarn 套件下載快取。", safety: .rebuildable),
    KnownCacheSpec(
      relativePath: ".yarn/berry/cache", displayName: "Yarn Berry global cache",
      reason: "Yarn Berry 的壓縮套件 cache；離線建置可能依賴它。", safety: .cautious),
    KnownCacheSpec(
      relativePath: ".m2/repository", displayName: "Maven local repository",
      reason: "多數為可重新下載的 Maven artifacts，但也可能包含只在本機 install 的套件。",
      safety: .cautious),
  ]

  /// Exact IDE/AI-tool cache-only paths verified against MacSai's declarations
  /// and negative safety tests. Do not replace this allowlist with a recursive
  /// walk of `.claude`, `.codex`, Cursor `User`, or editor extensions.
  static let developerToolCacheSpecs: [KnownCacheSpec] = {
    var specs: [KnownCacheSpec] = []
    for editor in ["Antigravity", "Cursor"] {
      for cacheName in ["Cache", "Code Cache", "GPUCache", "CachedData", "CachedProfilesData"] {
        specs.append(
          KnownCacheSpec(
            relativePath: "Library/Application Support/\(editor)/\(cacheName)",
            displayName: "\(editor) · \(cacheName)",
            reason: "VS Code／Electron 系編輯器的標準 cache 目錄；User 設定與 extensions 明確排除。",
            safety: .rebuildable
          ))
      }
    }
    specs.append(contentsOf: [
      KnownCacheSpec(
        relativePath: ".claude/cache", displayName: "Claude cache",
        reason: "Claude 的 cache 目錄；projects、file-history 等使用者資料不在 allowlist。",
        safety: .rebuildable),
      KnownCacheSpec(
        relativePath: ".claude/paste-cache", displayName: "Claude paste cache",
        reason: "Claude 的 paste cache；不掃描 projects 或歷史資料。", safety: .rebuildable),
      KnownCacheSpec(
        relativePath: ".claude/shell-snapshots", displayName: "Claude shell snapshots",
        reason: "Claude 的 shell scratch snapshots；不擴大到其他 .claude 內容。", safety: .rebuildable),
      KnownCacheSpec(
        relativePath: ".codex/.tmp", displayName: "Codex temporary cache",
        reason: "Codex 的明確 temporary 目錄；sessions 不在 allowlist。", safety: .rebuildable),
      KnownCacheSpec(
        relativePath: ".codex/cache", displayName: "Codex cache",
        reason: "Codex 的 cache 目錄；sessions 與 archived_sessions 明確排除。", safety: .rebuildable),
    ])
    return specs
  }()

  /// Load-bearing negative policy mirrored from MacSai's developer-cache tests.
  /// The scanner is allowlist-based, but this list is kept public to the local
  /// verification fixture so future target additions fail loudly if they drift
  /// into user data.
  static let developerUserDataForbiddenFragments = [
    "/.claude/projects", "/.claude/file-history",
    "/.codex/sessions", "/.codex/archived_sessions",
    "/extensions", "/Antigravity/User", "/Cursor/User",
    "com.docker.docker", "Docker.raw",
  ]

  static func leftoverRoots(home: URL) -> [(LeftoverRootKind, URL)] {
    LeftoverRootKind.allCases.map { kind in
      (kind, home.appendingPathComponent(kind.relativePath, isDirectory: true).standardizedFileURL)
    }
  }

  static func shouldExcludeStandardUserCache(directoryName: String) -> Bool {
    let lower = directoryName.lowercased()
    return standardUserCacheExcludedNames.contains { lower == $0.lowercased() }
  }

  static func packageManagerCacheURLs(home: URL) -> [(KnownCacheSpec, URL)] {
    cacheURLs(home: home, specs: packageManagerCacheSpecs)
  }

  static func developerToolCacheURLs(home: URL) -> [(KnownCacheSpec, URL)] {
    cacheURLs(home: home, specs: developerToolCacheSpecs)
  }

  private static func cacheURLs(
    home: URL,
    specs: [KnownCacheSpec]
  ) -> [(KnownCacheSpec, URL)] {
    specs.map { spec in
      (
        spec,
        home.appendingPathComponent(spec.relativePath, isDirectory: true).standardizedFileURL
      )
    }
  }

  static func candidateBundleIdentifier(
    entryName rawName: String,
    rootKind: LeftoverRootKind
  ) -> String? {
    var name = rawName
    guard isBundleIdentifierLike(name) else { return nil }

    let rawLower = name.lowercased()
    guard !orphanNeverFlagPrefixes.contains(where: { rawLower == $0 || rawLower.hasPrefix($0) })
    else { return nil }

    // Saved Application State names normally append `.savedState`; normalize it
    // for the user-facing identity after validating the original entry shape.
    if rootKind == .savedApplicationState,
      name.lowercased().hasSuffix(".savedstate")
    {
      name.removeLast(".savedState".count)
    }

    var normalized = name
    var changed = true
    while changed {
      changed = false
      let lower = normalized.lowercased()
      for suffix in helperSuffixes where lower.hasSuffix(suffix) && normalized.count > suffix.count
      {
        normalized.removeLast(suffix.count)
        changed = true
        break
      }
    }

    guard isBundleIdentifierLike(normalized) else { return nil }
    let lower = normalized.lowercased()
    guard !orphanNeverFlagPrefixes.contains(where: { lower == $0 || lower.hasPrefix($0) }) else {
      return nil
    }
    return normalized
  }

  static func isOrphanedAppEntry(
    entryName: String,
    rootKind: LeftoverRootKind,
    installedBundleIdentifiers: Set<String>
  ) -> Bool {
    guard let identifier = candidateBundleIdentifier(entryName: entryName, rootKind: rootKind)
    else {
      return false
    }
    return !belongsToInstalledApplication(
      identifier,
      installedBundleIdentifiers: installedBundleIdentifiers
    )
  }

  static func belongsToInstalledApplication(
    _ candidateIdentifier: String,
    installedBundleIdentifiers: Set<String>
  ) -> Bool {
    let candidate = candidateIdentifier.lowercased()
    for installedIdentifier in installedBundleIdentifiers {
      let installed = installedIdentifier.lowercased()
      if candidate == installed { return true }
      if candidate.hasPrefix(installed + ".") { return true }
      if installed.hasPrefix(candidate + ".") { return true }
    }
    return false
  }

  static func downloadResidueKind(
    pathExtension: String,
    modificationDate: Date,
    now: Date = Date()
  ) -> DownloadResidueKind? {
    let ext = pathExtension.lowercased()
    let kind: DownloadResidueKind
    if incompleteExtensions.contains(ext) {
      kind = .incompleteDownload
    } else if installerExtensions.contains(ext) {
      kind = .staleInstaller
    } else if diskImageExtensions.contains(ext) {
      kind = .staleDiskImage
    } else {
      return nil
    }

    guard now.timeIntervalSince(modificationDate) >= kind.minimumAge else { return nil }
    return kind
  }

  static func isProtectedPreferenceIdentifier(_ identifier: String) -> Bool {
    let lower = identifier.lowercased()
    return protectedPreferencePrefixes.contains(where: { lower == $0 || lower.hasPrefix($0) })
  }

  static func preferenceDomain(fileName: String) -> String? {
    guard fileName.lowercased().hasSuffix(".plist") else { return nil }
    let domain = String(fileName.dropLast(".plist".count))
    guard isBundleIdentifierLike(domain), !isProtectedPreferenceIdentifier(domain) else {
      return nil
    }
    return domain
  }

  static func plistIsCorrupt(data: Data) -> Bool {
    do {
      _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
      return false
    } catch {
      return true
    }
  }

  static func isForbiddenDeveloperUserData(relativePath: String) -> Bool {
    let normalized = "/" + relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let lower = normalized.lowercased()
    return developerUserDataForbiddenFragments.contains { lower.contains($0.lowercased()) }
  }

  private static func isBundleIdentifierLike(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
    return value.allSatisfy {
      $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
    }
  }
}
