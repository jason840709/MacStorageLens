# Security Policy — MacStorageLens 2.0.0

MacStorageLens analyzes storage and can perform destructive cleanup. The project therefore treats a scan result as **information**, not deletion authority.

## Safety boundaries

- Discovery, candidate classification, and deletion are separate stages.
- Candidates are revalidated immediately before execution.
- Symbolic links, package boundaries, unexpected parents, changed device/inode identity, read-only volumes, unsupported remote targets, and other rule violations fail closed.
- High-risk scopes are opt-in and are not silently enabled by upgrades.
- Finder-visible Trash and direct deletion are distinct; failure in one mode does not silently fall back to the other.
- Direct deletion removes filesystem entries immediately but is **not** secure overwrite / forensic erasure.

## One-click cleanup and manual tools

One-click cleanup performs a fresh scan, then directly removes eligible regular files from known application caches, package download caches and old diagnostic reports. It does not use Trash or ask for a second confirmation. Application cache files must be at least one day old; package download caches and diagnostic reports must be at least thirty days old. Age refers to modification time. Diagnostic history cannot be regenerated.

Automatic cleanup revalidates recorded file identity, ownership, link count and rule eligibility, and deletes individual files through no-follow descriptor operations. It does not recursively remove cache directories. Incomplete inspection, protected locations, unknown owners and detected running applications prevent automatic cleanup.

Project artifacts, installers, large or old files, duplicates, and applications with associated data require explicit selection and confirmation, then use Finder Trash. These checks cannot prove that downloaded project dependencies have no private edits, or prevent every concurrent write. Stop related work before moving a directory. Execution history distinguishes moved bytes from measured changes in system free space.

See [cleanup logic](docs/cleanup-logic.md) for exact scope and recovery limits, and [development contracts](docs/cleanup-development.md) for validation boundaries and extension requirements.

## Trash Bins

Trash cleanup is intentionally narrow: current-user `~/.Trash` plus validated local, writable, non-internal, non-Time-Machine external `.Trashes/<current UID>` roots. Other UIDs, whole `.Trashes` roots, remote mounts, NAS `#recycle`, symlinks, special files, and items added after candidate enumeration are excluded.

## Credentials and privacy

The source repository must not contain API keys, personal access tokens, signing private keys, `.env` secrets, or machine-specific private data. Build/signing identities are discovered locally and are not committed.

When reporting a security issue, do not paste credentials, private file contents, or destructive proof-of-concept data into a public issue. Use GitHub's private security reporting/advisory flow when available.

## Supported version

Security fixes are targeted at the current public release, **2.0.0**.
