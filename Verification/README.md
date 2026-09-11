# Verification source — MacStorageLens 1.7.5

This directory contains **re-runnable Swift/Python verification source**, not a dump of historical machine-specific result files.

Primary checks include:

- `static_contract_audit.py` — version, UI, cleanup, scanner, and safety contracts.
- `compiler_regression_audit.py` — Swift compiler regression checks.
- `provenance_audit_1_7_5.py` — current 1.7.5 source identity and optional tag/history checks.
- `system_junk_integration_audit.py` — System Junk policy wiring.
- `ui_enum_context_audit.py` — UI enum/switch contract.
- Swift fixtures for cleanup policy, external volumes, AppleDouble, report handling, incremental index, Trash Bins, live revalidation, and related behavior.

Run the full macOS gate from the repository root with:

```text
scripts/驗證原始碼.command
```

Generated `.json`, `.txt`, `.log`, preview images, and older release-specific provenance scripts are intentionally excluded from the public repository to keep it clean and avoid publishing stale or machine-specific data.
