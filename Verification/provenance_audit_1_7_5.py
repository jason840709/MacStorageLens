#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
checks: list[dict[str, object]] = []


def run(*args: str) -> str:
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def check(name: str, condition: bool, detail: str = "") -> None:
    checks.append({
        "name": name,
        "status": "passed" if condition else "failed",
        "passed": bool(condition),
        "detail": detail,
    })


def skip(name: str, detail: str) -> None:
    checks.append({"name": name, "status": "not_run", "passed": None, "detail": detail})


metadata = read("Sources/MacStorageLens/AppMetadata.swift")
models = read("Sources/MacStorageLens/Models.swift")
app_model = read("Sources/MacStorageLens/AppModel.swift")
cleaner = read("Sources/MacStorageLens/CleanerView.swift")
cleanup = read("Sources/MacStorageLens/CleanupEngine.swift")
index = read("Sources/MacStorageLens/CleanupIncrementalIndex.swift")
external_executor = read("Sources/MacStorageLens/ExternalVolumeCleanupExecutor.swift")
knowledge = read("Sources/MacStorageLens/SystemJunkKnowledge.swift")
build = read("scripts/建立並啟動.command")
verify = read("scripts/驗證原始碼.command")
source_review = read("docs/MACSAI_SOURCE_REVIEW.md")
notices = read("THIRD_PARTY_NOTICES.md")

check("metadata_version", 'fallbackVersion = "1.7.5"' in metadata)
check("metadata_build", 'fallbackBuild = "33"' in metadata)
check("developer", 'developer = "Jason Chen"' in metadata and "Jason Chen" in build)
check("scanner_version", 'scannerVersion = "2.5.3"' in metadata)
check("build_identity", 'APP_VERSION="1.7.5"' in build and 'APP_BUILD="33"' in build)
check("six_profiles_preserved", all(name in models for name in [
    'case ultraConservative = "超級保守"', 'case conservative = "保守"',
    'case balanced = "平衡"', 'case aggressive = "激進"',
    'case ultraAggressive = "超激進"', 'case custom = "自定義"'
]))
check(
    "native_profile_ui_integration",
    "CleanupRuleIntegrationMapCard" not in cleaner
    and "1.7.5 清理規則整併位置" not in cleaner
    and "CleanupProfileScopeGrid" in cleaner
    and "model.cleanupConfiguration.requiresScope" in cleaner
    and "UltraAggressiveOptionsStrip" in cleaner
    and "model.setPresetOptionalCleanupScope" in cleaner
    and "CleanupResearchReferenceNote" in cleaner,
)
check(
    "l5_optional_scopes_default_off",
    "var requiresExplicitPresetOptIn" in models
    and "let presetOptionalScopes: Set<CleanupScope>" in models
    and "@Published var cleanupPresetOptionalScopes: Set<CleanupScope> = []" in app_model
    and "func setPresetOptionalCleanupScope" in app_model,
)
check("trash_bins_scope", "case trashBins" in models and "case trashBinContents" in models)
check("trash_bins_l5", "case .highImpactUserData, .trashBins, .systemManagedReview" in models)
check("trash_bins_current_uid", "String(currentUserID)" in cleanup and "~/.Trash" in cleanup)
check("trash_bins_direct_only", "filemanager_remove_validated_current_user_trash_matches" in cleanup)
check("trash_bins_external_root_validation", "validateExternalVolumeRoot" in cleanup and "volumesRootURL" in external_executor)
check("trash_bins_not_default_custom", ".trashBins" not in app_model.split("@Published var cleanupFolderCustomScopes", 1)[0].split("@Published var cleanupCustomScopes", 1)[1])
check("cleanup_index_schema_6", "currentSchemaVersion = 6" in index)
check("source_review_present", "MacSai source review" in source_review and "Trash" in source_review)
check("bsd_notice_present", "BSD 3-Clause" in notices and (ROOT / "ThirdParty/MacSai-LICENSE.txt").is_file())
check("system_junk_knowledge_present", "enum SystemJunkKnowledge" in knowledge)
check("trash_fixture_wired", "TrashBinsCleanupAudit.swift" in verify)

if not (ROOT / ".git").is_dir():
    skip(
        "git_provenance",
        "來源封裝不含 .git；公開來源內容檢查已完成。",
    )
else:
    try:
        head = run("git", "rev-parse", "HEAD")
        if subprocess.run(["git", "rev-parse", "--verify", "-q", "v1.7.5^{commit}"], cwd=ROOT).returncode == 0:
            tagged = run("git", "rev-parse", "v1.7.5^{commit}")
            check("tag_v1_7_5_points_to_head", tagged == head, f"{tagged} == {head}")
        else:
            skip("tag_v1_7_5_points_to_head", "尚未建立 v1.7.5 tag。")

        # The public GitHub repository is intentionally a curated clean-root release.
        # If historical v1.7.4 is present, retain the deeper parent/change-scope checks;
        # otherwise do not require the internal handoff history to be published.
        if subprocess.run(["git", "rev-parse", "--verify", "-q", "v1.7.4^{commit}"], cwd=ROOT).returncode == 0 and subprocess.run(["git", "rev-parse", "--verify", "-q", "v1.7.5^{commit}"], cwd=ROOT).returncode == 0:
            commit = run("git", "rev-parse", "v1.7.5^{commit}")
            parent = run("git", "rev-parse", f"{commit}^")
            expected_parent = run("git", "rev-parse", "v1.7.4^{commit}")
            check("direct_parent_v1.7.4", parent == expected_parent, f"{parent} == {expected_parent}")
            changed = set(run("git", "diff", "--name-only", "v1.7.4", "v1.7.5").splitlines())
            runtime_expected = {
                "Sources/MacStorageLens/AppMetadata.swift",
                "Sources/MacStorageLens/AppModel.swift",
                "Sources/MacStorageLens/CleanerView.swift",
                "Sources/MacStorageLens/CleanupEngine.swift",
                "Sources/MacStorageLens/CleanupIncrementalIndex.swift",
                "Sources/MacStorageLens/ExternalVolumeCleanupExecutor.swift",
                "Sources/MacStorageLens/Models.swift",
                "Sources/MacStorageLens/SystemJunkKnowledge.swift",
            }
            runtime_changed = {p for p in changed if p.startswith("Sources/MacStorageLens/")}
            check("runtime_change_scope", runtime_changed <= runtime_expected, ", ".join(sorted(runtime_changed - runtime_expected)))
        else:
            skip("historical_parent_gate", "公開 repository 為整理後的乾淨發行根提交，未附內部 v1.7.4 Git history。")
    except Exception as exc:
        check("git_provenance", False, str(exc))

passed = sum(1 for item in checks if item["status"] == "passed")
failed = sum(1 for item in checks if item["status"] == "failed")
not_run = sum(1 for item in checks if item["status"] == "not_run")
payload = {
    "version": "1.7.5",
    "build": 33,
    "passed": passed,
    "failed": failed,
    "notRun": not_run,
    "total": len(checks),
    "checks": checks,
}
text = json.dumps(payload, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
if len(sys.argv) > 1:
    Path(sys.argv[1]).write_text(text, encoding="utf-8")
else:
    print(text, end="")
if failed:
    raise SystemExit(1)
