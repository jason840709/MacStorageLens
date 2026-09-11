from pathlib import Path

root = Path(__file__).resolve().parents[1]
models = (root / "Sources/MacStorageLens/Models.swift").read_text()
engine = (root / "Sources/MacStorageLens/CleanupEngine.swift").read_text()
view = (root / "Sources/MacStorageLens/CleanerView.swift").read_text()
index = (root / "Sources/MacStorageLens/CleanupIncrementalIndex.swift").read_text()
knowledge = (root / "Sources/MacStorageLens/SystemJunkKnowledge.swift").read_text()
metadata = (root / "Sources/MacStorageLens/AppMetadata.swift").read_text()
build = (root / "scripts/建立並啟動.command").read_text()
verify_script = (root / "scripts/驗證原始碼.command").read_text()
notices = (root / "THIRD_PARTY_NOTICES.md").read_text()

checks = {
    "scope app leftovers": "case appLeftovers" in models,
    "scope download residue": "case downloadResidue" in models,
    "scope broken preferences": "case brokenPreferences" in models,
    "scope Trash Bins": "case trashBins" in models,
    "Trash Bins rule": "case trashBinContents" in models,
    "developer cache rule": "case developerToolCacheDirectory" in models,
    "xcode previews rule": "case xcodePreviewsCache" in models,
    "app leftover scanner": "private func scanAppLeftovers" in engine,
    "download scanner": "private func scanDownloadResidue" in engine,
    "broken preferences scanner": "private func scanBrokenPreferences" in engine,
    "live leftover validation": "case .appLeftoverEntry:" in engine and "isOrphanedAppEntry" in engine,
    "live download validation": "case .incompleteDownload, .staleInstallerPackage, .staleDiskImage:" in engine,
    "live corrupt plist validation": "case .corruptPreferencePlist:" in engine and "plistIsCorrupt" in engine,
    "Apple preference guard": '"com.apple."' in knowledge and '"group.com.apple."' in knowledge,
    "shared runtime orphan guards": all(token in knowledge for token in [
        '"org.chromium."', '"com.google.keystone"', '"org.qt-project."',
        '"io.qt."', '"com.github.electron"', '"com.electron."'
    ]),
    "strict empty-component bundle parsing": "omittingEmptySubsequences: false" in knowledge,
    "safe leftover roots": all(token in knowledge for token in [
        "Library/Caches", "Library/Logs", "Library/HTTPStorages",
        "Library/Saved Application State", "Library/WebKit"
    ]),
    "no sensitive leftover roots": all(token not in knowledge for token in [
        "Library/Keychains", "Library/Containers", 'Library/Preferences"\n      case'
    ]),
    "standard-cache exclusions": all(token in knowledge for token in ["com.spotify.client", "org.gradle"]),
    "developer cache allowlist": all(token in knowledge for token in [
        ".claude/cache", ".claude/paste-cache", ".claude/shell-snapshots",
        ".codex/.tmp", ".codex/cache", "CachedProfilesData", "CachedData"
    ]),
    "developer user-data negative list": all(token in knowledge for token in [
        "/.claude/projects", "/.claude/file-history", "/.codex/sessions",
        "/.codex/archived_sessions", "/Antigravity/User", "/Cursor/User", "/extensions"
    ]),
    "package cache source-reviewed expansion": all(token in knowledge for token in [
        ".cargo/registry/src", ".gradle/daemon", ".gradle/wrapper/dists"
    ]),
    "package allowlist shared by scan and validation": (
        "SystemJunkKnowledge.packageManagerCacheURLs(home: home)" in engine
        and "private func isAllowedPackageCachePath" in engine
    ),
    "developer allowlist shared by scan and validation": (
        "SystemJunkKnowledge.developerToolCacheURLs(home: home)" in engine
        and "private func isAllowedDeveloperToolCachePath" in engine
    ),
    "download age guard": "minimumAge" in knowledge and "24 * 60 * 60" in knowledge and "7 * 24 * 60 * 60" in knowledge,
    "tmp incomplete download": '"download", "crdownload", "part", "partial", "tmp"' in knowledge,
    "move item can validate regular files": ".isRegularFileKey" in engine and "values.isDirectory == true || values.isRegularFile == true" in engine,
    "unreadable preferences fail closed": "let data = try? Data(contentsOf: item" in engine,
    "UI scope wiring": all(token in view for token in ["case .downloadResidue", "case .appLeftovers", "case .brokenPreferences"]),
    "Trash Bins scan wiring": all(token in engine for token in [
        "private func trashBinRoots", "private func scanTrashBin(",
        ".Trashes", "String(currentUserID)"
    ]),
    "Trash Bins direct-only execution": all(token in engine for token in [
        "private func directlyDeleteTrashBinItems", "validatedTrashBinRoot",
        "validatedTrashBinChild", "filemanager_remove_validated_current_user_trash_matches"
    ]),
    "Trash Bins excludes symlinks and server recycle": (
        "isSymbolicLink(at:" in engine and "NAS #recycle" in engine
        and "其他 UID" in engine
    ),
    "native profile-detail UI integration": (
        "CleanupRuleIntegrationMapCard" not in view
        and "1.7.5 清理規則整併位置" not in view
        and "CleanupProfileScopeGrid" in view
        and "model.cleanupConfiguration.requiresScope" in view
        and "UltraAggressiveOptionsStrip" in view
        and "model.setPresetOptionalCleanupScope" in view
        and "CleanupResearchReferenceNote" in view
        and "部分垃圾判定規則參考 MacSai 開源實作" in view
        and "掃描、風險分級、候選選取與刪除前重驗證均由 MacStorageLens 自行實作" in view
    ),
    "L5 optional scopes are explicit and persisted": (
        "requiresExplicitPresetOptIn" in models
        and "presetOptionalScopes" in models
        and "cleanupPresetOptionalScopes" in (root / "Sources/MacStorageLens/AppModel.swift").read_text()
        and "@Published var cleanupPresetOptionalScopes: Set<CleanupScope> = []" in (root / "Sources/MacStorageLens/AppModel.swift").read_text()
    ),
    "scan-step creation shares configuration authority": (
        "private func scopeCanAppear" in engine
        and "configuration.requiresScope(scope)" in engine
        and "case .highImpactUserData, .trashBins, .systemManagedReview:\n      return limit >= .ultraAggressive" not in engine
    ),
    "release identity 1.7.5 build 33": (
        'fallbackVersion = "1.7.5"' in metadata
        and 'fallbackBuild = "33"' in metadata
        and 'APP_VERSION="1.7.5"' in build
        and 'APP_BUILD="33"' in build
    ),
    "incremental index schema bumped": "currentSchemaVersion = 6" in index,
    "excluded broad caches filtered before sizing": (
        engine.find("shouldExcludeStandardUserCache") < engine.find("let sizes = try allocatedSizes(for: directories)")
    ),
    "verification script runs source-reviewed fixtures": all(token in verify_script for token in [
        "SystemJunkKnowledgeAudit.swift", "system_junk_integration_audit.py",
        "SystemJunkScannerFixtureAudit.swift", "SystemJunkDeveloperCacheFixtureAudit.swift",
        "SystemJunkLiveRevalidationAudit.swift", "SystemJunkDirectDeleteFixtureAudit.swift",
        "TrashBinsCleanupAudit.swift"
    ]),
    "BSD provenance notice included": (
        "MacSai-LICENSE.txt" in notices and "BSD 3-Clause" in notices
        and (root / "ThirdParty/MacSai-LICENSE.txt").exists()
    ),
}
failed = [name for name, ok in checks.items() if not ok]
if failed:
    raise SystemExit("FAIL: " + ", ".join(failed))
print(f"System junk integration static audit: {len(checks)} / {len(checks)} passed")
