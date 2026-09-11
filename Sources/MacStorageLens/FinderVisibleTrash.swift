import Foundation

#if canImport(AppKit)
  import AppKit
#endif

#if canImport(Darwin)
  import Darwin
#endif

enum FinderVisibleTrashError: LocalizedError {
  case unsupportedPlatform
  case invalidSource(String)
  case recycleTimedOut(String)
  case recycleFailed(String)
  case missingDestination(String)
  case invalidFinderTrashDestination(String)
  case visibilityVerificationFailed(String)
  case rollbackFailed(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedPlatform:
      return "Finder 可見垃圾桶只支援 macOS。"
    case .invalidSource(let message), .recycleFailed(let message),
      .missingDestination(let message), .invalidFinderTrashDestination(let message),
      .visibilityVerificationFailed(let message), .rollbackFailed(let message):
      return message
    case .recycleTimedOut(let path):
      return "Finder 垃圾桶操作逾時，未把它記錄成成功：\(path)"
    }
  }
}

/// The only reversible cleanup path in MacStorageLens.
///
/// The coordinator delegates the operation to `NSWorkspace.recycle`, never
/// creates a private Trash directory, and refuses to report success unless the
/// returned item is:
///
/// 1. in a system/Finder-managed Trash location;
/// 2. a direct child of that Trash location;
/// 3. named without a leading dot; and
/// 4. not marked hidden.
///
/// Dot-named sources such as `.Spotlight-V100`, `.fseventsd`, `.DS_Store`, and
/// `._*` are renamed in place to a visible, unique staging name before Finder
/// recycles them. This is intentionally different from older releases, which
/// allowed the original dot name to disappear into a volume's hidden `.Trashes`
/// directory while remaining absent from Finder's Trash view.
enum FinderVisibleTrash {
  static func recycle(
    _ sourceURL: URL,
    displayLabel: String? = nil,
    fileManager: FileManager = .default,
    timeout: TimeInterval = 300
  ) throws -> FinderVisibleTrashReceipt {
    #if os(macOS)
      let source = sourceURL.standardizedFileURL
      guard fileManager.fileExists(atPath: source.path) else {
        throw FinderVisibleTrashError.invalidSource(
          "找不到要移到 Finder 可見垃圾桶的項目：\(source.path)"
        )
      }
      guard !containsControlCharacters(source.path) else {
        throw FinderVisibleTrashError.invalidSource("來源路徑含不支援的控制字元。")
      }

      let originalPath = source.path
      let originalIdentity = itemIdentity(at: source, fileManager: fileManager)
      let allowedTrashParents = finderManagedTrashParents(
        for: source,
        fileManager: fileManager
      )
      let staged = try prepareVisibleSource(
        source,
        displayLabel: displayLabel,
        fileManager: fileManager
      )
      var recycledDestination: URL?

      do {
        let recycled = try recycleWithFinderSemantics(staged, timeout: timeout)
        recycledDestination = recycled
        guard fileManager.fileExists(atPath: recycled.path) else {
          throw FinderVisibleTrashError.missingDestination(
            "Finder 回報垃圾桶操作完成，但找不到目的地：\(recycled.path)"
          )
        }
        // Verify the system-returned parent before renaming anything inside it.
        // A malformed or unexpected mapping must never make the App modify an
        // arbitrary directory merely because it came back from the callback.
        guard
          isFinderManagedTrashDestination(
            recycled,
            allowedTrashParents: allowedTrashParents,
            fileManager: fileManager
          )
        else {
          throw FinderVisibleTrashError.invalidFinderTrashDestination(
            "Finder 回傳的位置不是可驗證的系統垃圾桶直接子項，未修改該目的地，也未把操作記錄成成功：\(recycled.path)"
          )
        }

        let destination = try ensureVisibleTrashDestination(
          recycled,
          preferredName: staged.lastPathComponent,
          fileManager: fileManager
        )
        recycledDestination = destination

        guard fileManager.fileExists(atPath: destination.path) else {
          throw FinderVisibleTrashError.missingDestination(
            "Finder 回報垃圾桶操作完成，但找不到目的地：\(destination.path)"
          )
        }
        guard
          isFinderManagedTrashDestination(
            destination,
            allowedTrashParents: allowedTrashParents,
            fileManager: fileManager
          )
        else {
          throw FinderVisibleTrashError.invalidFinderTrashDestination(
            "垃圾桶可見化後的位置不再是可驗證的系統垃圾桶直接子項，未把操作記錄成成功：\(destination.path)"
          )
        }
        guard isFinderVisible(destination, fileManager: fileManager) else {
          throw FinderVisibleTrashError.visibilityVerificationFailed(
            "垃圾桶項目仍是點號名稱或被標記為隱藏，未把操作記錄成成功：\(destination.path)"
          )
        }
        guard !fileManager.fileExists(atPath: staged.path) else {
          throw FinderVisibleTrashError.visibilityVerificationFailed(
            "Finder 回收後來源暫存路徑仍存在，未把複製或未完成的操作記錄成成功：\(staged.path)"
          )
        }

        var sourcePathRecreated = false
        if fileManager.fileExists(atPath: source.path) {
          let currentIdentity = itemIdentity(at: source, fileManager: fileManager)
          if originalIdentity != nil, currentIdentity == originalIdentity {
            throw FinderVisibleTrashError.visibilityVerificationFailed(
              "Finder 回收後原路徑仍是相同 device／inode，未把操作記錄成成功：\(source.path)"
            )
          }
          sourcePathRecreated = true
        }

        return FinderVisibleTrashReceipt(
          originalPath: originalPath,
          destinationPath: destination.path,
          visibleName: destination.lastPathComponent,
          finderVisibilityVerified: true,
          sourcePathRecreated: sourcePathRecreated,
          removalMethod: "nsworkspace_recycle_finder_visible_verified"
        )
      } catch let error as FinderVisibleTrashError {
        if case .recycleTimedOut = error {
          // NSWorkspace may still be completing the Finder operation. Hidden
          // sources have already been converted to a visible staging name, so
          // do not race the in-flight operation by renaming the item again.
          throw error
        }
        let recovery = recoverAfterFailure(
          originalURL: source,
          stagedURL: staged,
          recycledDestination: recycledDestination,
          fileManager: fileManager
        )
        if let recovery {
          throw FinderVisibleTrashError.rollbackFailed(
            "Finder 可見垃圾桶操作未通過驗證：\(error.localizedDescription)。項目已保留在：\(recovery.path)"
          )
        }
        throw error
      } catch {
        let recovery = recoverAfterFailure(
          originalURL: source,
          stagedURL: staged,
          recycledDestination: recycledDestination,
          fileManager: fileManager
        )
        if let recovery {
          throw FinderVisibleTrashError.rollbackFailed(
            "Finder 可見垃圾桶操作未通過驗證：\(error.localizedDescription)。項目已保留在：\(recovery.path)"
          )
        }
        throw error
      }
    #else
      throw FinderVisibleTrashError.unsupportedPlatform
    #endif
  }

  /// Brings Finder to the foreground and selects the exact verified Trash items.
  /// The operation is a visibility aid only; it never changes or deletes data.
  @discardableResult
  static func reveal(_ receipts: [FinderVisibleTrashReceipt]) -> Bool {
    #if os(macOS)
      let urls =
        receipts
        .filter(\.finderVisibilityVerified)
        .map { URL(fileURLWithPath: $0.destinationPath).standardizedFileURL }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
      guard !urls.isEmpty else { return false }
      DispatchQueue.main.async {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
      }
      return true
    #else
      return false
    #endif
  }

  static func isStructurallyVisibleName(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && !trimmed.hasPrefix(".") && !containsControlCharacters(trimmed)
  }

  static func containsControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }

  #if os(macOS)
    private static func prepareVisibleSource(
      _ source: URL,
      displayLabel: String?,
      fileManager: FileManager
    ) throws -> URL {
      let values = try? source.resourceValues(forKeys: [.isHiddenKey, .isDirectoryKey])
      let needsVisibleName = source.lastPathComponent.hasPrefix(".") || values?.isHidden == true
      guard needsVisibleName else { return source }

      let label = sanitizedLabel(displayLabel ?? source.lastPathComponent)
      let visibleName = uniqueVisibleName(
        parent: source.deletingLastPathComponent(),
        label: label,
        fileManager: fileManager
      )
      let staged = source.deletingLastPathComponent().appendingPathComponent(
        visibleName,
        isDirectory: values?.isDirectory == true
      )
      try fileManager.moveItem(at: source, to: staged)
      do {
        try? makeVisible(staged)
        guard isFinderVisible(staged, fileManager: fileManager) else {
          throw FinderVisibleTrashError.visibilityVerificationFailed(
            "無法把隱藏項目轉成 Finder 可見名稱：\(source.path)"
          )
        }
        return staged
      } catch {
        if !fileManager.fileExists(atPath: source.path), fileManager.fileExists(atPath: staged.path)
        {
          try? fileManager.moveItem(at: staged, to: source)
        }
        throw error
      }
    }

    private static func recycleWithFinderSemantics(
      _ source: URL,
      timeout: TimeInterval
    ) throws -> URL {
      let semaphore = DispatchSemaphore(value: 0)
      let lock = NSLock()
      var destination: URL?
      var operationError: Error?

      // Apple executes the completion handler on the same active dispatch
      // queue from which `recycle` was invoked. Always start it from a global
      // concurrent queue so a synchronous caller (including the main thread or
      // a serial worker) cannot deadlock while waiting for the result.
      DispatchQueue.global(qos: .userInitiated).async {
        NSWorkspace.shared.recycle([source]) { mapping, error in
          lock.lock()
          destination =
            mapping[source]
            ?? mapping.first(where: {
              $0.key.standardizedFileURL.path == source.standardizedFileURL.path
            })?.value
          operationError = error
          lock.unlock()
          semaphore.signal()
        }
      }

      guard semaphore.wait(timeout: .now() + timeout) == .success else {
        throw FinderVisibleTrashError.recycleTimedOut(source.path)
      }

      lock.lock()
      let capturedDestination = destination
      let capturedError = operationError
      lock.unlock()

      if let capturedError {
        throw FinderVisibleTrashError.recycleFailed(capturedError.localizedDescription)
      }
      guard let capturedDestination else {
        throw FinderVisibleTrashError.missingDestination(
          "Finder 沒有回傳垃圾桶目的地：\(source.path)"
        )
      }
      return capturedDestination.standardizedFileURL
    }

    private static func ensureVisibleTrashDestination(
      _ destination: URL,
      preferredName: String,
      fileManager: FileManager
    ) throws -> URL {
      if isFinderVisible(destination, fileManager: fileManager) {
        return destination
      }

      let parent = destination.deletingLastPathComponent()
      let preferred =
        isStructurallyVisibleName(preferredName)
        ? preferredName
        : uniqueVisibleName(
          parent: parent,
          label: "MacStorageLens 回收項目",
          fileManager: fileManager
        )
      let target = uniqueURL(parent: parent, preferredName: preferred, fileManager: fileManager)
      let finalURL: URL
      if destination.path == target.path {
        finalURL = destination
      } else {
        try fileManager.moveItem(at: destination, to: target)
        finalURL = target
      }
      try? makeVisible(finalURL)
      return finalURL
    }

    private static func finderManagedTrashParents(
      for sourceURL: URL,
      fileManager: FileManager
    ) -> [URL] {
      var parents: [URL] = []
      if let userTrash = fileManager.urls(for: .trashDirectory, in: .userDomainMask).first {
        parents.append(userTrash.standardizedFileURL)
      }
      if let volume = try? sourceURL.resourceValues(forKeys: [.volumeURLKey]).volume?
        .resolvingSymlinksInPath().standardizedFileURL
      {
        let uid = String(getuid())
        parents.append(
          volume
            .appendingPathComponent(".Trashes", isDirectory: true)
            .appendingPathComponent(uid, isDirectory: true)
            .standardizedFileURL
        )
        parents.append(
          volume.appendingPathComponent(".Trash", isDirectory: true).standardizedFileURL
        )
      }
      return Array(Dictionary(grouping: parents, by: \.path).values.compactMap(\.first))
    }

    static func isFinderManagedTrashDestination(
      _ destination: URL,
      allowedTrashParents: [URL],
      fileManager: FileManager = .default
    ) -> Bool {
      let destination = destination.standardizedFileURL
      let parent = destination.deletingLastPathComponent().standardizedFileURL
      guard destination.path != parent.path,
        fileManager.fileExists(atPath: destination.path),
        fileManager.fileExists(atPath: parent.path),
        let parentValues = try? parent.resourceValues(forKeys: [
          .isDirectoryKey, .isSymbolicLinkKey,
        ]),
        parentValues.isDirectory == true,
        parentValues.isSymbolicLink != true,
        let destinationValues = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]),
        destinationValues.isSymbolicLink != true
      else { return false }

      let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
      guard resolvedParent.path == parent.path else { return false }
      return allowedTrashParents.contains { candidate in
        let allowed = candidate.standardizedFileURL
        guard allowed.path == parent.path else { return false }
        return allowed.resolvingSymlinksInPath().standardizedFileURL.path == resolvedParent.path
      }
    }

    private static func recoverAfterFailure(
      originalURL: URL,
      stagedURL: URL,
      recycledDestination: URL?,
      fileManager: FileManager
    ) -> URL? {
      let candidates = [recycledDestination, stagedURL].compactMap { $0 }
      guard let existing = candidates.first(where: { fileManager.fileExists(atPath: $0.path) })
      else {
        return nil
      }

      if !fileManager.fileExists(atPath: originalURL.path) {
        do {
          try fileManager.moveItem(at: existing, to: originalURL)
          return originalURL
        } catch {
          // Fall through to a visible sibling instead of leaving an unreported
          // dot-named item inside Trash.
        }
      }

      let parent = originalURL.deletingLastPathComponent()
      let fallback = uniqueURL(
        parent: parent,
        preferredName: "MacStorageLens 未完成回收－\(sanitizedLabel(originalURL.lastPathComponent))",
        fileManager: fileManager
      )
      do {
        if existing.path != fallback.path {
          try fileManager.moveItem(at: existing, to: fallback)
        }
        try makeVisible(fallback)
        return fallback
      } catch {
        return existing
      }
    }

    private static func makeVisible(_ url: URL) throws {
      var mutableURL = url
      var values = URLResourceValues()
      values.isHidden = false
      try mutableURL.setResourceValues(values)
    }

    private static func isFinderVisible(
      _ url: URL,
      fileManager: FileManager
    ) -> Bool {
      guard fileManager.fileExists(atPath: url.path),
        isStructurallyVisibleName(url.lastPathComponent)
      else { return false }
      let values = try? url.resourceValues(forKeys: [.isHiddenKey])
      return values?.isHidden != true
    }

    private struct ItemIdentity: Equatable {
      let device: UInt64
      let inode: UInt64
    }

    private static func itemIdentity(
      at url: URL,
      fileManager: FileManager
    ) -> ItemIdentity? {
      guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
        let device = uint64Attribute(attributes[.systemNumber]),
        let inode = uint64Attribute(attributes[.systemFileNumber])
      else { return nil }
      return ItemIdentity(device: device, inode: inode)
    }

    private static func uint64Attribute(_ value: Any?) -> UInt64? {
      if let number = value as? NSNumber { return number.uint64Value }
      if let value = value as? UInt64 { return value }
      if let value = value as? UInt { return UInt64(value) }
      if let value = value as? Int, value >= 0 { return UInt64(value) }
      return nil
    }

    private static func sanitizedLabel(_ raw: String) -> String {
      let stripped = raw.trimmingCharacters(in: CharacterSet(charactersIn: "."))
      let replaced = stripped.unicodeScalars.map { scalar -> Character in
        if CharacterSet.controlCharacters.contains(scalar) || scalar.value == 47 {
          return "-"
        }
        return Character(String(scalar))
      }
      let compact = String(replaced)
        .replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return compact.isEmpty ? "隱藏項目" : String(compact.prefix(80))
    }

    private static func uniqueVisibleName(
      parent: URL,
      label: String,
      fileManager: FileManager
    ) -> String {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyyMMdd-HHmmss"
      let base = "MacStorageLens 回收－\(label)－\(formatter.string(from: Date()))"
      return uniqueURL(parent: parent, preferredName: base, fileManager: fileManager)
        .lastPathComponent
    }

    private static func uniqueURL(
      parent: URL,
      preferredName: String,
      fileManager: FileManager
    ) -> URL {
      var candidate = parent.appendingPathComponent(preferredName)
      var index = 2
      while fileManager.fileExists(atPath: candidate.path) {
        candidate = parent.appendingPathComponent("\(preferredName) \(index)")
        index += 1
      }
      return candidate
    }
  #endif
}
