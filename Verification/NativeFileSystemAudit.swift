import Foundation

@main
struct NativeFileSystemAudit {
  private static var checks = 0
  private static var failures = 0

  static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() {
      failures += 1
      fputs("FAIL: \(label)\n", stderr)
    }
  }

  static func main() throws {
    let fm = FileManager.default
    let temporary = fm.temporaryDirectory.appendingPathComponent(
      "MacStorageLens-NativeFS-\(UUID().uuidString)", isDirectory: true)
    let root = temporary.appendingPathComponent("root", isDirectory: true)
    let outside = temporary.appendingPathComponent("outside", isDirectory: true)
    defer { try? fm.removeItem(at: temporary) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    for name in ["._sidecar", ".hidden", "中文資料", "quote ' and $", "ordinary"] {
      try Data("fixture".utf8).write(to: root.appendingPathComponent(name))
    }
    try Data("outside".utf8).write(to: outside.appendingPathComponent("outside-marker"))
    try fm.createSymbolicLink(
      at: root.appendingPathComponent("linked"), withDestinationURL: outside)
    let nested = root.appendingPathComponent("nested/child", isDirectory: true)
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("nested".utf8).write(to: nested.appendingPathComponent("._nested"))
    let package = root.appendingPathComponent("Example.app/Contents", isDirectory: true)
    try fm.createDirectory(at: package, withIntermediateDirectories: true)
    try Data("package".utf8).write(to: package.appendingPathComponent("package-marker"))

    let entries = try NativeFileSystem.contentsOfDirectory(at: root)
    let names = Set(entries.map(\.lastPathComponent))
    expect(names.contains("._sidecar"), "raw AppleDouble entries remain discoverable")
    expect(names.contains(".hidden"), "ordinary hidden files remain discoverable")
    expect(names.contains("中文資料"), "Unicode names remain intact")
    expect(names.contains("quote ' and $"), "names are not interpreted by a shell")
    expect(
      entries.allSatisfy { $0.deletingLastPathComponent().path == root.path },
      "child paths stay anchored to the caller's logical root, including /var aliases")
    expect(names.contains("linked"), "listing includes symlinks for the caller to classify")

    guard let enumerator = NativeFileSystem.enumerator(at: root) else {
      throw NSError(domain: "NativeFileSystemAudit", code: 1)
    }
    var found: [URL] = []
    while let url = enumerator.nextObject() as? URL { found.append(url) }
    expect(
      found.contains { $0.lastPathComponent == "._sidecar" }, "walk includes top-level sidecars")
    expect(found.contains { $0.lastPathComponent == "._nested" }, "walk includes nested sidecars")
    expect(
      !found.contains { $0.lastPathComponent == "outside-marker" }, "walk never follows symlinks")
    expect(!found.contains { $0.lastPathComponent == "package-marker" }, "walk prunes App packages")
    expect(
      found.allSatisfy { $0.path.hasPrefix(root.path + "/") },
      "walk retains logical root spelling")

    let pruned = NativeFileSystem.enumerator(at: root)!
    var prunedNames: [String] = []
    while let url = pruned.nextObject() as? URL {
      prunedNames.append(url.lastPathComponent)
      if url.lastPathComponent == "nested" { pruned.skipDescendants() }
    }
    expect(!prunedNames.contains("._nested"), "caller can prune protected subtrees")

    do {
      _ = try NativeFileSystem.contentsOfDirectory(at: temporary.appendingPathComponent("missing"))
      expect(false, "missing directory is reported rather than silently empty")
    } catch {
      expect(true, "missing directory is reported rather than silently empty")
    }
    let swapped = root.appendingPathComponent("swap", isDirectory: true)
    try fm.createDirectory(at: swapped, withIntermediateDirectories: true)
    var traversalErrors = 0
    let race = NativeFileSystem.enumerator(at: root) { _, _ in
      traversalErrors += 1
      return true
    }!
    var racedOutside = false
    while let url = race.nextObject() as? URL {
      if url.lastPathComponent == "swap" {
        try fm.moveItem(at: swapped, to: temporary.appendingPathComponent("displaced"))
        try fm.createSymbolicLink(at: swapped, withDestinationURL: outside)
      }
      if url.lastPathComponent == "outside-marker" { racedOutside = true }
    }
    expect(!racedOutside, "directory-to-symlink replacement never escapes root")
    expect(traversalErrors > 0, "replacement is surfaced as an unreadable subtree")
    expect(
      NativeFileSystem.enumerator(at: root.appendingPathComponent("linked")) == nil,
      "symlink root is rejected")

    print("NativeFileSystemAudit: \(checks - failures) / \(checks) passed")
    if failures > 0 { exit(1) }
  }
}
