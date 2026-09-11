# MacStorageLens Architecture

## Overview

MacStorageLens 1.7.5 separates read-only discovery, presentation, cleanup policy, and destructive execution. This prevents a storage report from becoming deletion authority.

```text
MacStorageLensApp / AppShell
        │
        ▼
      AppModel
   ┌────┴───────────────┐
   │                    │
   ▼                    ▼
Scanning / reports      Cleanup
   │                    │
ScannerLauncher         CleanerView
   │                    │
Bundled scanner         CleanupEngine / FolderCleanupEngine
wrapper + core          │
   │                    ├─ SystemJunkKnowledge
Markdown report         ├─ AppleDoubleInspector
   │                    ├─ CleanupTargetCapabilities
ReportParser            └─ CleanupIncrementalIndex
   │                         │
ReportPresentationIndex      ▼
   │                    Runtime revalidation
ReportLibrary                │
   │                    ┌────┴──────────────┐
   ▼                    ▼                   ▼
Overview / Browser      FinderVisibleTrash  Direct delete
Sunburst / CapacityMap
```

## Read-only scanner

`Resources/mac-system-storage-tree-v2.5.3.command` is the wrapper and `mac-system-storage-tree-core-v2.5.3.command` is the core scanner. `ScannerLauncher` coordinates invocation and progress parsing. The scanner produces Markdown/key-value sections consumed by `ReportParser`.

The UI does not treat unexplained APFS/accounting differences as automatically reclaimable space.

## Presentation

`ReportPresentationIndex` builds a reusable index over report sections. `CapacityMapBuilder`, `StorageBrowserView`, `OverviewView`, and `SunburstChart` turn the parsed report into drill-down views without requiring destructive operations. `ReportLibrary` retains the newest report per scan target.

## Cleanup policy

The cleanup system uses six user-facing profiles backed by `CleanupScope` and rule-specific constraints. `SystemJunkKnowledge` contains policy knowledge; `CleanupEngine` and `FolderCleanupEngine` discover candidates; `CleanupIncrementalIndex` allows safe reuse of candidate discovery while preserving runtime revalidation.

High-impact user data, Trash Bins, and system-managed review are explicit opt-ins rather than automatic consequences of selecting a version upgrade.

## Destructive execution

There are two explicit result types:

- **Finder-visible Trash** through `FinderVisibleTrash`, with destination/visibility checks.
- **Direct deletion**, used only for rules whose contract explicitly permits it and only after live validation.

The application does not implement a hidden private trash and does not silently change one deletion mode into the other.

## External volumes and remote mounts

`CleanupTargetCapabilities` and `ExternalVolumeCleanupExecutor` distinguish local/writable/removable targets from remote or read-only mounts. NAS/server recycle behavior is not presented as Finder Trash semantics.

## Third-party research

MacSai was reviewed as a source-level research reference for selected cleanup policy decisions. Its source files are not compiled into MacStorageLens. See [`MACSAI_SOURCE_REVIEW.md`](MACSAI_SOURCE_REVIEW.md) and [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).
