import Foundation

@main
struct SystemJunkKnowledgeAudit {
  private static var checks = 0

  static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    guard condition() else {
      fputs("FAIL: \(label)\n", stderr)
      exit(1)
    }
  }

  static func main() {
    // MARK: - App leftover decision

    expect(
      SystemJunkKnowledge.candidateBundleIdentifier(
        entryName: "com.example.Editor.helper",
        rootKind: .caches
      ) == "com.example.Editor",
      "known helper suffix is normalized"
    )
    expect(
      SystemJunkKnowledge.candidateBundleIdentifier(
        entryName: "com.example.Editor.helper.agent",
        rootKind: .caches
      ) == "com.example.Editor",
      "multiple helper suffixes are normalized"
    )
    expect(
      SystemJunkKnowledge.candidateBundleIdentifier(
        entryName: "com.example.Editor.savedState",
        rootKind: .savedApplicationState
      ) == "com.example.Editor",
      "saved-state suffix is normalized"
    )

    for invalid in [
      "Google", "SomeApp", "cache.db", "a", ".com.foo.App", "com..foo.App", "com.foo.App.",
      " com.foo.App ",
    ] {
      expect(
        SystemJunkKnowledge.candidateBundleIdentifier(entryName: invalid, rootKind: .caches) == nil,
        "invalid/non-bundle name is rejected: \(invalid)"
      )
    }

    for protected in [
      "com.apple.Safari", "group.com.apple.notes", "org.chromium.Chromium",
      "com.google.Keystone", "org.qt-project.Qt", "io.qt.runtime",
      "com.github.Electron", "com.electron.runtime",
    ] {
      expect(
        SystemJunkKnowledge.candidateBundleIdentifier(entryName: protected, rootKind: .webKit)
          == nil,
        "system/shared runtime is never an orphan candidate: \(protected)"
      )
    }

    expect(
      !SystemJunkKnowledge.isOrphanedAppEntry(
        entryName: "com.example.app",
        rootKind: .caches,
        installedBundleIdentifiers: ["com.example.app"]
      ),
      "installed app is not orphaned"
    )
    expect(
      SystemJunkKnowledge.isOrphanedAppEntry(
        entryName: "com.example.deadapp",
        rootKind: .caches,
        installedBundleIdentifiers: ["com.other.app"]
      ),
      "deleted app can be orphaned"
    )
    expect(
      !SystemJunkKnowledge.isOrphanedAppEntry(
        entryName: "com.parallels.desktop.helper",
        rootKind: .caches,
        installedBundleIdentifiers: ["com.parallels.desktop"]
      ),
      "helper of installed app is protected"
    )
    expect(
      !SystemJunkKnowledge.isOrphanedAppEntry(
        entryName: "com.parallels.desktop",
        rootKind: .logs,
        installedBundleIdentifiers: ["com.parallels.desktop.business"]
      ),
      "parent lineage of installed app is protected"
    )
    expect(
      !SystemJunkKnowledge.isOrphanedAppEntry(
        entryName: "COM.Example.App",
        rootKind: .caches,
        installedBundleIdentifiers: ["com.example.app"]
      ),
      "installed-app matching is case insensitive"
    )
    expect(
      SystemJunkKnowledge.isOrphanedAppEntry(
        entryName: "com.adobe.illustrator",
        rootKind: .caches,
        installedBundleIdentifiers: ["com.adobe.photoshop"]
      ),
      "same-company sibling is not treated as installed lineage"
    )

    // MARK: - Negative cache knowledge

    expect(
      SystemJunkKnowledge.shouldExcludeStandardUserCache(directoryName: "com.spotify.client"),
      "Spotify is excluded from broad user-cache cleanup"
    )
    expect(
      SystemJunkKnowledge.shouldExcludeStandardUserCache(directoryName: "ORG.GRADLE"),
      "Gradle is excluded from broad user-cache cleanup case-insensitively"
    )
    expect(
      !SystemJunkKnowledge.shouldExcludeStandardUserCache(directoryName: "com.example.cache"),
      "ordinary user cache remains eligible"
    )

    let packagePaths = Set(SystemJunkKnowledge.packageManagerCacheSpecs.map(\.relativePath))
    for expected in [
      ".npm/_cacache", ".cargo/registry/cache", ".cargo/registry/src",
      ".gradle/caches", ".gradle/daemon", ".gradle/wrapper/dists", "Library/Caches/pip",
    ] {
      expect(packagePaths.contains(expected), "package cache allowlist includes \(expected)")
    }
    expect(
      !packagePaths.contains("Library/Caches/Homebrew"),
      "raw Homebrew cache is not duplicated because brew cleanup is authoritative"
    )

    let developerPaths = SystemJunkKnowledge.developerToolCacheSpecs.map(\.relativePath)
    for expected in [
      "Library/Application Support/Cursor/Cache",
      "Library/Application Support/Cursor/CachedData",
      "Library/Application Support/Antigravity/GPUCache",
      ".claude/cache", ".claude/paste-cache", ".claude/shell-snapshots",
      ".codex/.tmp", ".codex/cache",
    ] {
      expect(developerPaths.contains(expected), "developer cache allowlist includes \(expected)")
    }
    for path in developerPaths {
      expect(
        !SystemJunkKnowledge.isForbiddenDeveloperUserData(relativePath: path),
        "developer cache allowlist must not overlap user data: \(path)"
      )
    }
    for forbidden in [
      ".claude/projects", ".claude/file-history", ".codex/sessions",
      ".codex/archived_sessions", "Library/Application Support/Cursor/User",
      "Library/Application Support/Antigravity/User", "extensions", "Docker.raw",
    ] {
      expect(
        SystemJunkKnowledge.isForbiddenDeveloperUserData(relativePath: forbidden),
        "negative developer-data policy catches \(forbidden)"
      )
    }

    // MARK: - Download residue

    let now = Date(timeIntervalSince1970: 2_000_000)
    for ext in ["crdownload", "download", "part", "partial", "tmp"] {
      expect(
        SystemJunkKnowledge.downloadResidueKind(
          pathExtension: ext,
          modificationDate: now.addingTimeInterval(-25 * 60 * 60),
          now: now
        ) == .incompleteDownload,
        "stale incomplete download is recognized: \(ext)"
      )
    }
    expect(
      SystemJunkKnowledge.downloadResidueKind(
        pathExtension: "download",
        modificationDate: now.addingTimeInterval(-2 * 60 * 60),
        now: now
      ) == nil,
      "fresh partial download is protected"
    )
    expect(
      SystemJunkKnowledge.downloadResidueKind(
        pathExtension: "pkg",
        modificationDate: now.addingTimeInterval(-8 * 24 * 60 * 60),
        now: now
      ) == .staleInstaller,
      "old installer package is recognized"
    )
    expect(
      SystemJunkKnowledge.downloadResidueKind(
        pathExtension: "dmg",
        modificationDate: now.addingTimeInterval(-8 * 24 * 60 * 60),
        now: now
      ) == .staleDiskImage,
      "old disk image is recognized"
    )

    // MARK: - Preference corruption

    let validPlist = try! PropertyListSerialization.data(
      fromPropertyList: ["enabled": true],
      format: .binary,
      options: 0
    )
    expect(!SystemJunkKnowledge.plistIsCorrupt(data: validPlist), "valid plist is protected")
    expect(
      SystemJunkKnowledge.plistIsCorrupt(data: Data([0xFF, 0x00, 0xFE, 0x01])),
      "unparseable plist is recognized as corrupt"
    )
    expect(
      SystemJunkKnowledge.preferenceDomain(fileName: "com.example.Editor.plist")
        == "com.example.Editor",
      "third-party preference domain is accepted"
    )
    for protected in [
      "com.apple.finder.plist", "group.com.apple.notes.plist", "COM.APPLE.Safari.plist",
    ] {
      expect(
        SystemJunkKnowledge.preferenceDomain(fileName: protected) == nil,
        "Apple preference domain is protected: \(protected)"
      )
    }
    expect(
      SystemJunkKnowledge.preferenceDomain(fileName: "com.example..broken.plist") == nil,
      "malformed preference domain is rejected"
    )
    expect(
      SystemJunkKnowledge.preferenceDomain(fileName: "com.example.app.txt") == nil,
      "non-plist preference file is rejected"
    )

    print("SystemJunkKnowledgeAudit: \(checks) / \(checks) passed")
  }
}
