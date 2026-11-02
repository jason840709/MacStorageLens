import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

enum CleanupWorkbenchTool: String, CaseIterable, Identifiable, Codable {
  case smart, projects, installers, largeFiles, duplicates, applications
  var id: String { rawValue }
  var title: String {
    switch self {
    case .smart: return "智慧清理"
    case .projects: return "專案建置資料"
    case .installers: return "安裝檔整理"
    case .largeFiles: return "大型與舊檔案"
    case .duplicates: return "重複檔案"
    case .applications: return "程式與關聯資料"
    }
  }
  var symbol: String {
    switch self {
    case .smart: return "sparkles"
    case .projects: return "hammer"
    case .installers: return "shippingbox"
    case .largeFiles: return "doc.text.magnifyingglass"
    case .duplicates: return "doc.on.doc"
    case .applications: return "app.badge"
    }
  }
}

enum CleanupWorkbenchDecision: String, Codable {
  case automatic, review, protected, unavailable
  var title: String {
    switch self {
    case .automatic: return "可一鍵清理"
    case .review: return "請你確認"
    case .protected: return "已保留"
    case .unavailable: return "讀取受限"
    }
  }
}

struct CleanupFileSnapshot: Codable, Hashable {
  let path: String
  let device: UInt64
  let inode: UInt64
  let owner: UInt32
  let mode: UInt32
  let logicalBytes: Int64
  let allocatedBytes: Int64
  let linkCount: UInt64
  let flags: UInt32
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64
  var modifiedAt: Date {
    Date(
      timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000)
  }
  var isDirectory: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }
  var isRegularFile: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) }
  var fileIdentity: String { "\(device):\(inode)" }
}

struct CleanupWorkbenchItem: Identifiable, Codable, Hashable {
  let id: String
  let tool: CleanupWorkbenchTool
  let rule: String
  let path: String
  let rootPath: String
  let name: String
  let ownerName: String?
  let decision: CleanupWorkbenchDecision
  let reason: String
  let impact: String
  let bytes: Int64?
  let snapshot: CleanupFileSnapshot?
  let files: [CleanupFileSnapshot]
  let referencePath: String?
  let contentHash: String?
  let applicationID: String?
  let revision: UInt64

  init(
    tool: CleanupWorkbenchTool, rule: String, path: String, rootPath: String,
    name: String, ownerName: String? = nil, decision: CleanupWorkbenchDecision,
    reason: String, impact: String, bytes: Int64? = nil,
    snapshot: CleanupFileSnapshot? = nil, files: [CleanupFileSnapshot] = [],
    referencePath: String? = nil, contentHash: String? = nil, applicationID: String? = nil,
    revision: UInt64 = CleanupWorkbenchCoordinator.shared.revision
  ) {
    id = tool.rawValue + "|" + rule + "|" + path
    self.tool = tool
    self.rule = rule
    self.path = path
    self.rootPath = rootPath
    self.name = name
    self.ownerName = ownerName
    self.decision = decision
    self.reason = reason
    self.impact = impact
    self.bytes = bytes
    self.snapshot = snapshot
    self.files = files
    self.referencePath = referencePath
    self.contentHash = contentHash
    self.applicationID = applicationID
    self.revision = revision
  }
  var canSelect: Bool { decision == .automatic || decision == .review }
}

struct CleanupWorkbenchScan: Codable {
  let tool: CleanupWorkbenchTool
  let rootPath: String
  let items: [CleanupWorkbenchItem]
  let notices: [String]
  let visitedCount: Int
  let complete: Bool
  let createdAt: Date
  var automaticBytes: Int64 {
    items.filter { $0.decision == .automatic }.reduce(0) { $0 + ($1.bytes ?? 0) }
  }
}

struct CleanupWorkbenchExecution: Codable, Identifiable {
  struct Entry: Codable {
    let itemID: String
    let name: String
    let path: String
    let removedFiles: Int
    let processedBytes: Int64
    let failures: [String]
    let receipts: [FinderVisibleTrashReceipt]
    var sizeKnown: Bool? = nil
  }
  let id: UUID
  let createdAt: Date
  let tool: CleanupWorkbenchTool
  let automatic: Bool
  let entries: [Entry]
  let cancelled: Bool
  let availableBytesBefore: Int64?
  let availableBytesAfter: Int64?
  var persistenceWarning: String? = nil
  var processedBytes: Int64 { entries.reduce(0) { $0 + $1.processedBytes } }
  var removedFiles: Int { entries.reduce(0) { $0 + $1.removedFiles } }
}

struct CleanupWorkbenchProgress {
  let message: String
  let path: String?
  let completed: Int
  let total: Int?
}

final class CleanupWorkCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false
  func cancel() {
    lock.lock()
    stopped = true
    lock.unlock()
  }
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
  func check() throws { if isCancelled { throw CleanupWorkbenchError.cancelled } }
}

enum CleanupWorkbenchError: LocalizedError {
  case cancelled
  case rejected(String)
  var errorDescription: String? {
    switch self {
    case .cancelled: return "已停止；未開始的清理不會繼續執行。"
    case .rejected(let reason): return reason
    }
  }
}
