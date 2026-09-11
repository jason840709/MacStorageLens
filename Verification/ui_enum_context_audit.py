#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.7.5"
BUILD = 33


def balanced_block(text: str, open_brace: int) -> str:
    depth = 0
    i = open_brace
    in_string = False
    escaped = False
    while i < len(text):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
        else:
            if ch == '"':
                in_string = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return text[open_brace : i + 1]
        i += 1
    raise ValueError("unbalanced braces")


def enum_cases(text: str, enum_name: str) -> list[str]:
    match = re.search(rf"\benum\s+{re.escape(enum_name)}\b[^{{]*{{", text)
    if not match:
        raise ValueError(f"enum not found: {enum_name}")
    block = balanced_block(text, text.find("{", match.start()))
    cases: list[str] = []
    for line in block.splitlines():
        m = re.match(r"\s*case\s+([A-Za-z_][A-Za-z0-9_]*)\b", line)
        if m:
            cases.append(m.group(1))
    return cases


def function_switch_cases(text: str, function_name: str, switch_value: str) -> list[str]:
    match = re.search(rf"\bfunc\s+{re.escape(function_name)}\b[^{{]*{{", text)
    if not match:
        raise ValueError(f"function not found: {function_name}")
    function_block = balanced_block(text, text.find("{", match.start()))
    switch_match = re.search(rf"\bswitch\s+{re.escape(switch_value)}\s*{{", function_block)
    if not switch_match:
        raise ValueError(f"switch not found: {function_name}/{switch_value}")
    switch_block = balanced_block(function_block, function_block.find("{", switch_match.start()))
    return re.findall(r"\bcase\s+\.([A-Za-z_][A-Za-z0-9_]*)\b", switch_block)


models = (ROOT / "Sources/MacStorageLens/Models.swift").read_text(encoding="utf-8")
cleaner = (ROOT / "Sources/MacStorageLens/CleanerView.swift").read_text(encoding="utf-8")
app_model = (ROOT / "Sources/MacStorageLens/AppModel.swift").read_text(encoding="utf-8")

checks: list[dict[str, object]] = []


def check(name: str, passed: bool, detail: str = "") -> None:
    checks.append({"name": name, "passed": bool(passed), "detail": detail})


scope_expected = enum_cases(models, "CleanupScope")
category_expected = enum_cases(models, "CleanupCategory")
scope_actual = function_switch_cases(cleaner, "scopeTint", "scope")
category_actual = function_switch_cases(cleaner, "categorySymbol", "category")

scope_extra = sorted(set(scope_actual) - set(scope_expected))
scope_missing = sorted(set(scope_expected) - set(scope_actual))
category_extra = sorted(set(category_actual) - set(category_expected))
category_missing = sorted(set(category_expected) - set(category_actual))

check("cleanup_scope_enum_unique", len(scope_expected) == len(set(scope_expected)), repr(scope_expected))
check("cleanup_category_enum_unique", len(category_expected) == len(set(category_expected)), repr(category_expected))
check("scope_tint_no_duplicate_cases", len(scope_actual) == len(set(scope_actual)), repr(scope_actual))
check("category_symbol_no_duplicate_cases", len(category_actual) == len(set(category_actual)), repr(category_actual))
check("scope_tint_no_cross_enum_members", not scope_extra, repr(scope_extra))
check("scope_tint_exhaustive", not scope_missing, repr(scope_missing))
check("category_symbol_no_cross_enum_members", not category_extra, repr(category_extra))
check("category_symbol_exhaustive", not category_missing, repr(category_missing))
check(
    "legacy_trash_residue_is_category_only",
    "folderLegacyTrashResidue" in category_expected
    and "folderLegacyTrashResidue" not in scope_expected
    and "folderLegacyTrashResidue" in category_actual
    and "folderLegacyTrashResidue" not in scope_actual,
)
check(
    "report_index_try_warning_consumed",
    "_ = try? self.reportPresentationIndexStore.save(document: document, for: url)" in app_model,
)

failed = [item for item in checks if not item["passed"]]
result = {
    "version": VERSION,
    "build": BUILD,
    "passed": len(checks) - len(failed),
    "failed": len(failed),
    "cleanupScope": {"expected": scope_expected, "actual": scope_actual},
    "cleanupCategory": {"expected": category_expected, "actual": category_actual},
    "checks": checks,
}

payload = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
if len(sys.argv) > 1:
    Path(sys.argv[1]).write_text(payload, encoding="utf-8")
else:
    sys.stdout.write(payload)

if failed:
    for item in failed:
        print(f"FAIL {item['name']}: {item['detail']}", file=sys.stderr)
    raise SystemExit(1)
