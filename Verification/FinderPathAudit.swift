import Foundation

private enum AuditFailure: Error, CustomStringConvertible {
  case failed(String)
  var description: String {
    switch self {
    case .failed(let message): return message
    }
  }
}

@main
struct FinderPathAudit {
  static func main() throws {
    var assertions: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
      guard condition() else { throw AuditFailure.failed("Assertion failed: \(name)") }
      assertions.append(name)
    }

    func item(path: String?, kind: VirtualNodeKind?) -> SunburstItem {
      SunburstItem(
        id: UUID().uuidString,
        label: "測試",
        path: path,
        bytes: 1,
        kind: kind,
        children: []
      )
    }

    let folder = item(path: "/System/Volumes/Data/Users", kind: nil)
    try check(folder.finderPath == "/System/Volumes/Data/Users", "folder_path_available")
    try check(folder.finderActionTitle == "在 Finder 中顯示", "folder_reveal_title")
    try check(folder.finderOpenActionTitle == "在 Finder 中打開", "folder_open_title")
    try check(folder.finderCopyActionTitle == "複製完整路徑", "folder_copy_title")

    let direct = item(path: "/System/Volumes/Data/Users", kind: .directFiles)
    try check(direct.finderPath == "/System/Volumes/Data/Users", "direct_files_use_parent_path")
    try check(direct.finderActionTitle.contains("父資料夾"), "direct_files_reveal_parent_title")
    try check(direct.finderOpenActionTitle.contains("父資料夾"), "direct_files_open_parent_title")
    try check(direct.finderCopyActionTitle.contains("父資料夾"), "direct_files_copy_parent_title")

    let collapsed = item(path: "/System/Volumes/Data/Library", kind: .otherChildren)
    try check(
      collapsed.finderPath == "/System/Volumes/Data/Library", "collapsed_children_use_parent_path")
    try check(collapsed.finderActionTitle.contains("父資料夾"), "collapsed_children_parent_title")

    let otherVolume = item(path: "/System/Volumes/Preboot", kind: .otherVolume)
    try check(
      otherVolume.finderPath == "/System/Volumes/Preboot", "other_volume_real_path_available")

    for (kind, name) in [
      (VirtualNodeKind.accountingGap, "accounting_gap"),
      (.containerAccounting, "container_accounting"),
      (.scanDelta, "scan_delta"),
      (.freeSpace, "free_space"),
      (.purgeable, "purgeable"),
    ] {
      try check(
        item(path: "/not/a/real/folder", kind: kind).finderPath == nil,
        "\(name)_has_no_finder_path"
      )
    }

    try check(item(path: nil, kind: nil).finderPath == nil, "nil_path_stays_unavailable")
    try check(item(path: "relative/path", kind: nil).finderPath == nil, "relative_path_rejected")

    let result: [String: Any] = [
      "version": "1.6.8",
      "assertions": assertions,
      "passed": assertions.count,
      "total": assertions.count,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    let encoded = String(decoding: data, as: UTF8.self) + "\n"
    if CommandLine.arguments.count > 1 {
      try encoded.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
    }
    print(encoded, terminator: "")
  }
}
