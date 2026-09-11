# Verification

MacStorageLens 1.7.5 keeps the **re-runnable verification source** in the public repository while intentionally excluding historical generated JSON/log artifacts that contained machine-specific data or duplicated old release evidence.

## Main entry point

On macOS, run:

```text
scripts/驗證原始碼.command
```

The script performs 36 stages covering package identity, Swift parsing/formatting, compiler regression, capacity/report fixtures, cleanup policy, external-volume behavior, incremental cleanup index, UI/static contracts, System Junk rules, deletion-time revalidation, Trash Bins safety, release provenance, and a macOS release build.

## 1.7.5 verification baseline

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

The public GitHub repository is intentionally created as a **curated clean release root** rather than publishing the entire internal development Git bundle. The public provenance check therefore validates current 1.7.5 source identity and the `v1.7.5` tag when present; the old internal `v1.7.4 → v1.7.5` parent-history gate is optional and only runs when that historical tag is actually available.

## Platform limits

Cross-platform Foundation/static fixtures can run outside macOS, but AppKit/SwiftUI release linking, Finder behavior, Full Disk Access/TCC, real APFS/removable media/NAS, codesign, and notarization require a Mac.
