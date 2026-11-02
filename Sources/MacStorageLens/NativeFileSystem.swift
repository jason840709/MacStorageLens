import Foundation

#if canImport(Darwin)
  import Darwin
  private typealias DirectoryHandle = UnsafeMutablePointer<DIR>
#else
  import Glibc
  private typealias DirectoryHandle = OpaquePointer
#endif

/// Read names from the filesystem rather than Foundation's filtered directory
/// view. Keep URLs anchored to the supplied root: /var and /private/var must not
/// turn the same selected directory into two different cleanup candidates.
enum NativeFileSystem {
  static func contentsOfDirectory(at root: URL, skipHidden: Bool = false) throws -> [URL] {
    let cursor = try DirectoryCursor(root: root)
    var result: [URL] = []
    while let entry = try cursor.next() {
      let url = root.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
      if skipHidden {
        if entry.name.hasPrefix(".") { continue }
        if (try? url.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true { continue }
      }
      result.append(url)
    }
    return result
  }

  static func enumerator(
    at root: URL,
    errorHandler: ((URL, Error) -> Bool)? = nil
  ) -> NativeDirectoryEnumerator? {
    do {
      return try NativeDirectoryEnumerator(root: root, errorHandler: errorHandler)
    } catch {
      _ = errorHandler?(root, error)
      return nil
    }
  }
}

private struct DirectoryEntry {
  let name: String
  let isDirectory: Bool
}

private final class DirectoryCursor {
  let url: URL
  let handle: DirectoryHandle
  let device: dev_t

  var descriptor: Int32 { dirfd(handle) }

  init(root: URL, parent: DirectoryCursor? = nil, name: String? = nil) throws {
    url = root
    let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    let fd: Int32
    if let parent, let name {
      fd = name.withCString { openat(parent.descriptor, $0, flags) }
    } else {
      fd = root.path.withCString { open($0, flags) }
    }
    guard fd >= 0 else { throw Self.error(at: root) }
    var metadata = stat()
    guard fstat(fd, &metadata) == 0 else {
      let error = Self.error(at: root)
      close(fd)
      throw error
    }
    guard let opened = fdopendir(fd) else {
      let error = Self.error(at: root)
      close(fd)
      throw error
    }
    handle = opened
    device = metadata.st_dev
  }

  deinit { closedir(handle) }

  func next() throws -> DirectoryEntry? {
    while true {
      errno = 0
      guard let item = readdir(handle) else {
        if errno != 0 { throw Self.error(at: url) }
        return nil
      }
      let bytes = withUnsafeBytes(of: item.pointee.d_name) { raw -> [UInt8] in
        Array(raw.prefix { $0 != 0 })
      }
      guard let name = String(bytes: bytes, encoding: .utf8) else {
        throw NSError(
          domain: NSPOSIXErrorDomain, code: Int(EILSEQ),
          userInfo: [NSFilePathErrorKey: url.path])
      }
      if name == "." || name == ".." { continue }
      var isDirectory = item.pointee.d_type == UInt8(DT_DIR)
      if item.pointee.d_type == UInt8(DT_UNKNOWN) {
        var metadata = stat()
        let status = name.withCString {
          fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if status != 0 {
          if errno == ENOENT { continue }
          throw Self.error(at: url.appendingPathComponent(name))
        }
        isDirectory = metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
      }
      return DirectoryEntry(name: name, isDirectory: isDirectory)
    }
  }

  static func error(at url: URL, code: Int32 = errno) -> NSError {
    NSError(
      domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
  }
}

final class NativeDirectoryEnumerator {
  private struct PendingDirectory {
    let url: URL
    let name: String
    let parent: DirectoryCursor
  }

  private var stack: [DirectoryCursor]
  private var pending: PendingDirectory?
  private let rootDevice: dev_t
  private let errorHandler: ((URL, Error) -> Bool)?

  fileprivate init(root: URL, errorHandler: ((URL, Error) -> Bool)?) throws {
    let cursor = try DirectoryCursor(root: root)
    stack = [cursor]
    rootDevice = cursor.device
    self.errorHandler = errorHandler
  }

  func skipDescendants() { pending = nil }

  func nextObject() -> Any? {
    if let directory = pending {
      pending = nil
      do {
        guard stack.count < 128 else {
          throw DirectoryCursor.error(at: directory.url, code: ELOOP)
        }
        // openat + O_NOFOLLOW keeps traversal on the directory already read,
        // even if a child is replaced by a symlink between iteration steps.
        let cursor = try DirectoryCursor(
          root: directory.url, parent: directory.parent, name: directory.name)
        guard cursor.device == rootDevice else {
          throw DirectoryCursor.error(at: directory.url, code: EXDEV)
        }
        stack.append(cursor)
      } catch {
        if errorHandler?(directory.url, error) == false { stack.removeAll() }
      }
    }

    while let cursor = stack.last {
      do {
        guard let entry = try cursor.next() else {
          stack.removeLast()
          continue
        }
        let url = cursor.url.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
        if entry.isDirectory {
          let isPackage =
            (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
            || url.pathExtension.lowercased() == "app"
          if !isPackage {
            pending = PendingDirectory(url: url, name: entry.name, parent: cursor)
          }
        }
        return url
      } catch {
        stack.removeLast()
        if errorHandler?(cursor.url, error) == false { stack.removeAll() }
      }
    }
    return nil
  }
}
