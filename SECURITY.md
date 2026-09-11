# Security Policy — MacStorageLens 1.7.5

MacStorageLens analyzes storage and can perform destructive cleanup. The project therefore treats a scan result as **information**, not deletion authority.

## Safety boundaries

- Discovery, candidate classification, and deletion are separate stages.
- Candidates are revalidated immediately before execution.
- Symbolic links, package boundaries, unexpected parents, changed device/inode identity, read-only volumes, unsupported remote targets, and other rule violations fail closed.
- High-risk scopes are opt-in and are not silently enabled by upgrades.
- Finder-visible Trash and direct deletion are distinct; failure in one mode does not silently fall back to the other.
- Direct deletion removes filesystem entries immediately but is **not** secure overwrite / forensic erasure.

## Trash Bins

Trash cleanup is intentionally narrow: current-user `~/.Trash` plus validated local, writable, non-internal, non-Time-Machine external `.Trashes/<current UID>` roots. Other UIDs, whole `.Trashes` roots, remote mounts, NAS `#recycle`, symlinks, special files, and items added after candidate enumeration are excluded.

## Credentials and privacy

The source repository must not contain API keys, personal access tokens, signing private keys, `.env` secrets, or machine-specific private data. Build/signing identities are discovered locally and are not committed.

When reporting a security issue, do not paste credentials, private file contents, or destructive proof-of-concept data into a public issue. Use GitHub's private security reporting/advisory flow when available.

## Supported version

Security fixes are targeted at the current public release, **1.7.5**.
