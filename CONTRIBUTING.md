# Contributing to MacStorageLens

Thanks for contributing. MacStorageLens touches filesystem metadata and destructive cleanup paths, so changes should be small, reviewable, and backed by fixtures.

## Development

Requirements: macOS 14+, Swift 5.9+ / current Xcode Command Line Tools.

```bash
swift package dump-package
swift run MacStorageLens
```

For the full project checks on macOS, run:

```text
scripts/驗證原始碼.command
```

## Pull requests

- Explain user-visible behavior and safety implications.
- Add or update verification fixtures for cleanup-policy changes.
- Do not weaken live-revalidation or turn report data into direct deletion authority.
- Do not commit generated `.build/`, `dist/`, credentials, signing keys, personal filesystem snapshots, or machine-specific audit output.
- Preserve third-party attribution when a change is derived from external research.

## Author / license

The project is maintained by Jason Chen and released under the MIT License. Contributions are submitted under the same project license unless explicitly stated otherwise.
