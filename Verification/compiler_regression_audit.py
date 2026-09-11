#!/usr/bin/env python3
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWIFTC = shutil.which("swiftc")
if SWIFTC is None:
    raise SystemExit("swiftc not found")

checks: list[dict[str, object]] = []


def check(name: str, passed: bool, detail: str) -> None:
    checks.append({"name": name, "passed": bool(passed), "detail": detail})
    if not passed:
        raise AssertionError(f"{name}: {detail}")


def run(args: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


swift_version = run([SWIFTC, "--version"]).stdout.strip()

old_source = r'''import Foundation
func parse(_ text: String) -> [String: String] {
  text.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
    guard let separator = line.firstIndex(of: "=") else { return }
    result[String(line[..<separator])] = String(line[line.index(after: separator)...])
  }
}
'''

probe_owner = r'''import Foundation
final class ProbeOwner {
  var generation = UUID()
  var result = FullDiskAccessProbeResult.checking

  func refresh() {
    let generation = UUID()
    self.generation = generation
    FullDiskAccessProbe.inspectCurrentApp { [weak self] value in
      guard let self, self.generation == generation else { return }
      self.result = value
    }
  }
}
'''

with tempfile.TemporaryDirectory(prefix="MacStorageLens-compiler-regression-") as raw_tmp:
    tmp = Path(raw_tmp)
    old_url = tmp / "OldAmbiguousParser.swift"
    old_url.write_text(old_source, encoding="utf-8")
    owner_url = tmp / "ProbeOwner.swift"
    owner_url.write_text(probe_owner, encoding="utf-8")

    mode_results: dict[str, object] = {}
    for language_version in ("5", "6"):
        old = run(
            [
                SWIFTC,
                "-swift-version",
                language_version,
                "-typecheck",
                str(old_url),
            ]
        )
        check(
            f"old_parser_swift_{language_version}_fails",
            old.returncode != 0,
            "0.7.1 parser must reproduce the reported compiler failure",
        )
        check(
            f"old_parser_swift_{language_version}_ambiguity",
            "ambiguous use of 'index(after:)'" in old.stderr,
            "compiler output identifies the Substring/ArraySlice overload ambiguity",
        )

        audit_binary = tmp / f"key-value-audit-swift-{language_version}"
        compiled = run(
            [
                SWIFTC,
                "-swift-version",
                language_version,
                str(ROOT / "Sources/MacStorageLens/KeyValuePayload.swift"),
                str(ROOT / "Verification/KeyValuePayloadAudit.swift"),
                "-o",
                str(audit_binary),
            ]
        )
        check(
            f"new_parser_swift_{language_version}_compiles",
            compiled.returncode == 0,
            compiled.stderr.strip() or "typed helper compiled",
        )
        executed = run([str(audit_binary)]) if compiled.returncode == 0 else compiled
        check(
            f"new_parser_swift_{language_version}_cases",
            executed.returncode == 0 and "9/9" in executed.stdout,
            executed.stderr.strip() or executed.stdout.strip(),
        )

        probe = run(
            [
                SWIFTC,
                "-swift-version",
                language_version,
                "-typecheck",
                str(ROOT / "Sources/MacStorageLens/FullDiskAccessProbe.swift"),
                str(owner_url),
            ]
        )
        check(
            f"probe_swift_{language_version}_typechecks",
            probe.returncode == 0,
            probe.stderr.strip() or "probe callback type-check passed",
        )
        check(
            f"probe_swift_{language_version}_warning_free",
            "warning:" not in probe.stderr,
            probe.stderr.strip() or "no compiler warnings",
        )

        mode_results[language_version] = {
            "oldParserExit": old.returncode,
            "oldParserDiagnosticMatched": "ambiguous use of 'index(after:)'" in old.stderr,
            "newParserExit": executed.returncode,
            "newParserOutput": executed.stdout.strip(),
            "probeTypecheckExit": probe.returncode,
            "probeDiagnostics": probe.stderr.strip(),
        }

    scanner_source = ROOT / "Sources/MacStorageLens/ScannerLauncher.swift"
    scanner_inputs: list[str] = []
    if sys.platform == "darwin":
        scanner_inputs.append(str(scanner_source))
    else:
        portable_scanner = tmp / "ScannerLauncherPortable.swift"
        portable_text = scanner_source.read_text(encoding="utf-8")
        portable_text = portable_text.replace("import AppKit\n", "")
        portable_text = portable_text.replace("import Darwin\n", "import Glibc\n")
        portable_text = portable_text.replace("AppMetadata.version", '"1.6.8"')
        portable_text = portable_text.replace("AppMetadata.scannerVersion", '"2.5.3"')
        portable_scanner.write_text(portable_text, encoding="utf-8")
        appkit_shim = tmp / "AppKitShim.swift"
        appkit_shim.write_text(
            """import Foundation
final class NSWorkspace: @unchecked Sendable {
  static let shared = NSWorkspace()
  @discardableResult func open(_ url: URL) -> Bool { true }
}
""",
            encoding="utf-8",
        )
        scanner_inputs.extend([str(appkit_shim), str(portable_scanner)])

    scanner_dependencies = [
        ROOT / "Sources/MacStorageLens/Models.swift",
        ROOT / "Sources/MacStorageLens/ScanTargetResolver.swift",
        ROOT / "Sources/MacStorageLens/ByteFormatting.swift",
        ROOT / "Sources/MacStorageLens/ProcessRunner.swift",
        ROOT / "Sources/MacStorageLens/ReportPresentationIndex.swift",
        ROOT / "Sources/MacStorageLens/ReportLibrary.swift",
        ROOT / "Sources/MacStorageLens/ScanProgressParser.swift",
        ROOT / "Sources/MacStorageLens/FullDiskAccessProbe.swift",
        ROOT / "Sources/MacStorageLens/KeyValuePayload.swift",
    ]
    scanner = run(
        [SWIFTC, "-swift-version", "5", "-typecheck"]
        + [str(path) for path in scanner_dependencies]
        + scanner_inputs
    )
    check(
        "scanner_launcher_swift_5_typechecks",
        scanner.returncode == 0,
        scanner.stderr.strip() or "ScannerLauncher and direct dependencies type-check",
    )
    check(
        "scanner_launcher_swift_5_warning_free",
        "warning:" not in scanner.stderr,
        scanner.stderr.strip() or "ScannerLauncher type-check has no warnings",
    )

result = {
    "version": "1.6.8",
    "build": 25,
    "swiftCompiler": swift_version,
    "passed": sum(1 for item in checks if item["passed"]),
    "total": len(checks),
    "payloadCasesPerLanguageMode": 9,
    "payloadCaseExecutions": 18,
    "languageModes": mode_results,
    "scannerLauncherSwift5": {
        "exit": scanner.returncode,
        "diagnostics": scanner.stderr.strip(),
        "platformAdaptation": "native AppKit" if sys.platform == "darwin" else "AppKit/Darwin import shim only",
    },
    "checks": checks,
    "macOSAppReleaseBuild": "not-run-by-this-cross-platform-audit",
}

encoded = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
if len(sys.argv) > 1:
    Path(sys.argv[1]).write_text(encoded, encoding="utf-8")
sys.stdout.write(encoded)
