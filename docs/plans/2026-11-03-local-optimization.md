# Local optimization of the existing MacStorageLens functions

The requested scope is the current overview, directory tree, and safety-tiered cleanup. Keep the SwiftPM application and Markdown report format; improve the existing behavior with local macOS evidence, without adding unrelated catalog/search products.

1. Repair native directory discovery: preserve caller-root spelling, enumerate AppleDouble files explicitly, prune packages, refuse symlink traversal and nested filesystem crossings. Keep deletion-time rule validation separate. Tests must use nonempty positive cache fixtures on APFS instead of relying on directory allocation.
2. Speed up deep report navigation with bounded directory-offset hints collected during the existing parse. Validate hints before seeking and fall back to the original section reader; persist hints with the report signature, within the existing index size limit.
3. Honor local protection configuration during sizing, candidate presentation, index reuse, and execution. Read the user's existing Mole whitelist as data; do not execute Mole cleanup scripts. Protect models, browser runtimes, declared Python/Android environments, and active-application caches. Surface protection/unreadability rather than silently treating it as empty.
4. Preserve logical vs allocated bytes and current accounting-gap semantics, especially across APFS and externally mounted NTFS. Measure the real existing reports, keep private paths/results outside the public repository, and compare before/after timings.
5. Verify all existing fixtures plus native enumeration, protection reload/forged-candidate checks, and offset-index correctness and fallback. Build and inspect the native App on this Mac before updating the installed version.

References: Mole's protections, bounded scans, and incomplete-result semantics are research ideas only; its GPL source and executables are not incorporated. MacSai's BSD source informs targeted scans, path identity, and live execution validation; preserve existing provenance notices.
