import Foundation

/// One owner for all windows. Completion from an older window cannot unlock a
/// newer operation, and a second window cannot start another cleanup.
final class CleanupWorkbenchCoordinator: @unchecked Sendable {
  static let shared = CleanupWorkbenchCoordinator()
  private let lock = NSLock()
  private var owner: UUID?
  private var executionActive = false
  private var changeRevision: UInt64 = 0
  func claim(_ candidate: UUID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard owner == nil else { return false }
    owner = candidate
    return true
  }
  func release(_ candidate: UUID) {
    lock.lock()
    defer { lock.unlock() }
    if owner == candidate { owner = nil }
  }
  func claimExecution(expectedRevision: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !executionActive, expectedRevision == changeRevision else { return false }
    executionActive = true
    return true
  }
  func releaseExecution() {
    lock.lock()
    executionActive = false
    changeRevision &+= 1
    lock.unlock()
  }
  var revision: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return changeRevision
  }
  var isBusy: Bool {
    lock.lock()
    defer { lock.unlock() }
    return owner != nil
  }
}
