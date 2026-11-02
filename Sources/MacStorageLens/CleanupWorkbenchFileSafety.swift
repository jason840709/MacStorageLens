import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

enum CleanupWorkbenchFileSafety {
  static func physicalPath(_ url: URL) throws -> String {
    guard let pointer = url.path.withCString({ realpath($0, nil) }) else {
      throw CleanupWorkbenchError.rejected("無法確認目前位置：\(url.path)")
    }
    defer { free(pointer) }
    guard let path = String(validatingUTF8: pointer) else {
      throw CleanupWorkbenchError.rejected("路徑含無法辨識的字元。")
    }
    return path
  }

  static func snapshot(_ url: URL) throws -> CleanupFileSnapshot {
    var value = stat()
    guard url.path.withCString({ lstat($0, &value) }) == 0,
      value.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK)
    else { throw CleanupWorkbenchError.rejected("無法讀取此位置，或此位置是符號連結：\(url.path)") }
    return makeSnapshot(value, path: try physicalPath(url))
  }

  private static func makeSnapshot(_ value: stat, path: String) -> CleanupFileSnapshot {
    #if canImport(Darwin)
      let flags = UInt32(value.st_flags)
      let seconds = Int64(value.st_mtimespec.tv_sec)
      let nanoseconds = Int64(value.st_mtimespec.tv_nsec)
    #else
      let flags: UInt32 = 0
      let seconds = Int64(value.st_mtim.tv_sec)
      let nanoseconds = Int64(value.st_mtim.tv_nsec)
    #endif
    return CleanupFileSnapshot(
      path: path, device: UInt64(truncatingIfNeeded: value.st_dev), inode: UInt64(value.st_ino),
      owner: UInt32(value.st_uid), mode: UInt32(value.st_mode), logicalBytes: Int64(value.st_size),
      allocatedBytes: max(0, Int64(value.st_blocks)) * 512, linkCount: UInt64(value.st_nlink),
      flags: flags,
      modifiedSeconds: seconds, modifiedNanoseconds: nanoseconds)
  }

  static func isWithin(_ path: String, root: String) -> Bool {
    path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
  }

  /// Refuse symlinks in every component, while allowing APFS case differences.
  enum HomeDirectoryAccess { case direct, redirected, unavailable }

  static func homeDirectoryAccess(_ url: URL, home: URL) -> HomeDirectoryAccess {
    let base = home.standardizedFileURL.path
    let nominal = url.standardizedFileURL.path
    guard nominal != base, isWithin(nominal, root: base),
      let physicalHome = try? physicalPath(home)
    else { return .unavailable }
    var descriptor = physicalHome.withCString {
      open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { return .unavailable }
    defer { close(descriptor) }
    for component in nominal.dropFirst(base.count).split(separator: "/") {
      var metadata = stat()
      guard
        String(component).withCString({
          fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }) == 0
      else { return .unavailable }
      if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) { return .redirected }
      let next = String(component).withCString {
        openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard next >= 0 else { return .unavailable }
      close(descriptor)
      descriptor = next
    }
    return .direct
  }

  static func isUnredirectedHomeDirectory(_ url: URL, home: URL) -> Bool {
    homeDirectoryAccess(url, home: home) == .direct
  }

  static func safeUserRoot(_ url: URL, home: URL) throws -> String {
    let snapshot = try snapshot(url)
    guard snapshot.isDirectory else { throw CleanupWorkbenchError.rejected("請選擇資料夾。") }
    let path = snapshot.path
    let homePath = try physicalPath(home)
    let forbidden = [
      "/System", "/Library", "/Applications", "/bin", "/sbin", "/usr", "/opt", "/private", "/dev",
      "/proc",
    ]
    // A test home may live in /private/tmp. Its own descendants remain a valid
    // explicitly injected workspace; arbitrary /private roots are not accepted.
    let inHome = isWithin(path, root: homePath)
    guard path != "/", path != "/Volumes",
      inHome || !forbidden.contains(where: { isWithin(path, root: $0) }),
      !(path == homePath + "/Library" || path.hasPrefix(homePath + "/Library/"))
    else { throw CleanupWorkbenchError.rejected("這個位置由系統或程式管理，請選擇個人資料夾或專案。") }
    return path
  }

  static func sameFile(_ old: CleanupFileSnapshot, _ current: CleanupFileSnapshot) -> Bool {
    old.device == current.device && old.inode == current.inode && old.owner == current.owner
      && old.mode == current.mode && old.logicalBytes == current.logicalBytes
      && old.modifiedSeconds == current.modifiedSeconds
      && old.modifiedNanoseconds == current.modifiedNanoseconds
      && old.linkCount == current.linkCount && old.flags == current.flags
  }

  static func isDownloadedRegularFile(_ value: CleanupFileSnapshot) -> Bool {
    // A dataless/cloud placeholder must never be opened merely to find junk or
    // duplicates. Sparse files are conservatively omitted from content scans.
    guard value.isRegularFile, value.logicalBytes == 0 || value.allocatedBytes > 0 else {
      return false
    }
    #if canImport(Darwin)
      guard value.flags & UInt32(SF_DATALESS) == 0 else { return false }
    #endif
    let url = URL(fileURLWithPath: value.path)
    if let flags = try? url.resourceValues(forKeys: [
      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]),
      flags.isUbiquitousItem == true,
      flags.ubiquitousItemDownloadingStatus != .current,
      flags.ubiquitousItemDownloadingStatus != .downloaded
    {
      return false
    }
    return true
  }

  /// Remove only a frozen regular-file entry, through descriptors opened from
  /// the trusted root. Never re-enumerate and recursively delete new contents.
  static func unlinkPlannedFile(
    _ expected: CleanupFileSnapshot, rootPath: String, rootSnapshot: CleanupFileSnapshot? = nil
  ) throws {
    guard expected.isRegularFile, expected.owner == UInt32(getuid()),
      isWithin(expected.path, root: rootPath), expected.path != rootPath
    else { throw CleanupWorkbenchError.rejected("清理項目不在已確認的暫存位置。") }
    let components = expected.path.dropFirst(rootPath.count).split(separator: "/").map(String.init)
    guard let name = components.last, !components.contains("..") else {
      throw CleanupWorkbenchError.rejected("無法確認清理項目的相對位置。")
    }
    var descriptor = rootPath.withCString {
      open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw CleanupWorkbenchError.rejected("暫存資料夾目前無法讀取。") }
    defer { close(descriptor) }
    var rootMetadata = stat()
    guard fstat(descriptor, &rootMetadata) == 0 else {
      throw CleanupWorkbenchError.rejected("無法確認暫存目錄身分。")
    }
    if let rootSnapshot {
      guard UInt64(truncatingIfNeeded: rootMetadata.st_dev) == rootSnapshot.device,
        UInt64(rootMetadata.st_ino) == rootSnapshot.inode
      else {
        throw CleanupWorkbenchError.rejected("暫存目錄在執行前已被替換，先保留。")
      }
    }

    for component in components.dropLast() {
      let next = component.withCString {
        openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard next >= 0 else { throw CleanupWorkbenchError.rejected("資料夾已變更，這個項目已保留。") }
      close(descriptor)
      descriptor = next
    }
    var metadata = stat()
    guard name.withCString({ fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW) }) == 0,
      sameFile(expected, makeSnapshot(metadata, path: expected.path))
    else { throw CleanupWorkbenchError.rejected("檔案在掃描後已變更，這個項目已保留。") }
    guard name.withCString({ unlinkat(descriptor, $0, 0) }) == 0 else {
      throw CleanupWorkbenchError.rejected("無法清除此暫存檔：\(String(cString: strerror(errno)))")
    }
  }
}
