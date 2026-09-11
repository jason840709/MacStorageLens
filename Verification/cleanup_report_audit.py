#!/usr/bin/env python3
"""Read-only catalogue audit against a scanner 2.5.1 Markdown report."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

LINE_RE = re.compile(r"/ ([0-9]+) KiB  (/.+)$")
TREE_HEADER = "### DIRECTORY_TREE (/System/Volumes/Data)"


def parse_report(path: Path) -> dict[str, int]:
    sizes: dict[str, int] = {}
    in_tree = False
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if line.startswith(TREE_HEADER):
                in_tree = True
                continue
            if in_tree and line.startswith("### "):
                break
            if not in_tree:
                continue
            match = LINE_RE.search(line.rstrip("\n"))
            if match:
                sizes[match.group(2)] = int(match.group(1)) * 1024
    if not sizes:
        raise RuntimeError("Data tree not found or report format unsupported")
    return sizes


def parent(path: str) -> str:
    return path.rsplit("/", 1)[0] or "/"


def home_from_paths(paths: list[str]) -> str:
    counts: dict[str, int] = {}
    for path in paths:
        match = re.match(r"/System/Volumes/Data/Users/([^/]+)(?:/|$)", path)
        if match:
            home = f"/System/Volumes/Data/Users/{match.group(1)}"
            counts[home] = counts.get(home, 0) + 1
    if not counts:
        raise RuntimeError("Unable to infer scanned user's home directory")
    return max(counts, key=counts.get)


def is_cloud(path: str) -> bool:
    lower = path.lower()
    return any(
        token in lower
        for token in (
            "cloudkit",
            "icloud",
            "mobile documents",
            "clouddocs",
            "com.apple.bird",
            "protectedcloudstorage",
        )
    )


def add(rows: list[dict], seen: set[tuple[str, str]], *, level: int, category: str,
        action: str, path: str, size: int, name: str) -> None:
    key = (action, path)
    if key in seen or size <= 0 or is_cloud(path):
        return
    seen.add(key)
    rows.append(
        {
            "level": level,
            "category": category,
            "action": action,
            "path": path,
            "bytes": size,
            "name": name,
        }
    )


def catalogue(sizes: dict[str, int]) -> tuple[str, list[dict]]:
    paths = list(sizes)
    home = home_from_paths(paths)
    rows: list[dict] = []
    seen: set[tuple[str, str]] = set()

    user_caches = f"{home}/Library/Caches"
    for path, size in sizes.items():
        if parent(path) == user_caches:
            name = path.rsplit("/", 1)[-1]
            apple = name.lower().startswith(("com.apple.", "apple."))
            add(
                rows,
                seen,
                level=2 if apple else 1,
                category="standard-cache",
                action="trash-contents",
                path=path,
                size=size,
                name=name,
            )

    for path, size in sizes.items():
        if path.startswith(f"{home}/Library/Containers/") and path.endswith(
            "/Data/Library/Caches"
        ):
            container = path.split("/Library/Containers/", 1)[1].split("/", 1)[0]
            add(
                rows,
                seen,
                level=2 if container.lower().startswith("com.apple.") else 1,
                category="sandbox-cache",
                action="trash-contents",
                path=path,
                size=size,
                name=container,
            )
        if path.startswith(f"{home}/Library/Group Containers/") and (
            path.endswith("/Library/Caches") or path.endswith("/Data/Library/Caches")
        ):
            group = path.split("/Library/Group Containers/", 1)[1].split("/", 1)[0]
            add(
                rows,
                seen,
                level=2,
                category="group-cache",
                action="trash-contents",
                path=path,
                size=size,
                name=group,
            )

    clipboard = (
        f"{home}/Library/Group Containers/"
        "group.com.apple.coreservices.useractivityd/shared-pasteboard/archives"
    )
    if clipboard in sizes:
        add(
            rows,
            seen,
            level=2,
            category="clipboard",
            action="trash-contents",
            path=clipboard,
            size=sizes[clipboard],
            name="Universal Clipboard archives",
        )

    app_support = f"{home}/Library/Application Support/"
    render_markers = {"Cache", "Caches", "Code Cache", "GPUCache", "DawnCache", "ShaderCache", "GrShaderCache"}
    for path, size in sizes.items():
        if not path.startswith(app_support):
            continue
        basename = path.rsplit("/", 1)[-1]
        if basename in render_markers:
            add(
                rows,
                seen,
                level=2,
                category="app-render-cache",
                action="trash-contents",
                path=path,
                size=size,
                name=basename,
            )
        elif basename == "CacheStorage" and (
            "/Service Worker/" in path or "/WebStorage/" in path
        ):
            add(
                rows,
                seen,
                level=4,
                category="app-offline-cache",
                action="trash-contents",
                path=path,
                size=size,
                name="CacheStorage",
            )

    exact = [
        (3, "developer", "trash-contents", f"{home}/Library/Developer/Xcode/DerivedData", "Xcode DerivedData"),
        (3, "developer", "trash-contents", f"{home}/Library/Developer/CoreSimulator/Caches", "CoreSimulator caches"),
        (3, "package", "trash-contents", f"{home}/.npm/_cacache", "npm cache"),
        (4, "package", "trash-contents", f"{home}/.npm/_npx", "npx cache"),
        (3, "package", "trash-contents", f"{home}/.cache/pip", "pip cache"),
        (3, "package", "trash-contents", f"{home}/Library/Caches/pip", "pip cache"),
        (3, "package", "trash-contents", f"{home}/.gradle/caches", "Gradle caches"),
        (3, "package", "trash-contents", f"{home}/.cargo/registry/cache", "Cargo cache"),
        (3, "package", "trash-contents", f"{home}/.cargo/git/db", "Cargo Git cache"),
        (4, "package", "trash-contents", f"{home}/.m2/repository", "Maven local repository"),
        (4, "diagnostics", "trash-contents", f"{home}/Library/Logs/DiagnosticReports", "DiagnosticReports"),
        (4, "diagnostics", "trash-contents", f"{home}/Library/Application Support/CrashReporter", "CrashReporter"),
        (5, "high-impact", "trash-contents", f"{home}/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", "Mail Downloads"),
        (5, "review-only", "review", f"{home}/.Trash", "Trash"),
        (5, "system-review", "review", "/System/Volumes/Data/Library/Caches/com.apple.iconservices.store", "IconServices cache"),
        (5, "system-review", "review", "/System/Volumes/Data/private/var/db/diagnostics", "System diagnostics"),
        (5, "system-review", "review", "/System/Volumes/Data/private/var/db/uuidtext", "uuidtext"),
        (5, "system-review", "review", "/System/Volumes/Data/private/var/log", "System logs"),
        (5, "system-review", "review", "/System/Volumes/Data/Library/Logs", "System-wide App logs"),
        (5, "system-review", "review", "/System/Volumes/Data/private/tmp", "System temporary directory"),
        (5, "system-review", "review", "/System/Volumes/Data/Library/Application Support/Apple/AssetCache/Data", "Apple content cache"),
    ]
    for level, category, action, path, name in exact:
        if path in sizes:
            add(
                rows,
                seen,
                level=level,
                category=category,
                action=action,
                path=path,
                size=sizes[path],
                name=name,
            )

    # Conda is a managed action. The directory size is an upper bound; conda decides what is unused.
    for conda_path in (
        "/System/Volumes/Data/opt/anaconda3/pkgs",
        "/System/Volumes/Data/opt/miniconda3/pkgs",
        f"{home}/anaconda3/pkgs",
        f"{home}/miniconda3/pkgs",
        f"{home}/.conda/pkgs",
    ):
        if conda_path in sizes:
            add(
                rows,
                seen,
                level=3,
                category="package",
                action="managed-conda-clean",
                path=conda_path,
                size=sizes[conda_path],
                name="Conda package cache upper bound",
            )

    # All /Library/Caches children are system-wide and intentionally review-only.
    library_caches = "/System/Volumes/Data/Library/Caches"
    for path, size in sizes.items():
        if parent(path) == library_caches:
            add(
                rows,
                seen,
                level=5,
                category="system-review",
                action="review",
                path=path,
                size=size,
                name="System-wide cache",
            )

    # System-wide vendor caches are intentionally review-only.
    system_support = "/System/Volumes/Data/Library/Application Support/"
    for path, size in sizes.items():
        if path.startswith(system_support) and path.rsplit("/", 1)[-1] in {
            "cache",
            "Cache",
            "Caches",
        }:
            add(
                rows,
                seen,
                level=5,
                category="system-review",
                action="review",
                path=path,
                size=size,
                name="Vendor-managed system cache",
            )

    # Remove nested rows if an equivalent trash-contents parent already covers them.
    trash_roots = sorted(
        [row["path"] for row in rows if row["action"] == "trash-contents"],
        key=len,
    )
    filtered: list[dict] = []
    for row in rows:
        if row["action"] != "trash-contents":
            filtered.append(row)
            continue
        if any(root != row["path"] and row["path"].startswith(root + "/") for root in trash_roots):
            continue
        filtered.append(row)
    return home, sorted(filtered, key=lambda row: (row["level"], -row["bytes"], row["path"]))


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: cleanup_report_audit.py REPORT OUTPUT.json", file=sys.stderr)
        return 2
    report = Path(sys.argv[1])
    output = Path(sys.argv[2])
    sizes = parse_report(report)
    home, rows = catalogue(sizes)

    levels: dict[str, dict] = {}
    minimums = {1: 20 * 1024**2, 2: 10 * 1024**2, 3: 5 * 1024**2, 4: 1 * 1024**2, 5: 0}
    for level in range(1, 6):
        cumulative = [
            row for row in rows
            if row["level"] <= level
            and (row["action"] == "review" or row["bytes"] >= minimums[level])
        ]
        levels[str(level)] = {
            "minimum_bytes": minimums[level],
            "candidate_count": len(cumulative),
            "bytes_including_review_and_managed_upper_bounds": sum(row["bytes"] for row in cumulative),
            "executable_path_bytes": sum(
                row["bytes"]
                for row in cumulative
                if row["action"] in {"trash-contents", "trash-item"}
            ),
            "managed_upper_bound_bytes": sum(
                row["bytes"] for row in cumulative if row["action"].startswith("managed-")
            ),
            "review_only_bytes": sum(
                row["bytes"] for row in cumulative if row["action"] == "review"
            ),
        }

    result = {
        "report": str(report),
        "inferred_home": home,
        "catalogue_candidate_count": len(rows),
        "levels": levels,
        "largest_candidates": sorted(rows, key=lambda row: row["bytes"], reverse=True)[:40],
        "notes": [
            "Conda package-directory size is only an upper bound; the App uses conda clean --all rather than deleting pkgs.",
            "Review-only paths are never selectable.",
            "Report sizes are a point-in-time snapshot; live cleanup scan remeasures them.",
            "APFS clone/shared blocks mean displayed bytes are not guaranteed reclaimable bytes.",
        ],
    }
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
