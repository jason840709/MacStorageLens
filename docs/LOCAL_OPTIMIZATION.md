# Local macOS optimization review — 1.8.0

The existing overview, directory tree and cleanup remain the product scope. The
SwiftPM package still targets macOS 14, has no external package dependencies,
and reads the existing Markdown report format.

## Filesystem findings

Local validation covered an internal APFS Data volume and a writable external
volume mounted through Paragon UFSD NTFS. These filesystems do not share APFS
snapshot or clone accounting. The scanner therefore keeps its `du` allocated
size and volume-accounting difference semantics; a difference is not a cleanup
candidate. No FSEvents-based assumption is introduced for external volumes.

On current macOS, Foundation's directory view can omit AppleDouble `._` entries
and return `/private/var` URLs for a root supplied as `/var`. Cleanup now reads
raw directory entries and builds child URLs from the supplied logical root.
Traversal opens directories relative to an already-open parent, refuses symlink
traversal and filesystem crossings, and prunes packages. Permission/read errors
remain diagnostics. Ordinary download and plist rules explicitly exclude `._`
files so the dedicated AppleDouble classifier remains authoritative.

Empty APFS directories may allocate zero blocks. Positive cache fixtures now
contain real data rather than assuming empty directories consume reclaimable
space; no safety assertion was removed.

## Report navigation

During the normal parse, a bounded lookup records byte offsets for directory
rows through depth eight: at most 30,000 entries and 2 MiB of path text. A
navigation request starts from its nearest indexed ancestor. The reader verifies
that the row at the proposed offset names that ancestor; an invalid hint falls
back to sequential section reading. The same reader serves the list, chart and
report-guided cleanup.

Hints are optional and saved with the existing report signature. Presentation
index schema 3 invalidates previous presentation caches. The complete encoded
index is limited to 16 MiB; oversized payloads first drop the optional hints.
Cleanup index schema 7 rebuilds candidates under the new discovery semantics.
Reports are retained. Paths beyond the lookup budget/depth keep the existing
reader, so improvements depend on the directory and report.

A local release-mode sample of eight indexed directories per report produced
identical lists and charts between sequential and indexed readers:

| Report size | Sequential median | Indexed median |
| --- | ---: | ---: |
| 91.45 MB system report | 78.25 ms | 2.02 ms |
| 11.16 MB external NTFS report | 94.33 ms | 0.29 ms |

This measures navigation over existing reports on one Mac, not whole-volume
scan speed or a guarantee for every directory. First parsing still streams the
report; the measured runs took 5.55 s and 0.53 s respectively. Local fixture
paths, user configuration and raw diagnostic reports are not distributed.

## Cleanup protections

The optional local Mole whitelist is read as UTF-8 configuration data. Supported
patterns are absolute paths or paths starting with `~/`, `$HOME/`, `${HOME}/`;
components support shell-style filename globs through `fnmatch`, without shell
evaluation. A protected descendant also prevents removal of its parent.
`FINDER_METADATA` protects `.DS_Store` and AppleDouble entries. An existing
unreadable, malformed, oversized or dangling configuration stops executable
cleanup instead of treating it as an empty whitelist.

Built-in protections cover model caches, Playwright browsers, cloud folders,
shared Python entry points and the shared Android SDK, including physical
symlink targets. If the user's Python environment registry exists, its declared
runtime prefixes are protected. Running application bundle identifiers protect
matching standard caches, containers, HTTP storage and saved state, with exact
identifier boundaries. This does not claim to detect every busy file or every
vendor-specific Application Support layout.

Protection applies before recursive cache sizing, when presenting candidates
and reusing old candidates, and again immediately before execution. General
location traversal prunes fully protected subtrees. AppleDouble safety tiers,
resource-fork checks and final rule/path validation remain in force. A failed `du` batch is retried per directory. Only successful complete readings
count toward reclaimable size; unreadable roots are explicitly reported and
excluded without discarding unrelated successful readings. Homebrew preview and execution now both use the
normal `cleanup` retention policy; execution no longer silently adds
`--prune=all`.

## References and licensing

Research references: [Mole](https://github.com/tw93/Mole) and
[MacSai](https://github.com/iliyami/MacSai). Mole is GPL v3; no Mole source,
executables or scripts are copied or bundled. Reading a user's whitelist does
not require executing Mole. MacSai's BSD attribution remains in
[the third-party notices](../THIRD_PARTY_NOTICES.md).

## Verification

The final 41-stage source verification passed on macOS, including the native
release build. The earlier positive APFS fixtures were corrected to allocate
real bytes, and the Unicode cleanup fixture compares the same standardized
`/tmp` identity as its injected engine home. Its allocation and unchanged-file
assertions remain mandatory.

| Focused audit | Result |
| --- | ---: |
| Native discovery, package pruning, symlinks and replacement race | 16/16 |
| Directory hints, Unicode, persistence and invalid-offset fallback | 7/7 |
| Protection matching, active identifiers and invalid configuration | 12/12 |
| Late whitelist changes block old candidates at execution | 3/3 |
| Partial capacity batch recovery and size validation | 6/6 |
| Unicode scanner/parser and cleanup under a C-locale parent | 48/48 |
| Static architecture and safety contracts | 363/363 |
| Swift 5/6 compiler regressions | 14/14 |

A read-only standard-cache scan on the development Mac confirmed protected
entries are excluded and successful measurements survive unrelated permission
errors. No real cleanup was executed. The installed 1.8.0 App was checked on
the overview, a two-level Chinese directory drill-down, the rendered Sunburst,
the initial cleanup page, and About (Build 35). The existing app was backed up
before installation. Shared Python environment and entrypoint checks passed
before and after the app update; no packages or Python environments were added.
