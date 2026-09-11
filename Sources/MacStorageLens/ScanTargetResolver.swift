import Foundation

enum ScanTargetResolver {
  static func resolveMountedTarget(_ target: ScanTarget) -> ScanTarget? {
    switch target.kind {
    case .system:
      return FileManager.default.fileExists(atPath: target.path) ? target : nil

    case .folder:
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { return nil }
      let standardized = URL(fileURLWithPath: target.path, isDirectory: true).standardizedFileURL
      return ScanTarget(
        kind: .folder,
        displayName: target.displayName,
        path: standardized.path,
        volumeUUID: nil
      )

    case .volume:
      // Most rescans should take the fast path: validate the saved mount directly
      // instead of enumerating every mounted URL. Enumerating all volumes can itself
      // block on a slow network share, disk image, or card reader and used to happen
      // before the scanner's own timing started.
      if let direct = mountedVolumeTarget(atPath: target.path), identitiesMatch(target, direct) {
        return direct
      }

      // A removable volume can return under another mount name. Only fall back to a
      // full mounted-volume enumeration when the saved path is missing or now points
      // at a different UUID.
      return resolveMountedTarget(target, mountedVolumes: mountedVolumes())
    }
  }

  static func resolveMountedTarget(
    _ target: ScanTarget,
    mountedVolumes: [ScanTarget]
  ) -> ScanTarget? {
    guard target.kind == .volume else { return target }

    if let uuid = normalizedUUID(target.volumeUUID) {
      return mountedVolumes.first {
        normalizedUUID($0.volumeUUID) == uuid
      }
    }

    let requestedPath = standardizedPath(target.path)
    return mountedVolumes.first {
      standardizedPath($0.path) == requestedPath
    }
  }

  static func mountedVolumes() -> [ScanTarget] {
    let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeUUIDStringKey]
    let urls =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: Array(keys),
        options: [.skipHiddenVolumes]
      ) ?? []

    return urls.compactMap { url in
      let standardized = url.standardizedFileURL
      guard standardized.path != "/", standardized.path != "/System/Volumes/Data",
        standardized.path.hasPrefix("/Volumes/")
      else { return nil }
      return makeVolumeTarget(url: standardized)
    }
  }

  private static func mountedVolumeTarget(atPath path: String) -> ScanTarget? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return nil }

    let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    guard standardized.path.hasPrefix("/Volumes/"),
      standardized.path.split(separator: "/", omittingEmptySubsequences: true).count == 2
    else { return nil }
    return makeVolumeTarget(url: standardized)
  }

  private static func identitiesMatch(_ requested: ScanTarget, _ mounted: ScanTarget) -> Bool {
    if let requestedUUID = normalizedUUID(requested.volumeUUID) {
      return normalizedUUID(mounted.volumeUUID) == requestedUUID
    }
    return standardizedPath(requested.path) == standardizedPath(mounted.path)
  }

  private static func normalizedUUID(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value.lowercased()
  }

  private static func standardizedPath(_ value: String) -> String {
    let path = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  private static func makeVolumeTarget(url: URL) -> ScanTarget {
    let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeUUIDStringKey])
    let candidate = values?.volumeName ?? url.lastPathComponent
    return ScanTarget(
      kind: .volume,
      displayName: candidate.isEmpty ? url.path : candidate,
      path: url.path,
      volumeUUID: values?.volumeUUIDString
    )
  }
}
