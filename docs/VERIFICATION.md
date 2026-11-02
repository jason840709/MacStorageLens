# Verification

MacStorageLens 1.7.6 keeps the **re-runnable verification source** in the public repository while intentionally excluding historical generated JSON/log artifacts that contained machine-specific data or duplicated old release evidence.

## Main entry point

On macOS, run:

```text
scripts/驗證原始碼.command
```

The script performs the established 36 stages plus a Unicode path end-to-end fixture covering package identity, Swift parsing/formatting, compiler regression, capacity/report fixtures, cleanup policy, external-volume behavior, incremental cleanup index, UI/static contracts, System Junk rules, deletion-time revalidation, Trash Bins safety, release provenance, and a macOS release build.

## 1.7.6 acceptance on macOS 27.2

- Unicode scanner/parser/cleanup size fixture: **48 / 48 passed**, with the C-locale parent reproducing the original failure before the fix.
- Real external-volume scan through the native App, nested Chinese navigation, and selected-target report accounting: passed.
- Standalone Command Line Tools release build, App packaging, ad-hoc signature verification, launch, and macOS 14 deployment target: passed. Swift/linker warnings remain.
- Established stages: **27 passed, 8 failed, 1 not applicable**. Stage 23 requires a system report; the real acceptance scan here was an external volume. The new Unicode fixture is additional to those 36 stages.

The eight failed fixtures are `FolderCleanupAudit`, `ExternalAppleDoubleCleanupAudit`, `ApplicationCacheCanonicalPathAudit`, `SystemJunkScannerFixtureAudit`, `SystemJunkDeveloperCacheFixtureAudit`, `SystemJunkLiveRevalidationAudit`, `SystemJunkDirectDeleteFixtureAudit`, and `TrashBinsCleanupAudit`. Each failure was reproduced with source extracted from the previous public 1.7.5 ZIP on the same machine. The two AppleDouble suites had identical failed-check lists; the others stopped at the same missing-candidate/precondition checks. A minimal native Foundation enumeration probe also omitted `._` entries. These are existing acceptance limitations; this release does not claim the full cleanup suite is green.

The standard entry point stops at stage 11. Remaining stages were therefore executed independently with their original fixture sources and retained results; fixture compilation used whole-module mode to avoid repeated compilation of the same dependencies. The scanner compiler regression harness was corrected to include its existing `AppMetadata` dependency on macOS.

`LensState` names the original public `SwiftUI.State` property wrapper explicitly. This avoids the SDK 27 macro/plugin lookup in standalone Command Line Tools while preserving the App's pre-existing initialization and Binding semantics. The release does not adopt the new macro's lazy initialization behavior.

## Historical 1.7.5 verification baseline

The formal 1.7.5 handoff recorded the following key gates before this public-source cleanup:

| Gate | Result |
| --- | ---: |
| System Junk pure policy | 83 / 83 |
| System Junk static wiring | 40 / 40 |
| System Junk filesystem fixture | 23 / 23 |
| Developer / AI cache fixture | 25 / 25 |
| Deletion-time live revalidation | 6 / 6 |
| System Junk direct-delete fixture | 6 / 6 |
| Trash Bins safety fixture | 38 / 38 |
| Static/version/UI/deletion contract | 363 / 363 |
| UI enum context | 10 / 10 |
| Cleanup Incremental Index | 31 / 31 |

Additional established regression suites include Finder-path semantics, external volume cleanup, AppleDouble handling, report-guided cleanup, report presentation, scan activity timeout, and Swift 5/6 compiler checks.

## Public-repository provenance

The public GitHub repository began as a curated 1.7.5 release root. The current `provenance_audit_1_7_6.py` validates App 1.7.6 / Build 34, scanner 2.5.4, build/resource identity, and the Unicode fixture wiring. When `v1.7.6` is present, it must be an ancestor of HEAD and its runtime/build/verification tree must match the working copy. A source ZIP without `.git` explicitly skips Git-only checks.

## Unicode path regression

`UnicodePathAudit.swift` creates disposable filesystem fixtures and runs both scanner entry points from a C-locale parent. It reads the generated reports through the production parser and checks exact directory identities, nested navigation, nonzero allocated sizes, equal-length Chinese names, mixed scripts, emoji, combining characters, spaces, quotes, and `$`. It also exercises the cleanup engine's public scan API with a Chinese cache path and verifies fixture file contents remain unchanged.

Run this on macOS 27 or later to reproduce the original `du` C-locale behavior. Older supported macOS versions can still run the fixture, but their system `du` may not exhibit the original failure. Administrative TCC authorization and execution on every supported macOS version are separate acceptance checks; the fixture does not request authorization or scan real user storage.

## Platform limits

Cross-platform Foundation/static fixtures can run outside macOS, but AppKit/SwiftUI release linking, Finder behavior, Full Disk Access/TCC, real APFS/removable media/NAS, codesign, and notarization require a Mac.
