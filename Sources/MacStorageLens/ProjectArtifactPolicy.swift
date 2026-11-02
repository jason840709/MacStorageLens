import Foundation

enum ProjectArtifactPolicy {
  static let names: Set<String> = [
    "node_modules", ".next", "dist", "build", "target", ".build", "__pycache__", "Pods",
  ]
  static let neverRemove: Set<String> = [
    ".venv", "venv", ".git", ".svn", ".hg", "env", "__pypackages__",
  ]

  static func kind(at artifact: URL) -> String? {
    let parent = artifact.deletingLastPathComponent()
    let fm = FileManager.default
    func exists(_ name: String) -> Bool {
      fm.fileExists(atPath: parent.appendingPathComponent(name).path)
    }
    func text(_ name: String) -> String {
      let url = parent.appendingPathComponent(name)
      guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 256 * 1024
      else { return "" }
      return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
    switch artifact.lastPathComponent {
    case "node_modules":
      guard exists("package.json"),
        ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "npm-shrinkwrap.json"].contains(
          where: exists)
      else { return nil }
      return "Node 專案的下載套件目錄；有套件清單與版本鎖定檔"
    case ".next":
      guard text("package.json").contains("\"next\"") else { return nil }
      return "Next 專案產生的網站建置暫存"
    case "dist":
      guard let data = text("package.json").data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let scripts = object["scripts"] as? [String: String], let build = scripts["build"],
        !build.contains("--noEmit"), !build.contains("--outDir"),
        let configData = text("tsconfig.json").data(using: .utf8),
        let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
        let options = config["compilerOptions"] as? [String: Any],
        options["noEmit"] as? Bool != true,
        let output = options["outDir"] as? String,
        ["dist", "./dist"].contains(output),
        build == "tsc" || build == "tsc -p tsconfig.json"
      else { return nil }
      return "TypeScript 設定明確指定的輸出目錄；移除後需重新建置"
    case "target":
      if text("Cargo.toml").contains("[package]") || text("Cargo.toml").contains("[workspace]") {
        return "Rust 專案的編譯輸出"
      }
      if text("pom.xml").contains("<project") { return "Maven 專案的編譯輸出" }
      return nil
    case "build":
      if exists("build.gradle") || exists("build.gradle.kts") { return "Gradle 專案的建置輸出" }
      if exists("CMakeLists.txt")
        && fm.fileExists(atPath: artifact.appendingPathComponent("CMakeCache.txt").path)
      {
        return "有建置紀錄的 CMake 輸出目錄"
      }
      return nil
    case ".build":
      guard text("Package.swift").contains("PackageDescription") else { return nil }
      return "Swift 專案的編譯與套件下載資料"
    case "__pycache__":
      let siblings = (try? NativeFileSystem.contentsOfDirectory(at: parent)) ?? []
      guard siblings.contains(where: { $0.pathExtension == "py" }) || exists("pyproject.toml")
      else { return nil }
      return "Python 原始檔產生的編譯暫存"
    case "Pods":
      guard exists("Podfile"), exists("Podfile.lock") else { return nil }
      return "依版本鎖定檔下載的 CocoaPods 套件"
    default: return nil
    }
  }

  static func concern(at artifact: URL, cancellation: CleanupWorkCancellation) throws -> String? {
    let handwritten: Set<String> = ["swift", "py", "rs", "c", "cpp", "h", "ipynb", "tex"]
    let entries = try NativeFileSystem.contentsOfDirectory(at: artifact)
    if entries.contains(where: { handwritten.contains($0.pathExtension.lowercased()) }) {
      return "目錄最外層含有原始碼或研究文件，先保留，避免把手寫資料當成建置產物。"
    }
    var failed = false
    guard
      let walker = NativeFileSystem.enumerator(
        at: artifact,
        errorHandler: { _, _ in
          failed = true
          return true
        })
    else { return "無法完整檢查此目錄，先保留。" }
    var visited = 0
    let downloadedSources = ["node_modules", "Pods", ".build"].contains(artifact.lastPathComponent)
    while let url = walker.nextObject() as? URL {
      try cancellation.check()
      visited += 1
      if !downloadedSources && handwritten.contains(url.pathExtension.lowercased()) {
        return "內含原始碼或研究文件，可能有手寫內容，先保留。"
      }
      if url.lastPathComponent == ".git" || url.lastPathComponent == ".hg"
        || url.lastPathComponent == ".svn"
      {
        return "內含另一份版本管理資料，可能有尚未保存的修改，先保留。"
      }
      if visited > 20_000 { return "內容超過本次檢查上限，先保留。" }
    }
    return failed ? "部分內容無法讀取，先保留。" : nil
  }
}
