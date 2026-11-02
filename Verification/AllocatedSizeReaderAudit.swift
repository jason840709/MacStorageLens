import Foundation

@main
struct AllocatedSizeReaderAudit {
  static func main() throws {
    let good = URL(fileURLWithPath: "/fixture/中文快取")
    let denied = URL(fileURLWithPath: "/fixture/denied")
    var calls: [[String]] = []
    func result(_ status: Int32, _ output: String) -> ProcessResult {
      ProcessResult(status: status, stdout: Data(output.utf8), stderr: Data())
    }
    let partial = try AllocatedSizeReader.measure([good, denied]) { args in
      calls.append(args)
      if args.count == 5 { return result(1, "999\t\(good.path)\n999\t\(denied.path)\n") }
      return args.last == good.path
        ? result(0, "4\t\(good.path)\n") : result(1, "12\t\(denied.path)\n")
    }
    func expect(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    expect(partial.bytesByPath == [good.path: 4096], "only fully measured paths count")
    expect(partial.incompletePaths == [denied.path], "incomplete path is explicit")
    expect(calls.count == 3, "retry individually only after batch failure")
    expect(
      calls.allSatisfy { $0.prefix(3) == ["LC_ALL=en_US.UTF-8", "/usr/bin/du", "-sk"] },
      "UTF-8 command contract")
    var successfulCalls = 0
    let complete = try AllocatedSizeReader.measure([good]) { _ in
      successfulCalls += 1
      return result(0, "8\t\(good.path)\n")
    }
    expect(
      complete.bytesByPath[good.path] == 8192 && successfulCalls == 1, "normal case stays batched")
    let missing = try AllocatedSizeReader.measure([good]) { _ in
      result(0, "9223372036854775807\t\(good.path)\n")
    }
    expect(
      missing.bytesByPath.isEmpty && missing.incompletePaths == [good.path],
      "invalid or overflowing size is incomplete")
    print("AllocatedSizeReaderAudit: 6 / 6 passed")
  }
}
