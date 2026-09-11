import Foundation

private struct AuditCheck: Codable {
  let name: String
  let passed: Bool
  let detail: String
}

@main
struct ScanActivityTimeoutAudit {
  static func event(
    epoch: TimeInterval = 1_700_000_000,
    status: String = "heartbeat",
    current: Int? = 1,
    total: Int? = 4,
    path: String? = "/Volumes/NAS",
    elapsed: Int? = 60,
    nodes: Int? = 100,
    errors: Int? = 0,
    message: String = "正在掃描 /Volumes/NAS"
  ) -> ScanProgressEvent {
    ScanProgressEvent(
      epochSeconds: epoch,
      phase: "scan",
      status: status,
      stage: "資料夾掃描",
      message: message,
      detail: nil,
      currentStep: current,
      totalSteps: total,
      path: path,
      elapsedSeconds: elapsed,
      nodeCount: nodes,
      errorCount: errors,
      fraction: 0.25
    )
  }

  static func main() throws {
    let baseline = event()
    var checks: [AuditCheck] = []

    func check(_ name: String, _ condition: Bool, _ detail: String) {
      checks.append(AuditCheck(name: name, passed: condition, detail: detail))
    }

    let laterHeartbeat = event(
      epoch: baseline.epochSeconds + 300,
      status: "heartbeat",
      elapsed: 360,
      message: "正在掃描 /Volumes/NAS"
    )
    check(
      "heartbeat_elapsed_not_activity",
      baseline.meaningfulActivityToken == laterHeartbeat.meaningfulActivityToken,
      "epoch/elapsed-only heartbeat changes must not reset the inactivity timer"
    )

    let delayedHeartbeat = event(
      epoch: baseline.epochSeconds + 420,
      status: "delayed",
      elapsed: 480
    )
    check(
      "delayed_status_not_activity",
      baseline.meaningfulActivityToken == delayedHeartbeat.meaningfulActivityToken,
      "heartbeat/delayed health state changes are liveness, not scan advancement"
    )

    check(
      "node_growth_is_activity",
      baseline.meaningfulActivityToken != event(nodes: 101).meaningfulActivityToken,
      "new directory nodes must reset the 10-minute inactivity window"
    )
    check(
      "path_change_is_activity",
      baseline.meaningfulActivityToken
        != event(path: "/Volumes/NAS/Archive").meaningfulActivityToken,
      "advancing to another path must reset the inactivity window"
    )
    check(
      "step_change_is_activity",
      baseline.meaningfulActivityToken != event(current: 2).meaningfulActivityToken,
      "advancing to another scanner step must reset the inactivity window"
    )
    check(
      "diagnostic_growth_is_activity",
      baseline.meaningfulActivityToken != event(errors: 1).meaningfulActivityToken,
      "new diagnostic/error rows still prove that traversal is advancing"
    )
    check(
      "completion_is_activity",
      baseline.meaningfulActivityToken
        != event(status: "complete").meaningfulActivityToken,
      "phase completion must be recognized as meaningful progress"
    )

    let parsedLinePrefix =
      "MLS_PROGRESS\tversion=1\tphase=scan\tstatus=heartbeat\tstage=資料夾掃描"
      + "\tmessage=scan\tdetail=\tcurrent=1\ttotal=4\tpath=/Volumes/NAS"
    let parsedA = ScanProgressParser.parse(
      line: parsedLinePrefix + "\tepoch=1700000000\telapsed=60\tnodes=100\terrors=0"
    )
    let parsedB = ScanProgressParser.parse(
      line: parsedLinePrefix + "\tepoch=1700000300\telapsed=360\tnodes=100\terrors=0"
    )
    check(
      "parsed_heartbeat_stability",
      parsedA?.meaningfulActivityToken == parsedB?.meaningfulActivityToken,
      "real structured progress lines keep the same activity token when only time advances"
    )

    let passed = checks.filter(\.passed).count
    let payload: [String: Any] = [
      "version": "1.6.8",
      "passed": passed,
      "total": checks.count,
      "checks": checks.map { ["name": $0.name, "passed": $0.passed, "detail": $0.detail] },
    ]
    let data = try JSONSerialization.data(
      withJSONObject: payload,
      options: [.prettyPrinted, .sortedKeys]
    )

    if CommandLine.arguments.count > 1 {
      try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    } else {
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
    }

    if passed != checks.count {
      exit(1)
    }
  }
}
