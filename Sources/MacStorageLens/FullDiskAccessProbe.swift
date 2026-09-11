import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

enum FullDiskAccessProbeState: String, Hashable, Sendable {
  case checking
  case available
  case blocked
  case indeterminate
  case notApplicable

  var isAvailable: Bool { self == .available }
}

struct FullDiskAccessProbeResult: Hashable, Sendable {
  let state: FullDiskAccessProbeState
  let path: String?
  let detail: String
  let checkedAt: Date?

  static let checking = FullDiskAccessProbeResult(
    state: .checking,
    path: nil,
    detail: "正在由 MacStorageLens App 本身核對受保護路徑…",
    checkedAt: nil
  )

  static let indeterminate = FullDiskAccessProbeResult(
    state: .indeterminate,
    path: nil,
    detail: "找不到可用的受保護測試路徑，因此無法自動判定。",
    checkedAt: nil
  )

  /// External volumes and explicitly selected folders do not need a probe of
  /// Mail, Messages, Safari, or AddressBook. Avoid touching unrelated protected
  /// locations at the scan boundary; those probes can block while macOS services
  /// are busy and made a two-second external scan appear to take twenty seconds.
  static var notApplicableToSelectedLocation: FullDiskAccessProbeResult {
    FullDiskAccessProbeResult(
      state: .notApplicable,
      path: nil,
      detail: "外接磁碟與指定資料夾只讀取使用者明確選擇的位置；不需要探測 Mac 的受保護使用者資料。",
      checkedAt: Date()
    )
  }

  var reportStatus: String {
    switch state {
    case .available: return "LIKELY_AVAILABLE"
    case .blocked: return "LIKELY_MISSING_OR_TCC_BLOCKED"
    case .notApplicable: return "NOT_APPLICABLE"
    case .checking, .indeterminate: return "UNKNOWN"
    }
  }

  var reportPath: String { path ?? "NONE" }
}

enum FullDiskAccessProbe {
  /// macOS does not expose a public API that returns the Full Disk Access switch.
  /// Read a small set of protected directories from the App process itself. This
  /// deliberately avoids using the elevated AppleScript/root process, whose TCC
  /// responsibility chain is different from MacStorageLens.app.
  static func inspectCurrentApp() -> FullDiskAccessProbeResult {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let candidates = [
      home.appendingPathComponent("Library/Mail", isDirectory: true),
      home.appendingPathComponent("Library/Messages", isDirectory: true),
      home.appendingPathComponent("Library/Safari", isDirectory: true),
      home.appendingPathComponent(
        "Library/Application Support/AddressBook", isDirectory: true),
    ]

    var denied: [(URL, NSError)] = []
    var otherFailures: [(URL, NSError)] = []
    var existingCandidateCount = 0

    for candidate in candidates {
      do {
        _ = try FileManager.default.contentsOfDirectory(
          at: candidate,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        return FullDiskAccessProbeResult(
          state: .available,
          path: candidate.path,
          detail: "MacStorageLens App 本身可讀取受 TCC 保護的測試路徑。",
          checkedAt: Date()
        )
      } catch {
        let nsError = error as NSError
        if isMissing(nsError) { continue }
        existingCandidateCount += 1
        if isPermissionDenied(nsError) {
          denied.append((candidate, nsError))
        } else {
          otherFailures.append((candidate, nsError))
        }
      }
    }

    if let failure = denied.first {
      return FullDiskAccessProbeResult(
        state: .blocked,
        path: failure.0.path,
        detail:
          "App 直接讀取被 macOS 拒絕（\(failure.1.domain) \(failure.1.code)）。若剛完成授權，請完全退出 MacStorageLens 後重新開啟。",
        checkedAt: Date()
      )
    }

    if let failure = otherFailures.first {
      return FullDiskAccessProbeResult(
        state: .indeterminate,
        path: failure.0.path,
        detail:
          "受保護路徑探針回傳非權限型錯誤（\(failure.1.domain) \(failure.1.code)），無法可靠判定完整磁碟存取。",
        checkedAt: Date()
      )
    }

    guard existingCandidateCount > 0 else {
      return FullDiskAccessProbeResult(
        state: .indeterminate,
        path: nil,
        detail: "這台 Mac 上找不到 Mail、Messages、Safari 或 AddressBook 的既有測試目錄。",
        checkedAt: Date()
      )
    }

    return .indeterminate
  }

  static func inspectCurrentApp(
    completion: @escaping @MainActor @Sendable (FullDiskAccessProbeResult) -> Void
  ) {
    DispatchQueue.global(qos: .utility).async {
      let result = inspectCurrentApp()
      DispatchQueue.main.async {
        completion(result)
      }
    }
  }

  private static func isMissing(_ error: NSError) -> Bool {
    if error.domain == NSCocoaErrorDomain,
      error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError
    {
      return true
    }
    return error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
  }

  private static func isPermissionDenied(_ error: NSError) -> Bool {
    if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError {
      return true
    }
    return error.domain == NSPOSIXErrorDomain
      && (error.code == Int(EACCES) || error.code == Int(EPERM))
  }
}
