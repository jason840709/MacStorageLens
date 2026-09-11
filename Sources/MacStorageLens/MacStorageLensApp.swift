import AppKit
import SwiftUI

@main
struct MacStorageLensApp: App {
  @NSApplicationDelegateAdaptor(MacStorageLensAppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup("磁碟透視") {
      ContentView()
        .environmentObject(model)
        .frame(minWidth: 1100, minHeight: 720)
    }
    .defaultSize(width: 1280, height: 840)
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unifiedCompact)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("關於磁碟透視") {
          model.destination = .about
          NSApplication.shared.activate(ignoringOtherApps: true)
        }
      }

      CommandGroup(after: .newItem) {
        Button("重新掃描") { model.runFullScan() }
          .keyboardShortcut("r", modifiers: [.command, .shift])
        Button("重新載入") { model.reloadDisplayedReport() }
          .keyboardShortcut("l", modifiers: [.command, .shift])
      }
    }
  }
}
