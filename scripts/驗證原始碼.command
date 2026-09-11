#!/bin/zsh
emulate -L zsh
set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

printf '%s\n' \
  'MacStorageLens 1.7.5 原始碼驗證' \
  '只會編譯、解析與讀取測試 fixture；不會掃描、清理或修改磁碟內容。' \
  ''

if ! command -v swift >/dev/null 2>&1; then
  printf '%s\n' \
    'ERROR: 找不到 Swift。請先安裝 Xcode Command Line Tools：' \
    'xcode-select --install' >&2
  exit 1
fi

TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/MacStorageLens-verify.XXXXXX")"
cleanup() {
  case "$TMP" in
    "${TMPDIR:-/tmp}"/MacStorageLens-verify.*) /bin/rm -rf -- "$TMP" ;;
  esac
}
trap cleanup EXIT INT TERM

printf '[1/36] Package manifest\n'
swift package dump-package > "$TMP/package-dump.json"

printf '[2/36] Swift syntax\n'
swiftc -parse Sources/MacStorageLens/*.swift

printf '[3/36] Swift formatting\n'
SWIFT_FORMAT=""
if command -v swift-format >/dev/null 2>&1; then
  SWIFT_FORMAT="$(command -v swift-format)"
elif command -v xcrun >/dev/null 2>&1; then
  SWIFT_FORMAT="$(xcrun --find swift-format 2>/dev/null || true)"
fi
if [[ -n "$SWIFT_FORMAT" ]]; then
  "$SWIFT_FORMAT" lint --strict Package.swift Sources/MacStorageLens/*.swift Verification/*.swift
else
  printf 'WARNING: 找不到 swift-format，略過格式檢查。\n' >&2
fi

printf '[4/36] zsh scanner／build scripts\n'
for script in Resources/*.command scripts/*.command; do
  /bin/zsh -n "$script"
done

printf '[5/36] Swift 5／6 compiler regression\n'
if command -v python3 >/dev/null 2>&1; then
  python3 Verification/compiler_regression_audit.py "$TMP/compiler-regression-result.json" >/dev/null
else
  printf 'ERROR: 找不到 python3，無法執行 compiler regression。\n' >&2
  exit 1
fi

printf '[6/36] Target／容量 fixture\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ReportParser.swift \
  Sources/MacStorageLens/CapacityMapBuilder.swift \
  Verification/TargetFixtureAudit.swift \
  -o "$TMP/target-fixture-audit"
"$TMP/target-fixture-audit" "$TMP/target-fixture-result.json" >/dev/null

printf '[7/36] TCC 責任鏈 fixture\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ReportParser.swift \
  Sources/MacStorageLens/CapacityMapBuilder.swift \
  Verification/PermissionChainAudit.swift \
  -o "$TMP/permission-chain-audit"
"$TMP/permission-chain-audit" "$TMP/permission-chain-result.json" >/dev/null

printf '[8/36] Finder 路徑語意\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Verification/FinderPathAudit.swift \
  -o "$TMP/finder-path-audit"
"$TMP/finder-path-audit" "$TMP/finder-path-result.json" >/dev/null

printf '[9/36] 階層配色契約\n'
swiftc \
  Sources/MacStorageLens/StorageColorModel.swift \
  Verification/PaletteAudit.swift \
  -o "$TMP/palette-audit"
"$TMP/palette-audit" "$TMP/palette-audit-result.json" >/dev/null

printf '[10/36] 六級清理政策 fixture\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ProcessRunner.swift \
  Sources/MacStorageLens/ReportParser.swift \
  Sources/MacStorageLens/ReportPresentationIndex.swift \
  Sources/MacStorageLens/ReportLibrary.swift \
  Sources/MacStorageLens/AppleDoubleInspector.swift \
  Sources/MacStorageLens/FolderCleanupEngine.swift \
  Sources/MacStorageLens/FinderVisibleTrash.swift \
  Sources/MacStorageLens/ExternalVolumeCleanupExecutor.swift \
  Sources/MacStorageLens/CleanupTargetCapabilities.swift \
  Sources/MacStorageLens/CleanupEngine.swift \
  Sources/MacStorageLens/SystemJunkKnowledge.swift \
  Verification/CleanupPolicyAudit.swift \
  -o "$TMP/cleanup-policy-audit"
"$TMP/cleanup-policy-audit" "$TMP/cleanup-policy-result.json" >/dev/null

printf '[11/36] 一般位置隱藏中繼資料清理 fixture\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ProcessRunner.swift \
  Sources/MacStorageLens/ReportParser.swift \
  Sources/MacStorageLens/ReportPresentationIndex.swift \
  Sources/MacStorageLens/ReportLibrary.swift \
  Sources/MacStorageLens/AppleDoubleInspector.swift \
  Sources/MacStorageLens/FolderCleanupEngine.swift \
  Sources/MacStorageLens/FinderVisibleTrash.swift \
  Sources/MacStorageLens/ExternalVolumeCleanupExecutor.swift \
  Sources/MacStorageLens/CleanupTargetCapabilities.swift \
  Sources/MacStorageLens/CleanupEngine.swift \
  Sources/MacStorageLens/SystemJunkKnowledge.swift \
  Verification/FolderCleanupAudit.swift \
  -o "$TMP/folder-cleanup-audit"
"$TMP/folder-cleanup-audit" "$TMP/folder-cleanup-result.json" >/dev/null

printf '[12/36] 外部媒體 AppleDouble 與 NAS #recycle 排除 fixture\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ProcessRunner.swift \
  Sources/MacStorageLens/ReportParser.swift \
  Sources/MacStorageLens/ReportPresentationIndex.swift \
  Sources/MacStorageLens/ReportLibrary.swift \
  Sources/MacStorageLens/AppleDoubleInspector.swift \
  Sources/MacStorageLens/FolderCleanupEngine.swift \
  Sources/MacStorageLens/FinderVisibleTrash.swift \
  Sources/MacStorageLens/ExternalVolumeCleanupExecutor.swift \
  Sources/MacStorageLens/CleanupTargetCapabilities.swift \
  Sources/MacStorageLens/CleanupEngine.swift \
  Sources/MacStorageLens/SystemJunkKnowledge.swift \
  Verification/ExternalAppleDoubleCleanupAudit.swift \
  -o "$TMP/external-appledouble-cleanup-audit"
"$TMP/external-appledouble-cleanup-audit" \
  "$TMP/external-appledouble-cleanup-result.json" >/dev/null

printf '[13/36] 既有容量報告快速安全清理 fixture\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ProcessRunner.swift \
  Sources/MacStorageLens/ReportParser.swift \
  Sources/MacStorageLens/ReportPresentationIndex.swift \
  Sources/MacStorageLens/ReportLibrary.swift \
  Sources/MacStorageLens/AppleDoubleInspector.swift \
  Sources/MacStorageLens/FolderCleanupEngine.swift \
  Sources/MacStorageLens/FinderVisibleTrash.swift \
  Sources/MacStorageLens/ExternalVolumeCleanupExecutor.swift \
  Sources/MacStorageLens/CleanupTargetCapabilities.swift \
  Sources/MacStorageLens/CleanupEngine.swift \
  Sources/MacStorageLens/SystemJunkKnowledge.swift \
  Verification/ReportGuidedCleanupAudit.swift \
  -o "$TMP/report-guided-cleanup-audit"
"$TMP/report-guided-cleanup-audit" "$TMP/report-guided-cleanup-result.json" >/dev/null

printf '[14/36] 安全清理增量索引與跨等級重用 fixture\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ProcessRunner.swift \
  Sources/MacStorageLens/ReportParser.swift \
  Sources/MacStorageLens/ReportPresentationIndex.swift \
  Sources/MacStorageLens/ReportLibrary.swift \
  Sources/MacStorageLens/AppleDoubleInspector.swift \
  Sources/MacStorageLens/FolderCleanupEngine.swift \
  Sources/MacStorageLens/FinderVisibleTrash.swift \
  Sources/MacStorageLens/ExternalVolumeCleanupExecutor.swift \
  Sources/MacStorageLens/CleanupTargetCapabilities.swift \
  Sources/MacStorageLens/CleanupEngine.swift \
  Sources/MacStorageLens/SystemJunkKnowledge.swift \
  Sources/MacStorageLens/CleanupIncrementalIndex.swift \
  Verification/CleanupIncrementalIndexAudit.swift \
  -o "$TMP/cleanup-incremental-index-audit"
"$TMP/cleanup-incremental-index-audit" \
  "$TMP/cleanup-incremental-index-result.json" >/dev/null

printf '[15/36] NAS／遠端檔案系統清理能力契約\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/CleanupTargetCapabilities.swift \
  Verification/CleanupTargetCapabilityAudit.swift \
  -o "$TMP/cleanup-target-capability-audit"
"$TMP/cleanup-target-capability-audit" "$TMP/cleanup-target-capability-result.json" >/dev/null

printf '[16/36] Application Support cache canonical path fixture\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ProcessRunner.swift \
  Sources/MacStorageLens/ReportParser.swift \
  Sources/MacStorageLens/ReportPresentationIndex.swift \
  Sources/MacStorageLens/ReportLibrary.swift \
  Sources/MacStorageLens/AppleDoubleInspector.swift \
  Sources/MacStorageLens/FolderCleanupEngine.swift \
  Sources/MacStorageLens/FinderVisibleTrash.swift \
  Sources/MacStorageLens/ExternalVolumeCleanupExecutor.swift \
  Sources/MacStorageLens/CleanupTargetCapabilities.swift \
  Sources/MacStorageLens/CleanupEngine.swift \
  Sources/MacStorageLens/SystemJunkKnowledge.swift \
  Verification/ApplicationCacheCanonicalPathAudit.swift \
  -o "$TMP/application-cache-canonical-path-audit"
"$TMP/application-cache-canonical-path-audit" \
  "$TMP/application-cache-canonical-path-result.json" >/dev/null

printf '[17/36] App 內外接卷宗永久清除契約\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ProcessRunner.swift \
  Sources/MacStorageLens/ReportParser.swift \
  Sources/MacStorageLens/ReportPresentationIndex.swift \
  Sources/MacStorageLens/ReportLibrary.swift \
  Sources/MacStorageLens/AppleDoubleInspector.swift \
  Sources/MacStorageLens/FolderCleanupEngine.swift \
  Sources/MacStorageLens/FinderVisibleTrash.swift \
  Sources/MacStorageLens/ExternalVolumeCleanupExecutor.swift \
  Sources/MacStorageLens/CleanupTargetCapabilities.swift \
  Sources/MacStorageLens/CleanupEngine.swift \
  Sources/MacStorageLens/SystemJunkKnowledge.swift \
  Verification/ExternalVolumeCleanupAudit.swift \
  -o "$TMP/external-volume-cleanup-audit"
"$TMP/external-volume-cleanup-audit" "$TMP/external-volume-cleanup-result.json" >/dev/null

printf '[18/36] 互動式容量條命中契約\n'
swiftc \
  Sources/MacStorageLens/InteractionGeometry.swift \
  Verification/InteractionGeometryAudit.swift \
  -o "$TMP/interaction-geometry-audit"
"$TMP/interaction-geometry-audit" "$TMP/interaction-geometry-result.json" >/dev/null

printf '[19/36] 每個掃描位置保留最新報告 fixture\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ReportPresentationIndex.swift \
  Sources/MacStorageLens/ReportLibrary.swift \
  Verification/ReportLibraryAudit.swift \
  -o "$TMP/report-library-audit"
"$TMP/report-library-audit" "$TMP/report-library-result.json" >/dev/null

printf '[20/36] 報告單次解析與容量索引 fixture\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ReportParser.swift \
  Sources/MacStorageLens/ReportPresentationIndex.swift \
  Verification/ReportPresentationIndexAudit.swift \
  -o "$TMP/report-presentation-index-audit"
"$TMP/report-presentation-index-audit" \
  "$TMP/report-presentation-index-result.json" >/dev/null

printf '[21/36] 容量地圖自動合併與可展開契約\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ReportParser.swift \
  Verification/SunburstAggregationAudit.swift \
  -o "$TMP/sunburst-aggregation-audit"
"$TMP/sunburst-aggregation-audit" "$TMP/sunburst-aggregation-result.json" >/dev/null

if [[ -n "${1:-}" ]]; then
  REPORT="$1"
  if [[ ! -f "$REPORT" ]]; then
    printf 'ERROR: 找不到指定報告：%s\n' "$REPORT" >&2
    exit 1
  fi

  TARGET_KIND="$(/usr/bin/awk -F= '$1 == "scan_target_kind" { print $2; exit }' "$REPORT")"
  if [[ "$TARGET_KIND" == "system" || -z "$TARGET_KIND" ]]; then
    printf '[22/36] 指定系統真實報告容量 audit\n'
    swiftc \
      Sources/MacStorageLens/Models.swift \
      Sources/MacStorageLens/ReportParser.swift \
      Sources/MacStorageLens/CapacityMapBuilder.swift \
      Verification/ReportAudit.swift \
      -o "$TMP/report-audit"
    "$TMP/report-audit" "$REPORT" "$TMP/report-audit-result.json" >/dev/null

    printf '[23/36] 指定系統真實報告清理目錄 audit\n'
    python3 Verification/cleanup_report_audit.py \
      "$REPORT" "$TMP/cleanup-report-audit-result.json" >/dev/null
  else
    printf '[22/36] 指定磁碟／資料夾真實報告容量 audit\n'
    swiftc \
      Sources/MacStorageLens/Models.swift \
      Sources/MacStorageLens/ReportParser.swift \
      Sources/MacStorageLens/CapacityMapBuilder.swift \
      Verification/SelectedTargetReportAudit.swift \
      -o "$TMP/selected-target-report-audit"
    "$TMP/selected-target-report-audit" \
      "$REPORT" "$TMP/selected-target-report-audit-result.json" >/dev/null

    printf '[23/36] 系統六級清理目錄 audit：非系統報告不適用，略過。\n'
  fi
else
  printf '[22/36] 真實報告容量 audit：未指定報告，略過。\n'
  printf '[23/36] 真實報告清理目錄 audit：未指定報告，略過。\n'
  printf '      用法：%s /path/to/*-storage-tree-*.md\n' "$0"
fi

printf '[24/36] 外接卷宗重複掃描與狀態欄位 fixture\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ReportParser.swift \
  Sources/MacStorageLens/CapacityMapBuilder.swift \
  Sources/MacStorageLens/ScanTargetResolver.swift \
  Verification/ExternalVolumeRescanAudit.swift \
  -o "$TMP/external-volume-rescan-audit"
"$TMP/external-volume-rescan-audit" "$TMP/external-volume-rescan-result.json" >/dev/null

printf '[25/36] 靜態契約、互動一致性與安全邊界\n'
if command -v python3 >/dev/null 2>&1; then
  python3 Verification/static_contract_audit.py "$TMP/static-contract-result.json" >/dev/null
else
  printf 'ERROR: 找不到 python3，無法執行正式靜態契約檢查。\n' >&2
  exit 1
fi

printf '[26/36] UI enum context 與 Swift 6 警告回歸\n'
python3 Verification/ui_enum_context_audit.py "$TMP/ui-enum-context-result.json" >/dev/null

printf '[27/36] Scan activity timeout\n'
swiftc \
  Sources/MacStorageLens/ScanProgressParser.swift \
  Verification/ScanActivityTimeoutAudit.swift \
  -o "$TMP/scan-activity-timeout-audit"
"$TMP/scan-activity-timeout-audit" "$TMP/scan-activity-timeout-result.json" >/dev/null

printf '[28/36] MacSai source-reviewed 純 cleanup policy\n'
swiftc \
  Sources/MacStorageLens/SystemJunkKnowledge.swift \
  Verification/SystemJunkKnowledgeAudit.swift \
  -o "$TMP/system-junk-knowledge-audit"
"$TMP/system-junk-knowledge-audit" >/dev/null

printf '[29/36] MacSai cleanup scanner/executor 靜態 wiring\n'
python3 Verification/system_junk_integration_audit.py >/dev/null

printf '[30/36] System Junk synthetic filesystem fixture\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ProcessRunner.swift \
  Sources/MacStorageLens/ReportParser.swift \
  Sources/MacStorageLens/ReportPresentationIndex.swift \
  Sources/MacStorageLens/ReportLibrary.swift \
  Sources/MacStorageLens/AppleDoubleInspector.swift \
  Sources/MacStorageLens/FolderCleanupEngine.swift \
  Sources/MacStorageLens/FinderVisibleTrash.swift \
  Sources/MacStorageLens/ExternalVolumeCleanupExecutor.swift \
  Sources/MacStorageLens/CleanupTargetCapabilities.swift \
  Sources/MacStorageLens/CleanupEngine.swift \
  Sources/MacStorageLens/CleanupIncrementalIndex.swift \
  Sources/MacStorageLens/SystemJunkKnowledge.swift \
  Verification/SystemJunkScannerFixtureAudit.swift \
  -o "$TMP/system-junk-scanner-fixture-audit"
"$TMP/system-junk-scanner-fixture-audit" >/dev/null

printf '[31/36] Developer／AI cache synthetic filesystem fixture\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ProcessRunner.swift \
  Sources/MacStorageLens/ReportParser.swift \
  Sources/MacStorageLens/ReportPresentationIndex.swift \
  Sources/MacStorageLens/ReportLibrary.swift \
  Sources/MacStorageLens/AppleDoubleInspector.swift \
  Sources/MacStorageLens/FolderCleanupEngine.swift \
  Sources/MacStorageLens/FinderVisibleTrash.swift \
  Sources/MacStorageLens/ExternalVolumeCleanupExecutor.swift \
  Sources/MacStorageLens/CleanupTargetCapabilities.swift \
  Sources/MacStorageLens/CleanupEngine.swift \
  Sources/MacStorageLens/CleanupIncrementalIndex.swift \
  Sources/MacStorageLens/SystemJunkKnowledge.swift \
  Verification/SystemJunkDeveloperCacheFixtureAudit.swift \
  -o "$TMP/system-junk-developer-cache-fixture-audit"
"$TMP/system-junk-developer-cache-fixture-audit" >/dev/null

printf '[32/36] System Junk deletion-time live revalidation fixture\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ProcessRunner.swift \
  Sources/MacStorageLens/ReportParser.swift \
  Sources/MacStorageLens/ReportPresentationIndex.swift \
  Sources/MacStorageLens/ReportLibrary.swift \
  Sources/MacStorageLens/AppleDoubleInspector.swift \
  Sources/MacStorageLens/FolderCleanupEngine.swift \
  Sources/MacStorageLens/FinderVisibleTrash.swift \
  Sources/MacStorageLens/ExternalVolumeCleanupExecutor.swift \
  Sources/MacStorageLens/CleanupTargetCapabilities.swift \
  Sources/MacStorageLens/CleanupEngine.swift \
  Sources/MacStorageLens/CleanupIncrementalIndex.swift \
  Sources/MacStorageLens/SystemJunkKnowledge.swift \
  Verification/SystemJunkLiveRevalidationAudit.swift \
  -o "$TMP/system-junk-live-revalidation-audit"
"$TMP/system-junk-live-revalidation-audit" >/dev/null

printf '[33/36] System Junk direct-delete filesystem fixture\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ProcessRunner.swift \
  Sources/MacStorageLens/ReportParser.swift \
  Sources/MacStorageLens/ReportPresentationIndex.swift \
  Sources/MacStorageLens/ReportLibrary.swift \
  Sources/MacStorageLens/AppleDoubleInspector.swift \
  Sources/MacStorageLens/FolderCleanupEngine.swift \
  Sources/MacStorageLens/FinderVisibleTrash.swift \
  Sources/MacStorageLens/ExternalVolumeCleanupExecutor.swift \
  Sources/MacStorageLens/CleanupTargetCapabilities.swift \
  Sources/MacStorageLens/CleanupEngine.swift \
  Sources/MacStorageLens/CleanupIncrementalIndex.swift \
  Sources/MacStorageLens/SystemJunkKnowledge.swift \
  Verification/SystemJunkDirectDeleteFixtureAudit.swift \
  -o "$TMP/system-junk-direct-delete-fixture-audit"
"$TMP/system-junk-direct-delete-fixture-audit" >/dev/null

printf '[34/36] 廢紙簍 current-UID／外接卷宗安全 fixture\n'
swiftc \
  Sources/MacStorageLens/Models.swift \
  Sources/MacStorageLens/ProcessRunner.swift \
  Sources/MacStorageLens/ReportParser.swift \
  Sources/MacStorageLens/ReportPresentationIndex.swift \
  Sources/MacStorageLens/ReportLibrary.swift \
  Sources/MacStorageLens/AppleDoubleInspector.swift \
  Sources/MacStorageLens/FolderCleanupEngine.swift \
  Sources/MacStorageLens/FinderVisibleTrash.swift \
  Sources/MacStorageLens/ExternalVolumeCleanupExecutor.swift \
  Sources/MacStorageLens/CleanupTargetCapabilities.swift \
  Sources/MacStorageLens/CleanupEngine.swift \
  Sources/MacStorageLens/CleanupIncrementalIndex.swift \
  Sources/MacStorageLens/SystemJunkKnowledge.swift \
  Verification/TrashBinsCleanupAudit.swift \
  -o "$TMP/trash-bins-cleanup-audit"
"$TMP/trash-bins-cleanup-audit" >/dev/null

printf '[35/36] 1.7.5 公開來源與 tag provenance\n'
python3 Verification/provenance_audit_1_7_5.py "$TMP/provenance-result.json" >/dev/null
if [[ ! -d .git ]]; then
  printf '      來源封裝不含 .git；公開來源 provenance 已通過。\n'
fi

printf '[36/36] macOS App release build\n'
FULL_APP_BUILD="not-run"
if [[ "$(uname -s)" == "Darwin" ]]; then
  swift package clean
  swift build -c release --arch "$(uname -m)"
  FULL_APP_BUILD="passed"
else
  printf 'WARNING: 目前不是 macOS；AppKit release build 必須在 Mac 上執行，這一項未宣稱通過。\n' >&2
fi

if command -v git >/dev/null 2>&1 && [[ -d .git ]]; then
  git diff --check
fi

if [[ "$FULL_APP_BUILD" == "passed" ]]; then
  printf '\n全部檢查（含 macOS release build）已通過。\n'
else
  printf '\n所有跨平台檢查已通過；macOS AppKit release build 尚待在 Mac 上執行。\n'
fi
printf '本次暫存輸出會在視窗關閉時自動移除。\n'
if [[ -t 0 ]]; then
  read -r '?按 Return 關閉：' || true
fi
