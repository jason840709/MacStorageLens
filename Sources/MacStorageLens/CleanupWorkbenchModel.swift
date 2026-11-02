import AppKit
import Foundation

final class CleanupWorkbenchModel: ObservableObject {
  @Published var tool: CleanupWorkbenchTool = .smart
  @Published var root: URL = FileManager.default.homeDirectoryForCurrentUser
  @Published var result: CleanupWorkbenchScan?
  @Published var execution: CleanupWorkbenchExecution?
  @Published var progress = CleanupWorkbenchProgress(
    message: "準備就緒", path: nil, completed: 0, total: nil)
  @Published var isBusy = false {
    didSet { busyChanged?() }
  }
  var busyChanged: (() -> Void)?
  @Published var isExecuting = false
  @Published var selected: Set<String> = []
  @Published var error: String?
  @Published var inspectedItem: CleanupWorkbenchItem?
  @Published var history: [CleanupWorkbenchExecution] = []
  @Published var protectedPaths: [String] = []
  private var cancellation = CleanupWorkCancellation()
  private var generation = UUID()
  private let operationOwner = UUID()
  let engine: CleanupWorkbenchEngine
  private let historyURL: URL

  init(homeURL: URL? = nil, historyURL: URL? = nil) {
    let home = homeURL ?? FileManager.default.homeDirectoryForCurrentUser
    self.historyURL =
      historyURL
      ?? home.appendingPathComponent(
        "Library/Application Support/MacStorageLens/Cleanup History/Workbench")
    engine = CleanupWorkbenchEngine(homeURL: homeURL, historyURL: self.historyURL)
    root = home
    loadHistory()
    protectedPaths = (try? CleanupUserProtectionStore(home: home).load()) ?? []
  }

  deinit {
    cancellation.cancel()
    CleanupWorkbenchCoordinator.shared.release(operationOwner)
    let notify = busyChanged
    DispatchQueue.main.async { notify?() }
  }

  func changeTool(_ value: CleanupWorkbenchTool) {
    guard !isBusy else { return }
    tool = value
    result = nil
    execution = nil
    selected.removeAll()
    if value == .installers {
      root = engine.home.appendingPathComponent("Downloads")
    } else if value != .smart && value != .applications {
      root = engine.home
    }
  }

  func chooseRoot() {
    guard !isBusy else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "選擇這個資料夾"
    panel.message = "只檢查你選擇的位置；不會在掃描時刪除檔案。"
    panel.directoryURL = root
    if panel.runModal() == .OK, let url = panel.url {
      root = url
      result = nil
      execution = nil
      selected.removeAll()
    }
  }

  func scan(andClean: Bool = false) {
    guard !isBusy else { return }
    guard CleanupWorkbenchCoordinator.shared.claim(operationOwner) else {
      error = "另一個視窗正在檢查或清理磁碟，請等它完成。"
      return
    }
    isBusy = true
    isExecuting = false
    selected.removeAll()
    error = nil
    execution = nil
    cancellation = CleanupWorkCancellation()
    generation = UUID()
    let token = cancellation
    let operation = generation
    let tool = tool
    let root = root
    progress = CleanupWorkbenchProgress(
      message: "正在查看\(tool.title)", path: nil, completed: 0, total: nil)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let update: CleanupWorkbenchEngine.Progress = { [weak self] progress in
        DispatchQueue.main.async { [weak self] in
          guard let self, self.generation == operation else { return }
          self.progress = progress
        }
      }
      let outcome = Result { () -> (CleanupWorkbenchScan?, CleanupWorkbenchExecution?) in
        let scan: CleanupWorkbenchScan
        if tool == .smart {
          scan = try self.engine.scanSmart(cancellation: token, progress: update)
        } else if tool == .applications {
          scan = try self.engine.scanApplications(cancellation: token, progress: update)
        } else {
          scan = try self.engine.scanFiles(
            tool: tool, root: root, cancellation: token, progress: update)
        }
        try token.check()
        if andClean && tool == .smart {
          DispatchQueue.main.async { [weak self] in
            self?.isExecuting = true
            self?.result = scan
          }
          let execution = try self.engine.executeAutomatic(
            scan, cancellation: token, progress: update)
          DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == operation else { return }
            self.execution = execution
            self.loadHistory()
          }
          if token.isCancelled { return (nil, execution) }
          let refreshed = try self.engine.scanSmart(cancellation: token, progress: update)
          return (refreshed, execution)
        }
        return (scan, nil)
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generation == operation else { return }
        CleanupWorkbenchCoordinator.shared.release(self.operationOwner)
        self.isBusy = false
        self.isExecuting = false
        switch outcome {
        case .success(let value):
          self.result = value.0
          self.execution = value.1
          self.loadHistory()
        case .failure(let error):
          self.result = nil
          self.loadHistory()
          if token.isCancelled {
            self.progress = CleanupWorkbenchProgress(
              message: "已停止；沒有繼續執行後續清理。", path: nil, completed: 0, total: nil)
          } else {
            self.error = error.localizedDescription
          }
        }
      }
    }
  }

  func cancel() {
    cancellation.cancel()
    progress = CleanupWorkbenchProgress(
      message: "正在停止，已完成的操作會保留紀錄…", path: nil, completed: 0, total: nil)
  }
  func toggle(_ item: CleanupWorkbenchItem) {
    guard !isBusy, item.canSelect else { return }
    if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
  }
  var selectedItems: [CleanupWorkbenchItem] {
    result?.items.filter { selected.contains($0.id) } ?? []
  }

  func executeManual() {
    guard !isBusy, !selectedItems.isEmpty else { return }
    guard CleanupWorkbenchCoordinator.shared.claim(operationOwner) else {
      error = "另一個視窗正在檢查或清理磁碟，請等它完成。"
      return
    }
    let items = selectedItems
    let selectedTool = tool
    let selectedRoot = root
    isBusy = true
    isExecuting = true
    error = nil
    cancellation = CleanupWorkCancellation()
    generation = UUID()
    let token = cancellation
    let operation = generation
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let outcome = Result {
        let execution = try self.engine.executeManual(
          items, cancellation: token,
          progress: { [weak self] progress in
            DispatchQueue.main.async { [weak self] in self?.progress = progress }
          })
        DispatchQueue.main.async { [weak self] in
          guard let self, self.generation == operation else { return }
          self.execution = execution
          self.loadHistory()
        }
        // Rebuild the remaining candidates from disk after the global revision
        // changes. Reusing or simply restamping old rows would retain stale proofs.
        let refreshed: CleanupWorkbenchScan?
        if token.isCancelled {
          refreshed = nil
        } else if selectedTool == .smart {
          refreshed = try? self.engine.scanSmart(cancellation: token)
        } else if selectedTool == .applications {
          refreshed = try? self.engine.scanApplications(cancellation: token)
        } else {
          refreshed = try? self.engine.scanFiles(
            tool: selectedTool, root: selectedRoot, cancellation: token)
        }
        return (execution, refreshed)
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generation == operation else { return }
        CleanupWorkbenchCoordinator.shared.release(self.operationOwner)
        self.isBusy = false
        self.isExecuting = false
        switch outcome {
        case .success(let value):
          self.execution = value.0
          self.result = value.1
          self.selected.removeAll()
          self.loadHistory()
        case .failure(let error): self.error = error.localizedDescription
        }
      }
    }
  }

  func protect(_ item: CleanupWorkbenchItem) {
    guard !isBusy else { return }
    do {
      try CleanupUserProtectionStore(home: engine.home).add(item.path)
      protectedPaths = try CleanupUserProtectionStore(home: engine.home).load()
      selected.remove(item.id)
      scan()
    } catch { self.error = error.localizedDescription }
  }

  func chooseProtection() {
    guard !isBusy else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.showsHiddenFiles = true
    panel.directoryURL = engine.home
    panel.prompt = "加入保留清單"
    panel.message = "選擇要保留的位置；該位置與裡面的內容都不會被清理。"
    guard panel.runModal() == .OK else { return }
    do {
      let store = CleanupUserProtectionStore(home: engine.home)
      for url in panel.urls { try store.add(url.path) }
      protectedPaths = try store.load()
      result = nil
      selected.removeAll()
    } catch { self.error = error.localizedDescription }
  }

  func removeProtection(_ path: String) {
    guard !isBusy else { return }
    do {
      try CleanupUserProtectionStore(home: engine.home).remove(path)
      protectedPaths = try CleanupUserProtectionStore(home: engine.home).load()
      result = nil
      selected.removeAll()
    } catch { self.error = error.localizedDescription }
  }

  func loadHistory() {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: historyURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]))
      ?? []
    history = files.compactMap { url -> CleanupWorkbenchExecution? in
      guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size < 8 * 1024 * 1024,
        let data = try? Data(contentsOf: url)
      else { return nil }
      return try? decoder.decode(CleanupWorkbenchExecution.self, from: data)
    }.sorted { $0.createdAt > $1.createdAt }
  }
}
