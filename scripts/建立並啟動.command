#!/bin/zsh
emulate -L zsh
set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

APP_VERSION="1.7.5"
APP_BUILD="33"
SCANNER_VERSION="2.5.3"
BUNDLE_ID="local.macstoragelens.app"

printf '%s\n' \
  "MacStorageLens（磁碟透視）v${APP_VERSION} 建立工具" \
  '這會在本機編譯 Swift 原生 macOS App，不會執行磁碟掃描或清理。' \
  ''

if ! command -v swift >/dev/null 2>&1; then
  printf '%s\n' \
    'ERROR: 找不到 Swift 編譯器。' \
    '請先在 Terminal 執行：xcode-select --install' >&2
  read -r '?按 Return 關閉：'
  exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
  arm64|x86_64) ;;
  *)
    printf 'ERROR: 不支援的 CPU 架構：%s\n' "$ARCH" >&2
    exit 1
    ;;
esac

for required in \
  "$ROOT/Resources/mac-system-storage-tree-v${SCANNER_VERSION}.command" \
  "$ROOT/Resources/mac-system-storage-tree-core-v${SCANNER_VERSION}.command" \
  "$ROOT/Resources/MacStorageLens.icns" \
  "$ROOT/Resources/MacStorageLens-icon-1024.png"
do
  if [[ ! -f "$required" ]]; then
    printf 'ERROR: 缺少必要資源：%s\n' "$required" >&2
    exit 1
  fi
done

# Prefer a stable local signing identity. TCC grants are tied to code identity;
# repeatedly ad-hoc signing a rebuilt app can make macOS treat it as a new grant
# subject. The user may override automatic selection with this environment value:
#   MACSTORAGELENS_SIGNING_IDENTITY='Apple Development: ...' ./scripts/建立並啟動.command
SIGNING_IDENTITY="${MACSTORAGELENS_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
  identity_line="$({ security find-identity -v -p codesigning 2>/dev/null || true; } | \
    /usr/bin/grep -E '"(Apple Development|Developer ID Application):' | /usr/bin/head -n 1 || true)"
  if [[ -n "$identity_line" ]]; then
    SIGNING_IDENTITY="${identity_line#*\"}"
    SIGNING_IDENTITY="${SIGNING_IDENTITY%\"*}"
  fi
fi

if command -v codesign >/dev/null 2>&1; then
  if [[ -n "$SIGNING_IDENTITY" ]]; then
    SIGNING_MODE="identity"
  else
    SIGNING_MODE="ad-hoc"
  fi
else
  SIGNING_MODE="unsigned"
fi

printf 'Swift 編譯器：%s\n' "$(swift --version | /usr/bin/head -n 1)"
printf '正在清除舊的 SwiftPM 建置快取…\n'
swift package clean
printf '正在以 release 模式編譯（%s）…\n' "$ARCH"
swift build -c release --arch "$ARCH"
BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"
BINARY="$BIN_DIR/MacStorageLens"

if [[ ! -x "$BINARY" ]]; then
  printf 'ERROR: 找不到編譯結果：%s\n' "$BINARY" >&2
  exit 1
fi

DIST="$ROOT/dist"
APP="$DIST/MacStorageLens.app"
EXPECTED_APP="$ROOT/dist/MacStorageLens.app"
if [[ "$APP" != "$EXPECTED_APP" ]]; then
  printf 'ERROR: 安全檢查拒絕清除非預期建立路徑：%s\n' "$APP" >&2
  exit 1
fi
/bin/rm -rf -- "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/MacStorageLens"
cp "$ROOT/Resources/mac-system-storage-tree-v${SCANNER_VERSION}.command" "$APP/Contents/Resources/"
cp "$ROOT/Resources/mac-system-storage-tree-core-v${SCANNER_VERSION}.command" "$APP/Contents/Resources/"
cp "$ROOT/Resources/MacStorageLens.icns" "$APP/Contents/Resources/"
cp "$ROOT/Resources/MacStorageLens-icon-1024.png" "$APP/Contents/Resources/"
chmod 755 \
  "$APP/Contents/MacOS/MacStorageLens" \
  "$APP/Contents/Resources/mac-system-storage-tree-v${SCANNER_VERSION}.command" \
  "$APP/Contents/Resources/mac-system-storage-tree-core-v${SCANNER_VERSION}.command"
chmod 644 \
  "$APP/Contents/Resources/MacStorageLens.icns" \
  "$APP/Contents/Resources/MacStorageLens-icon-1024.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_TW</string>
    <key>CFBundleDisplayName</key>
    <string>磁碟透視</string>
    <key>CFBundleExecutable</key>
    <string>MacStorageLens</string>
    <key>CFBundleGetInfoString</key>
    <string>MacStorageLens ${APP_VERSION} — Jason Chen，使用 GPT-5.6 Pro 協作開發</string>
    <key>CFBundleIconFile</key>
    <string>MacStorageLens.icns</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MacStorageLens</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>MacStorageLensCodeSigningMode</key>
    <string>${SIGNING_MODE}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Jason Chen</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>用於掃描或匯入你選擇的資料夾與儲存空間報告。</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>用於掃描或匯入你選擇的資料夾與儲存空間報告。</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>用於掃描、移動到垃圾桶或永久清除你明確選擇之外接磁碟中繼資料。</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>用於掃描或匯入你選擇的資料夾與儲存空間報告。</string>
</dict>
</plist>
PLIST

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$APP/Contents/Info.plist" >/dev/null
fi

touch "$APP"
case "$SIGNING_MODE" in
  identity)
    printf '使用穩定程式簽章：%s\n' "$SIGNING_IDENTITY"
    codesign --force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
    ;;
  ad-hoc)
    printf '%s\n' \
      'WARNING: 找不到 Apple Development／Developer ID 簽章，改用 ad-hoc 簽章。' \
      '         重新建立後 macOS 可能要求重新授予完整磁碟存取。' >&2
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
    ;;
  unsigned)
    printf 'WARNING: 找不到 codesign，建立結果未簽章。\n' >&2
    ;;
esac

if command -v codesign >/dev/null 2>&1; then
  codesign --verify --deep --strict "$APP"
fi

printf '\n建立完成：\n%s\n\n' "$APP"
printf '%s\n' \
  '第一次開啟若被 Gatekeeper 阻擋，請在 Finder 對 App 按右鍵 →「打開」。' \
  '請把這一份固定路徑的「磁碟透視」加入「系統設定 → 隱私權與安全性 → 完整磁碟存取權」。' \
  '授權後請完全退出 App，再重新開啟；掃描設定頁會由 App 本身核對受保護路徑。' \
  '系統掃描建議使用「App + 管理員掃描」：App TCC 使用者資料會合併到管理員唯讀系統掃描。' \
  'Terminal 診斷模式仍使用同一個 scanner core，但權限主體是 Terminal。' \
  ''
open "$APP"
read -r '?按 Return 關閉這個視窗：'
