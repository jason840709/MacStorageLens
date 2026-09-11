import Foundation

struct ScanProgressEvent: Hashable {
  let epochSeconds: TimeInterval
  let phase: String
  let status: String
  let stage: String
  let message: String
  let detail: String?
  let currentStep: Int?
  let totalSteps: Int?
  let path: String?
  let elapsedSeconds: Int?
  let nodeCount: Int?
  let errorCount: Int?
  let fraction: Double?

  var stageElapsedSeconds: Int? { elapsedSeconds }

  /// A stable token for progress that represents actual scan advancement.
  /// Heartbeat timestamps and elapsed-time-only changes are intentionally excluded,
  /// so a long-running NAS scan can continue indefinitely while it keeps discovering
  /// new directory nodes or advances to a new phase/path/step.
  var meaningfulActivityToken: String {
    let semanticStatus: String
    switch status.lowercased() {
    case "complete", "skipped": semanticStatus = status.lowercased()
    default: semanticStatus = "running"
    }

    return [
      phase,
      semanticStatus,
      stage,
      String(currentStep ?? -1),
      String(totalSteps ?? -1),
      path ?? "",
      String(nodeCount ?? -1),
      String(errorCount ?? -1),
    ].joined(separator: "|")
  }
}

struct ScanProgressParseResult: Hashable {
  let latest: ScanProgressEvent?
  let recentMessages: [String]
  let lastPlainTextLine: String?
}

enum ScanProgressParser {
  private static let prefix = "MLS_PROGRESS\t"
  private static let legacyPrefix = "MSL_PROGRESS\t"

  static func parse(data: Data, recentLimit: Int = 7) -> ScanProgressParseResult {
    let text = String(decoding: data, as: UTF8.self)
    let lines = text.split(whereSeparator: \.isNewline).map(String.init)
    var events: [ScanProgressEvent] = []
    var lastPlainTextLine: String?

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      if let event = parse(line: line) {
        events.append(event)
      } else {
        lastPlainTextLine = trimmed
      }
    }

    var recent: [String] = []
    var seen = Set<String>()
    for event in events.reversed() {
      let value = event.message.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty, !seen.contains(value) else { continue }
      seen.insert(value)
      recent.append(value)
      if recent.count >= recentLimit { break }
    }

    return ScanProgressParseResult(
      latest: events.last,
      recentMessages: recent.reversed(),
      lastPlainTextLine: lastPlainTextLine
    )
  }

  static func parse(line: String) -> ScanProgressEvent? {
    if line.hasPrefix(prefix) {
      return parseKeyValueLine(line)
    }
    if line.hasPrefix(legacyPrefix) {
      return parseLegacyLine(line)
    }
    return nil
  }

  private static func parseKeyValueLine(_ line: String) -> ScanProgressEvent? {
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.first == "MLS_PROGRESS" else { return nil }

    var values: [String: String] = [:]
    for field in fields.dropFirst() {
      guard let separator = field.firstIndex(of: "=") else { continue }
      let key = String(field[..<separator])
      let value = String(field[field.index(after: separator)...])
      values[key] = value
    }

    let epoch = TimeInterval(values["epoch"] ?? "") ?? Date().timeIntervalSince1970
    let phase = nonempty(values["phase"]) ?? "prepare"
    let status = nonempty(values["status"]) ?? "active"
    let stage = nonempty(values["stage"]) ?? localizedStage(for: phase)
    let message = nonempty(values["message"]) ?? stage
    let detail = nonempty(values["detail"])
    let current = Int(values["current"] ?? "")
    let total = Int(values["total"] ?? "")
    let path = nonempty(values["path"])
    let elapsed = Int(values["elapsed"] ?? "")
    let nodes = Int(values["nodes"] ?? "")
    let errors = Int(values["errors"] ?? "")

    return ScanProgressEvent(
      epochSeconds: epoch,
      phase: phase,
      status: status,
      stage: stage,
      message: message,
      detail: detail,
      currentStep: current,
      totalSteps: total,
      path: path,
      elapsedSeconds: elapsed,
      nodeCount: nodes,
      errorCount: errors,
      fraction: fraction(
        phase: phase,
        status: status,
        current: current,
        total: total,
        elapsed: elapsed
      )
    )
  }

  private static func parseLegacyLine(_ line: String) -> ScanProgressEvent? {
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.count >= 10, fields[0] == "MSL_PROGRESS" else { return nil }
    let epoch = TimeInterval(fields[1]) ?? Date().timeIntervalSince1970
    let stage = String(fields[2])
    let current = Int(fields[3])
    let total = Int(fields[4])
    let permille = Int(fields[5])
    let path = nonempty(String(fields[6]))
    let message = nonempty(String(fields[7])) ?? stage

    return ScanProgressEvent(
      epochSeconds: epoch,
      phase: stage,
      status: "active",
      stage: stage,
      message: message,
      detail: nil,
      currentStep: current,
      totalSteps: total,
      path: path,
      elapsedSeconds: nil,
      nodeCount: Int(fields[8]),
      errorCount: Int(fields[9]),
      fraction: permille.map { min(1, max(0, Double($0) / 1000)) }
    )
  }

  private static func fraction(
    phase: String,
    status: String,
    current: Int?,
    total: Int?,
    elapsed: Int?
  ) -> Double? {
    let normalizedPhase = phase.lowercased()
    let normalizedStatus = status.lowercased()

    if normalizedPhase == "complete" { return 1 }
    if normalizedPhase == "cancelled" { return nil }

    switch normalizedPhase {
    case "authorization":
      return 0.005
    case "prepare":
      return stagedFraction(
        base: 0.01, span: 0.04, current: current, total: total, status: normalizedStatus)
    case "scan":
      guard let current, let total, total > 0 else { return 0.05 }
      let completedBefore = max(0, current - 1)
      let currentContribution: Double
      if normalizedStatus == "complete" {
        currentContribution = 1
      } else if let elapsed, elapsed > 0 {
        currentContribution = min(0.88, Double(elapsed) / (Double(elapsed) + 20))
      } else {
        currentContribution = 0.04
      }
      return min(
        0.65, 0.05 + 0.60 * (Double(completedBefore) + currentContribution) / Double(total))
    case "largefiles":
      return 0.66
    case "metadata":
      return stagedFraction(
        base: 0.67, span: 0.08, current: current, total: total, status: normalizedStatus)
    case "report":
      return stagedFraction(
        base: 0.76, span: 0.23, current: current, total: total, status: normalizedStatus)
    case "finalize":
      return 0.995
    default:
      return nil
    }
  }

  private static func stagedFraction(
    base: Double,
    span: Double,
    current: Int?,
    total: Int?,
    status: String
  ) -> Double {
    guard let current, let total, total > 0 else { return base }
    let clampedCurrent = min(total, max(0, current))
    let completed: Double
    if status == "complete" || status == "skipped" {
      completed = Double(clampedCurrent)
    } else if clampedCurrent > 0 {
      completed = Double(clampedCurrent - 1) + 0.12
    } else {
      completed = 0
    }
    return min(base + span, base + span * completed / Double(total))
  }

  private static func localizedStage(for phase: String) -> String {
    switch phase.lowercased() {
    case "authorization": return "等待管理員授權"
    case "prepare": return "準備與容量核對"
    case "scan": return "資料夾掃描"
    case "largefiles": return "大檔案附加掃描"
    case "metadata": return "APFS 與系統狀態"
    case "report": return "建立報告"
    case "finalize": return "自我檢查"
    case "complete": return "完成"
    case "cancelled": return "已取消"
    default: return phase
    }
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
