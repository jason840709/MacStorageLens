import Foundation

enum KeyValuePayload {
  static func parse(_ text: String) -> [String: String] {
    var values: [String: String] = [:]

    for line in text.split(whereSeparator: \.isNewline) {
      let fields = line.split(
        separator: "=",
        maxSplits: 1,
        omittingEmptySubsequences: false
      )
      guard fields.count == 2 else { continue }
      values[String(fields[0])] = String(fields[1])
    }

    return values
  }

  static func read(from url: URL) -> [String: String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    return parse(text)
  }
}
