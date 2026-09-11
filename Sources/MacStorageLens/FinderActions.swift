import AppKit
import Foundation

enum FinderActions {
  static func reveal(path: String) -> Bool {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return false
    }

    if url.path == "/" {
      return NSWorkspace.shared.open(url)
    }

    NSWorkspace.shared.activateFileViewerSelecting([url])
    return true
  }

  static func open(path: String) -> Bool {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return false
    }

    // "Open in Finder" must never launch a scanned file in its default app.
    // Directories open themselves; files open their containing directory.
    let finderURL = isDirectory.boolValue ? url : url.deletingLastPathComponent()
    return NSWorkspace.shared.open(finderURL)
  }

  static func launch(path: String) -> Bool {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    return NSWorkspace.shared.open(url)
  }

  static func copy(path: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(path, forType: .string)
  }
}
