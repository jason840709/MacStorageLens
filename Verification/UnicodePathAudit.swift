import Foundation

@main
struct UnicodePathAudit {
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
    let repository = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
    let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
      "MacStorageLens-Unicode-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temporary) }

    // Reintroducing a C-locale du call must fail these real scanner/parser tests.
    // Equal-length Chinese names also catch paths collapsing to the same ??? key.
    let names = ["名稱甲", "名稱乙", "STS研究V10", "日本語📁", "cafe\u{301}", "中文 ' $ 空格"]
    let payload = Data(repeating: 0x41, count: 8192)
    for (index, scanner) in [
      "mac-system-storage-tree-core-v2.5.4.command",
      "mac-system-storage-tree-v2.5.4.command",
    ].enumerated() {
      let target = temporary.appendingPathComponent(
        index == 0 ? "ASCII-root" : "中文根目錄📁", isDirectory: true)
      let output = temporary.appendingPathComponent("報告-\(index)", isDirectory: true)
      try fm.createDirectory(at: output, withIntermediateDirectories: true)
      for name in names {
        let directory = target.appendingPathComponent(name, isDirectory: true)
          .appendingPathComponent("中文子目錄", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.write(to: directory.appendingPathComponent("中文檔案.bin"))
      }

      let result = try ProcessRunner.run(
        "/usr/bin/env",
        [
          "LC_ALL=C", "/bin/zsh", repository.appendingPathComponent("Resources/\(scanner)").path,
          "--no-sudo", "--skip-large-files", "--target-kind", "folder",
          "--target-path", target.path, "--target-name", target.lastPathComponent,
          "--output-dir", output.path,
        ], timeout: 120)
      expect(result.status == 0, "\(scanner): scanner completes: \(result.stderrString)")
      let reports = try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "md" }
      expect(reports.count == 1, "\(scanner): exactly one report")
      guard let report = reports.first else { continue }
      let text = try String(contentsOf: report, encoding: .utf8)
      expect(text.contains("report_complete=true"), "\(scanner): completed report")
      expect(!text.contains("???"), "\(scanner): paths are never replaced with question marks")

      let parser = ReportParser()
      let document = try parser.parse(url: report)
      let children = try parser.loadChildren(document: document, parentPath: target.path)
      expect(
        Set(children.map(\.path)) == Set(names.map { target.appendingPathComponent($0).path }),
        "\(scanner): parser preserves every distinct Unicode directory")
      for name in names {
        let child = target.appendingPathComponent(name)
        expect(
          children.contains { $0.path == child.path && $0.allocatedBytes > 0 },
          "\(scanner): \(name) keeps its allocated size")
        let nested = try parser.loadChildren(document: document, parentPath: child.path)
        expect(
          nested.contains { $0.path == child.appendingPathComponent("中文子目錄").path },
          "\(scanner): drill-down preserves the nested Chinese path")
        let file = child.appendingPathComponent("中文子目錄/中文檔案.bin")
        let unchanged = try Data(contentsOf: file)
        expect(unchanged == payload, "\(scanner): scanned files remain unchanged")
      }
    }

    // Exercise the separate cleanup size reader through its public scan API.
    // A C-locale parent must not turn a Unicode path into an unknown/zero size.
    let home = temporary.appendingPathComponent("使用者", isDirectory: true)
    let cache = home.appendingPathComponent("Library/Caches/中文快取", isDirectory: true)
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    try payload.write(to: cache.appendingPathComponent("payload.bin"))
    let library = try ReportLibrary(rootURL: temporary.appendingPathComponent("Reports"))
    let engine = CleanupEngine(library: library, homeURL: home)
    let configuration = CleanupScanConfiguration(
      profile: .custom, customScopes: [.standardCaches], customMinimumBytes: 0)
    let candidates = try engine.scanCandidates(configuration: configuration).candidates
    // CleanupEngine standardizes its injected home. Native enumeration now
    // preserves that root spelling instead of Foundation rewriting /tmp back
    // to /private/tmp. Compare the same canonical identity, still requiring
    // a real positive allocation under a C-locale parent process.
    let expectedCachePath = cache.standardizedFileURL.path
    expect(
      candidates.contains { $0.path == expectedCachePath && $0.bytes > 0 },
      "cleanup scan preserves allocated size for a Chinese cache path")
    let unchanged = try Data(contentsOf: cache.appendingPathComponent("payload.bin"))
    expect(unchanged == payload, "cleanup scan does not modify fixture files")

    print("UnicodePathAudit: \(checks - failures) / \(checks) passed")
    if failures > 0 { exit(1) }
  }
}
