import Foundation

@main
struct KeyValuePayloadAudit {
  static func main() throws {
    let payload = """
      status=READY
      probe=LIKELY_AVAILABLE
      probe_path=/Users/example/Library/Application Support/AddressBook
      root=/System/Volumes/Data
      empty=
      value_with_equals=a=b=c
      malformed
      status=FINAL
      """

    let values = KeyValuePayload.parse(payload)
    var checks: [(String, Bool)] = [
      ("last duplicate wins", values["status"] == "FINAL"),
      ("simple value", values["probe"] == "LIKELY_AVAILABLE"),
      (
        "space in value",
        values["probe_path"] == "/Users/example/Library/Application Support/AddressBook"
      ),
      ("root value", values["root"] == "/System/Volumes/Data"),
      ("empty value retained", values["empty"] == ""),
      ("embedded equals retained", values["value_with_equals"] == "a=b=c"),
      ("malformed line ignored", values["malformed"] == nil),
    ]

    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("MacStorageLens-key-value-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try Data("unicode=繁體中文\r\nnumber=42\r\n".utf8).write(to: temporaryURL)
    let fileValues = KeyValuePayload.read(from: temporaryURL)
    checks.append(("file UTF-8", fileValues["unicode"] == "繁體中文"))
    checks.append(("CRLF", fileValues["number"] == "42"))

    let failures = checks.filter { !$0.1 }.map(\.0)
    if !failures.isEmpty {
      FileHandle.standardError.write(Data((failures.joined(separator: "\n") + "\n").utf8))
      Foundation.exit(1)
    }

    print("KeyValuePayload audit: \(checks.count)/\(checks.count)")
  }
}
