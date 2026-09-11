# MacSai source review → MacStorageLens cleanup integration

Reviewed: 2026-08-26

Reference repository: https://github.com/iliyami/MacSai

This is the source-review record for the cleanup changes in this package. The first exploratory pass was based partly on feature-level understanding; it was subsequently superseded by this pass, which traced actual MacSai Swift source and tests before finalizing the MacStorageLens behavior.

## How the source was reviewed

The execution environment could not complete a local `git clone` because its command-line network resolver could not reach GitHub. The source review therefore used GitHub's rendered/raw source directly, file by file, including implementation and test files. The integration was then implemented and tested locally against the MacStorageLens source tree.

No MacSai source file is compiled into MacStorageLens. The integration retains MacStorageLens' existing `CleanupEngine`, six-tier risk model, Finder-visible Trash behavior, external/NAS rules, AppleDouble handling, and deletion-time revalidation.

## Direct source links used in the review

- https://github.com/iliyami/MacSai/blob/main/Sources/MacCleanKit/OrphanedAppFiles.swift
- https://github.com/iliyami/MacSai/blob/main/Sources/MacCleanKit/SafetyGuard.swift
- https://github.com/iliyami/MacSai/blob/main/Sources/MacCleanKit/PlistJunkFilter.swift
- https://github.com/iliyami/MacSai/blob/main/Sources/MacCleanKit/AppMatching.swift
- https://github.com/iliyami/MacSai/blob/main/Sources/MacCleanKit/Categories/SimpleCategories.swift
- https://github.com/iliyami/MacSai/blob/main/Sources/MacCleanKit/Categories/DeveloperCacheCategories.swift
- https://github.com/iliyami/MacSai/blob/main/Sources/MacClean/Core/Scanner/TargetedScanner.swift
- https://github.com/iliyami/MacSai/blob/main/Sources/MacClean/Modules/SystemJunk/SystemJunkModule.swift
- https://github.com/iliyami/MacSai/blob/main/Sources/MacClean/Modules/TrashBins/TrashBinsModule.swift
- https://github.com/iliyami/MacSai/blob/main/LICENSE

Corresponding XCTest files under `Tests/` were also read for the orphan, plist, developer-cache and safety contracts. The separate Trash Bins implementation was traced through its module and targeted scanner flow; the MacStorageLens fixtures below reproduce the safety properties that materially affect this app.

## Files and behavior actually reviewed

| MacSai source/test area | What the implementation establishes | MacStorageLens decision |
| --- | --- | --- |
| `Sources/MacCleanKit/OrphanedAppFiles.swift` + orphan tests | Automatic orphan cleanup trusts strict reverse-DNS bundle IDs, strips helper suffixes, uses dotted-prefix lineage, and never flags Apple/system or shared Chromium/Keystone/Qt/Electron namespaces. Same-vendor sibling apps are *not* treated as ownership evidence. | Adopted as a pure policy rule. Added strict empty-component rejection, shared-runtime exclusions, helper normalization, case-insensitive lineage, and sibling-app regression tests. |
| `Sources/MacClean/Modules/SystemJunk/AppLeftoversScanner.swift` | Enumerates installed bundle IDs from standard app roots; if no installed IDs can be enumerated, orphan detection fails closed. Automatic leftovers are limited to Caches, Logs, HTTPStorages, Saved Application State, and WebKit. | Adopted. Existing MacStorageLens deletion-time installed-app revalidation is retained, so a scan result cannot authorize deletion after an app is reinstalled. Preferences/Containers/Keychains/Application Support are not inferred as automatic leftovers. |
| `Sources/MacCleanKit/SafetyGuard.swift` + SafetyGuard tests | Deletion has an independent safety gate; paths are re-resolved/canonicalized and protected roots are rejected. Orphan deletion has a narrow root allowlist. | Concept retained rather than copied. MacStorageLens already had separate execution validation, symlink rejection, target capability checks, NAS/external rules, and live rule revalidation. New knowledge rules are routed through that existing executor. |
| `Sources/MacCleanKit/PlistJunkFilter.swift` + tests | A preference plist is only surfaced as broken when it is provably unparsable. Apple/group Apple domains never qualify. Missing Launch Services registration is intentionally not evidence that a valid preference is junk. | Adopted. Only corrupt third-party `~/Library/Preferences/*.plist` files qualify; bytes are parsed again before deletion. |
| `Sources/MacCleanKit/Categories/SimpleCategories.swift` | User Caches excludes `com.spotify.client` and `org.gradle`; incomplete downloads include `.download`, `.crdownload`, `.part`, `.partial`, `.tmp`; Xcode includes Previews; old disk images use an age gate. | Adopted selectively. Spotify/Gradle broad-cache exclusions, `.tmp`, and Xcode Previews were added. MacStorageLens intentionally keeps a stricter 24-hour quiet period for incomplete Downloads. |
| `Sources/MacClean/Core/Scanner/TargetedScanner.swift` | Exclusions prune entire subtrees; the source explicitly documents Spotify cache as containing offline music that must not be removed by the broad cache scan. Target scanning is separate from target declarations. | Adopted as negative policy. MacStorageLens excludes Spotify/Gradle before directory-size traversal, so excluded trees do not even become broad-cache sizing inputs. |
| `Sources/MacCleanKit/Categories/DeveloperCacheCategories.swift` + tests | Package-manager, IDE, and AI cleanup is exact allowlist based. Cursor/Antigravity only target standard Electron cache directories; Claude/Codex only target cache/scratch. Tests explicitly forbid projects, history, sessions, editor `User`, extensions, and Docker data. | Adopted. Added exact Cursor/Antigravity/Claude/Codex targets and a load-bearing forbidden-user-data regression list; no recursive walk of `.claude`, `.codex`, editor `User`, extensions, or Docker storage. |
| `Sources/MacCleanKit/Constants.swift` | Defines exact cache paths including Cargo registry source, Gradle daemon/wrapper distributions, Claude/Codex cache/scratch paths, editor cache directories, and Xcode Previews. | Adopted where the target is unambiguously disposable/rebuildable. Added Cargo registry source, Gradle daemon/wrapper dists, developer/AI exact caches, and Xcode Previews. |
| `Sources/MacCleanKit/AppMatching.swift` | The uninstaller has a broad 10-level matching engine, but its default deliberately stops before company-name matching because vendor-level substring matching produced sibling-app false positives. | **Not reused for automatic orphan cleanup.** This distinction is important: broad matching can make sense when a user explicitly uninstalls a known app, but it is too permissive for unattended “find orphan junk” classification. |
| `Sources/MacClean/Core/Cleaner/CleaningEngine.swift` | Scan results do not bypass deletion safety; cleanup validates batches/items, handles missing files benignly, chunks large work, and recomputes actual directory bytes. | Architectural principle retained. MacStorageLens continues to treat scan-time classification as advisory and deletion-time validation as authority. |
| `Sources/MacClean/Modules/SystemJunk/SystemJunkModule.swift` | The current source composes more System Junk categories than the high-level marketing summary alone reveals, including package-manager, IDE, AI-tool caches and app leftovers. | Used only as a map of functionality; each integrated category was traced into its actual target/filter implementation before adoption. |
| `Sources/MacClean/Modules/TrashBins/TrashBinsModule.swift` + `TargetedScanner` | Trash Bins is a separate cleanup module rather than merely a System Junk label. It builds explicit Trash targets, including the current user and mounted-volume Trash locations, and distinguishes permission failures from a genuinely empty result. | Adopted as an independent MacStorageLens `trashBins` scope rather than hidden inside another category. It is mapped to L5/custom, current UID only, local writable external volumes only, direct-only, manual-only, with root and each matched child revalidated at execution. NAS `#recycle`, other UIDs, entire `.Trashes`, remote mounts, Time Machine and symlinks are excluded. |
| `LICENSE` | MacSai is BSD 3-Clause. | `ThirdParty/MacSai-LICENSE.txt` and `THIRD_PARTY_NOTICES.md` are included for explicit provenance/redistribution hygiene. |

## What changed in MacStorageLens after source review

### Automatic app leftovers

- Only the five safe user-Library roots are eligible.
- Reverse-DNS parsing is strict and fail-closed; leading/trailing dots, empty components, arbitrary names, and whitespace-padded names are rejected rather than normalized into eligibility.
- Helper/agent-style suffixes are normalized only after the raw name passes strict validation.
- Apple/system plus Chromium/CEF, Google Keystone, Qt, and Electron shared namespaces are never auto-classified as orphaned.
- Installed app lineage is case-insensitive and component-boundary aware; same-company siblings are not considered ownership matches.
- Installed bundle IDs are rebuilt immediately before execution. Empty enumeration fails closed.

### Broad user-cache negative knowledge

- `~/Library/Caches/com.spotify.client` is excluded from the broad cache category.
- `~/Library/Caches/org.gradle` is excluded from the broad cache category; only the exact Gradle cache paths below are considered by the package-manager category.
- These exclusions are applied before recursive size calculation.

### Exact developer/package-manager caches

Added explicit known-cache targets for:

- Cargo registry cache and registry source.
- Gradle caches, daemon state, and wrapper distributions.
- Cursor and Antigravity standard Electron cache directories only.
- Claude cache / paste-cache / shell-snapshots only.
- Codex `.tmp` / cache only.
- Xcode Previews.

Existing MacStorageLens targets such as npm, npx, pip, uv, Poetry, CocoaPods, SwiftPM, Yarn and Maven remain under its own risk tiers. Homebrew continues to use `brew cleanup` rather than a raw cache-directory deletion rule.

### Download residue and broken preferences

- Incomplete Downloads now recognize `.tmp` in addition to the existing partial-download suffixes, but MacStorageLens keeps a 24-hour quiet period before offering them.
- Old installer/disk-image candidates remain direct children of `~/Downloads`; MacSai's broader old-package scan under Application Support was not adopted.
- Preferences are never declared orphaned based on app-registration absence. Only provably corrupt non-Apple plist files qualify, and corruption is revalidated before execution.

### Trash Bins

- Added a dedicated `CleanupScope.trashBins`, `CleanupCategory.trashBins`, and `CleanupRuleID.trashBinContents`; this is not represented as an ordinary cache rule.
- The existing six-mode UI remains intact. Trash Bins appears only in L5 Ultra Aggressive or when explicitly enabled in Custom, and the new 1.7.5 integration map tells the user exactly where it lives.
- Discovery covers `~/.Trash` and `/Volumes/<local writable external>/.Trashes/<current UID>`. Production external roots must pass the existing external-volume validator; remote, read-only, internal and Time Machine volumes fail closed.
- Candidates list only exact first-level regular files/directories. Symlinks, special files, other UIDs, entire `.Trashes`, network mounts and NAS `#recycle` are excluded.
- Execution is permanent/direct-only because moving an item from Trash into another Trash would be misleading. The root and every matched child are revalidated, the root is never removed, and partial failures are logged item by item.
- Any Trash execution invalidates the incremental index's `.trashBins` coverage so the next supplemental scan re-enumerates current contents rather than trusting a stale match list.

## Explicitly *not* adopted in this pass

The following MacSai categories were reviewed at the category-composition level but deliberately not enabled in MacStorageLens because they require a different threat model or macOS-specific fixture coverage:

- Universal Binary thinning / `lipo` rewriting.
- Language resource pruning.
- Broken login-item repair.
- Document Versions cleanup.
- Deleted-user data cleanup.
- Broad system cache/log deletion requiring privilege escalation.
- Recursive temporary-directory cleanup outside the existing MacStorageLens Downloads rule.
- Broad `~/Library/Application Support/**/*.pkg` old-update deletion.
- Raw Homebrew cache deletion (MacStorageLens already prefers the package manager's authoritative `brew cleanup`).
- Uninstaller-style fuzzy/name/company matching for automatic orphan detection.

## Local verification added for this integration

The source-reviewed rules are guarded by both pure policy checks and filesystem fixtures:

- `Verification/SystemJunkKnowledgeAudit.swift` — strict bundle-ID/orphan rules, shared-runtime exclusions, cache allowlists, negative user-data policy, download ages/types, plist rules.
- `Verification/system_junk_integration_audit.py` — scanner/executor/model/index wiring contract.
- `Verification/SystemJunkScannerFixtureAudit.swift` — synthetic home fixture for orphan/shared-runtime/malformed-name/download/preference behavior.
- `Verification/SystemJunkDeveloperCacheFixtureAudit.swift` — synthetic Cursor/Antigravity/Claude/Codex/Cargo/Gradle/Xcode fixture, including forged-candidate deletion rejection for forbidden user data.
- `Verification/SystemJunkLiveRevalidationAudit.swift` — proves scan-time state does not authorize later deletion after state changes.
- `Verification/SystemJunkDirectDeleteFixtureAudit.swift` — exercises direct-delete behavior for eligible file/directory candidates without relying on Finder/AppKit.
- `Verification/TrashBinsCleanupAudit.swift` — exercises current-user and external current-UID Trash discovery, direct-only execution, root preservation, other-UID/NAS/symlink exclusion, and forged outside-root path rejection.

Full SwiftUI/AppKit linking, Finder Trash behavior, codesigning/notarization, TCC, and real APFS/NAS behavior still require a macOS machine. The Linux verification here executes the actual Foundation-based `CleanupEngine` against synthetic filesystems in addition to static/parser gates.
