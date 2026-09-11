import AppKit
import Darwin
import Foundation

enum ScannerLauncherError: LocalizedError {
  case resourceMissing
  case unableToCreateSession(String)
  case authorizationCancelled
  case scanCancelled(String)
  case scanTimedOut(String)
  case scanFailed(String)
  case missingCompletedReport

  var errorDescription: String? {
    switch self {
    case .resourceMissing:
      return "找不到內附的唯讀掃描器。請確認 App 的 Resources 目錄完整。"
    case .unableToCreateSession(let message):
      return "無法建立掃描工作階段：\(message)"
    case .authorizationCancelled:
      return "你已取消管理員授權；磁碟內容沒有被修改。"
    case .scanCancelled(let message), .scanTimedOut(let message):
      return message
    case .scanFailed(let message):
      return "完整掃描失敗：\(message)"
    case .missingCompletedReport:
      return "掃描程序已結束，但沒有找到包含完成旗標的新報告。"
    }
  }
}

private struct AppTCCOverlayResult {
  let status: String
  let probe: String
  let probePath: String
  let root: String

  var isReady: Bool { status == "READY" && probe == "LIKELY_AVAILABLE" }
}

final class ScanSession {
  let id = UUID()
  let mode: ScanPrivilegeMode
  let target: ScanTarget
  let progressURL: URL

  private let library: ReportLibrary
  private let scannerURL: URL
  private let sessionURL: URL
  private let logURL: URL
  private let launchMarkerURL: URL
  private let wrapperStartedURL: URL
  private let resultURL: URL
  private let wrapperURL: URL
  private let cancelURL: URL
  private let appOverlayWrapperURL: URL
  private let appOverlayRawURL: URL
  private let appOverlayErrorURL: URL
  private let appOverlayResultURL: URL
  private let requestedAt: Date
  private let targetResolvedAt: Date
  private let scannerInstalledAt: Date
  private let permissionProbeFinishedAt: Date
  private let startedAt: Date
  private let sessionReadyAt: Date
  private let reportsBeforeStart: Set<String>
  private let onProgress: (ScanProgressSnapshot) -> Void
  private let completion: (Result<URL, Error>) -> Void
  private let appFullDiskAccessProbe: FullDiskAccessProbeResult

  private var process: Process?
  private var outputHandle: FileHandle?
  private var authorizationPipe: Pipe?
  private var progressTimer: DispatchSourceTimer?
  private var lastProgressFraction: Double?
  private var lastEventToken: String?
  private var lastEventDate: Date?
  private var lastMeaningfulProgressToken: String?
  private var lastMeaningfulProgressDate: Date?
  private var lastParseResult = ScanProgressParseResult(
    latest: nil, recentMessages: [], lastPlainTextLine: nil)
  private var cancellationRequested = false
  private var cancellationReason = "掃描已取消。"
  private var watchdogCancellationIssued = false
  private var administratorAuthorizationStarted = false
  private var firstProcessStartedAt: Date?
  private var authorizationProcessStartedAt: Date?
  private var scannerFinishedAt: Date?
  private let stateLock = NSLock()
  private var finished = false

  private let heartbeatWarningSeconds = 20
  private let heartbeatStalledSeconds = 60
  private let heartbeatAbortSeconds = 120
  private let meaningfulProgressTimeoutSeconds = 10 * 60

  init(
    mode: ScanPrivilegeMode,
    target: ScanTarget,
    library: ReportLibrary,
    scannerURL: URL,
    sessionURL: URL,
    appFullDiskAccessProbe: FullDiskAccessProbeResult,
    requestedAt: Date,
    targetResolvedAt: Date,
    scannerInstalledAt: Date,
    permissionProbeFinishedAt: Date,
    onProgress: @escaping (ScanProgressSnapshot) -> Void,
    completion: @escaping (Result<URL, Error>) -> Void
  ) throws {
    self.mode = mode
    self.target = target
    self.library = library
    self.scannerURL = scannerURL
    self.sessionURL = sessionURL
    self.appFullDiskAccessProbe = appFullDiskAccessProbe
    self.requestedAt = requestedAt
    self.targetResolvedAt = targetResolvedAt
    self.scannerInstalledAt = scannerInstalledAt
    self.permissionProbeFinishedAt = permissionProbeFinishedAt
    startedAt = Date()
    progressURL = sessionURL.appendingPathComponent("progress.log")
    logURL = sessionURL.appendingPathComponent("scanner.log")
    launchMarkerURL = sessionURL.appendingPathComponent("launch.marker")
    wrapperStartedURL = sessionURL.appendingPathComponent("wrapper-started.marker")
    resultURL = sessionURL.appendingPathComponent("result.txt")
    wrapperURL = sessionURL.appendingPathComponent("authorized-scan.command")
    cancelURL = sessionURL.appendingPathComponent("cancel.request")
    appOverlayWrapperURL = sessionURL.appendingPathComponent("app-tcc-overlay.command")
    appOverlayRawURL = sessionURL.appendingPathComponent("app-tcc-overlay.raw")
    appOverlayErrorURL = sessionURL.appendingPathComponent("app-tcc-overlay.err")
    appOverlayResultURL = sessionURL.appendingPathComponent("app-tcc-overlay.result")
    reportsBeforeStart = Set(library.scanReportURLs().map { $0.standardizedFileURL.path })
    self.onProgress = onProgress
    self.completion = completion

    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(at: sessionURL, withIntermediateDirectories: true)
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessionURL.path)
      let launchText = "started_at=\(Date().timeIntervalSince1970)\n"
      try Data(launchText.utf8).write(to: launchMarkerURL, options: .atomic)
      for url in [
        progressURL, logURL, resultURL, appOverlayRawURL, appOverlayErrorURL,
        appOverlayResultURL,
      ] {
        _ = fileManager.createFile(atPath: url.path, contents: Data())
      }
      for url in [
        progressURL, logURL, launchMarkerURL, resultURL, appOverlayRawURL,
        appOverlayErrorURL, appOverlayResultURL,
      ] {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      }
    } catch {
      throw ScannerLauncherError.unableToCreateSession(error.localizedDescription)
    }
    sessionReadyAt = Date()
  }

  func start() throws {
    startProgressTimer()
    switch mode {
    case .currentUser:
      try startCurrentUserScan()
    case .administrator:
      try startAdministratorScan()
    }
  }

  func cancel(reason: String = "你已取消掃描；既有完成報告仍然保留。") {
    stateLock.lock()
    guard !finished, !cancellationRequested else {
      stateLock.unlock()
      return
    }
    cancellationRequested = true
    cancellationReason = reason
    let runningProcess = process
    let wrapperHasStarted = FileManager.default.fileExists(atPath: wrapperStartedURL.path)
    stateLock.unlock()

    let text = "requested_at=\(Date().timeIntervalSince1970)\nreason=\(reason)\n"
    try? Data(text.utf8).write(to: cancelURL, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cancelURL.path)

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.onProgress(self.progressSnapshot(forceHealth: .cancelling))
    }

    if mode == .currentUser {
      runningProcess?.interrupt()
    } else if !wrapperHasStarted {
      runningProcess?.terminate()
    }
  }

  func discardAfterFailedStart() {
    stopProgressTimer()
    try? outputHandle?.close()
    outputHandle = nil
    process?.terminate()
    process = nil
    try? FileManager.default.removeItem(at: sessionURL)
  }

  private func scannerArguments(
    privilegeChannel: String,
    appFDAProbe: String = "UNKNOWN",
    appFDAProbePath: String = "NONE",
    overlay: AppTCCOverlayResult? = nil
  ) -> [String] {
    var arguments = [
      scannerURL.path,
      "--no-sudo",
      "--output-dir", library.scansURL.path,
      "--skip-large-files",
      "--progress-file", progressURL.path,
      "--control-dir", sessionURL.path,
      "--heartbeat-seconds", "5",
      "--command-timeout-seconds", "600",
      "--target-kind", target.kind.rawValue,
      "--target-path", target.path,
      "--target-name", target.displayName,
      "--launcher-mode", "app",
      "--privilege-channel", privilegeChannel,
      "--app-fda-probe", appFDAProbe,
      "--app-fda-probe-path", appFDAProbePath,
      "--tcc-overlay-status", overlay?.status ?? "NOT_REQUESTED",
    ]
    if let volumeUUID = target.volumeUUID, !volumeUUID.isEmpty {
      arguments += ["--target-volume-uuid", volumeUUID]
    }
    if let overlay, overlay.isReady {
      arguments += [
        "--tcc-overlay-root", overlay.root,
        "--tcc-overlay-raw", appOverlayRawURL.path,
        "--tcc-overlay-errors", appOverlayErrorURL.path,
      ]
    }
    return arguments
  }

  private func startCurrentUserScan() throws {
    let handle = try FileHandle(forWritingTo: logURL)
    try handle.truncate(atOffset: 0)
    outputHandle = handle

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = scannerArguments(
      privilegeChannel: "app_direct",
      appFDAProbe: appFullDiskAccessProbe.reportStatus,
      appFDAProbePath: appFullDiskAccessProbe.reportPath
    )
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
    process.environment = environment
    process.standardOutput = handle
    process.standardError = handle
    process.terminationHandler = { [weak self] process in
      self?.finishProcess(status: process.terminationStatus, diagnostic: nil)
    }

    do {
      try process.run()
      recordProcessStart()
      stateLock.lock()
      self.process = process
      stateLock.unlock()
    } catch {
      stopProgressTimer()
      try? handle.close()
      outputHandle = nil
      throw ScannerLauncherError.scanFailed(error.localizedDescription)
    }
  }

  private func startAdministratorScan() throws {
    guard target.kind == .system, let overlayRoot = appTCCOverlayRoot() else {
      try startAdministratorProcess(
        appProbe: appFullDiskAccessProbe.reportStatus,
        appProbePath: appFullDiskAccessProbe.reportPath,
        overlay: AppTCCOverlayResult(
          status: "NOT_APPLICABLE", probe: "UNKNOWN", probePath: "NONE", root: "NONE")
      )
      return
    }
    try startAppTCCOverlay(root: overlayRoot)
  }

  private func appTCCOverlayRoot() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    guard home.hasPrefix("/Users/") else { return nil }
    let dataHome = "/System/Volumes/Data" + home
    guard FileManager.default.fileExists(atPath: dataHome) else { return nil }
    return dataHome
  }

  private func startAppTCCOverlay(root: String) throws {
    let script = """
      #!/bin/zsh
      emulate -L zsh
      set -u
      umask 077

      ROOT=\(root.shellSingleQuoted)
      RAW=\(appOverlayRawURL.path.shellSingleQuoted)
      ERR=\(appOverlayErrorURL.path.shellSingleQuoted)
      RESULT=\(appOverlayResultURL.path.shellSingleQuoted)
      PROGRESS=\(progressURL.path.shellSingleQuoted)
      CANCEL=\(cancelURL.path.shellSingleQuoted)
      ACTIVE_PID=""

      cleanup_overlay() {
        if [[ -n "$ACTIVE_PID" ]] && /bin/kill -0 "$ACTIVE_PID" >/dev/null 2>&1; then
          /usr/bin/pkill -TERM -P "$ACTIVE_PID" >/dev/null 2>&1 || true
          /bin/kill -TERM "$ACTIVE_PID" >/dev/null 2>&1 || true
          wait "$ACTIVE_PID" >/dev/null 2>&1 || true
        fi
      }
      trap 'cleanup_overlay; exit 130' INT HUP TERM

      write_result() {
        local overlay_status="$1"
        local du_status="$2"
        local tree_kib="$3"
        {
          printf 'status=%s\n' "$overlay_status"
          printf 'probe=%s\n' "$probe"
          printf 'probe_path=%s\n' "$probe_path"
          printf 'root=%s\n' "$ROOT"
          printf 'du_status=%s\n' "$du_status"
          printf 'tree_kib=%s\n' "$tree_kib"
        } > "$RESULT"
      }

      : > "$RAW"
      : > "$ERR"
      : > "$RESULT"

      printf 'MLS_PROGRESS\tversion=1\tepoch=%s\tphase=tcc_overlay\tstatus=active\tstage=App 權限核對\tmessage=正在由 MacStorageLens 的程序鏈核對受保護路徑…\tdetail=這個步驟在管理員授權前執行，用來分開判讀 App TCC 與 root 權限。\tpath=%s\n' \
        "$(/bin/date +%s)" "$ROOT" >> "$PROGRESS"

      # The App process itself ran this probe synchronously immediately before
      # starting the session. Do not re-attribute the decision to a shell child.
      probe=\(appFullDiskAccessProbe.reportStatus.shellSingleQuoted)
      probe_path=\(appFullDiskAccessProbe.reportPath.shellSingleQuoted)

      if [[ "$probe" != "LIKELY_AVAILABLE" ]]; then
        overlay_status="APP_FDA_INDETERMINATE"
        message="無法自動判定 App 的完整磁碟存取。"
        detail="找不到可用的受保護測試路徑；管理員掃描仍可繼續，但資料覆蓋可能受限。"
        if [[ "$probe" == "LIKELY_MISSING_OR_TCC_BLOCKED" ]]; then
          overlay_status="APP_FDA_BLOCKED"
          message="App 權限探針遭 macOS 拒絕。"
          detail="不執行耗時的 App 覆蓋掃描；請完全退出 App、核對完整磁碟存取後再試。"
        fi
        write_result "$overlay_status" 0 UNKNOWN
        printf 'MLS_PROGRESS\tversion=1\tepoch=%s\tphase=tcc_overlay\tstatus=complete\tstage=App 權限核對\tmessage=%s\tdetail=%s\tpath=%s\n' \
          "$(/bin/date +%s)" "$message" "$detail" "$ROOT" >> "$PROGRESS"
        exit 0
      fi

      printf 'MLS_PROGRESS\tversion=1\tepoch=%s\tphase=tcc_overlay\tstatus=active\tstage=App 權限預掃描\tmessage=正在以 MacStorageLens 的完整磁碟存取權讀取使用者資料…\tdetail=完成後才會顯示管理員授權對話框。\tpath=%s\n' \
        "$(/bin/date +%s)" "$ROOT" >> "$PROGRESS"

      du_status=0
      /usr/bin/du -xk -I 'MacStorageLens' "$ROOT" > "$RAW" 2>> "$ERR" &
      ACTIVE_PID=$!
      started="$(/bin/date +%s)"
      while /bin/kill -0 "$ACTIVE_PID" >/dev/null 2>&1; do
        if [[ -f "$CANCEL" ]]; then
          cleanup_overlay
          exit 130
        fi
        /bin/sleep 5
        elapsed=$(( $(/bin/date +%s) - started ))
        nodes="$(/usr/bin/wc -l < "$RAW" | /usr/bin/tr -d '[:space:]')"
        errors="$(/usr/bin/wc -l < "$ERR" | /usr/bin/tr -d '[:space:]')"
        printf 'MLS_PROGRESS\tversion=1\tepoch=%s\tphase=tcc_overlay\tstatus=active\tstage=App 權限預掃描\tmessage=正在建立受保護使用者資料覆蓋…\tdetail=完成後會接續管理員唯讀掃描。\tpath=%s\telapsed=%s\tnodes=%s\terrors=%s\n' \
          "$(/bin/date +%s)" "$ROOT" "$elapsed" "$nodes" "$errors" >> "$PROGRESS"
      done
      wait "$ACTIVE_PID" || du_status=$?
      ACTIVE_PID=""

      tree_kib="$(/usr/bin/awk -v target="$ROOT" '
        {
          tab=index($0, "\t")
          if (tab > 0) { kib=substr($0, 1, tab-1); path=substr($0, tab+1) }
          else if (match($0, /^[0-9]+[[:space:]]+/)) {
            kib=substr($0, 1, RLENGTH); gsub(/[[:space:]]/, "", kib); path=substr($0, RLENGTH+1)
          } else next
          if (path == target) { print kib; found=1 }
        }
        END { if (!found) print "UNKNOWN" }
      ' "$RAW")"

      overlay_status="FAILED"
      if [[ "$tree_kib" == <-> ]]; then
        overlay_status="READY"
      fi
      write_result "$overlay_status" "$du_status" "$tree_kib"

      if [[ "$overlay_status" == "READY" ]]; then
        message="受保護使用者資料覆蓋已完成。"
        detail="接下來會顯示管理員授權對話框。"
      else
        message="App 權限覆蓋沒有產生可核對的根節點。"
        detail="管理員掃描仍可繼續，但受保護路徑會保留為診斷。"
      fi
      printf 'MLS_PROGRESS\tversion=1\tepoch=%s\tphase=tcc_overlay\tstatus=complete\tstage=App 權限預掃描\tmessage=%s\tdetail=%s\tpath=%s\n' \
        "$(/bin/date +%s)" "$message" "$detail" "$ROOT" >> "$PROGRESS"
      exit 0
      """

    try script.write(to: appOverlayWrapperURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: appOverlayWrapperURL.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [appOverlayWrapperURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { [weak self] process in
      self?.finishAppTCCOverlay(status: process.terminationStatus, root: root)
    }
    try process.run()
    recordProcessStart()
    stateLock.lock()
    self.process = process
    stateLock.unlock()
  }

  private func finishAppTCCOverlay(status: Int32, root: String) {
    stateLock.lock()
    let wasCancelled = cancellationRequested
    let reason = cancellationReason
    stateLock.unlock()

    if wasCancelled || status == 130 {
      finishWithError(ScannerLauncherError.scanCancelled(reason))
      return
    }

    let values = readKeyValueFile(appOverlayResultURL)
    let result = AppTCCOverlayResult(
      status: values["status"] ?? "FAILED",
      probe: values["probe"] ?? "UNKNOWN",
      probePath: values["probe_path"] ?? "NONE",
      root: values["root"] ?? root
    )

    do {
      try startAdministratorProcess(
        appProbe: result.probe,
        appProbePath: result.probePath,
        overlay: result
      )
    } catch {
      finishWithError(ScannerLauncherError.scanFailed(error.localizedDescription))
    }
  }

  private func readKeyValueFile(_ url: URL) -> [String: String] {
    KeyValuePayload.read(from: url)
  }

  private func startAdministratorProcess(
    appProbe: String,
    appProbePath: String,
    overlay: AppTCCOverlayResult
  ) throws {
    let uid = getuid()
    let gid = getgid()
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let channel = overlay.isReady ? "app_tcc_overlay_plus_administrator" : "administrator_only"
    let arguments = scannerArguments(
      privilegeChannel: channel,
      appFDAProbe: appProbe,
      appFDAProbePath: appProbePath,
      overlay: overlay
    ).dropFirst().map(\.shellSingleQuoted).joined(separator: " ")

    let wrapper = """
      #!/bin/zsh
      emulate -L zsh
      set -u
      umask 077

      PROGRESS=\(progressURL.path.shellSingleQuoted)
      LOG=\(logURL.path.shellSingleQuoted)
      RESULT=\(resultURL.path.shellSingleQuoted)
      STARTED=\(wrapperStartedURL.path.shellSingleQuoted)
      MARKER=\(launchMarkerURL.path.shellSingleQuoted)
      OUTPUT_DIR=\(library.scansURL.path.shellSingleQuoted)
      SCANNER=\(scannerURL.path.shellSingleQuoted)

      /usr/bin/touch "$STARTED"
      /usr/sbin/chown \(uid):\(gid) "$STARTED" >/dev/null 2>&1 || true
      /bin/chmod 600 "$STARTED" >/dev/null 2>&1 || true
      printf 'MLS_PROGRESS\\tversion=1\\tepoch=%s\\tphase=authorization\\tstatus=complete\\tstage=授權\\tmessage=管理員唯讀授權已通過，正在啟動掃描器。\\n' "$(/bin/date +%s)" >> "$PROGRESS"
      /usr/sbin/chown \(uid):\(gid) "$PROGRESS" >/dev/null 2>&1 || true
      /bin/chmod 600 "$PROGRESS" >/dev/null 2>&1 || true

      exec >> "$LOG" 2>&1
      export HOME=\(home.shellSingleQuoted)

      typeset -i scanner_exit_status=0
      /bin/zsh "$SCANNER" \(arguments) || scanner_exit_status=$?

      typeset -a reports
      reports=("$OUTPUT_DIR"/*-storage-tree-*.md(Nom))
      for report in "${reports[@]}"; do
        if [[ "$report" -nt "$MARKER" ]]; then
          /usr/sbin/chown \(uid):\(gid) "$report" >/dev/null 2>&1 || true
          /bin/chmod 600 "$report" >/dev/null 2>&1 || true
        fi
      done

      result_tmp="$RESULT.tmp.$$"
      printf 'status=%s\\n' "$scanner_exit_status" > "$result_tmp"
      /usr/sbin/chown \(uid):\(gid) "$result_tmp" >/dev/null 2>&1 || true
      /bin/chmod 600 "$result_tmp" >/dev/null 2>&1 || true
      /bin/mv -f "$result_tmp" "$RESULT"
      /usr/sbin/chown \(uid):\(gid) "$LOG" "$PROGRESS" >/dev/null 2>&1 || true
      /bin/chmod 600 "$LOG" "$PROGRESS" >/dev/null 2>&1 || true
      exit 0
      """

    try wrapper.write(to: wrapperURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: wrapperURL.path)

    let command = "/bin/zsh \(wrapperURL.path.shellSingleQuoted)"
    let source = """
      with timeout of 7200 seconds
        do shell script "\(command.appleScriptStringEscaped)" with administrator privileges
      end timeout
      """

    let pipe = Pipe()
    authorizationPipe = pipe
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    process.standardOutput = pipe
    process.standardError = pipe
    process.terminationHandler = { [weak self] process in
      let diagnostic: String?
      do {
        if let data = try pipe.fileHandleForReading.readToEnd() {
          diagnostic = String(decoding: data, as: UTF8.self)
        } else {
          diagnostic = nil
        }
      } catch {
        diagnostic = error.localizedDescription
      }
      guard let self else { return }
      if let resultStatus = self.resultStatusIfAvailable() {
        self.finishProcess(status: resultStatus, diagnostic: diagnostic)
      } else {
        self.finishAuthorizationProcess(status: process.terminationStatus, diagnostic: diagnostic)
      }
    }

    stateLock.lock()
    administratorAuthorizationStarted = true
    authorizationProcessStartedAt = Date()
    stateLock.unlock()

    do {
      try process.run()
      recordProcessStart()
      stateLock.lock()
      self.process = process
      stateLock.unlock()
    } catch {
      stateLock.lock()
      administratorAuthorizationStarted = false
      stateLock.unlock()
      stopProgressTimer()
      throw ScannerLauncherError.scanFailed(error.localizedDescription)
    }
  }

  private func recordProcessStart() {
    stateLock.lock()
    if firstProcessStartedAt == nil { firstProcessStartedAt = Date() }
    stateLock.unlock()
  }

  private func finishAuthorizationProcess(status: Int32, diagnostic: String?) {
    let normalized = diagnostic?.lowercased() ?? ""
    stateLock.lock()
    let wasCancelled = cancellationRequested
    let reason = cancellationReason
    stateLock.unlock()

    if wasCancelled {
      finishWithError(ScannerLauncherError.scanCancelled(reason))
    } else if finishUsingCompletedReportIfAvailable() {
      return
    } else if normalized.contains("-128") || normalized.contains("user canceled")
      || normalized.contains("user cancelled")
    {
      finishWithError(ScannerLauncherError.authorizationCancelled)
    } else if status != 0 {
      let authorizationMessage = diagnostic?.trimmingCharacters(in: .whitespacesAndNewlines)
      let scannerMessage = lastLogLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
      finishWithError(
        ScannerLauncherError.scanFailed(
          scannerMessage?.nilIfEmpty ?? authorizationMessage?.nilIfEmpty
            ?? "macOS 授權程序結束，狀態碼 \(status)。"
        )
      )
    } else {
      finishWithError(ScannerLauncherError.missingCompletedReport)
    }
  }

  private func finishProcess(status: Int32, diagnostic: String?) {
    stateLock.lock()
    let wasCancelled = cancellationRequested
    let cancelReason = cancellationReason
    let watchdogCancelled = watchdogCancellationIssued
    stateLock.unlock()

    if status == 130 || wasCancelled {
      let error: ScannerLauncherError =
        watchdogCancelled
        ? .scanTimedOut(cancelReason)
        : .scanCancelled(cancelReason)
      finishWithError(error)
      return
    }
    if status == 124 {
      finishWithError(
        ScannerLauncherError.scanTimedOut(
          lastStructuredMessage()
            ?? "掃描核心長時間沒有輸出，已由自我檢查安全中止；既有完成報告仍保留。"
        )
      )
      return
    }

    // A complete report is authoritative. Recover it even if a thin outer
    // authorization or compatibility wrapper fails during post-processing.
    if finishUsingCompletedReportIfAvailable() {
      return
    }

    guard status == 0 else {
      let detail = lastStructuredMessage() ?? lastLogLine() ?? diagnostic
      finishWithError(
        ScannerLauncherError.scanFailed(
          detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "掃描器結束，狀態碼 \(status)。"
        )
      )
      return
    }

    finishWithError(ScannerLauncherError.missingCompletedReport)
  }

  private func finishWithError(_ error: Error) {
    finish(.failure(error))
  }

  private func finish(_ result: Result<URL, Error>) {
    let completedAt = Date()
    stateLock.lock()
    guard !finished else {
      stateLock.unlock()
      return
    }
    finished = true
    scannerFinishedAt = completedAt
    stateLock.unlock()

    stopProgressTimer()
    try? outputHandle?.close()
    outputHandle = nil
    authorizationPipe = nil

    // Keep a compact diagnostic bundle for completed scans as well as failures.
    // The report retention policy keeps only one report per location, so without
    // this bundle a repeated 2 s / 18 s / 22 s slowdown cannot be attributed to a
    // specific phase. Heavy App TCC overlay rows are removed before preservation;
    // ReportLibrary deletes old bundles after 24 hours and caps their count.
    let preserveDiagnostics = shouldPreserveDiagnostics(for: result)
    compactSessionArtifacts()
    writeSessionSummary(for: result, finishedAt: completedAt)
    try? library.pruneScanDiagnostics()
    DispatchQueue.main.async { [completion, sessionURL] in
      completion(result)
      if !preserveDiagnostics {
        try? FileManager.default.removeItem(at: sessionURL)
      }
    }
  }

  private func shouldPreserveDiagnostics(for result: Result<URL, Error>) -> Bool {
    guard case .failure(let error) = result else { return true }
    guard let scannerError = error as? ScannerLauncherError else { return true }
    switch scannerError {
    case .authorizationCancelled, .scanCancelled:
      return false
    default:
      return true
    }
  }

  private func compactSessionArtifacts() {
    // A system TCC overlay can contain hundreds of thousands of raw `du` rows.
    // The completed Markdown already contains the merged result, so retaining the
    // raw overlay would turn diagnostics into another storage leak.
    for url in [appOverlayRawURL, appOverlayWrapperURL, wrapperURL] {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func writeSessionSummary(for result: Result<URL, Error>, finishedAt: Date) {
    let wrapperStartedAt = wrapperStartDate()
    let processStartedAt: Date?
    let authorizationStartedAt: Date?
    stateLock.lock()
    processStartedAt = firstProcessStartedAt
    authorizationStartedAt = authorizationProcessStartedAt
    stateLock.unlock()

    let scannerStartAt = wrapperStartedAt ?? processStartedAt
    var payload: [String: Any] = [
      "schema_version": 3,
      "app_version": AppMetadata.version,
      "scanner_version": AppMetadata.scannerVersion,
      "target_kind": target.kind.rawValue,
      "target_path": target.path,
      "target_display_name": target.displayName,
      "target_volume_uuid": target.volumeUUID ?? "",
      "requested_privilege_mode": mode == .administrator ? "administrator" : "current_user",
      "requested_at": iso8601(requestedAt),
      "target_resolved_at": iso8601(targetResolvedAt),
      "scanner_installed_at": iso8601(scannerInstalledAt),
      "permission_probe_finished_at": iso8601(permissionProbeFinishedAt),
      "session_created_at": iso8601(startedAt),
      "session_ready_at": iso8601(sessionReadyAt),
      "finished_at": iso8601(finishedAt),
      "target_resolution_seconds": duration(requestedAt, targetResolvedAt),
      "scanner_installation_seconds": duration(targetResolvedAt, scannerInstalledAt),
      "permission_probe_seconds": duration(scannerInstalledAt, permissionProbeFinishedAt),
      "session_preparation_seconds": duration(permissionProbeFinishedAt, sessionReadyAt),
      "request_to_finish_seconds": duration(requestedAt, finishedAt),
      "session_elapsed_seconds": duration(startedAt, finishedAt),
      "app_fda_probe": appFullDiskAccessProbe.reportStatus,
      "diagnostic_directory": sessionURL.path,
      "last_progress_message": lastStructuredMessage() ?? "",
      "last_log_line": lastLogLine() ?? "",
    ]
    if let processStartedAt {
      payload["first_process_started_at"] = iso8601(processStartedAt)
    }
    if let authorizationStartedAt {
      payload["authorization_process_started_at"] = iso8601(authorizationStartedAt)
    }
    if let wrapperStartedAt {
      payload["scanner_wrapper_started_at"] = iso8601(wrapperStartedAt)
    }
    if let scannerStartAt {
      payload["launch_to_scanner_start_seconds"] = duration(sessionReadyAt, scannerStartAt)
    }
    if let authorizationStartedAt, let wrapperStartedAt {
      payload["authorization_wait_seconds"] = duration(authorizationStartedAt, wrapperStartedAt)
    }

    switch result {
    case .success(let report):
      payload["outcome"] = "success"
      payload["report_path"] = report.path
      if let size = try? report.resourceValues(forKeys: [.fileSizeKey]).fileSize {
        payload["report_file_size_bytes"] = size
      }
      let reportMetadata = compactReportMetadata(at: report)
      for (key, value) in reportMetadata {
        payload["report_\(key)"] = value
      }
      if let scannerSeconds = reportMetadata["total_duration_seconds"] as? Int {
        payload["app_before_report_seconds"] = max(
          0,
          duration(requestedAt, finishedAt) - Double(scannerSeconds)
        )
      }
    case .failure(let error):
      payload["outcome"] = "failure"
      payload["error"] = error.localizedDescription
    }

    writeSessionPayload(payload)
  }

  func makeTimingSnapshot(
    reportURL: URL,
    summary: ScanSummary,
    reportParseSeconds: TimeInterval,
    initialViewBuildSeconds: TimeInterval,
    presentationIndexSource: ReportPresentationIndexSource,
    presentationIndexWriteSeconds: TimeInterval,
    readyAt: Date
  ) -> ScanTimingSnapshot {
    let completedAt: Date
    let processStartedAt: Date?
    stateLock.lock()
    completedAt = scannerFinishedAt ?? readyAt
    processStartedAt = firstProcessStartedAt
    stateLock.unlock()

    let scannerStartAt = wrapperStartDate() ?? processStartedAt
    return ScanTimingSnapshot(
      target: target,
      reportURL: reportURL,
      diagnosticDirectoryURL: sessionURL,
      requestedAt: requestedAt,
      scannerCompletedAt: completedAt,
      readyAt: readyAt,
      targetResolutionSeconds: duration(requestedAt, targetResolvedAt),
      scannerInstallationSeconds: duration(targetResolvedAt, scannerInstalledAt),
      permissionProbeSeconds: duration(scannerInstalledAt, permissionProbeFinishedAt),
      sessionPreparationSeconds: duration(permissionProbeFinishedAt, sessionReadyAt),
      launchToScannerStartSeconds: scannerStartAt.map { duration(sessionReadyAt, $0) },
      requestToScannerCompletionSeconds: duration(requestedAt, completedAt),
      scannerPreflightSeconds: summary.preflightDurationSeconds,
      scannerPrepareSeconds: summary.prepareDurationSeconds,
      scannerPathSeconds: summary.pathScanDurationSeconds,
      scannerMetadataSeconds: summary.metadataDurationSeconds,
      scannerReportWriteSeconds: summary.reportWriteDurationSeconds,
      scannerTotalSeconds: summary.totalDurationSeconds,
      reportParseSeconds: max(0, reportParseSeconds),
      initialViewBuildSeconds: max(0, initialViewBuildSeconds),
      presentationIndexSource: presentationIndexSource,
      presentationIndexWriteSeconds: max(0, presentationIndexWriteSeconds),
      usedTerminalFallback: false
    )
  }

  func recordPostProcessing(_ timing: ScanTimingSnapshot) {
    let summaryURL = sessionURL.appendingPathComponent("session-summary.json")
    var payload: [String: Any] = [:]
    if let data = try? Data(contentsOf: summaryURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      payload = object
    }
    payload["workflow_ready_at"] = iso8601(timing.readyAt)
    // `report_parse_seconds` is retained for compatibility with schema 2 readers.
    // In schema 3 the same measured interval is named precisely: it can represent
    // either a fresh Markdown single-pass index build or a persistent-index read.
    payload["report_parse_seconds"] = timing.reportParseSeconds
    payload["report_index_seconds"] = timing.reportParseSeconds
    payload["initial_view_build_seconds"] = timing.initialViewBuildSeconds
    payload["presentation_index_source"] = timing.presentationIndexSource.rawValue
    payload["presentation_index_write_seconds"] = timing.presentationIndexWriteSeconds
    payload["request_to_ready_seconds"] = timing.requestToReadySeconds
    payload["scanner_completion_to_ready_seconds"] = max(
      0,
      timing.readyAt.timeIntervalSince(timing.scannerCompletedAt)
    )
    payload["app_total_outside_scanner_seconds"] = max(
      0,
      timing.requestToReadySeconds - Double(timing.scannerTotalSeconds)
    )
    payload["scanner_phase_accounted_seconds"] = timing.scannerPhaseAccountedSeconds
    payload["scanner_unattributed_seconds"] = timing.scannerUnattributedSeconds
    payload["report_ready"] = true
    writeSessionPayload(payload)
  }

  private func compactReportMetadata(at report: URL) -> [String: Any] {
    let numericKeys: Set<String> = [
      "preflight_duration_seconds",
      "prepare_duration_seconds",
      "path_scan_duration_seconds",
      "metadata_duration_seconds",
      "data_collection_duration_seconds",
      "report_write_duration_seconds",
      "total_duration_seconds",
      "target_accounting_gap_kib",
      "target_volume_used_kib_pre_scan",
      "target_volume_available_kib_pre_scan",
    ]
    let retainedKeys: Set<String> = numericKeys.union([
      "scanner_version",
      "scan_target_kind",
      "scan_target_path",
      "scan_target_volume_uuid",
      "target_mount_point",
      "target_device_identifier",
      "target_filesystem_type",
      "target_is_apfs",
      "target_spotlight_root_status",
      "target_fsevents_root_status",
      "target_trash_root_status",
      "volume_scan_profile",
      "volume_volatile_metadata_excluded",
      "full_disk_access_probe",
      "path_scan_status",
    ])

    guard let handle = try? FileHandle(forReadingFrom: report) else { return [:] }
    defer { try? handle.close() }

    do {
      let size = try handle.seekToEnd()
      var data = Data()
      try handle.seek(toOffset: 0)
      data.append(try handle.read(upToCount: 256 * 1024) ?? Data())
      if size > 128 * 1024 {
        try handle.seek(toOffset: size - 128 * 1024)
        data.append(Data("\n".utf8))
        data.append(try handle.read(upToCount: 128 * 1024) ?? Data())
      }
      guard let text = String(data: data, encoding: .utf8) else { return [:] }

      var result: [String: Any] = [:]
      for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = String(rawLine)
        guard let separator = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        guard retainedKeys.contains(key) else { continue }
        let value = String(line[line.index(after: separator)...])
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if numericKeys.contains(key), let number = Int(value) {
          result[key] = number
        } else {
          result[key] = value
        }
      }
      return result
    } catch {
      return [:]
    }
  }

  private func wrapperStartDate() -> Date? {
    (try? wrapperStartedURL.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate
  }

  private func duration(_ start: Date, _ end: Date) -> TimeInterval {
    max(0, end.timeIntervalSince(start))
  }

  private func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private func writeSessionPayload(_ payload: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(payload),
      let data = try? JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    else { return }
    let url = sessionURL.appendingPathComponent("session-summary.json")
    try? data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func resultStatusIfAvailable() -> Int32? {
    guard let text = try? String(contentsOf: resultURL, encoding: .utf8), !text.isEmpty else {
      return nil
    }
    for line in text.split(whereSeparator: \.isNewline) {
      if line.hasPrefix("status="), let value = Int32(line.dropFirst("status=".count)) {
        return value
      }
    }
    return nil
  }

  @discardableResult
  private func finishUsingCompletedReportIfAvailable() -> Bool {
    guard let report = newestCompletedReportCreatedByThisSession() else { return false }
    do {
      try library.keepLatestReportForLocation(report)
      finish(.success(report))
    } catch {
      finish(.failure(error))
    }
    return true
  }

  private func newestCompletedReportCreatedByThisSession() -> URL? {
    library.scanReportURLs()
      .filter { !reportsBeforeStart.contains($0.standardizedFileURL.path) }
      .filter { url in
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate
        return date == nil || date! >= startedAt.addingTimeInterval(-2)
      }
      .sorted { modificationDate($0) > modificationDate($1) }
      .first(where: isCompletedReport)
  }

  private func modificationDate(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate ?? .distantPast
  }

  private func isCompletedReport(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    do {
      let size = try handle.seekToEnd()
      try handle.seek(toOffset: size > 131_072 ? size - 131_072 : 0)
      let tail = try handle.readToEnd() ?? Data()
      let text = String(decoding: tail, as: UTF8.self)
      return text.contains("\nreport_complete=true\n") || text.hasSuffix("report_complete=true\n")
    } catch {
      return false
    }
  }

  private var isFinished: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return finished
  }

  private func startProgressTimer() {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now(), repeating: .milliseconds(400), leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      guard let self, !self.isFinished else { return }
      let snapshot = self.progressSnapshot()
      DispatchQueue.main.async { self.onProgress(snapshot) }
      self.runWatchdog(snapshot: snapshot)
    }
    timer.resume()
    progressTimer = timer
  }

  private func stopProgressTimer() {
    progressTimer?.cancel()
    progressTimer = nil
  }

  private func progressSnapshot(forceHealth: ScanProgressHealth? = nil) -> ScanProgressSnapshot {
    let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
    let parsed = readProgressTail()
    let event = parsed.latest

    if let event {
      let token = [
        event.phase,
        event.status,
        event.message,
        String(event.epochSeconds),
        String(event.currentStep ?? -1),
        String(event.stageElapsedSeconds ?? -1),
        String(event.nodeCount ?? -1),
      ].joined(separator: "|")
      if token != lastEventToken {
        lastEventToken = token
        lastEventDate = Date(timeIntervalSince1970: event.epochSeconds)
      }
      let meaningfulToken = event.meaningfulActivityToken
      if meaningfulToken != lastMeaningfulProgressToken {
        lastMeaningfulProgressToken = meaningfulToken
        lastMeaningfulProgressDate = Date(timeIntervalSince1970: event.epochSeconds)
      }
      if let fraction = event.fraction {
        lastProgressFraction = max(lastProgressFraction ?? 0, fraction)
      }
      lastParseResult = parsed
    }

    stateLock.lock()
    let isCancelling = cancellationRequested
    let authorizationStarted = administratorAuthorizationStarted
    stateLock.unlock()

    let wrapperStarted = FileManager.default.fileExists(atPath: wrapperStartedURL.path)
    let scannerHasLaunched = mode == .currentUser || authorizationStarted || wrapperStarted
    let secondsSinceUpdate =
      lastEventDate.map { max(0, Int(Date().timeIntervalSince($0))) }
      ?? (scannerHasLaunched ? elapsed : nil)
    let health: ScanProgressHealth
    if let forceHealth {
      health = forceHealth
    } else if isCancelling {
      health = .cancelling
    } else if mode == .administrator && authorizationStarted && !wrapperStarted {
      health = .waitingForAuthorization
    } else if event?.status == "stalled" || event?.status == "timeout" {
      health = .stalled
    } else if event?.status == "delayed" {
      health = .delayed
    } else if let secondsSinceUpdate, secondsSinceUpdate >= heartbeatStalledSeconds {
      health = .stalled
    } else if let secondsSinceUpdate, secondsSinceUpdate >= heartbeatWarningSeconds {
      health = .delayed
    } else {
      health = .active
    }

    let fallbackMessage: String
    let fallbackStage: String
    if mode == .administrator && !authorizationStarted {
      fallbackMessage = "正在以 App 權限核對並建立受保護使用者資料覆蓋…"
      fallbackStage = "App 權限預掃描"
    } else if mode == .administrator && !wrapperStarted {
      fallbackMessage = "等待你完成 macOS 管理員授權…"
      fallbackStage = "授權"
    } else if wrapperStarted {
      fallbackMessage = "授權已完成，正在啟動唯讀掃描器…"
      fallbackStage = "準備"
    } else {
      fallbackMessage = "正在啟動唯讀掃描器…"
      fallbackStage = "準備"
    }

    return ScanProgressSnapshot(
      message: isCancelling ? "正在安全停止掃描…" : (event?.message ?? fallbackMessage),
      detail: event?.detail,
      currentPath: event?.path,
      fraction: lastProgressFraction,
      stage: event?.stage ?? fallbackStage,
      currentStep: event?.currentStep,
      totalSteps: event?.totalSteps,
      elapsedSeconds: elapsed,
      estimatedRemainingSeconds: estimatedRemainingSeconds(
        fraction: lastProgressFraction, elapsed: elapsed),
      secondsSinceUpdate: secondsSinceUpdate,
      nodeCount: event?.nodeCount,
      errorCount: event?.errorCount,
      health: health,
      recentMessages: lastParseResult.recentMessages,
      isEstimated: true
    )
  }

  private func readProgressTail() -> ScanProgressParseResult {
    guard let handle = try? FileHandle(forReadingFrom: progressURL) else {
      return lastParseResult
    }
    defer { try? handle.close() }
    do {
      let size = try handle.seekToEnd()
      try handle.seek(toOffset: size > 256 * 1024 ? size - 256 * 1024 : 0)
      let data = try handle.readToEnd() ?? Data()
      guard !data.isEmpty else { return lastParseResult }
      return ScanProgressParser.parse(data: data)
    } catch {
      return lastParseResult
    }
  }

  private func runWatchdog(snapshot: ScanProgressSnapshot) {
    stateLock.lock()
    let alreadyCancelling = cancellationRequested
    let alreadyIssued = watchdogCancellationIssued
    stateLock.unlock()
    guard !alreadyCancelling, !alreadyIssued else { return }

    let wrapperStarted =
      mode == .currentUser
      || FileManager.default.fileExists(atPath: wrapperStartedURL.path)
    guard wrapperStarted else { return }

    if let meaningfulDate = lastMeaningfulProgressDate {
      let idleSeconds = max(0, Int(Date().timeIntervalSince(meaningfulDate)))
      if idleSeconds >= meaningfulProgressTimeoutSeconds {
        stateLock.lock()
        watchdogCancellationIssued = true
        stateLock.unlock()
        cancel(
          reason: "掃描已連續 10 分鐘沒有新增目錄節點或階段進展，App 已要求安全中止；只要掃描仍有實質進度，就不受總執行時間限制。"
        )
        return
      }
    }

    if let stale = snapshot.secondsSinceUpdate, stale >= heartbeatAbortSeconds {
      stateLock.lock()
      watchdogCancellationIssued = true
      stateLock.unlock()
      cancel(
        reason: "掃描器已 \(stale) 秒沒有回報心跳，App 已要求安全中止；這通常表示外部磁碟、APFS 工具或檔案系統呼叫沒有回應。"
      )
    }
  }

  private func estimatedRemainingSeconds(fraction: Double?, elapsed: Int) -> Int? {
    guard let fraction, fraction > 0.04, fraction < 0.995, elapsed > 2 else { return nil }
    let estimate = Double(elapsed) * (1 - fraction) / fraction
    guard estimate.isFinite, estimate >= 0 else { return nil }
    return min(6 * 60 * 60, Int(estimate.rounded()))
  }

  private func lastStructuredMessage() -> String? {
    readProgressTail().latest?.message
  }

  private func lastLogLine() -> String? {
    guard let handle = try? FileHandle(forReadingFrom: logURL) else { return nil }
    defer { try? handle.close() }
    do {
      let size = try handle.seekToEnd()
      try handle.seek(toOffset: size > 64 * 1024 ? size - 64 * 1024 : 0)
      let data = try handle.readToEnd() ?? Data()
      return String(decoding: data, as: UTF8.self)
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .reversed()
        .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    } catch {
      return nil
    }
  }
}

struct ScannerLauncher {
  let library: ReportLibrary

  func startIntegratedScan(
    mode: ScanPrivilegeMode,
    target: ScanTarget,
    onProgress: @escaping (ScanProgressSnapshot) -> Void,
    completion: @escaping (Result<URL, Error>) -> Void
  ) throws -> ScanSession {
    let requestedAt = Date()
    guard let resolvedTarget = ScanTargetResolver.resolveMountedTarget(target) else {
      throw ScannerLauncherError.scanFailed(
        "找不到已掛載的「\(target.displayName)」。請重新插入磁碟，或重新選擇掃描位置。"
      )
    }
    let targetResolvedAt = Date()
    let installedScanner = try installScanner()
    let scannerInstalledAt = Date()
    // Full Disk Access probes inspect Mail, Messages, Safari, and AddressBook.
    // They are meaningful only for a full system scan. Running them before every
    // external-volume scan touched unrelated services and introduced a variable
    // delay that was not included in the scanner report's duration.
    let appFullDiskAccessProbe =
      resolvedTarget.kind == .system
      ? FullDiskAccessProbe.inspectCurrentApp()
      : .notApplicableToSelectedLocation
    let permissionProbeFinishedAt = Date()
    let sessionURL = library.scanWorkURL.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let session = try ScanSession(
      mode: mode,
      target: resolvedTarget,
      library: library,
      scannerURL: installedScanner,
      sessionURL: sessionURL,
      appFullDiskAccessProbe: appFullDiskAccessProbe,
      requestedAt: requestedAt,
      targetResolvedAt: targetResolvedAt,
      scannerInstalledAt: scannerInstalledAt,
      permissionProbeFinishedAt: permissionProbeFinishedAt,
      onProgress: onProgress,
      completion: completion
    )
    do {
      try session.start()
      return session
    } catch {
      session.discardAfterFailedStart()
      throw error
    }
  }

  /// Compatibility path for machines where the integrated authorization workflow fails.
  ///
  /// The terminal fallback runs the core scanner directly. This keeps the password
  /// prompt in the foreground Terminal process, where `sudo -v` can safely read from
  /// the terminal, instead of asking a background child to read a password.
  @discardableResult
  func launchInTerminal(target: ScanTarget) throws -> ScanTarget {
    guard let resolvedTarget = ScanTargetResolver.resolveMountedTarget(target) else {
      throw ScannerLauncherError.scanFailed(
        "找不到已掛載的「\(target.displayName)」。請重新插入磁碟，或重新選擇掃描位置。"
      )
    }
    _ = try installScanner()
    let installedCore = library.scannerURL.appendingPathComponent(
      "mac-system-storage-tree-core-v2.5.3.command")
    guard FileManager.default.fileExists(atPath: installedCore.path) else {
      throw ScannerLauncherError.resourceMissing
    }

    let wrapper = library.scannerURL.appendingPathComponent("執行 MacStorageLens 完整掃描.command")
    var targetArguments = [
      "--target-kind", resolvedTarget.kind.rawValue,
      "--target-path", resolvedTarget.path,
      "--target-name", resolvedTarget.displayName,
      "--launcher-mode", "terminal",
      "--privilege-channel", "terminal",
    ]
    if let volumeUUID = resolvedTarget.volumeUUID, !volumeUUID.isEmpty {
      targetArguments += ["--target-volume-uuid", volumeUUID]
    }
    let targetArgumentText = targetArguments.map(\.shellSingleQuoted).joined(separator: " ")
    let script = """
      #!/bin/zsh
      emulate -L zsh
      set -u
      clear
      OUTPUT_DIR=\(library.scansURL.path.shellSingleQuoted)
      CORE=\(installedCore.path.shellSingleQuoted)

      printf '%s\\n' \\
        'MacStorageLens Terminal 相容模式' \\
        '注意：此模式使用 Terminal 自己的「完整磁碟存取權」，不是 MacStorageLens App 的授權。' \\
        '若受限／診斷行異常增加，請在系統設定中授權 Terminal，完全退出 Terminal 後再重試。' \\
        ''

      typeset -i scanner_exit_status=0
      /bin/zsh "$CORE" --sudo --output-dir "$OUTPUT_DIR" --skip-large-files --heartbeat-seconds 5 \
        \(targetArgumentText) || scanner_exit_status=$?

      if (( scanner_exit_status == 0 )); then
        printf '\\n掃描與報告建立完成。現在可以回到 MacStorageLens；App 會自動偵測並載入最新報告。\\n'
      else
        printf '\\n掃描程序以狀態碼 %s 結束。既有完成報告仍會保留。\\n' "$scanner_exit_status"
      fi
      exit "$scanner_exit_status"
      """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

    let result = try ProcessRunner.run(
      "/usr/bin/open", ["-a", "Terminal", wrapper.path], timeout: 10)
    guard result.status == 0 else {
      throw ProcessRunnerError.launchFailed(
        result.stderrString.isEmpty ? "無法開啟 Terminal 掃描器。" : result.stderrString)
    }
    return resolvedTarget
  }

  @discardableResult
  func installScanner() throws -> URL {
    guard let wrapperSource = bundledScannerURL(), let coreSource = bundledScannerCoreURL() else {
      throw ScannerLauncherError.resourceMissing
    }

    let wrapperDestination = library.scannerURL.appendingPathComponent(
      "mac-system-storage-tree-v2.5.3.command")
    let coreDestination = library.scannerURL.appendingPathComponent(
      "mac-system-storage-tree-core-v2.5.3.command")

    let currentScannerNames = Set([
      wrapperDestination.lastPathComponent, coreDestination.lastPathComponent,
    ])
    if let installedResources = try? FileManager.default.contentsOfDirectory(
      at: library.scannerURL,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) {
      for resource in installedResources {
        let name = resource.lastPathComponent
        guard name.hasPrefix("mac-system-storage-tree"), name.hasSuffix(".command"),
          !currentScannerNames.contains(name)
        else { continue }
        try? FileManager.default.removeItem(at: resource)
      }
    }

    try installScannerResourceIfNeeded(from: wrapperSource, to: wrapperDestination)
    try installScannerResourceIfNeeded(from: coreSource, to: coreDestination)
    return wrapperDestination
  }

  private func installScannerResourceIfNeeded(from source: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    let sourceData = try Data(contentsOf: source, options: [.mappedIfSafe])
    let destinationData = try? Data(contentsOf: destination, options: [.mappedIfSafe])

    if destinationData != sourceData {
      let temporary = destination.deletingLastPathComponent().appendingPathComponent(
        ".scanner-install-\(UUID().uuidString)")
      defer { try? fileManager.removeItem(at: temporary) }
      try sourceData.write(to: temporary, options: .atomic)
      if fileManager.fileExists(atPath: destination.path) {
        _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try fileManager.moveItem(at: temporary, to: destination)
      }
    }

    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
  }

  private func bundledScannerURL() -> URL? {
    bundledResource(
      resourceName: "mac-system-storage-tree-v2.5.3",
      developmentPath: "Resources/mac-system-storage-tree-v2.5.3.command"
    )
  }

  private func bundledScannerCoreURL() -> URL? {
    bundledResource(
      resourceName: "mac-system-storage-tree-core-v2.5.3",
      developmentPath: "Resources/mac-system-storage-tree-core-v2.5.3.command"
    )
  }

  private func bundledResource(resourceName: String, developmentPath: String) -> URL? {
    if let resource = Bundle.main.url(forResource: resourceName, withExtension: "command") {
      return resource
    }

    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let development = current.appendingPathComponent(developmentPath)
    if FileManager.default.fileExists(atPath: development.path) {
      return development
    }
    return nil
  }

  static func openFullDiskAccessSettings() {
    openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
  }

  static func openStorageSettings() {
    openSettingsURL("x-apple.systempreferences:com.apple.settings.Storage")
  }

  static func openSpotlightSettings() {
    for value in [
      "x-apple.systempreferences:com.apple.Spotlight-Settings.extension",
      "x-apple.systempreferences:com.apple.preference.spotlight",
    ] {
      guard let url = URL(string: value) else { continue }
      if NSWorkspace.shared.open(url) { return }
    }
  }

  private static func openSettingsURL(_ value: String) {
    guard let url = URL(string: value) else { return }
    NSWorkspace.shared.open(url)
  }
}

extension String {
  fileprivate var appleScriptStringEscaped: String {
    replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
