import Foundation

@main
struct DirectoryLookupAudit {
  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let url = root.appendingPathComponent("report.md")
    let base = "/System/Volumes/Data"
    var text = "### DIRECTORY_TREE (\(base))\n```text\n100000 KiB  \(base)\n"
    for index in 0..<3000 {
      let path = "\(base)/資料夾-\(index)"
      text +=
        "├── 20 KiB  \(path)\n│   ├── 10 KiB  \(path)/子目錄\n│   │   ├── 5 KiB  \(path)/子目錄/引號'與$字元\n"
    }
    text += "```\nreport_complete=true\n"
    try Data(text.utf8).write(to: url)
    let parser = ReportParser()
    let doc = try parser.parse(url: url)
    let target = "\(base)/資料夾-2999/子目錄"
    func expect(_ value: Bool, _ message: String) {
      if !value { fatalError(message) }
    }
    expect(doc.directoryLookup?.offsets[target] != nil, "deep Unicode directory indexed")
    var plain = doc
    plain.directoryLookup = nil
    let expected = try parser.loadPresentation(document: plain, parentPath: target)
    let actual = try parser.loadPresentation(document: doc, parentPath: target)
    expect(
      actual.0 == expected.0 && actual.1 == expected.1,
      "seek preserves children and byte accounting")
    let children = try parser.loadChildren(document: doc, parentPath: target)
    expect(children == expected.0, "children reader uses same subtree")
    var forged = doc
    forged.directoryLookup = ReportDirectoryLookup(offsets: [
      target: doc.sections[base]!.startOffset + 3
    ])
    let fallback = try parser.loadPresentation(document: forged, parentPath: target)
    expect(fallback.0 == expected.0 && fallback.1 == expected.1, "mid-line hint falls back safely")
    let wrongRow = doc.directoryLookup!.offsets["\(base)/資料夾-0"]!
    forged.directoryLookup = ReportDirectoryLookup(offsets: [target: wrongRow])
    expect(
      try parser.loadChildren(document: forged, parentPath: target) == expected.0,
      "wrong directory hint falls back")
    let store = try ReportPresentationIndexStore(
      directoryURL: root.appendingPathComponent("Indexes"))
    _ = try store.save(document: doc, for: url)
    let restored = try store.load(for: url)!.document(for: url)
    expect(
      restored.directoryLookup?.offsets == doc.directoryLookup?.offsets,
      "hints persist with signature")
    var paths: [String] = []
    _ = try parser.forEachDirectoryNode(document: restored, under: target) { paths.append($0.path) }
    expect(paths.count == 2 && paths.first == target, "guided cleanup visits only intended subtree")
    print("DirectoryLookupAudit: 7 / 7 passed")
  }
}
