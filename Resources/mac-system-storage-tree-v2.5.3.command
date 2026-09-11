#!/bin/zsh
emulate -L zsh

# MacStorageLens read-only storage scanner supervisor
# Version 2.5.3
#
# This wrapper runs the 2.5.3 read-only tree scanner, converts its human-readable
# output into structured progress events, monitors heartbeat/liveness, supports a
# cooperative cancel file, and removes only an incomplete report created by this
# run. It never deletes, moves, repairs, thins, flushes, or modifies user/system data.

set -u
umask 077
export LC_ALL=C

VERSION="2.5.3"
PROGRESS_FILE=""
CONTROL_DIR=""
HEARTBEAT_SECONDS=5
STALL_TIMEOUT_SECONDS=120
OUTPUT_DIR=""
typeset -a CORE_ARGS
CORE_ARGS=()

usage() {
  cat <<'EOF'
Usage:
  mac-system-storage-tree-v2.5.3.command [scanner options]

MacStorageLens integration options:
  --progress-file PATH          Append structured progress events to PATH.
  --control-dir PATH            Watch PATH/cancel.request for cancellation.
  --heartbeat-seconds N         Structured heartbeat interval (default: 5).
  --command-timeout-seconds N   Abort after N seconds without core output
                                (default: 120).

All other options are forwarded to the read-only storage tree core, including:
  --sudo | --no-sudo
  --output-dir PATH
  --target-kind system|volume|folder
  --target-path PATH
  --target-name NAME
  --target-volume-uuid UUID
  --launcher-mode app|terminal|direct|unknown
  --privilege-channel app_direct|administrator_only|app_tcc_overlay_plus_administrator|terminal
  --app-fda-probe STATUS | --app-fda-probe-path PATH
  --tcc-overlay-status STATUS | --tcc-overlay-root PATH
  --tcc-overlay-raw PATH | --tcc-overlay-errors PATH
  --skip-large-files | --scan-large-files
  --large-file-mib N

The scan is read-only. Cancellation removes only this run's incomplete report and
its own temporary supervisor files; previous complete reports remain untouched.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --progress-file)
      (( $# >= 2 )) || { printf 'ERROR: --progress-file requires a path.\n' >&2; exit 2; }
      PROGRESS_FILE="$2"
      shift 2
      ;;
    --progress-file=*)
      PROGRESS_FILE="${1#*=}"
      shift
      ;;
    --control-dir)
      (( $# >= 2 )) || { printf 'ERROR: --control-dir requires a path.\n' >&2; exit 2; }
      CONTROL_DIR="$2"
      shift 2
      ;;
    --control-dir=*)
      CONTROL_DIR="${1#*=}"
      shift
      ;;
    --heartbeat-seconds)
      (( $# >= 2 )) || { printf 'ERROR: --heartbeat-seconds requires a number.\n' >&2; exit 2; }
      HEARTBEAT_SECONDS="$2"
      shift 2
      ;;
    --heartbeat-seconds=*)
      HEARTBEAT_SECONDS="${1#*=}"
      shift
      ;;
    --command-timeout-seconds|--stall-timeout-seconds)
      (( $# >= 2 )) || { printf 'ERROR: timeout option requires a number.\n' >&2; exit 2; }
      STALL_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --command-timeout-seconds=*|--stall-timeout-seconds=*)
      STALL_TIMEOUT_SECONDS="${1#*=}"
      shift
      ;;
    --output-dir)
      (( $# >= 2 )) || { printf 'ERROR: --output-dir requires a path.\n' >&2; exit 2; }
      OUTPUT_DIR="$2"
      CORE_ARGS+=("$1" "$2")
      shift 2
      ;;
    --output-dir=*)
      OUTPUT_DIR="${1#*=}"
      CORE_ARGS+=("$1")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      CORE_ARGS+=("$1")
      shift
      ;;
  esac
done

case "$HEARTBEAT_SECONDS" in
  ''|*[!0-9]*) printf 'ERROR: --heartbeat-seconds must be a positive integer.\n' >&2; exit 2 ;;
esac
case "$STALL_TIMEOUT_SECONDS" in
  ''|*[!0-9]*) printf 'ERROR: timeout must be a positive integer.\n' >&2; exit 2 ;;
esac
(( HEARTBEAT_SECONDS >= 1 )) || { printf 'ERROR: heartbeat must be at least 1.\n' >&2; exit 2; }
(( STALL_TIMEOUT_SECONDS >= 30 )) || { printf 'ERROR: timeout must be at least 30 seconds.\n' >&2; exit 2; }

if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
  printf 'ERROR: this scanner is designed for macOS only.\n' >&2
  exit 1
fi

SCRIPT_DIR="$(cd -P "$(/usr/bin/dirname "$0")" && pwd -P)"
CORE="$SCRIPT_DIR/mac-system-storage-tree-core-v2.5.3.command"
if [[ ! -f "$CORE" ]]; then
  printf 'ERROR: missing scanner core: %s\n' "$CORE" >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$SCRIPT_DIR"
fi
if [[ ! -d "$OUTPUT_DIR" || ! -w "$OUTPUT_DIR" ]]; then
  printf 'ERROR: output directory is missing or not writable: %s\n' "$OUTPUT_DIR" >&2
  exit 1
fi

if [[ -n "$PROGRESS_FILE" ]]; then
  progress_parent="$(/usr/bin/dirname "$PROGRESS_FILE")"
  if [[ ! -d "$progress_parent" ]]; then
    printf 'ERROR: progress parent directory is missing: %s\n' "$progress_parent" >&2
    exit 1
  fi
  /usr/bin/touch "$PROGRESS_FILE" || {
    printf 'ERROR: progress file is not writable: %s\n' "$PROGRESS_FILE" >&2
    exit 1
  }
fi

if [[ -n "$CONTROL_DIR" && ! -d "$CONTROL_DIR" ]]; then
  printf 'ERROR: control directory is missing: %s\n' "$CONTROL_DIR" >&2
  exit 1
fi

# Force the core to use the same short heartbeat cadence. If the caller already
# supplied this option, the later value wins in the core's option parser.
CORE_ARGS+=("--heartbeat-seconds" "$HEARTBEAT_SECONDS")

SUPERVISOR_TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/mac-storage-lens-supervisor.XXXXXX")" || {
  printf 'ERROR: unable to create supervisor temporary directory.\n' >&2
  exit 1
}
FIFO="$SUPERVISOR_TMP/core-output.fifo"
/usr/bin/mkfifo "$FIFO"
CORE_PID=""
REPORT_PATH=""
SCAN_SUCCEEDED="false"
CANCELLED="false"
TIMED_OUT="false"

PHASE="prepare"
STATUS="active"
STAGE="準備與容量核對"
MESSAGE="正在建立掃描清單並準備 APFS／快照核對…"
DETAIL="掃描器每 ${HEARTBEAT_SECONDS} 秒回報心跳；無回應 ${STALL_TIMEOUT_SECONDS} 秒會自動安全中止"
CURRENT=""
TOTAL=""
CURRENT_PATH=""
ELAPSED="0"
NODES=""
ERRORS=""
LAST_CORE_OUTPUT_EPOCH="$(/bin/date +%s)"
LAST_PROGRESS_EPOCH=0

sanitize_field() {
  local value="$1"
  value="${value//$'\t'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  printf '%s' "$value"
}

emit_progress() {
  [[ -n "$PROGRESS_FILE" ]] || return 0
  local epoch phase status_field stage message detail current total path_field elapsed nodes errors
  epoch="$(/bin/date +%s)"
  phase="$(sanitize_field "$PHASE")"
  status_field="$(sanitize_field "$STATUS")"
  stage="$(sanitize_field "$STAGE")"
  message="$(sanitize_field "$MESSAGE")"
  detail="$(sanitize_field "$DETAIL")"
  current="$(sanitize_field "$CURRENT")"
  total="$(sanitize_field "$TOTAL")"
  path_field="$(sanitize_field "$CURRENT_PATH")"
  elapsed="$(sanitize_field "$ELAPSED")"
  nodes="$(sanitize_field "$NODES")"
  errors="$(sanitize_field "$ERRORS")"
  printf 'MLS_PROGRESS\tversion=1\tepoch=%s\tphase=%s\tstatus=%s\tstage=%s\tmessage=%s\tdetail=%s\tcurrent=%s\ttotal=%s\tpath=%s\telapsed=%s\tnodes=%s\terrors=%s\n' \
    "$epoch" "$phase" "$status_field" "$stage" "$message" "$detail" "$current" "$total" "$path_field" "$elapsed" "$nodes" "$errors" >> "$PROGRESS_FILE"
  LAST_PROGRESS_EPOCH="$epoch"
}

cancel_requested() {
  [[ -n "$CONTROL_DIR" && -f "$CONTROL_DIR/cancel.request" ]]
}

core_process_state() {
  [[ -n "$CORE_PID" ]] || return 1
  /bin/ps -p "$CORE_PID" -o state= 2>/dev/null | /usr/bin/tr -d '[:space:]'
}

core_is_active() {
  local state=""
  state="$(core_process_state)"
  [[ -n "$state" && "$state" != Z* ]]
}

signal_process_tree() {
  local pid="$1"
  local signal_name="$2"
  local child=""
  [[ -n "$pid" ]] || return 0
  for child in $(/usr/bin/pgrep -P "$pid" 2>/dev/null || true); do
    signal_process_tree "$child" "$signal_name"
  done
  /bin/kill "-$signal_name" "$pid" >/dev/null 2>&1 || true
}

terminate_core() {
  [[ -n "$CORE_PID" ]] || return 0
  if core_is_active; then
    signal_process_tree "$CORE_PID" TERM
  fi

  local attempt=0
  while core_is_active && (( attempt < 8 )); do
    /bin/sleep 1
    attempt=$(( attempt + 1 ))
  done

  if core_is_active; then
    signal_process_tree "$CORE_PID" KILL
  fi
}

report_has_completion_marker() {
  local report="$1"
  [[ -f "$report" ]] || return 1
  /usr/bin/tail -c 131072 "$report" 2>/dev/null |
    /usr/bin/grep -q '^report_complete=true$'
}

remove_incomplete_report() {
  [[ "$SCAN_SUCCEEDED" == "true" ]] && return 0
  [[ -n "$REPORT_PATH" && -f "$REPORT_PATH" ]] || return 0
  # The core writes report_complete=true only after every report section is closed.
  # Preserve that authoritative report even if a thin supervisor/authorization layer
  # is interrupted during its final few instructions.
  report_has_completion_marker "$REPORT_PATH" && return 0
  case "$REPORT_PATH" in
    "$OUTPUT_DIR"/system-storage-tree-*.md|\
    "$OUTPUT_DIR"/volume-storage-tree-*.md|\
    "$OUTPUT_DIR"/folder-storage-tree-*.md)
      /bin/rm -f -- "$REPORT_PATH"
      ;;
  esac
}

cleanup() {
  terminate_core
  if [[ -n "$CORE_PID" ]]; then
    wait "$CORE_PID" >/dev/null 2>&1 || true
  fi
  remove_incomplete_report
  if [[ -d "$SUPERVISOR_TMP" && "$(/usr/bin/basename "$SUPERVISOR_TMP")" == mac-storage-lens-supervisor.* ]]; then
    /bin/rm -rf -- "$SUPERVISOR_TMP"
  fi
}
trap cleanup EXIT
trap 'CANCELLED="true"; PHASE="cancelled"; STATUS="cancelled"; STAGE="已取消"; MESSAGE="掃描收到中止訊號，正在清理本次工作。"; emit_progress; exit 130' INT HUP TERM

emit_progress
printf '%s\n' \
  "MacStorageLens 掃描監督器 v${VERSION}" \
  "核心掃描器：$(/usr/bin/basename "$CORE")" \
  "心跳間隔：${HEARTBEAT_SECONDS} 秒；無核心輸出逾 ${STALL_TIMEOUT_SECONDS} 秒會安全中止。" \
  ''

/bin/zsh "$CORE" "${CORE_ARGS[@]}" > "$FIFO" 2>&1 &
CORE_PID=$!
exec 7< "$FIFO"

process_core_line() {
  local line="$1" parsed="" current="" total="" parsed_path=""
  printf '%s\n' "$line"
  LAST_CORE_OUTPUT_EPOCH="$(/bin/date +%s)"
  STATUS="active"

  parsed="$(printf '%s\n' "$line" | /usr/bin/sed -n 's/^\[準備 \([0-9][0-9]*\)\/\([0-9][0-9]*\)\] \(.*\)$/\1\t\2\t\3/p')"
  if [[ -n "$parsed" ]]; then
    current="${parsed%%$'\t'*}"
    parsed="${parsed#*$'\t'}"
    total="${parsed%%$'\t'*}"
    parsed_path="${parsed#*$'\t'}"
    PHASE="prepare"
    STATUS="active"
    STAGE="準備與容量核對"
    CURRENT="$current"
    TOTAL="$total"
    CURRENT_PATH=""
    MESSAGE="$parsed_path"
    DETAIL="準備步驟 ${current}／${total}"
    ELAPSED="0"
    NODES=""
    ERRORS=""
    emit_progress
    return
  fi

  parsed="$(printf '%s\n' "$line" | /usr/bin/sed -n 's/^\[準備完成 \([0-9][0-9]*\)\/\([0-9][0-9]*\)\] \(.*\)$/\1\t\2\t\3/p')"
  if [[ -n "$parsed" ]]; then
    current="${parsed%%$'\t'*}"
    parsed="${parsed#*$'\t'}"
    total="${parsed%%$'\t'*}"
    parsed_path="${parsed#*$'\t'}"
    PHASE="prepare"
    STATUS="complete"
    STAGE="準備與容量核對"
    CURRENT="$current"
    TOTAL="$total"
    CURRENT_PATH=""
    MESSAGE="$parsed_path"
    DETAIL="掃描前檢查已完成"
    emit_progress
    return
  fi

  if [[ "$line" == 掃描根節點數：* ]]; then
    TOTAL="${line#掃描根節點數：}"
    CURRENT="0"
    PHASE="scan"
    STAGE="資料夾掃描"
    MESSAGE="已建立掃描清單，共 ${TOTAL} 個根節點。"
    DETAIL=""
    CURRENT_PATH=""
    ELAPSED="0"
    NODES=""
    ERRORS=""
    emit_progress
    return
  fi

  parsed="$(printf '%s\n' "$line" | /usr/bin/sed -n 's/^\[\([0-9][0-9]*\)\/\([0-9][0-9]*\)\] \(.*\)$/\1\t\2\t\3/p')"
  if [[ -n "$parsed" ]]; then
    current="${parsed%%$'\t'*}"
    parsed="${parsed#*$'\t'}"
    total="${parsed%%$'\t'*}"
    parsed_path="${parsed#*$'\t'}"
    PHASE="scan"
    STATUS="active"
    STAGE="資料夾掃描"
    CURRENT="$current"
    TOTAL="$total"
    CURRENT_PATH="$parsed_path"
    MESSAGE="正在掃描 $parsed_path"
    DETAIL="第 ${current}／${total} 個根節點"
    ELAPSED="0"
    NODES="0"
    ERRORS="0"
    emit_progress
    return
  fi

  parsed="$(printf '%s\n' "$line" | /usr/bin/sed -n 's/.*已經過 \([0-9][0-9]*\) 秒；目前目錄節點 \([0-9][0-9]*\)；受限／診斷行 \([0-9][0-9]*\).*/\1\t\2\t\3/p')"
  if [[ -n "$parsed" && "$PHASE" == "scan" ]]; then
    ELAPSED="${parsed%%$'\t'*}"
    parsed="${parsed#*$'\t'}"
    NODES="${parsed%%$'\t'*}"
    ERRORS="${parsed#*$'\t'}"
    STATUS="heartbeat"
    MESSAGE="正在掃描 ${CURRENT_PATH:-目前根節點}"
    DETAIL="已掃描 ${NODES} 個目錄節點；受限／診斷行 ${ERRORS}"
    emit_progress
    return
  fi

  parsed="$(printf '%s\n' "$line" | /usr/bin/sed -n 's/.*完成：\([0-9][0-9]*\) 秒；目錄節點 \([0-9][0-9]*\)；受限／診斷行 \([0-9][0-9]*\)；du exit=\([0-9][0-9]*\).*/\1\t\2\t\3\t\4/p')"
  if [[ -n "$parsed" && "$PHASE" == "scan" ]]; then
    ELAPSED="${parsed%%$'\t'*}"
    parsed="${parsed#*$'\t'}"
    NODES="${parsed%%$'\t'*}"
    parsed="${parsed#*$'\t'}"
    ERRORS="${parsed%%$'\t'*}"
    STATUS="complete"
    MESSAGE="已完成 ${CURRENT_PATH:-目前根節點}"
    if (( ERRORS > 0 )); then
      DETAIL="目錄節點 ${NODES}；受限／診斷行 ${ERRORS}（已記錄為 UNKNOWN_SIZE，非整體失敗）"
    else
      DETAIL="目錄節點 ${NODES}；受限／診斷行 0"
    fi
    emit_progress
    return
  fi

  if [[ "$line" == *略過附加大檔案掃描* ]]; then
    PHASE="largefiles"
    STATUS="skipped"
    STAGE="大檔案附加掃描"
    MESSAGE="已略過非必要的第二次大檔案遍歷。"
    DETAIL="完整資料夾樹仍會正常產生"
    CURRENT="1"
    TOTAL="1"
    CURRENT_PATH=""
    ELAPSED="0"
    NODES=""
    ERRORS=""
    emit_progress
    return
  fi

  if [[ "$line" == 收集目標磁碟、APFS* || "$line" == 收集磁碟、APFS、Time\ Machine* ]]; then
    PHASE="metadata"
    STATUS="active"
    STAGE="APFS 與系統狀態"
    MESSAGE="正在讀取磁碟、APFS、Time Machine 與內容快取狀態。"
    DETAIL="這個階段會呼叫 macOS 的磁碟與快照查詢工具"
    CURRENT="0"
    TOTAL="1"
    CURRENT_PATH=""
    ELAPSED="0"
    NODES=""
    ERRORS=""
    emit_progress
    return
  fi

  parsed="$(printf '%s\n' "$line" | /usr/bin/sed -n 's/^\[系統狀態 \([0-9][0-9]*\)\/\([0-9][0-9]*\)\] \(.*\)$/\1\t\2\t\3/p')"
  if [[ -n "$parsed" ]]; then
    current="${parsed%%$'\t'*}"
    parsed="${parsed#*$'\t'}"
    total="${parsed%%$'\t'*}"
    parsed_path="${parsed#*$'\t'}"
    PHASE="metadata"
    STATUS="active"
    STAGE="APFS 與系統狀態"
    CURRENT="$current"
    TOTAL="$total"
    CURRENT_PATH=""
    MESSAGE="$parsed_path"
    DETAIL="系統狀態步驟 ${current}／${total}"
    ELAPSED="0"
    NODES=""
    ERRORS=""
    emit_progress
    return
  fi

  parsed="$(printf '%s\n' "$line" | /usr/bin/sed -n 's/^\[系統狀態完成 \([0-9][0-9]*\)\/\([0-9][0-9]*\)\] \(.*\)$/\1\t\2\t\3/p')"
  if [[ -n "$parsed" ]]; then
    current="${parsed%%$'\t'*}"
    parsed="${parsed#*$'\t'}"
    total="${parsed%%$'\t'*}"
    parsed_path="${parsed#*$'\t'}"
    PHASE="metadata"
    STATUS="complete"
    STAGE="APFS 與系統狀態"
    CURRENT="$current"
    TOTAL="$total"
    CURRENT_PATH=""
    MESSAGE="$parsed_path"
    DETAIL="系統狀態收集已完成"
    emit_progress
    return
  fi

  if [[ "$line" == 產生\ Markdown\ 報告：* ]]; then
    REPORT_PATH="${line#產生 Markdown 報告：}"
    PHASE="report"
    STATUS="active"
    STAGE="建立報告"
    MESSAGE="正在建立 Markdown 報告。"
    DETAIL="$REPORT_PATH"
    CURRENT="0"
    [[ -n "$TOTAL" ]] || TOTAL="1"
    CURRENT_PATH=""
    ELAPSED="0"
    NODES=""
    ERRORS=""
    emit_progress
    return
  fi

  parsed="$(printf '%s\n' "$line" | /usr/bin/sed -n 's/^\[報告 \([0-9][0-9]*\)\/\([0-9][0-9]*\)\] \(.*\)$/\1\t\2\t\3/p')"
  if [[ -n "$parsed" ]]; then
    current="${parsed%%$'\t'*}"
    parsed="${parsed#*$'\t'}"
    total="${parsed%%$'\t'*}"
    parsed_path="${parsed#*$'\t'}"
    PHASE="report"
    STATUS="active"
    STAGE="建立報告"
    CURRENT="$current"
    TOTAL="$total"
    CURRENT_PATH="$parsed_path"
    MESSAGE="正在寫入 $parsed_path 的資料樹。"
    DETAIL="報告區段 ${current}／${total}"
    ELAPSED="0"
    NODES=""
    ERRORS=""
    emit_progress
    return
  fi

  if [[ "$line" == OUTPUT=* ]]; then
    REPORT_PATH="${line#OUTPUT=}"
    return
  fi

  if [[ "$line" == DONE* ]]; then
    PHASE="complete"
    STATUS="complete"
    STAGE="完成"
    MESSAGE="掃描與報告建立完成。"
    DETAIL="$REPORT_PATH"
    CURRENT="1"
    TOTAL="1"
    CURRENT_PATH=""
    ELAPSED="0"
    NODES=""
    ERRORS=""
    emit_progress
    return
  fi
}

while true; do
  line=""
  if IFS= read -r -t 1 -u 7 line; then
    process_core_line "$line"
  fi

  now="$(/bin/date +%s)"
  source_age=$(( now - LAST_CORE_OUTPUT_EPOCH ))

  if cancel_requested; then
    CANCELLED="true"
    PHASE="cancelled"
    STATUS="cancelled"
    STAGE="正在取消"
    MESSAGE="已收到取消要求，正在安全停止目前的唯讀工作。"
    DETAIL="上一份完整報告會保留"
    emit_progress
    terminate_core
    break
  fi

  if (( source_age >= STALL_TIMEOUT_SECONDS )); then
    TIMED_OUT="true"
    PHASE="finalize"
    STATUS="timeout"
    STAGE="自我檢查"
    MESSAGE="核心掃描器已 ${source_age} 秒沒有輸出，正在安全中止。"
    DETAIL="可能原因：外部掛載、APFS 工具或檔案系統呼叫沒有回應"
    emit_progress
    terminate_core
    break
  fi

  if (( now - LAST_PROGRESS_EPOCH >= HEARTBEAT_SECONDS )); then
    if (( source_age >= 60 )); then
      STATUS="stalled"
      MESSAGE="核心掃描器已 ${source_age} 秒沒有新輸出；仍在監看。"
      DETAIL="若達 ${STALL_TIMEOUT_SECONDS} 秒將自動安全中止"
    elif (( source_age >= 20 )); then
      STATUS="delayed"
      MESSAGE="目前階段已 ${source_age} 秒沒有新輸出；程序仍在執行。"
      DETAIL="大型目錄或 APFS 查詢可能短暫延遲"
    else
      STATUS="heartbeat"
    fi
    emit_progress
  fi

  # A terminated child can remain as a zombie until `wait` reaps it. On macOS,
  # `kill -0` can still succeed for that zombie, so inspect the process state and
  # treat an empty or Z state as finished. This prevents a completed scan from
  # sitting in the supervisor loop until the stall timeout expires.
  if ! core_is_active; then
    # Drain any final lines already written to the FIFO before leaving the loop.
    while IFS= read -r -t 0.05 -u 7 line; do
      process_core_line "$line"
    done
    break
  fi
done

core_status=0
wait "$CORE_PID" || core_status=$?
CORE_PID=""

if [[ "$CANCELLED" == "true" ]]; then
  exit 130
fi
if [[ "$TIMED_OUT" == "true" ]]; then
  exit 124
fi
if (( core_status != 0 )); then
  PHASE="finalize"
  STATUS="error"
  STAGE="掃描器錯誤"
  MESSAGE="核心掃描器結束，狀態碼 ${core_status}。"
  DETAIL="請查看 App 顯示的診斷資訊"
  emit_progress
  exit "$core_status"
fi

SCAN_SUCCEEDED="true"
if [[ "$PHASE" != "complete" ]]; then
  PHASE="complete"
  STATUS="complete"
  STAGE="完成"
  MESSAGE="掃描程序已完成。"
  DETAIL="$REPORT_PATH"
  CURRENT="1"
  TOTAL="1"
  emit_progress
fi
exit 0
