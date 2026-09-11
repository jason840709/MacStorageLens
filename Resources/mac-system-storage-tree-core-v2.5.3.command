#!/bin/zsh
emulate -L zsh

# macOS read-only storage tree generator
# Core Version 2.5.3
#
# This script only reads filesystem/APFS metadata and creates one Markdown report.
# It never deletes, moves, truncates, repairs, thins, flushes, or modifies user or
# system data. The only deletion is removal of this run's own mktemp directory.

set -u
umask 077
export LC_ALL=C

# Start the end-to-end scanner clock before target validation, TCC probing, and
# Disk Arbitration preflight. Older reports started the timer later and could say
# "2 seconds" even when the App had visibly waited twenty seconds.
PROCESS_START_EPOCH="$(/bin/date +%s)"

VERSION="2.5.3"
LARGE_FILE_MIB=500
LARGE_FILE_SCAN_MODE="no"   # ask | yes | no
LARGE_FILE_HEARTBEAT_SECONDS=15
SUDO_MODE="ask"          # ask | yes | no
SUDO_REQUIRED="false"
OUTPUT_DIR=""
TARGET_KIND="system"       # system | volume | folder
TARGET_PATH="/System/Volumes/Data"
TARGET_NAME=""
TARGET_VOLUME_UUID=""
LAUNCHER_MODE="unknown"    # app | terminal | direct
PRIVILEGE_CHANNEL="unknown" # app_direct | administrator_only | app_tcc_overlay_plus_administrator | terminal
APP_FDA_STATUS="UNKNOWN"
APP_FDA_PROBE_PATH="NONE"
TCC_OVERLAY_STATUS="NOT_REQUESTED"
TCC_OVERLAY_ROOT="NONE"
TCC_OVERLAY_RAW=""
TCC_OVERLAY_ERRORS=""
TCC_OVERLAY_APPLIED="false"
TCC_OVERLAY_DELTA_KIB="0"
TCC_OVERLAY_ROOT_KIB="UNKNOWN"
TCC_OVERLAY_REPLACED_KIB="UNKNOWN"
VOLUME_SCAN_PROFILE="complete_path_tree"
VOLUME_VOLATILE_METADATA_EXCLUDED="false"
typeset -a VOLUME_VOLATILE_METADATA_NAMES
VOLUME_VOLATILE_METADATA_NAMES=(
  .Trashes .Trash .Spotlight-V100 .fseventsd .TemporaryItems
  .DocumentRevisions-V100 .MobileBackups
)

usage() {
  cat <<'EOF'
Usage:
  Double-click the .command file, or run:

    mac-system-storage-tree.command [options]

Options:
  --sudo                    Require administrator read access.
  --no-sudo                 Do not request administrator read access.
  --scan-large-files        Run the optional exhaustive large-file second pass.
  --large-files             Alias for --scan-large-files.
  --ask-large-files         Ask after the directory tree has completed.
  --skip-large-files        Skip the optional second pass (default).
  --tree-only               Alias for --skip-large-files.
  --large-file-mib N        Large-file threshold in MiB (default: 500).
  --heartbeat-seconds N     Progress heartbeat for long scans (default: 15).
  --output-dir PATH         Write the Markdown report to PATH.
  --target-kind KIND        system, volume, or folder (default: system).
  --target-path PATH        Mounted volume root or folder to scan.
  --target-name NAME        Human-readable target name stored in the report.
  --target-volume-uuid UUID Optional mounted-volume UUID.
  --launcher-mode MODE      app, terminal, or direct.
  --privilege-channel MODE  app_direct, administrator_only,
                            app_tcc_overlay_plus_administrator, or terminal.
  --app-fda-probe STATUS    App-owned Full Disk Access probe supplied by the App.
  --app-fda-probe-path PATH Protected path used by the App-owned probe.
  --tcc-overlay-status S    App overlay status (NOT_REQUESTED, READY, etc.).
  --tcc-overlay-root PATH   User-home root represented by the App overlay.
  --tcc-overlay-raw PATH    App-owned `du -xk` rows to merge into Data.
  --tcc-overlay-errors PATH App-owned overlay diagnostic rows.
  -h, --help             Show this help.

The scan is read-only. For the most complete result, the launching host
(MacStorageLens or Terminal fallback) needs Full Disk Access in System Settings.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --sudo)
      SUDO_MODE="yes"
      SUDO_REQUIRED="true"
      shift
      ;;
    --no-sudo)
      SUDO_MODE="no"
      shift
      ;;
    --scan-large-files|--large-files)
      LARGE_FILE_SCAN_MODE="yes"
      shift
      ;;
    --ask-large-files)
      LARGE_FILE_SCAN_MODE="ask"
      shift
      ;;
    --skip-large-files|--tree-only)
      LARGE_FILE_SCAN_MODE="no"
      shift
      ;;
    --large-file-mib)
      if (( $# < 2 )); then
        printf 'ERROR: --large-file-mib requires a number.\n' >&2
        exit 2
      fi
      LARGE_FILE_MIB="$2"
      shift 2
      ;;
    --large-file-mib=*)
      LARGE_FILE_MIB="${1#*=}"
      shift
      ;;
    --heartbeat-seconds)
      if (( $# < 2 )); then
        printf 'ERROR: --heartbeat-seconds requires a number.\n' >&2
        exit 2
      fi
      LARGE_FILE_HEARTBEAT_SECONDS="$2"
      shift 2
      ;;
    --heartbeat-seconds=*)
      LARGE_FILE_HEARTBEAT_SECONDS="${1#*=}"
      shift
      ;;
    --output-dir)
      if (( $# < 2 )); then
        printf 'ERROR: --output-dir requires a path.\n' >&2
        exit 2
      fi
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --output-dir=*)
      OUTPUT_DIR="${1#*=}"
      shift
      ;;
    --target-kind)
      (( $# >= 2 )) || { printf 'ERROR: --target-kind requires a value.\n' >&2; exit 2; }
      TARGET_KIND="$2"
      shift 2
      ;;
    --target-kind=*)
      TARGET_KIND="${1#*=}"
      shift
      ;;
    --target-path)
      (( $# >= 2 )) || { printf 'ERROR: --target-path requires a path.\n' >&2; exit 2; }
      TARGET_PATH="$2"
      shift 2
      ;;
    --target-path=*)
      TARGET_PATH="${1#*=}"
      shift
      ;;
    --target-name)
      (( $# >= 2 )) || { printf 'ERROR: --target-name requires a value.\n' >&2; exit 2; }
      TARGET_NAME="$2"
      shift 2
      ;;
    --target-name=*)
      TARGET_NAME="${1#*=}"
      shift
      ;;
    --target-volume-uuid)
      (( $# >= 2 )) || { printf 'ERROR: --target-volume-uuid requires a value.\n' >&2; exit 2; }
      TARGET_VOLUME_UUID="$2"
      shift 2
      ;;
    --target-volume-uuid=*)
      TARGET_VOLUME_UUID="${1#*=}"
      shift
      ;;
    --launcher-mode)
      (( $# >= 2 )) || { printf 'ERROR: --launcher-mode requires a value.\n' >&2; exit 2; }
      LAUNCHER_MODE="$2"
      shift 2
      ;;
    --launcher-mode=*)
      LAUNCHER_MODE="${1#*=}"
      shift
      ;;
    --privilege-channel)
      (( $# >= 2 )) || { printf 'ERROR: --privilege-channel requires a value.\n' >&2; exit 2; }
      PRIVILEGE_CHANNEL="$2"
      shift 2
      ;;
    --privilege-channel=*)
      PRIVILEGE_CHANNEL="${1#*=}"
      shift
      ;;
    --app-fda-probe)
      (( $# >= 2 )) || { printf 'ERROR: --app-fda-probe requires a value.\n' >&2; exit 2; }
      APP_FDA_STATUS="$2"
      shift 2
      ;;
    --app-fda-probe=*)
      APP_FDA_STATUS="${1#*=}"
      shift
      ;;
    --app-fda-probe-path)
      (( $# >= 2 )) || { printf 'ERROR: --app-fda-probe-path requires a path.\n' >&2; exit 2; }
      APP_FDA_PROBE_PATH="$2"
      shift 2
      ;;
    --app-fda-probe-path=*)
      APP_FDA_PROBE_PATH="${1#*=}"
      shift
      ;;
    --tcc-overlay-status)
      (( $# >= 2 )) || { printf 'ERROR: --tcc-overlay-status requires a value.\n' >&2; exit 2; }
      TCC_OVERLAY_STATUS="$2"
      shift 2
      ;;
    --tcc-overlay-status=*)
      TCC_OVERLAY_STATUS="${1#*=}"
      shift
      ;;
    --tcc-overlay-root)
      (( $# >= 2 )) || { printf 'ERROR: --tcc-overlay-root requires a path.\n' >&2; exit 2; }
      TCC_OVERLAY_ROOT="$2"
      shift 2
      ;;
    --tcc-overlay-root=*)
      TCC_OVERLAY_ROOT="${1#*=}"
      shift
      ;;
    --tcc-overlay-raw)
      (( $# >= 2 )) || { printf 'ERROR: --tcc-overlay-raw requires a path.\n' >&2; exit 2; }
      TCC_OVERLAY_RAW="$2"
      shift 2
      ;;
    --tcc-overlay-raw=*)
      TCC_OVERLAY_RAW="${1#*=}"
      shift
      ;;
    --tcc-overlay-errors)
      (( $# >= 2 )) || { printf 'ERROR: --tcc-overlay-errors requires a path.\n' >&2; exit 2; }
      TCC_OVERLAY_ERRORS="$2"
      shift 2
      ;;
    --tcc-overlay-errors=*)
      TCC_OVERLAY_ERRORS="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$LARGE_FILE_MIB" in
  ''|*[!0-9]*)
    printf 'ERROR: --large-file-mib must be a positive integer.\n' >&2
    exit 2
    ;;
esac
if (( LARGE_FILE_MIB < 1 )); then
  printf 'ERROR: --large-file-mib must be at least 1.\n' >&2
  exit 2
fi
case "$LARGE_FILE_HEARTBEAT_SECONDS" in
  ''|*[!0-9]*)
    printf 'ERROR: --heartbeat-seconds must be a positive integer.\n' >&2
    exit 2
    ;;
esac
if (( LARGE_FILE_HEARTBEAT_SECONDS < 1 )); then
  printf 'ERROR: --heartbeat-seconds must be at least 1.\n' >&2
  exit 2
fi

case "$TARGET_KIND" in
  system|volume|folder) ;;
  *)
    printf 'ERROR: --target-kind must be system, volume, or folder.\n' >&2
    exit 2
    ;;
esac
case "$LAUNCHER_MODE" in
  app|terminal|direct|unknown) ;;
  *)
    printf 'ERROR: --launcher-mode must be app, terminal, direct, or unknown.\n' >&2
    exit 2
    ;;
esac

case "$PRIVILEGE_CHANNEL" in
  app_direct|administrator_only|app_tcc_overlay_plus_administrator|terminal|direct|unknown) ;;
  *)
    printf 'ERROR: invalid --privilege-channel value: %s\n' "$PRIVILEGE_CHANNEL" >&2
    exit 2
    ;;
esac
case "$APP_FDA_STATUS" in
  UNKNOWN|LIKELY_AVAILABLE|LIKELY_MISSING_OR_TCC_BLOCKED|NOT_APPLICABLE) ;;
  *)
    printf 'ERROR: invalid --app-fda-probe value: %s\n' "$APP_FDA_STATUS" >&2
    exit 2
    ;;
esac

if [[ "$TCC_OVERLAY_STATUS" == "READY" ]]; then
  if [[ "$TARGET_KIND" != "system" ]]; then
    printf 'ERROR: a TCC overlay is supported only for the system target.\n' >&2
    exit 2
  fi
  case "$TCC_OVERLAY_ROOT" in
    /System/Volumes/Data/Users/*) ;;
    *)
      printf 'ERROR: unsafe TCC overlay root: %s\n' "$TCC_OVERLAY_ROOT" >&2
      exit 2
      ;;
  esac
  if [[ ! -f "$TCC_OVERLAY_RAW" || ! -f "$TCC_OVERLAY_ERRORS" ]]; then
    printf 'ERROR: TCC overlay files are missing.\n' >&2
    exit 2
  fi
fi

if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
  printf 'ERROR: this scanner is designed for macOS only.\n' >&2
  exit 1
fi

if [[ "$TARGET_KIND" == "system" ]]; then
  TARGET_PATH="/System/Volumes/Data"
  TARGET_NAME="Macintosh HD"
fi
if [[ "$TARGET_PATH" != /* ]]; then
  printf 'ERROR: --target-path must be an absolute path.\n' >&2
  exit 2
fi
if [[ "$TARGET_PATH" == *$'\n'* || "$TARGET_PATH" == *$'\r'* || "$TARGET_PATH" == *$'\t'* ]]; then
  printf 'ERROR: scan target paths containing tabs or line breaks are not supported.\n' >&2
  exit 2
fi
if [[ ! -d "$TARGET_PATH" ]]; then
  printf 'ERROR: scan target is missing or not a directory: %s\n' "$TARGET_PATH" >&2
  exit 1
fi
TARGET_PATH="$(cd -P "$TARGET_PATH" 2>/dev/null && pwd -P)" || {
  printf 'ERROR: unable to resolve scan target: %s\n' "$TARGET_PATH" >&2
  exit 1
}

# POSIX `df -P` is the source of truth for the containing filesystem. Rebuild
# field 6 onward because mounted volume names may contain spaces. The first field
# gives the mounted device, which is then matched against the exact `mount` record.
# Do not use BSD stat `%T` here: on macOS it describes the file object type, not
# the filesystem format.
TARGET_DEVICE_IDENTIFIER="$(
  /bin/df -kP "$TARGET_PATH" 2>/dev/null |
    /usr/bin/awk 'NR == 2 { print $1; found=1 } END { if (!found) print "" }'
)"
TARGET_MOUNT_POINT="$(
  /bin/df -kP "$TARGET_PATH" 2>/dev/null |
    /usr/bin/awk '
      NR == 2 {
        mount=$6
        for (i=7; i<=NF; i++) mount=mount " " $i
        print mount
        found=1
      }
      END { if (!found) print "" }
    '
)"
if [[ -z "$TARGET_DEVICE_IDENTIFIER" || -z "$TARGET_MOUNT_POINT" || ! -d "$TARGET_MOUNT_POINT" ]]; then
  printf 'ERROR: unable to determine the mounted volume containing: %s\n' "$TARGET_PATH" >&2
  exit 1
fi
if [[ "$TARGET_KIND" == "volume" ]]; then
  # A volume scan always starts at the actual mount root, even if the picker was
  # handed a descendant URL by Finder or an alias.
  TARGET_PATH="$TARGET_MOUNT_POINT"
fi

TARGET_MOUNT_RECORD="$(
  /sbin/mount | /usr/bin/awk -v device="$TARGET_DEVICE_IDENTIFIER" -v mountpoint="$TARGET_MOUNT_POINT" '
    index($0, device " on ") == 1 { print; found=1; exit }
    index($0, " on " mountpoint " (") > 0 { fallback=$0 }
    END { if (!found && fallback != "") print fallback }
  '
)"
TARGET_FILESYSTEM_TYPE="$(
  printf '%s\n' "$TARGET_MOUNT_RECORD" |
    /usr/bin/sed -n 's/^.* (\([^,)]*\).*$/\1/p' |
    /usr/bin/head -n 1
)"
TARGET_FILESYSTEM_TYPE_SOURCE="mount_record"
if [[ -z "$TARGET_FILESYSTEM_TYPE" && -x /usr/sbin/diskutil && -x /usr/bin/plutil ]]; then
  TARGET_FILESYSTEM_TYPE="$(
    /usr/sbin/diskutil info -plist "$TARGET_MOUNT_POINT" 2>/dev/null |
      /usr/bin/plutil -extract FilesystemType raw -o - - 2>/dev/null || true
  )"
  TARGET_FILESYSTEM_TYPE_SOURCE="diskutil_plist_fallback"
fi
[[ -n "$TARGET_FILESYSTEM_TYPE" ]] || TARGET_FILESYSTEM_TYPE="UNKNOWN"
TARGET_FILESYSTEM_TYPE="${TARGET_FILESYSTEM_TYPE:l}"
TARGET_IS_APFS="false"
if [[ "$TARGET_FILESYSTEM_TYPE" == apfs* ]]; then
  TARGET_IS_APFS="true"
fi

TARGET_NAME="${TARGET_NAME//$'\n'/ }"
TARGET_NAME="${TARGET_NAME//$'\r'/ }"
TARGET_NAME="${TARGET_NAME//$'\t'/ }"
TARGET_VOLUME_UUID="${TARGET_VOLUME_UUID//$'\n'/}"
TARGET_VOLUME_UUID="${TARGET_VOLUME_UUID//$'\r'/}"
TARGET_VOLUME_UUID="${TARGET_VOLUME_UUID//$'\t'/}"
if [[ -z "$TARGET_NAME" ]]; then
  TARGET_NAME="$(/usr/bin/basename "$TARGET_PATH")"
  [[ -n "$TARGET_NAME" ]] || TARGET_NAME="$TARGET_PATH"
fi

SCRIPT_DIR="$(cd -P "$(/usr/bin/dirname "$0")" && pwd -P)"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$SCRIPT_DIR"
fi
if [[ ! -d "$OUTPUT_DIR" || ! -w "$OUTPUT_DIR" ]]; then
  printf 'ERROR: output directory is missing or not writable: %s\n' "$OUTPUT_DIR" >&2
  exit 1
fi

case "$TARGET_KIND" in
  system)
    WHOLE_ROOT_DU_SCANNED="false"
    WHOLE_ROOT_DU_OMISSION_REASON="unified_root_can_duplicate_firmlink_or_mounted_data"
    SCAN_SCOPE_MODE="logical_components_and_mounted_filesystems"
    ROOT_TOTALS_SUMMABLE="false"
    ;;
  volume)
    WHOLE_ROOT_DU_SCANNED="true"
    WHOLE_ROOT_DU_OMISSION_REASON="not_applicable"
    SCAN_SCOPE_MODE="selected_volume_single_filesystem"
    ROOT_TOTALS_SUMMABLE="true"
    ;;
  folder)
    WHOLE_ROOT_DU_SCANNED="true"
    WHOLE_ROOT_DU_OMISSION_REASON="not_applicable"
    SCAN_SCOPE_MODE="selected_folder_single_filesystem"
    ROOT_TOTALS_SUMMABLE="true"
    ;;
esac

STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
case "$TARGET_KIND" in
  system) OUT_PREFIX="system-storage-tree" ;;
  volume) OUT_PREFIX="volume-storage-tree" ;;
  folder) OUT_PREFIX="folder-storage-tree" ;;
esac
OUT_BASE="$OUTPUT_DIR/$OUT_PREFIX-$STAMP"
OUT="$OUT_BASE.md"
OUT_SUFFIX=1
while [[ -e "$OUT" ]]; do
  OUT="$OUT_BASE-$OUT_SUFFIX.md"
  OUT_SUFFIX=$(( OUT_SUFFIX + 1 ))
done
TMP_PARENT="${TMPDIR:-/tmp}"
TMP_PARENT="${TMP_PARENT%/}"
TMP="$(/usr/bin/mktemp -d "$TMP_PARENT/mac-system-tree.XXXXXX")" || {
  printf 'ERROR: could not create a temporary directory.\n' >&2
  exit 1
}
TMP_BASENAME="$(/usr/bin/basename "$TMP")"
SUDO_KEEPALIVE_PID=""
ACTIVE_SCAN_PID=""
ADMIN_READ="false"

cleanup() {
  if [[ -n "${ACTIVE_SCAN_PID:-}" ]] && /bin/kill -0 "$ACTIVE_SCAN_PID" >/dev/null 2>&1; then
    /usr/bin/pkill -TERM -P "$ACTIVE_SCAN_PID" >/dev/null 2>&1 || true
    /bin/kill -TERM "$ACTIVE_SCAN_PID" >/dev/null 2>&1 || true
    wait "$ACTIVE_SCAN_PID" >/dev/null 2>&1 || true
    ACTIVE_SCAN_PID=""
  fi

  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    /bin/kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
    wait "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
  fi

  # Safety guard: remove only the directory returned by this run's mktemp.
  if [[ -n "${TMP:-}" && -d "$TMP" && "$(/usr/bin/basename "$TMP")" == mac-system-tree.* ]]; then
    /bin/rm -rf -- "$TMP"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM

run_privileged() {
  if [[ "$ADMIN_READ" == "true" && "${EUID:-$(/usr/bin/id -u)}" -ne 0 ]]; then
    # Credentials were validated before scanning. -n prevents an invisible
    # background password prompt from making a long scan appear frozen.
    /usr/bin/sudo -n "$@"
  else
    "$@"
  fi
}

capture_command() {
  local label="$1"
  shift
  local rc=0
  local command_started_epoch="$(/bin/date +%s)"
  printf '%s\n' "--- $label ---"
  "$@" 2>&1 || rc=$?
  local command_finished_epoch="$(/bin/date +%s)"
  printf 'exit_status=%d\n' "$rc"
  printf 'duration_seconds=%d\n\n' $(( command_finished_epoch - command_started_epoch ))
}

printf '%s\n' \
  "macOS 唯讀儲存空間資料樹掃描器 v${VERSION}" \
  "掃描目標：${TARGET_NAME}（${TARGET_KIND}）" \
  "目標路徑：${TARGET_PATH}" \
  '唯讀：不會刪除、移動、清空、修復或修改任何使用者／系統資料。' \
  ''

if [[ "${EUID:-$(/usr/bin/id -u)}" -eq 0 ]]; then
  ADMIN_READ="true"
elif [[ "$SUDO_MODE" == "ask" && -t 0 ]]; then
  printf '%s' '要使用管理員「唯讀」權限提高掃描完整度嗎？[Y/n] '
  reply=""
  IFS= read -r reply || true
  case "$reply" in
    n|N|no|NO|No)
      SUDO_MODE="no"
      ;;
    *)
      SUDO_MODE="yes"
      ;;
  esac
fi

if [[ "$SUDO_MODE" == "yes" && "$ADMIN_READ" != "true" ]]; then
  printf '%s\n' 'macOS 會要求管理員密碼；輸入時畫面不會顯示字元。'
  if /usr/bin/sudo -v; then
    ADMIN_READ="true"
    (
      while /usr/bin/sudo -n -v >/dev/null 2>&1; do
        /bin/sleep 45
      done
    ) &
    SUDO_KEEPALIVE_PID=$!
  else
    if [[ "$SUDO_REQUIRED" == "true" ]]; then
      printf '%s\n' 'ERROR: --sudo 已指定，但未取得管理員讀取權限。' >&2
      exit 1
    fi
    printf '%s\n' 'WARNING: 未取得管理員讀取權限，將繼續進行受限掃描。' >&2
  fi
fi

# TCC applies to the responsible process chain, not merely to uid 0. A full
# system scan needs a protected-user-data probe. An external volume or selected
# folder does not: probing Mail/Messages/Safari touched unrelated macOS services
# and introduced a variable delay before a tiny volume scan even began.
SCANNER_FDA_STATUS="NOT_APPLICABLE"
SCANNER_FDA_PROBE_PATH="NONE"
if [[ "$TARGET_KIND" == "system" ]]; then
  SCANNER_FDA_STATUS="UNKNOWN"
  : > "$TMP/fda-probe.err"
  for protected_path in \
    "$HOME/Library/Mail" \
    "$HOME/Library/Messages" \
    "$HOME/Library/Safari" \
    "$HOME/Library/Application Support/AddressBook"
  do
    if [[ -d "$protected_path" ]]; then
      SCANNER_FDA_PROBE_PATH="$protected_path"
      if run_privileged /bin/ls -A "$protected_path" >/dev/null 2>"$TMP/fda-probe.err"; then
        SCANNER_FDA_STATUS="LIKELY_AVAILABLE"
      else
        SCANNER_FDA_STATUS="LIKELY_MISSING_OR_TCC_BLOCKED"
      fi
      break
    fi
  done
else
  APP_FDA_STATUS="NOT_APPLICABLE"
  APP_FDA_PROBE_PATH="NONE"
fi

if [[ "$PRIVILEGE_CHANNEL" == "app_direct" && "$APP_FDA_STATUS" == "UNKNOWN" ]]; then
  APP_FDA_STATUS="$SCANNER_FDA_STATUS"
  APP_FDA_PROBE_PATH="$SCANNER_FDA_PROBE_PATH"
fi

EFFECTIVE_FDA_STATUS="$SCANNER_FDA_STATUS"
EFFECTIVE_FDA_PROBE_PATH="$SCANNER_FDA_PROBE_PATH"
EFFECTIVE_FDA_SOURCE="scanner_process"
if [[ "$TARGET_KIND" != "system" ]]; then
  EFFECTIVE_FDA_STATUS="NOT_APPLICABLE"
  EFFECTIVE_FDA_PROBE_PATH="NONE"
  EFFECTIVE_FDA_SOURCE="selected_location"
elif [[ "$TCC_OVERLAY_STATUS" == "READY" && "$APP_FDA_STATUS" == "LIKELY_AVAILABLE" ]]; then
  EFFECTIVE_FDA_STATUS="LIKELY_AVAILABLE"
  EFFECTIVE_FDA_PROBE_PATH="$APP_FDA_PROBE_PATH"
  EFFECTIVE_FDA_SOURCE="app_tcc_overlay_pending"
elif [[ "$PRIVILEGE_CHANNEL" == "app_direct" ]]; then
  EFFECTIVE_FDA_SOURCE="app_direct"
elif [[ "$PRIVILEGE_CHANNEL" == "terminal" ]]; then
  EFFECTIVE_FDA_SOURCE="terminal"
fi

if [[ "$TARGET_KIND" == "system" && "$SCANNER_FDA_STATUS" == "LIKELY_MISSING_OR_TCC_BLOCKED" ]]; then
  if [[ "$PRIVILEGE_CHANNEL" == "administrator_only" || "$PRIVILEGE_CHANNEL" == "app_tcc_overlay_plus_administrator" ]]; then
    printf '%s\n' \
      'NOTICE: 管理員掃描子程序本身沒有繼承 MacStorageLens App 的 TCC 權限。' \
      '這不代表使用者沒有授權 App；若 App 覆蓋可用，受保護的使用者資料會在後續合併。' >&2
  else
    printf '%s\n' \
      'WARNING: 目前直接掃描通道無法讀取完整磁碟存取測試路徑。' \
      '請允許對應的啟動程式，完全退出後再重新開啟。' >&2
  fi
fi

# Build logical scan roots without running `du` on the unified `/` namespace.
# On modern macOS, firmlinks and mounted Data paths can make a whole-root `du`
# duplicate mutable data. The report therefore scans the Data volume, each
# immediate /System component except /System/Volumes, /usr, /bin, /sbin, and
# mounted filesystems below /System as independent, explicitly non-summable roots.
typeset -a ROOTS
ROOTS=()

add_root() {
  local candidate="$1"
  local existing=""
  [[ -d "$candidate" ]] || return 0
  for existing in "${ROOTS[@]}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  ROOTS+=("$candidate")
}

if [[ "$TARGET_KIND" == "system" ]]; then
  add_root "/System/Volumes/Data"

  if [[ -d /System ]]; then
    while IFS= read -r system_component; do
      [[ "$system_component" == "/System/Volumes" ]] && continue
      add_root "$system_component"
    done < <(
      /usr/bin/find /System -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null |
        /usr/bin/sort
    )
  fi

  for system_root in /usr /bin /sbin; do
    add_root "$system_root"
  done

  # Add mounted filesystems below /System, including auxiliary APFS volumes and
  # mounted cryptexes. Each is scanned separately with -x.
  while IFS= read -r mountpoint; do
    [[ "$mountpoint" == "/System/Volumes/Data" ]] && continue
    [[ "$mountpoint" == "/System/Volumes/Data/"* ]] && continue
    add_root "$mountpoint"
  done < <(
    /sbin/mount | /usr/bin/awk '
      / on \/System\// {
        line=$0
        sub(/^.* on /, "", line)
        sub(/ \([^)]*\)$/, "", line)
        if (line ~ /^\/System\//) print line
      }
    '
  )
else
  # Volume and folder modes intentionally scan one user-selected root. -x keeps
  # traversal on that filesystem and avoids silently crossing into other mounts.
  add_root "$TARGET_PATH"
fi
ROOT_COUNT=${#ROOTS[@]}

# macOS du -I lets us exclude this run's temporary directory from the Data scan,
# preventing the scanner from counting its own growing intermediate files.
DU_IGNORE_SUPPORTED="false"
typeset -a DU_IGNORE_ARGS
DU_IGNORE_ARGS=()
if /usr/bin/du -sk -I "__mac_system_tree_ignore_probe__" "$TMP" >/dev/null 2>&1; then
  DU_IGNORE_SUPPORTED="true"
  DU_IGNORE_ARGS=(-I "$TMP_BASENAME")

  # A mounted-volume scan keeps df as the complete capacity source, but does not
  # recursively traverse volatile macOS service data or this volume's hidden
  # Trash. Repeated cleanup otherwise moves a large Spotlight/FSEvents tree under
  # .Trashes and the next `du` walks the same data again, making each rescan
  # progressively slower without adding useful user-file information. The omitted
  # bytes remain visible in target_accounting_gap_kib and are inspected separately
  # by the general-location cleanup engine. Folder scans are intentionally left
  # unchanged because a user-selected folder may legitimately contain similarly
  # named descendants.
  if [[ "$TARGET_KIND" == "volume" ]]; then
    for volatile_name in "${VOLUME_VOLATILE_METADATA_NAMES[@]}"; do
      DU_IGNORE_ARGS+=(-I "$volatile_name")
    done
    VOLUME_SCAN_PROFILE="fast_stable_volume_tree"
    VOLUME_VOLATILE_METADATA_EXCLUDED="true"
  fi
fi

LARGE_THRESHOLD_BYTES=$(( LARGE_FILE_MIB * 1024 * 1024 - 1 ))
START_EPOCH="$PROCESS_START_EPOCH"
PREFLIGHT_END_EPOCH="$(/bin/date +%s)"
PREFLIGHT_DURATION_SECONDS=$(( PREFLIGHT_END_EPOCH - PROCESS_START_EPOCH ))
PREPARE_PHASE_START_EPOCH="$PREFLIGHT_END_EPOCH"

# Capture accounting before the scanner creates its large temporary result files.
# Each read-only command is announced on stdout so the App can show the exact
# preflight operation and detect a Disk Arbitration/APFS command that stops replying.
PRE_SCAN_STATUS="$TMP/pre-scan-status.txt"
: > "$PRE_SCAN_STATUS"
PREPARE_STEP=0
if [[ "$TARGET_KIND" == "system" ]]; then
  PREPARE_TOTAL=6
elif [[ "$TARGET_KIND" == "volume" && "$TARGET_IS_APFS" == "true" ]]; then
  PREPARE_TOTAL=4
else
  PREPARE_TOTAL=3
fi
prepare_capture() {
  local label="$1"
  shift
  PREPARE_STEP=$(( PREPARE_STEP + 1 ))
  printf '[準備 %d/%d] %s\n' "$PREPARE_STEP" "$PREPARE_TOTAL" "$label"
  capture_command "$label" "$@" >> "$PRE_SCAN_STATUS"
}
prepare_capture '記錄掃描時間基準' /bin/date '+%Y-%m-%d %H:%M:%S %z'
prepare_capture '核對掃描根節點容量（df -h）' /bin/df -h "${ROOTS[@]}"
prepare_capture '核對掃描根節點區塊帳務（df -kP）' /bin/df -kP "${ROOTS[@]}"
if [[ "$TARGET_KIND" == "system" ]]; then
  prepare_capture '讀取系統卷 APFS 快照' /usr/sbin/diskutil apfs listSnapshots /
  prepare_capture '讀取 Data 卷 APFS 快照' /usr/sbin/diskutil apfs listSnapshots /System/Volumes/Data
  prepare_capture '讀取 Time Machine 本機快照' /usr/bin/tmutil listlocalsnapshots /
elif [[ "$TARGET_KIND" == "volume" && "$TARGET_IS_APFS" == "true" ]]; then
  prepare_capture '讀取目標磁碟 APFS 快照' /usr/sbin/diskutil apfs listSnapshots "$TARGET_PATH"
fi
PREPARE_DURATION_SECONDS=$(( $(/bin/date +%s) - PREPARE_PHASE_START_EPOCH ))
printf '[準備完成 %d/%d] 掃描前容量與快照核對完成（%d 秒）\n' \
  "$PREPARE_STEP" "$PREPARE_TOTAL" "$PREPARE_DURATION_SECONDS"
PATH_SCAN_PHASE_START_EPOCH="$(/bin/date +%s)"

TARGET_DF_CAPACITY_KIB_PRE="$(/bin/df -kP "$TARGET_PATH" 2>/dev/null | /usr/bin/awk 'NR==2 {print $2; found=1} END{if(!found) print "UNKNOWN"}')"
TARGET_DF_USED_KIB_PRE="$(/bin/df -kP "$TARGET_PATH" 2>/dev/null | /usr/bin/awk 'NR==2 {print $3; found=1} END{if(!found) print "UNKNOWN"}')"
TARGET_DF_AVAILABLE_KIB_PRE="$(/bin/df -kP "$TARGET_PATH" 2>/dev/null | /usr/bin/awk 'NR==2 {print $4; found=1} END{if(!found) print "UNKNOWN"}')"
if [[ "$TARGET_KIND" == "system" ]]; then
  DATA_DF_USED_KIB_PRE="$TARGET_DF_USED_KIB_PRE"
else
  DATA_DF_USED_KIB_PRE="UNKNOWN"
fi

META="$TMP/root-meta.tsv"
: > "$META"

extract_du_kib() {
  local source="$1"
  local target="$2"
  /usr/bin/awk -v target="$target" '
    {
      tab=index($0, "\t")
      if (tab > 0) {
        kib=substr($0, 1, tab-1)
        path=substr($0, tab+1)
      } else if (match($0, /^[0-9]+[[:space:]]+/)) {
        kib=substr($0, 1, RLENGTH)
        gsub(/[[:space:]]/, "", kib)
        path=substr($0, RLENGTH+1)
      } else {
        next
      }
      if (path == target) {
        print kib
        found=1
      }
    }
    END { if (!found) print "UNKNOWN" }
  ' "$source"
}

merge_app_tcc_overlay() {
  local root_raw="$1"
  local root_err="$2"
  local overlay_kib="UNKNOWN"
  local replaced_kib="UNKNOWN"
  local delta=0
  local merged="$TMP/tcc-overlay-merged.raw"
  local filtered_err="$TMP/tcc-overlay-merged.err"

  [[ "$TCC_OVERLAY_STATUS" == "READY" ]] || return 0
  [[ "$APP_FDA_STATUS" == "LIKELY_AVAILABLE" ]] || return 0
  [[ -f "$TCC_OVERLAY_RAW" && -f "$TCC_OVERLAY_ERRORS" ]] || return 0

  overlay_kib="$(extract_du_kib "$TCC_OVERLAY_RAW" "$TCC_OVERLAY_ROOT")"
  replaced_kib="$(extract_du_kib "$root_raw" "$TCC_OVERLAY_ROOT")"
  if [[ "$overlay_kib" != <-> || "$replaced_kib" != <-> ]]; then
    TCC_OVERLAY_STATUS="MERGE_FAILED"
    EFFECTIVE_FDA_STATUS="$SCANNER_FDA_STATUS"
    EFFECTIVE_FDA_PROBE_PATH="$SCANNER_FDA_PROBE_PATH"
    EFFECTIVE_FDA_SOURCE="scanner_process"
    printf '%s\n' 'WARNING: App TCC 覆蓋缺少可核對的根節點，未合併到 Data 資料樹。' >&2
    return 0
  fi

  delta=$(( overlay_kib - replaced_kib ))
  /usr/bin/awk -v overlay="$TCC_OVERLAY_ROOT" -v delta="$delta" '
    {
      tab=index($0, "\t")
      if (tab > 0) {
        kib=substr($0, 1, tab-1)
        path=substr($0, tab+1)
      } else if (match($0, /^[0-9]+[[:space:]]+/)) {
        kib=substr($0, 1, RLENGTH)
        gsub(/[[:space:]]/, "", kib)
        path=substr($0, RLENGTH+1)
      } else {
        next
      }

      if (path == overlay || index(path, overlay "/") == 1) next
      if (index(overlay, path "/") == 1) {
        kib += delta
        if (kib < 0) kib=0
      }
      print kib "\t" path
    }
  ' "$root_raw" > "$merged"
  /bin/cat "$TCC_OVERLAY_RAW" >> "$merged"
  /bin/mv -f "$merged" "$root_raw"

  /usr/bin/awk -v overlay="$TCC_OVERLAY_ROOT" 'index($0, overlay) == 0' \
    "$root_err" > "$filtered_err"
  /bin/cat "$TCC_OVERLAY_ERRORS" >> "$filtered_err"
  /bin/mv -f "$filtered_err" "$root_err"

  TCC_OVERLAY_STATUS="APPLIED"
  TCC_OVERLAY_APPLIED="true"
  TCC_OVERLAY_DELTA_KIB="$delta"
  TCC_OVERLAY_ROOT_KIB="$overlay_kib"
  TCC_OVERLAY_REPLACED_KIB="$replaced_kib"
  EFFECTIVE_FDA_STATUS="LIKELY_AVAILABLE"
  EFFECTIVE_FDA_PROBE_PATH="$APP_FDA_PROBE_PATH"
  EFFECTIVE_FDA_SOURCE="app_tcc_overlay"
  printf '  App TCC 覆蓋已合併：%s KiB（取代管理員子程序的 %s KiB；差額 %+d KiB）\n' \
    "$overlay_kib" "$replaced_kib" "$delta"
}

printf '掃描根節點數：%d\n' "$ROOT_COUNT"
if [[ "$TARGET_KIND" == "volume" && "$VOLUME_VOLATILE_METADATA_EXCLUDED" == "true" ]]; then
  printf '%s\n' \
    '快速穩定卷宗樹：略過 .Trashes、Spotlight／FSEvents 等會重建的卷宗中繼資料深度遍歷；完整容量仍由 df 帳務保留。'
fi
root_index=0
for root in "${ROOTS[@]}"; do
  root_index=$(( root_index + 1 ))
  root_id="$(printf '%03d' "$root_index")"
  raw="$TMP/du-$root_id.raw"
  sorted="$TMP/du-$root_id.sorted"
  err="$TMP/du-$root_id.err"
  : > "$raw"
  : > "$sorted"
  : > "$err"

  printf '[%d/%d] %s\n' "$root_index" "$ROOT_COUNT" "$root"
  scan_start="$(/bin/date +%s)"
  du_done="$TMP/du-$root_id.done"
  /bin/rm -f "$du_done" "$du_done.tmp"

  (
    root_du_status=0
    run_privileged /usr/bin/du -xk "${DU_IGNORE_ARGS[@]}" "$root" > "$raw" 2> "$err" || root_du_status=$?
    printf '%s\n' "$root_du_status" > "$du_done.tmp"
    /bin/mv "$du_done.tmp" "$du_done"
  ) &
  ACTIVE_SCAN_PID=$!

  next_heartbeat=$LARGE_FILE_HEARTBEAT_SECONDS
  while [[ ! -f "$du_done" ]]; do
    /bin/sleep 1
    now="$(/bin/date +%s)"
    elapsed=$(( now - scan_start ))
    if (( elapsed >= next_heartbeat )); then
      nodes_so_far="$(/usr/bin/wc -l < "$raw" | /usr/bin/tr -d '[:space:]')"
      errors_so_far="$(/usr/bin/wc -l < "$err" | /usr/bin/tr -d '[:space:]')"
      printf '  仍在掃描：已經過 %d 秒；目前目錄節點 %s；受限／診斷行 %s\n' \
        "$elapsed" "$nodes_so_far" "$errors_so_far"
      next_heartbeat=$(( next_heartbeat + LARGE_FILE_HEARTBEAT_SECONDS ))
    fi
  done

  wait "$ACTIVE_SCAN_PID" >/dev/null 2>&1 || true
  ACTIVE_SCAN_PID=""
  du_status="$(/bin/cat "$du_done" 2>/dev/null || printf '1')"

  if [[ "$root" == "/System/Volumes/Data" ]]; then
    merge_app_tcc_overlay "$raw" "$err"
  fi

  sort_status=0
  /usr/bin/sort -t $'\t' -k2 "$raw" > "$sorted" 2>> "$err" || sort_status=$?
  if (( sort_status != 0 && du_status == 0 )); then
    du_status=$sort_status
  fi

  total_kib="$(/usr/bin/awk -v target="$root" '
    {
      tab=index($0, "\t")
      if (tab > 0) {
        kib=substr($0, 1, tab-1)
        path=substr($0, tab+1)
      } else if (match($0, /^[0-9]+[[:space:]]+/)) {
        kib=substr($0, 1, RLENGTH)
        gsub(/[[:space:]]/, "", kib)
        path=substr($0, RLENGTH+1)
      } else {
        next
      }
      if (path == target) {
        print kib
        found=1
      }
    }
    END { if (!found) print "UNKNOWN" }
  ' "$raw")"

  node_count="$(/usr/bin/wc -l < "$raw" | /usr/bin/tr -d '[:space:]')"
  error_count="$(/usr/bin/wc -l < "$err" | /usr/bin/tr -d '[:space:]')"
  permission_count="$(/usr/bin/grep -Eic 'Permission denied|Operation not permitted' "$err" 2>/dev/null || true)"
  scan_end="$(/bin/date +%s)"
  scan_seconds=$(( scan_end - scan_start ))

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$root_id" "$root" "$total_kib" "$node_count" "$error_count" \
    "$permission_count" "$du_status" "$scan_seconds" >> "$META"
  du_note="完整"
  if (( du_status != 0 )); then
    du_note="部分路徑受限或讀取失敗；已保留全部可讀結果"
  fi
  printf '  完成：%s 秒；目錄節點 %s；受限／診斷行 %s；du exit=%s（%s）\n' \
    "$scan_seconds" "$node_count" "$error_count" "$du_status" "$du_note"
  if (( error_count > 0 )); then
    printf '%s\n' '  註：受限／診斷行已寫入報告並標示為 UNKNOWN_SIZE；不代表整體掃描失敗。'
  fi
done

ROOT_SCAN_ERROR_LINES="$(/usr/bin/awk -F '\t' '{sum+=$5} END{print sum+0}' "$META")"
ROOT_SCAN_PERMISSION_ERRORS="$(/usr/bin/awk -F '\t' '{sum+=$6} END{print sum+0}' "$META")"
if (( ROOT_SCAN_ERROR_LINES > 0 )); then
  printf '\n路徑掃描完成：%s 個受限／診斷行（其中 %s 個權限／TCC 錯誤）已保留在報告；掃描會繼續建立完整 Markdown。\n' \
    "$ROOT_SCAN_ERROR_LINES" "$ROOT_SCAN_PERMISSION_ERRORS"
fi

# The complete directory tree is already available at this point. The large-file
# list is an optional second full traversal and is not required for directory-tree
# coverage. Double-click runs skip it by default so the scanner cannot appear
# frozen after the useful tree scan has already completed.
LARGE_RAW="$TMP/large-files.raw"
LARGE_BY_LOGICAL="$TMP/large-files.logical"
LARGE_BY_ALLOCATED="$TMP/large-files.allocated"
LARGE_ERR="$TMP/large-files.err"
: > "$LARGE_RAW"
: > "$LARGE_ERR"

PATH_SCAN_DURATION_SECONDS=$(( $(/bin/date +%s) - PATH_SCAN_PHASE_START_EPOCH ))

LARGE_FILE_SCAN_SELECTED="false"
if [[ "$LARGE_FILE_SCAN_MODE" == "yes" ]]; then
  LARGE_FILE_SCAN_SELECTED="true"
elif [[ "$LARGE_FILE_SCAN_MODE" == "ask" && -t 0 ]]; then
  printf '\n%s\n' \
    '完整資料夾樹已掃描完成。' \
    '接下來的「大檔案逐檔掃描」會再次遍歷檔案系統，可能比前面更久；它只是附加清單，不影響資料夾樹完整度。'
  printf '%s' '要執行這個附加掃描嗎？[y/N] '
  large_reply=""
  IFS= read -r large_reply || true
  case "$large_reply" in
    y|Y|yes|YES|Yes)
      LARGE_FILE_SCAN_SELECTED="true"
      ;;
  esac
fi

# Large-file discovery uses canonical physical roots instead of re-running find
# over every logical /System component. This avoids redundant traversal of the
# same sealed-system filesystem while retaining Data, the sealed root, and each
# separately mounted auxiliary filesystem.
typeset -a LARGE_ROOTS
LARGE_ROOTS=()
add_large_root() {
  local candidate="$1"
  local existing=""
  [[ -d "$candidate" ]] || return 0
  for existing in "${LARGE_ROOTS[@]}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  LARGE_ROOTS+=("$candidate")
}

if [[ "$LARGE_FILE_SCAN_SELECTED" == "true" ]]; then
  if [[ "$TARGET_KIND" == "system" ]]; then
    add_large_root "/System/Volumes/Data"
    add_large_root "/"
    while IFS= read -r mountpoint; do
      [[ "$mountpoint" == "/System/Volumes/Data" ]] && continue
      [[ "$mountpoint" == "/System/Volumes/Data/"* ]] && continue
      add_large_root "$mountpoint"
    done < <(
      /sbin/mount | /usr/bin/awk '
        / on \/System\// {
          line=$0
          sub(/^.* on /, "", line)
          sub(/ \([^)]*\)$/, "", line)
          if (line ~ /^\/System\//) print line
        }
      '
    )
  else
    add_large_root "$TARGET_PATH"
  fi
fi

LARGE_ROOT_COUNT=${#LARGE_ROOTS[@]}
LARGE_FILE_SCAN_STATUS="SKIPPED_OPTIONAL_SECOND_PASS"
LARGE_FILE_SCAN_SECONDS=0
LARGE_FILE_SCAN_NONZERO_ROOTS=0
LARGE_FILE_MATCH_COUNT=0

if [[ "$LARGE_FILE_SCAN_SELECTED" == "true" ]]; then
  LARGE_FILE_SCAN_STATUS="RUNNING"
  printf '\n掃描大檔案（≥ %d MiB）；物理根節點數：%d\n' "$LARGE_FILE_MIB" "$LARGE_ROOT_COUNT"
  large_scan_start="$(/bin/date +%s)"
  large_index=0

  for root in "${LARGE_ROOTS[@]}"; do
    large_index=$(( large_index + 1 ))
    large_id="$(printf '%03d' "$large_index")"
    large_root_raw="$TMP/large-root-$large_id.raw"
    large_done="$TMP/large-root-$large_id.done"
    : > "$large_root_raw"
    /bin/rm -f "$large_done" "$large_done.tmp"

    typeset -a find_args
    find_args=("$root" -xdev)

    # Do not enter external/network/automount namespaces. They are not internal
    # Macintosh HD data and stale mounts can block metadata traversal.
    if [[ "$root" == "/System/Volumes/Data" ]]; then
      find_args+=(
        '(' -name "$TMP_BASENAME"
            -o -path "$root/Volumes"
            -o -path "$root/Network"
            -o -path "$root/home"
            -o -path "$root/net" ')' -prune -o
      )
    elif [[ "$root" == "/" ]]; then
      find_args+=(
        '(' -name "$TMP_BASENAME"
            -o -path '/System/Volumes/Data'
            -o -path '/Volumes'
            -o -path '/Network'
            -o -path '/home'
            -o -path '/net' ')' -prune -o
      )
    else
      find_args+=( '(' -name "$TMP_BASENAME" ')' -prune -o )
    fi

    # macOS find supports the batched `-exec ... {} +` form. This records file
    # metadata without launching one stat process for every matching file.
    find_args+=(
      '(' -type f -size "+${LARGE_THRESHOLD_BYTES}c"
          -exec /usr/bin/stat
            -f '%z%t%b%t%d%t%i%t%l%t%Sm%t%N'
            -t '%Y-%m-%dT%H:%M:%S%z' '{}' + ')'
    )

    printf '[大檔 %d/%d] %s\n' "$large_index" "$LARGE_ROOT_COUNT" "$root"
    root_scan_start="$(/bin/date +%s)"

    (
      find_status_inner=0
      if [[ "$ADMIN_READ" == "true" && "${EUID:-$(/usr/bin/id -u)}" -ne 0 ]]; then
        /usr/bin/sudo -n /usr/bin/find "${find_args[@]}" > "$large_root_raw" 2>> "$LARGE_ERR" || find_status_inner=$?
      else
        /usr/bin/find "${find_args[@]}" > "$large_root_raw" 2>> "$LARGE_ERR" || find_status_inner=$?
      fi
      printf '%s\n' "$find_status_inner" > "$large_done.tmp"
      /bin/mv "$large_done.tmp" "$large_done"
    ) &
    ACTIVE_SCAN_PID=$!

    next_heartbeat=$LARGE_FILE_HEARTBEAT_SECONDS
    while [[ ! -f "$large_done" ]]; do
      /bin/sleep 1
      now="$(/bin/date +%s)"
      elapsed=$(( now - root_scan_start ))
      if (( elapsed >= next_heartbeat )); then
        matches_so_far="$(/usr/bin/wc -l < "$large_root_raw" | /usr/bin/tr -d '[:space:]')"
        error_lines_so_far="$(/usr/bin/wc -l < "$LARGE_ERR" | /usr/bin/tr -d '[:space:]')"
        printf '  仍在掃描：已經過 %d 秒；目前列出 %s 個大檔；累計受限／診斷行 %s\n' \
          "$elapsed" "$matches_so_far" "$error_lines_so_far"
        next_heartbeat=$(( next_heartbeat + LARGE_FILE_HEARTBEAT_SECONDS ))
      fi
    done

    wait "$ACTIVE_SCAN_PID" >/dev/null 2>&1 || true
    ACTIVE_SCAN_PID=""
    find_status="$(/bin/cat "$large_done" 2>/dev/null || printf '1')"
    if (( find_status != 0 )); then
      LARGE_FILE_SCAN_NONZERO_ROOTS=$(( LARGE_FILE_SCAN_NONZERO_ROOTS + 1 ))
    fi

    /bin/cat "$large_root_raw" >> "$LARGE_RAW"
    root_match_count="$(/usr/bin/wc -l < "$large_root_raw" | /usr/bin/tr -d '[:space:]')"
    root_scan_end="$(/bin/date +%s)"
    printf '  完成：%s 個候選，%d 秒，find exit=%s\n' \
      "$root_match_count" "$(( root_scan_end - root_scan_start ))" "$find_status"
  done

  /usr/bin/sort -t $'\t' -k1,1nr "$LARGE_RAW" > "$LARGE_BY_LOGICAL"
  /usr/bin/sort -t $'\t' -k2,2nr "$LARGE_RAW" > "$LARGE_BY_ALLOCATED"
  LARGE_FILE_MATCH_COUNT="$(/usr/bin/wc -l < "$LARGE_RAW" | /usr/bin/tr -d '[:space:]')"
  large_scan_end="$(/bin/date +%s)"
  LARGE_FILE_SCAN_SECONDS=$(( large_scan_end - large_scan_start ))
  if (( LARGE_FILE_SCAN_NONZERO_ROOTS == 0 )); then
    LARGE_FILE_SCAN_STATUS="COMPLETE"
  else
    LARGE_FILE_SCAN_STATUS="COMPLETE_WITH_FIND_ERRORS"
  fi
else
  : > "$LARGE_BY_LOGICAL"
  : > "$LARGE_BY_ALLOCATED"
  printf '\n略過附加大檔案掃描；完整資料夾樹仍會正常產生。\n'
fi

# Read-only volume, APFS, snapshot, Time Machine, Spotlight, and content-cache status.
METADATA_PHASE_START_EPOCH="$(/bin/date +%s)"
printf '\n收集目標磁碟、APFS 與快照狀態\n'
SYSTEM_STATUS="$TMP/system-status.txt"
ASSETCACHE_STATUS="$TMP/assetcache-status.txt"
: > "$SYSTEM_STATUS"
: > "$ASSETCACHE_STATUS"
ASSETCACHE_TOOL="$(command -v AssetCacheManagerUtil 2>/dev/null || true)"
METADATA_STEP=0
if [[ "$TARGET_KIND" == "system" ]]; then
  if [[ -n "$ASSETCACHE_TOOL" ]]; then
    METADATA_TOTAL=27
  else
    METADATA_TOTAL=23
  fi
elif [[ "$TARGET_KIND" == "volume" && "$TARGET_IS_APFS" == "true" ]]; then
  # Seven target facts, APFS inventory text/plist, target snapshot text/plist,
  # and one explicit content-cache not-applicable note.
  METADATA_TOTAL=12
else
  # Non-APFS external media and selected folders do not need a full-machine APFS
  # inventory. Skipping it prevents unrelated Disk Arbitration latency from making
  # repeated scans of the same 32 GB card progressively slower.
  METADATA_TOTAL=10
fi
metadata_capture() {
  local destination="$1"
  local label="$2"
  shift 2
  METADATA_STEP=$(( METADATA_STEP + 1 ))
  printf '[系統狀態 %d/%d] %s\n' "$METADATA_STEP" "$METADATA_TOTAL" "$label"
  capture_command "$label" "$@" >> "$destination"
}
metadata_note() {
  local destination="$1"
  local label="$2"
  local note="$3"
  METADATA_STEP=$(( METADATA_STEP + 1 ))
  printf '[系統狀態 %d/%d] %s\n' "$METADATA_STEP" "$METADATA_TOTAL" "$label"
  printf '%s\n' "$note" >> "$destination"
}

metadata_capture "$SYSTEM_STATUS" '讀取 macOS 版本' /usr/bin/sw_vers
metadata_capture "$SYSTEM_STATUS" '讀取核心與硬體架構' /usr/bin/uname -a
metadata_capture "$SYSTEM_STATUS" '核對掃描後容量（df -h）' /bin/df -h "${ROOTS[@]}"
metadata_capture "$SYSTEM_STATUS" '核對掃描後區塊帳務（df -kP）' /bin/df -kP "${ROOTS[@]}"
if [[ "$TARGET_KIND" == "system" ]]; then
  metadata_capture "$SYSTEM_STATUS" '讀取目前掛載點' /sbin/mount
  metadata_capture "$SYSTEM_STATUS" '讀取掃描目標磁碟資訊' /usr/sbin/diskutil info "$TARGET_MOUNT_POINT"
  metadata_capture "$SYSTEM_STATUS" '讀取掃描目標磁碟 plist 資訊' /usr/sbin/diskutil info -plist "$TARGET_MOUNT_POINT"
else
  metadata_note "$SYSTEM_STATUS" '讀取掃描目標掛載點' "selected_target_device=$TARGET_DEVICE_IDENTIFIER\nselected_target_mount_record=$TARGET_MOUNT_RECORD"
  metadata_note "$SYSTEM_STATUS" '讀取掃描目標磁碟資訊' 'target_diskutil_info_text=SKIPPED_FOR_FAST_SELECTED_LOCATION_SCAN'
  if [[ "$TARGET_KIND" == "volume" && "$TARGET_IS_APFS" == "true" ]]; then
    metadata_capture "$SYSTEM_STATUS" '讀取掃描目標磁碟 plist 資訊' /usr/sbin/diskutil info -plist "$TARGET_MOUNT_POINT"
  else
    metadata_note "$SYSTEM_STATUS" '讀取掃描目標磁碟 plist 資訊' 'target_diskutil_info_plist=SKIPPED_NOT_REQUIRED_FOR_SELECTED_NON_APFS_TARGET'
  fi
fi
if [[ "$TARGET_KIND" == "system" || ( "$TARGET_KIND" == "volume" && "$TARGET_IS_APFS" == "true" ) ]]; then
  metadata_capture "$SYSTEM_STATUS" '列出 APFS 容器與卷' /usr/sbin/diskutil apfs list
  metadata_capture "$SYSTEM_STATUS" '列出 APFS 容器 plist' /usr/sbin/diskutil apfs list -plist
else
  metadata_note "$SYSTEM_STATUS" 'APFS 全機清單' 'apfs_global_inventory=SKIPPED_NOT_REQUIRED_FOR_SELECTED_NON_APFS_TARGET'
  metadata_note "$SYSTEM_STATUS" 'APFS 容器 plist' 'apfs_global_inventory_plist=SKIPPED_NOT_REQUIRED_FOR_SELECTED_NON_APFS_TARGET'
fi

if [[ "$TARGET_KIND" == "system" ]]; then
  if [[ -r /usr/share/firmlinks ]]; then
    metadata_capture "$SYSTEM_STATUS" '讀取 APFS firmlink 對照表' /bin/cat /usr/share/firmlinks
  else
    metadata_note "$SYSTEM_STATUS" '檢查 APFS firmlink 對照表' 'firmlinks=NOT_READABLE'
  fi
  metadata_capture "$SYSTEM_STATUS" '讀取系統卷資訊' /usr/sbin/diskutil info /
  metadata_capture "$SYSTEM_STATUS" '讀取系統卷 plist 資訊' /usr/sbin/diskutil info -plist /
  metadata_capture "$SYSTEM_STATUS" '列出 APFS Volume Groups' /usr/sbin/diskutil apfs listVolumeGroups -plist
  metadata_capture "$SYSTEM_STATUS" '列出系統卷 APFS 快照' /usr/sbin/diskutil apfs listSnapshots /
  metadata_capture "$SYSTEM_STATUS" '列出系統卷 APFS 快照 plist' /usr/sbin/diskutil apfs listSnapshots -plist /
  metadata_capture "$SYSTEM_STATUS" '列出 Data 卷 APFS 快照' /usr/sbin/diskutil apfs listSnapshots /System/Volumes/Data
  metadata_capture "$SYSTEM_STATUS" '列出 Data 卷 APFS 快照 plist' /usr/sbin/diskutil apfs listSnapshots -plist /System/Volumes/Data
  metadata_capture "$SYSTEM_STATUS" '列出 Time Machine 本機快照' /usr/bin/tmutil listlocalsnapshots /
  metadata_capture "$SYSTEM_STATUS" '列出 Time Machine 本機快照日期' /usr/bin/tmutil listlocalsnapshotdates /
  metadata_capture "$SYSTEM_STATUS" '讀取 Time Machine 狀態' /usr/bin/tmutil status
  metadata_capture "$SYSTEM_STATUS" '讀取 Time Machine 目的地' /usr/bin/tmutil destinationinfo
  if [[ -x /usr/bin/mdutil ]]; then
    metadata_capture "$SYSTEM_STATUS" '讀取 Spotlight 索引狀態' /usr/bin/mdutil -sa
  else
    metadata_note "$SYSTEM_STATUS" '檢查 Spotlight 索引工具' 'mdutil=NOT_AVAILABLE'
  fi

  if [[ -n "$ASSETCACHE_TOOL" ]]; then
    metadata_capture "$ASSETCACHE_STATUS" '檢查內容快取是否啟用' "$ASSETCACHE_TOOL" isActivated
    metadata_capture "$ASSETCACHE_STATUS" '讀取內容快取狀態' "$ASSETCACHE_TOOL" status
    metadata_capture "$ASSETCACHE_STATUS" '讀取內容快取設定' "$ASSETCACHE_TOOL" settings
    metadata_capture "$ASSETCACHE_STATUS" '讀取內容快取 JSON 狀態' "$ASSETCACHE_TOOL" -j status
    metadata_capture "$ASSETCACHE_STATUS" '讀取內容快取 JSON 設定' "$ASSETCACHE_TOOL" -j settings
  else
    metadata_note "$ASSETCACHE_STATUS" '檢查內容快取工具' 'AssetCacheManagerUtil=NOT_AVAILABLE'
  fi
elif [[ "$TARGET_KIND" == "volume" && "$TARGET_IS_APFS" == "true" ]]; then
  metadata_capture "$SYSTEM_STATUS" '列出目標磁碟 APFS 快照' /usr/sbin/diskutil apfs listSnapshots "$TARGET_MOUNT_POINT"
  metadata_capture "$SYSTEM_STATUS" '列出目標磁碟 APFS 快照 plist' /usr/sbin/diskutil apfs listSnapshots -plist "$TARGET_MOUNT_POINT"
  metadata_note "$ASSETCACHE_STATUS" '內容快取系統分析' 'content_cache_analysis=NOT_APPLICABLE_FOR_NON_SYSTEM_TARGET'
else
  metadata_note "$ASSETCACHE_STATUS" '內容快取系統分析' 'content_cache_analysis=NOT_APPLICABLE_FOR_NON_SYSTEM_TARGET'
fi
TOTAL_ERROR_LINES="$(/usr/bin/awk -F '\t' '{sum+=$5} END{print sum+0}' "$META")"
TOTAL_PERMISSION_ERRORS="$(/usr/bin/awk -F '\t' '{sum+=$6} END{print sum+0}' "$META")"
if (( TOTAL_ERROR_LINES == 0 )); then
  PATH_SCAN_STATUS="NO_REPORTED_DU_ERRORS"
else
  PATH_SCAN_STATUS="PARTIAL_UNREADABLE_PATHS"
fi

TARGET_TREE_DU_KIB="$(/usr/bin/awk -F '\t' -v target="$TARGET_PATH" '$2==target {print $3; found=1} END{if(!found) print "UNKNOWN"}' "$META")"
TARGET_DF_USED_KIB_POST="$(/bin/df -kP "$TARGET_PATH" 2>/dev/null | /usr/bin/awk 'NR==2 {print $3; found=1} END{if(!found) print "UNKNOWN"}')"
if [[ "$TARGET_DF_USED_KIB_PRE" != "UNKNOWN" && "$TARGET_DF_USED_KIB_POST" != "UNKNOWN" ]]; then
  TARGET_DF_SCAN_DELTA_KIB=$(( TARGET_DF_USED_KIB_POST - TARGET_DF_USED_KIB_PRE ))
else
  TARGET_DF_SCAN_DELTA_KIB="UNKNOWN"
fi

if [[ "$TARGET_KIND" == "folder" ]]; then
  TARGET_ACCOUNTING_SCOPE="folder_tree_only"
  TARGET_ACCOUNTING_GAP_APPLICABLE="false"
  TARGET_ACCOUNTING_DIFFERENCE_KIB=0
elif [[ "$TARGET_KIND" == "volume" ]]; then
  TARGET_ACCOUNTING_SCOPE="selected_volume"
  TARGET_ACCOUNTING_GAP_APPLICABLE="true"
  if [[ "$TARGET_TREE_DU_KIB" != "UNKNOWN" && "$TARGET_DF_USED_KIB_PRE" != "UNKNOWN" ]]; then
    TARGET_ACCOUNTING_DIFFERENCE_KIB=$(( TARGET_DF_USED_KIB_PRE - TARGET_TREE_DU_KIB ))
    (( TARGET_ACCOUNTING_DIFFERENCE_KIB >= 0 )) || TARGET_ACCOUNTING_DIFFERENCE_KIB=0
  else
    TARGET_ACCOUNTING_DIFFERENCE_KIB="UNKNOWN"
  fi
else
  TARGET_ACCOUNTING_SCOPE="system_data_volume"
  TARGET_ACCOUNTING_GAP_APPLICABLE="true"
  if [[ "$TARGET_TREE_DU_KIB" != "UNKNOWN" && "$TARGET_DF_USED_KIB_PRE" != "UNKNOWN" ]]; then
    TARGET_ACCOUNTING_DIFFERENCE_KIB=$(( TARGET_DF_USED_KIB_PRE - TARGET_TREE_DU_KIB ))
    (( TARGET_ACCOUNTING_DIFFERENCE_KIB >= 0 )) || TARGET_ACCOUNTING_DIFFERENCE_KIB=0
  else
    TARGET_ACCOUNTING_DIFFERENCE_KIB="UNKNOWN"
  fi
fi

# Record only root-entry identity for volatile service data. Do not recurse:
# this section exists to distinguish "excluded from the stable tree" from
# "actually absent" without reintroducing the metadata-I/O slowdown.
TARGET_VOLATILE_STATUS_FILE="$TMP/target-volatile-status.tsv"
: > "$TARGET_VOLATILE_STATUS_FILE"
TARGET_SPOTLIGHT_STATUS="NOT_APPLICABLE"
TARGET_FSEVENTS_STATUS="NOT_APPLICABLE"
TARGET_TRASH_STATUS="NOT_APPLICABLE"
if [[ "$TARGET_KIND" == "volume" ]]; then
  for volatile_name in "${VOLUME_VOLATILE_METADATA_NAMES[@]}"; do
    volatile_path="$TARGET_PATH/$volatile_name"
    volatile_status="ABSENT"
    volatile_kind="NONE"
    volatile_device="UNKNOWN"
    volatile_inode="UNKNOWN"
    volatile_mtime="UNKNOWN"
    if [[ -e "$volatile_path" || -L "$volatile_path" ]]; then
      volatile_status="PRESENT"
      if [[ -L "$volatile_path" ]]; then
        volatile_kind="SYMLINK"
      elif [[ -d "$volatile_path" ]]; then
        volatile_kind="DIRECTORY"
      elif [[ -f "$volatile_path" ]]; then
        volatile_kind="FILE"
      else
        volatile_kind="OTHER"
      fi
      volatile_device="$(/usr/bin/stat -f '%d' "$volatile_path" 2>/dev/null || printf 'UNKNOWN')"
      volatile_inode="$(/usr/bin/stat -f '%i' "$volatile_path" 2>/dev/null || printf 'UNKNOWN')"
      volatile_mtime="$(/usr/bin/stat -f '%m' "$volatile_path" 2>/dev/null || printf 'UNKNOWN')"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$volatile_name" "$volatile_status" "$volatile_kind" "$volatile_device" "$volatile_inode" "$volatile_mtime" \
      >> "$TARGET_VOLATILE_STATUS_FILE"
    case "$volatile_name" in
      .Spotlight-V100) TARGET_SPOTLIGHT_STATUS="$volatile_status" ;;
      .fseventsd) TARGET_FSEVENTS_STATUS="$volatile_status" ;;
      .Trashes|.Trash)
        if [[ "$volatile_status" == "PRESENT" ]]; then TARGET_TRASH_STATUS="PRESENT"; elif [[ "$TARGET_TRASH_STATUS" == "NOT_APPLICABLE" ]]; then TARGET_TRASH_STATUS="ABSENT"; fi
        ;;
    esac
  done
  [[ "$TARGET_TRASH_STATUS" != "NOT_APPLICABLE" ]] || TARGET_TRASH_STATUS="ABSENT"
fi

if [[ "$TARGET_KIND" == "system" ]]; then
  DATA_DU_KIB="$TARGET_TREE_DU_KIB"
  DATA_DF_USED_KIB_POST="$TARGET_DF_USED_KIB_POST"
  DATA_DF_SCAN_DELTA_KIB="$TARGET_DF_SCAN_DELTA_KIB"
  DATA_ACCOUNTING_DIFFERENCE_KIB="$TARGET_ACCOUNTING_DIFFERENCE_KIB"
else
  DATA_DU_KIB="UNKNOWN"
  DATA_DF_USED_KIB_POST="UNKNOWN"
  DATA_DF_SCAN_DELTA_KIB="UNKNOWN"
  DATA_ACCOUNTING_DIFFERENCE_KIB="UNKNOWN"
fi

ASSETCACHE_DEFAULT_PATH="NOT_APPLICABLE"
ASSETCACHE_DU_KIB="NOT_APPLICABLE"
if [[ "$TARGET_KIND" == "system" ]]; then
  ASSETCACHE_DEFAULT_PATH="/System/Volumes/Data/Library/Application Support/Apple/AssetCache/Data"
  DATA_RAW=""
  while IFS=$'\t' read -r meta_id meta_root meta_total meta_nodes meta_errors meta_denied meta_status meta_seconds; do
    if [[ "$meta_root" == "/System/Volumes/Data" ]]; then
      DATA_RAW="$TMP/du-$meta_id.raw"
      break
    fi
  done < "$META"

  ASSETCACHE_DU_KIB="UNKNOWN"
  if [[ -n "$DATA_RAW" && -s "$DATA_RAW" ]]; then
    ASSETCACHE_DU_KIB="$(/usr/bin/awk -v target="$ASSETCACHE_DEFAULT_PATH" '
      {
        tab=index($0, "\t")
        if (tab > 0) {
          kib=substr($0, 1, tab-1)
          path=substr($0, tab+1)
        } else if (match($0, /^[0-9]+[[:space:]]+/)) {
          kib=substr($0, 1, RLENGTH)
          gsub(/[[:space:]]/, "", kib)
          path=substr($0, RLENGTH+1)
        } else next
        if (path == target) { print kib; found=1 }
      }
      END { if (!found) print "UNKNOWN" }
    ' "$DATA_RAW")"
  fi
fi

# End the data-collection clock only after root-only volatile metadata identity,
# accounting reconciliation, and Content Caching extraction have completed. This
# keeps report timings aligned with the wait visible in the App.
METADATA_DURATION_SECONDS=$(( $(/bin/date +%s) - METADATA_PHASE_START_EPOCH ))
printf '[系統狀態完成 %d/%d] 目標磁碟、APFS 與快照狀態已收集（%d 秒）\n' \
  "$METADATA_STEP" "$METADATA_TOTAL" "$METADATA_DURATION_SECONDS"
END_EPOCH="$(/bin/date +%s)"
DURATION_SECONDS=$(( END_EPOCH - START_EPOCH ))


# The output file is intentionally created only after the directory scan and any
# user-selected optional large-file scan have finished, so the report cannot count
# its own growing Markdown file.
REPORT_WRITE_PHASE_START_EPOCH="$(/bin/date +%s)"
printf '\n產生 Markdown 報告：%s\n' "$OUT"
: > "$OUT"

{
  printf '# %s - 唯讀儲存空間資料樹\n\n' "$TARGET_NAME"
  printf '%s\n\n' '## RUN_METADATA'
  printf '%s\n' '````text'
  printf 'scanner_version=%s\n' "$VERSION"
  printf 'generated_at=%s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S %z')"
  printf 'output=%s\n' "$OUT"
  printf 'data_collection_duration_seconds=%s\n' "$DURATION_SECONDS"
  printf 'scanner_process_started_epoch=%s\n' "$PROCESS_START_EPOCH"
  printf 'preflight_duration_seconds=%s\n' "$PREFLIGHT_DURATION_SECONDS"
  printf 'prepare_duration_seconds=%s\n' "$PREPARE_DURATION_SECONDS"
  printf 'path_scan_duration_seconds=%s\n' "$PATH_SCAN_DURATION_SECONDS"
  printf 'metadata_duration_seconds=%s\n' "$METADATA_DURATION_SECONDS"
  printf 'scan_target_kind=%s\n' "$TARGET_KIND"
  printf 'scan_target_path=%s\n' "$TARGET_PATH"
  printf 'scan_target_display_name=%s\n' "$TARGET_NAME"
  printf 'scan_target_volume_uuid=%s\n' "${TARGET_VOLUME_UUID:-NONE}"
  printf 'target_mount_point=%s\n' "$TARGET_MOUNT_POINT"
  printf 'target_device_identifier=%s\n' "$TARGET_DEVICE_IDENTIFIER"
  printf 'target_mount_record=%s\n' "$TARGET_MOUNT_RECORD"
  printf 'target_filesystem_type=%s\n' "$TARGET_FILESYSTEM_TYPE"
  printf 'target_filesystem_type_source=%s\n' "$TARGET_FILESYSTEM_TYPE_SOURCE"
  printf 'target_is_apfs=%s\n' "$TARGET_IS_APFS"
  printf 'target_spotlight_root_status=%s\n' "$TARGET_SPOTLIGHT_STATUS"
  printf 'target_fsevents_root_status=%s\n' "$TARGET_FSEVENTS_STATUS"
  printf 'target_trash_root_status=%s\n' "$TARGET_TRASH_STATUS"
  printf 'target_volatile_status_is_recursive=false\n'
  printf 'launcher_mode=%s\n' "$LAUNCHER_MODE"
  printf 'scanner_privilege_channel=%s\n' "$PRIVILEGE_CHANNEL"
  printf '%s\n' \
    'user_or_system_data_deletion=false' \
    'user_or_system_data_modification=false' \
    'temporary_directory_removed_after_run=true' \
    'output_created_after_path_scan=true' \
    'existing_report_overwritten=false'
  printf 'administrator_read_access=%s\n' "$ADMIN_READ"
  printf 'full_disk_access_probe=%s\n' "$EFFECTIVE_FDA_STATUS"
  printf 'full_disk_access_probe_path=%s\n' "$EFFECTIVE_FDA_PROBE_PATH"
  printf 'full_disk_access_source=%s\n' "$EFFECTIVE_FDA_SOURCE"
  printf 'app_full_disk_access_probe=%s\n' "$APP_FDA_STATUS"
  printf 'app_full_disk_access_probe_path=%s\n' "$APP_FDA_PROBE_PATH"
  printf 'scanner_full_disk_access_probe=%s\n' "$SCANNER_FDA_STATUS"
  printf 'scanner_full_disk_access_probe_path=%s\n' "$SCANNER_FDA_PROBE_PATH"
  printf 'tcc_overlay_status=%s\n' "$TCC_OVERLAY_STATUS"
  printf 'tcc_overlay_root=%s\n' "$TCC_OVERLAY_ROOT"
  printf 'tcc_overlay_applied=%s\n' "$TCC_OVERLAY_APPLIED"
  printf 'tcc_overlay_delta_kib=%s\n' "$TCC_OVERLAY_DELTA_KIB"
  printf 'tcc_overlay_tree_kib=%s\n' "$TCC_OVERLAY_ROOT_KIB"
  printf 'tcc_overlay_replaced_kib=%s\n' "$TCC_OVERLAY_REPLACED_KIB"
  printf 'scan_root_count=%s\n' "$ROOT_COUNT"
  printf 'path_scan_status=%s\n' "$PATH_SCAN_STATUS"
  printf 'du_error_line_count=%s\n' "$TOTAL_ERROR_LINES"
  printf 'permission_or_tcc_error_count=%s\n' "$TOTAL_PERMISSION_ERRORS"
  printf 'du_ignore_supported=%s\n' "$DU_IGNORE_SUPPORTED"
  printf 'temporary_directory_excluded_from_du=%s\n' "$DU_IGNORE_SUPPORTED"
  printf 'volume_scan_profile=%s\n' "$VOLUME_SCAN_PROFILE"
  printf 'volume_volatile_metadata_excluded=%s\n' "$VOLUME_VOLATILE_METADATA_EXCLUDED"
  printf 'volume_volatile_metadata_names=%s\n' "${(j:,:)VOLUME_VOLATILE_METADATA_NAMES}"
  printf 'volume_volatile_metadata_accounted_by_df=true\n'
  printf 'large_file_threshold_mib=%s\n' "$LARGE_FILE_MIB"
  printf 'large_file_scan_mode=%s\n' "$LARGE_FILE_SCAN_MODE"
  printf 'large_file_scan_selected=%s\n' "$LARGE_FILE_SCAN_SELECTED"
  printf 'large_file_scan_status=%s\n' "$LARGE_FILE_SCAN_STATUS"
  printf 'large_file_scan_root_count=%s\n' "$LARGE_ROOT_COUNT"
  printf 'large_file_scan_seconds=%s\n' "$LARGE_FILE_SCAN_SECONDS"
  printf 'large_file_scan_nonzero_root_count=%s\n' "$LARGE_FILE_SCAN_NONZERO_ROOTS"
  printf 'large_file_match_count=%s\n' "$LARGE_FILE_MATCH_COUNT"
  printf 'large_file_heartbeat_seconds=%s\n' "$LARGE_FILE_HEARTBEAT_SECONDS"
  if [[ "$TARGET_KIND" == "system" ]]; then
    printf '%s\n' 'macos_system_data_is_single_path=false'
  else
    printf '%s\n' 'macos_system_data_is_single_path=not_applicable'
  fi
  printf 'whole_root_du_scanned=%s\n' "$WHOLE_ROOT_DU_SCANNED"
  printf 'whole_root_du_omission_reason=%s\n' "$WHOLE_ROOT_DU_OMISSION_REASON"
  printf 'scan_scope_mode=%s\n' "$SCAN_SCOPE_MODE"
  # Retain the legacy key for older parsers while making its meaning target-aware.
  printf 'system_scan_mode=%s\n' "$SCAN_SCOPE_MODE"
  printf 'root_totals_are_summable=%s\n' "$ROOT_TOTALS_SUMMABLE"
  printf '%s\n' \
    'directory_node_totals_are_summable=false' \
    'reclaimable_bytes_calculated=false' \
    'du_measurement=filesystem_block_usage_in_1024_byte_blocks' \
    'decimal_gb_formula=KiB*1024/1000000000' \
    'gib_formula=KiB/1048576' \
    'large_file_allocated_bytes_formula=st_blocks*512' \
    'large_file_rows_are_summable=false' \
    'hardlink_paths_may_share_the_same_device_and_inode=true' \
    'apfs_clone_or_snapshot_exclusive_bytes_calculated=false'
  printf '%s\n\n' '````'

  printf '%s\n\n' '## TARGET_VOLUME_ACCOUNTING_DIFFERENCE'
  printf '%s\n' '````text'
  printf 'accounting_scope=%s\n' "$TARGET_ACCOUNTING_SCOPE"
  printf 'accounting_gap_applicable=%s\n' "$TARGET_ACCOUNTING_GAP_APPLICABLE"
  printf 'target_path=%s\n' "$TARGET_PATH"
  printf 'target_mount_point=%s\n' "$TARGET_MOUNT_POINT"
  printf 'target_tree_du_kib=%s\n' "$TARGET_TREE_DU_KIB"
  printf 'target_volume_capacity_kib=%s\n' "$TARGET_DF_CAPACITY_KIB_PRE"
  printf 'target_volume_used_kib_pre_scan=%s\n' "$TARGET_DF_USED_KIB_PRE"
  printf 'target_volume_available_kib_pre_scan=%s\n' "$TARGET_DF_AVAILABLE_KIB_PRE"
  printf 'target_volume_used_kib_post_scan_before_report=%s\n' "$TARGET_DF_USED_KIB_POST"
  printf 'target_post_minus_pre_kib=%s\n' "$TARGET_DF_SCAN_DELTA_KIB"
  printf 'target_accounting_gap_kib=%s\n' "$TARGET_ACCOUNTING_DIFFERENCE_KIB"
  if [[ "$TARGET_KIND" == "folder" ]]; then
    printf '%s\n' \
      'interpretation=folder_tree_size_is_not_a_volume_accounting_reconciliation' \
      'possible_components=not_applicable'
  elif [[ "$TARGET_KIND" == "volume" && "$VOLUME_VOLATILE_METADATA_EXCLUDED" == "true" ]]; then
    printf '%s\n' \
      'interpretation=stable_tree_excludes_volatile_volume_metadata' \
      'possible_components=volume_trash|spotlight_index|fsevents_history|temporary_items|document_revisions|metadata|filesystem_semantics'
  else
    printf '%s\n' \
      'interpretation=accounting_difference_not_automatically_deletable' \
      'possible_components=unreadable_paths|snapshots|metadata|filesystem_semantics'
  fi
  printf '%s\n\n' '````'

  if [[ "$TARGET_KIND" == "system" ]]; then
    printf '%s\n\n' '## DATA_VOLUME_ACCOUNTING_DIFFERENCE'
    printf '%s\n' '````text'
    printf 'data_volume_du_kib=%s\n' "$DATA_DU_KIB"
    printf 'data_volume_df_used_kib_pre_scan=%s\n' "$DATA_DF_USED_KIB_PRE"
    printf 'data_volume_df_used_kib_post_scan_before_report=%s\n' "$DATA_DF_USED_KIB_POST"
    printf 'post_minus_pre_kib=%s\n' "$DATA_DF_SCAN_DELTA_KIB"
    printf 'df_pre_used_minus_du_kib=%s\n' "$DATA_ACCOUNTING_DIFFERENCE_KIB"
    printf '%s\n' \
      'interpretation=accounting_difference_not_automatically_deletable' \
      'possible_components=unreadable_paths|snapshots|metadata|filesystem_semantics'
    printf '%s\n\n' '````'
  fi

  printf '%s\n\n' '## CONTENT_CACHE_KEY_PATH'
  printf '%s\n' '````text'
  printf 'default_path=%s\n' "$ASSETCACHE_DEFAULT_PATH"
  printf 'du_kib=%s\n' "$ASSETCACHE_DU_KIB"
  printf '%s\n' 'size_unknown_means=path_absent_or_unreadable_or_cache_moved'
  printf '%s\n\n' '````'

  printf '%s\n\n' '## ROOT_SCAN_SUMMARY'
  printf '%s\n' '| Root | du KiB | GiB | GB | Directory nodes | Diagnostic lines | Permission/TCC restrictions | du exit | Seconds |'
  printf '%s\n' '|---|---:|---:|---:|---:|---:|---:|---:|---:|'
} >> "$OUT"

/usr/bin/awk -F '\t' '
  {
    if ($3 == "UNKNOWN") {
      gib="UNKNOWN"; gb="UNKNOWN"
    } else {
      gib=sprintf("%.3f", $3/1048576)
      gb=sprintf("%.3f", $3*1024/1000000000)
    }
    printf "| `%s` | %s | %s | %s | %s | %s | %s | %s | %s |\n", \
      $2, $3, gib, gb, $4, $5, $6, $7, $8
  }
' "$META" >> "$OUT"

cat >> "$OUT" <<'EOF'

## TARGET_VOLATILE_METADATA_STATUS

````text
name	status	kind	device	inode	mtime_epoch
EOF
if [[ -s "$TARGET_VOLATILE_STATUS_FILE" ]]; then
  /bin/cat "$TARGET_VOLATILE_STATUS_FILE" >> "$OUT"
else
  printf '%s\n' 'NOT_APPLICABLE' >> "$OUT"
fi
printf '%s\n\n' '````' >> "$OUT"

cat >> "$OUT" <<'EOF'

## PRE_SCAN_ACCOUNTING_AND_SNAPSHOTS

````text
EOF
cat "$PRE_SCAN_STATUS" >> "$OUT"
printf '%s\n\n' '````' >> "$OUT"

cat >> "$OUT" <<'EOF'
## POST_SCAN_VOLUME_AND_APFS_STATUS

````text
EOF
cat "$SYSTEM_STATUS" >> "$OUT"
printf '%s\n\n' '````' >> "$OUT"

cat >> "$OUT" <<'EOF'
## CONTENT_CACHING_STATUS

````text
EOF
cat "$ASSETCACHE_STATUS" >> "$OUT"
printf '%s\n\n' '````' >> "$OUT"

# Render each root: largest directory nodes, complete path-sorted tree, errors.
render_index=0
while IFS=$'\t' read -r meta_id meta_root meta_total meta_nodes meta_errors meta_denied meta_status meta_seconds; do
  render_index=$(( render_index + 1 ))
  printf '[報告 %d/%d] %s\n' "$render_index" "$ROOT_COUNT" "$meta_root"
  raw="$TMP/du-$meta_id.raw"
  sorted="$TMP/du-$meta_id.sorted"
  err="$TMP/du-$meta_id.err"

  printf '## ROOT %s\n\n' "$meta_root" >> "$OUT"
  printf '%s\n' '````text' >> "$OUT"
  printf 'root=%s\n' "$meta_root" >> "$OUT"
  printf 'du_kib=%s\n' "$meta_total" >> "$OUT"
  printf 'directory_nodes=%s\n' "$meta_nodes" >> "$OUT"
  printf 'error_lines=%s\n' "$meta_errors" >> "$OUT"
  printf 'permission_or_tcc_errors=%s\n' "$meta_denied" >> "$OUT"
  printf 'du_exit_status=%s\n' "$meta_status" >> "$OUT"
  printf 'scan_seconds=%s\n' "$meta_seconds" >> "$OUT"
  printf '%s\n\n' '````' >> "$OUT"

  printf '### LARGEST_DIRECTORY_NODES_TOP_200 (%s)\n\n' "$meta_root" >> "$OUT"
  printf '%s\n' '````text' >> "$OUT"
  /usr/bin/sort -nr -k1,1 "$raw" | /usr/bin/head -200 | /usr/bin/awk '
    function human_kib(kib, bytes) {
      bytes=kib*1024
      if (bytes >= 1099511627776) return sprintf("%.2f TiB", bytes/1099511627776)
      if (bytes >= 1073741824) return sprintf("%.2f GiB", bytes/1073741824)
      if (bytes >= 1048576) return sprintf("%.2f MiB", bytes/1048576)
      if (bytes >= 1024) return sprintf("%.2f KiB", bytes/1024)
      return sprintf("%.0f B", bytes)
    }
    {
      tab=index($0, "\t")
      if (tab > 0) {
        kib=substr($0, 1, tab-1)
        path=substr($0, tab+1)
      } else if (match($0, /^[0-9]+[[:space:]]+/)) {
        kib=substr($0, 1, RLENGTH)
        gsub(/[[:space:]]/, "", kib)
        path=substr($0, RLENGTH+1)
      } else next
      printf "%s / %.3f GB / %s KiB  %s\n", human_kib(kib), kib*1024/1000000000, kib, path
    }
  ' >> "$OUT"
  printf '%s\n\n' '````' >> "$OUT"

  printf '### DIRECTORY_TREE (%s)\n\n' "$meta_root" >> "$OUT"
  printf '%s\n' '````text' >> "$OUT"
  /usr/bin/awk -v base="$meta_root" '
    function human_kib(kib, bytes) {
      bytes=kib*1024
      if (bytes >= 1099511627776) return sprintf("%.2f TiB", bytes/1099511627776)
      if (bytes >= 1073741824) return sprintf("%.2f GiB", bytes/1073741824)
      if (bytes >= 1048576) return sprintf("%.2f MiB", bytes/1048576)
      if (bytes >= 1024) return sprintf("%.2f KiB", bytes/1024)
      return sprintf("%.0f B", bytes)
    }
    {
      tab=index($0, "\t")
      if (tab > 0) {
        kib=substr($0, 1, tab-1)
        path=substr($0, tab+1)
      } else if (match($0, /^[0-9]+[[:space:]]+/)) {
        kib=substr($0, 1, RLENGTH)
        gsub(/[[:space:]]/, "", kib)
        path=substr($0, RLENGTH+1)
      } else next

      if (path == base) {
        printf "%s / %.3f GB / %s KiB  %s\n", human_kib(kib), kib*1024/1000000000, kib, path
        next
      }

      if (base == "/") rel=substr(path, 2)
      else rel=substr(path, length(base)+2)
      depth=1+gsub(/\//, "/", rel)
      indent=""
      for (i=1; i<depth; i++) indent=indent "│   "
      printf "%s├── %s / %.3f GB / %s KiB  %s\n", indent, human_kib(kib), kib*1024/1000000000, kib, path
    }
  ' "$sorted" >> "$OUT"
  printf '%s\n\n' '````' >> "$OUT"

  printf '### UNREADABLE_PATH_LIST (%s)\n\n' "$meta_root" >> "$OUT"
  printf '%s\n' '````text' >> "$OUT"
  if [[ -s "$err" ]]; then
    /usr/bin/sed 's/^/UNKNOWN_SIZE  /' "$err" >> "$OUT"
  else
    printf '%s\n' 'NONE' >> "$OUT"
  fi
  printf '%s\n\n' '````' >> "$OUT"
done < "$META"

render_large_file_list() {
  local source_file="$1"
  /usr/bin/awk -F '\t' '
    function human_bytes(bytes) {
      if (bytes >= 1099511627776) return sprintf("%.2f TiB", bytes/1099511627776)
      if (bytes >= 1073741824) return sprintf("%.2f GiB", bytes/1073741824)
      if (bytes >= 1048576) return sprintf("%.2f MiB", bytes/1048576)
      if (bytes >= 1024) return sprintf("%.2f KiB", bytes/1024)
      return sprintf("%.0f B", bytes)
    }
    {
      logical=$1
      allocated=$2*512
      dev=$3
      inode=$4
      links=$5
      mtime=$6
      path=$7
      for (i=8; i<=NF; i++) path=path "\t" $i
      printf "logical=%s (%s)  allocated=%s (%s)  links=%s  dev=%s  inode=%s  mtime=%s  path=%s\n", \
        logical, human_bytes(logical), allocated, human_bytes(allocated), links, dev, inode, mtime, path
    }
  ' "$source_file"
}

printf '## LARGE_FILES_BY_LOGICAL_SIZE_GE_%sMiB\n\n%s\n' "$LARGE_FILE_MIB" '````text' >> "$OUT"
if [[ "$LARGE_FILE_SCAN_SELECTED" != "true" ]]; then
  printf '%s\n' 'SKIPPED_OPTIONAL_SECOND_PASS' >> "$OUT"
elif [[ -s "$LARGE_BY_LOGICAL" ]]; then
  render_large_file_list "$LARGE_BY_LOGICAL" >> "$OUT"
else
  printf '%s\n' 'NONE' >> "$OUT"
fi
printf '%s\n\n' '````' >> "$OUT"

printf '## LARGE_FILES_LOGICAL_GE_%sMiB_SORTED_BY_ALLOCATED_BLOCKS\n\n%s\n' "$LARGE_FILE_MIB" '````text' >> "$OUT"
if [[ "$LARGE_FILE_SCAN_SELECTED" != "true" ]]; then
  printf '%s\n' 'SKIPPED_OPTIONAL_SECOND_PASS' >> "$OUT"
elif [[ -s "$LARGE_BY_ALLOCATED" ]]; then
  render_large_file_list "$LARGE_BY_ALLOCATED" >> "$OUT"
else
  printf '%s\n' 'NONE' >> "$OUT"
fi
printf '%s\n\n' '````' >> "$OUT"

cat >> "$OUT" <<'EOF'
## LARGE_FILE_SCAN_ERRORS

````text
EOF
if [[ "$LARGE_FILE_SCAN_SELECTED" != "true" ]]; then
  printf '%s\n' 'SKIPPED_OPTIONAL_SECOND_PASS' >> "$OUT"
elif [[ -s "$LARGE_ERR" ]]; then
  /usr/bin/sed 's/^/UNKNOWN_SIZE  /' "$LARGE_ERR" >> "$OUT"
else
  printf '%s\n' 'NONE' >> "$OUT"
fi
printf '%s\n\n' '````' >> "$OUT"

cat >> "$OUT" <<'EOF'
## INTERPRETATION_FLAGS

````text
parent_directory_sizes_include_children=true
adding_tree_nodes_is_invalid=true
adding_apfs_volume_du_totals_is_invalid=true
du_default_mode_is_block_usage_not_apparent_size=true
du_hard_links_counted_once_per_du_execution=true
large_file_scan_is_optional_second_pass=true
large_file_scan_skipped_does_not_reduce_directory_tree_coverage=true
large_file_scan_prunes_external_network_and_automount_namespaces=true
large_file_logical_size_is_not_reclaimable_size=true
large_file_allocated_blocks_are_not_apfs_exclusive_blocks=true
large_file_rows_are_summable=false
hardlink_paths_may_share_the_same_device_and_inode=true
snapshots_are_not_normal_directory_paths=true
free_space_is_not_a_file_path=true
purgeable_space_is_not_assumed_to_be_a_directory=true
unknown_size_is_not_treated_as_zero=true
files_with_newline_or_control_characters_in_names_may_render_imperfectly=true
````
EOF

FINAL_EPOCH="$(/bin/date +%s)"
REPORT_WRITE_DURATION_SECONDS=$(( FINAL_EPOCH - REPORT_WRITE_PHASE_START_EPOCH ))
TOTAL_DURATION_SECONDS=$(( FINAL_EPOCH - PROCESS_START_EPOCH ))
{
  printf '%s\n\n' '## COMPLETION'
  printf '%s\n' '````text'
  printf 'completed_at=%s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S %z')"
  printf 'total_duration_seconds=%s\n' "$TOTAL_DURATION_SECONDS"
  printf 'report_write_duration_seconds=%s\n' "$REPORT_WRITE_DURATION_SECONDS"
  printf '%s\n' 'report_complete=true'
  printf '%s\n' '````'
} >> "$OUT"

/bin/chmod 600 "$OUT" 2>/dev/null || true
if [[ "${EUID:-$(/usr/bin/id -u)}" -eq 0 && -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
  /usr/sbin/chown "$SUDO_UID:$SUDO_GID" "$OUT" 2>/dev/null || true
fi

printf '\nDONE\nOUTPUT=%s\n\n' "$OUT"
if [[ -t 0 ]]; then
  printf '%s' '按 Return 關閉這個 Terminal 視窗：'
  IFS= read -r _close_reply || true
fi
