import Foundation

/// A bounded, read-only parser for the AppleDouble header stored in files whose
/// names begin with `._`.  The filename alone is never treated as proof that an
/// item is disposable: the binary magic, version, descriptor table and entry
/// bounds must all validate first.
struct AppleDoubleInspection: Hashable {
  enum Kind: String, Hashable {
    /// Valid AppleDouble, no companion data file, and no resource fork or
    /// unknown/application-defined entry.  This is a stale metadata remnant.
    case orphanedMetadataOnly
    /// Valid AppleDouble with no companion, but it still carries a resource
    /// fork or an entry whose meaning the App cannot prove.
    case orphanedSensitive
    /// Valid AppleDouble whose companion still exists; no resource fork or
    /// unknown entry was found.  It can still hold Finder info and xattrs.
    case pairedMetadataOnly
    /// Valid AppleDouble whose companion exists and that may contain meaningful
    /// resource-fork, package, symlink or application-defined metadata.
    case pairedSensitive
    /// The name begins with `._`, but the content cannot be proved to be a
    /// structurally valid AppleDouble header.
    case unrecognized
  }

  let kind: Kind
  let companionPath: String?
  let entryIDs: [UInt32]
  let resourceForkBytes: UInt64
  let unknownEntryIDs: [UInt32]
  let detail: String

  var isValidAppleDouble: Bool { kind != .unrecognized }
  var isExecutableOrphan: Bool { kind == .orphanedMetadataOnly }
  var isExecutablePairedMetadata: Bool { kind == .pairedMetadataOnly }
  var isSensitive: Bool { kind == .orphanedSensitive || kind == .pairedSensitive }
}

struct AppleDoubleInspector {
  private struct EntryDescriptor: Hashable {
    let id: UInt32
    let offset: UInt32
    let length: UInt32
  }

  private enum CompanionState {
    case missing
    case regular
    case directory
    case package
    case symbolicLink
    case unsupported
  }

  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func inspect(_ sidecar: URL) -> AppleDoubleInspection {
    let standardized = sidecar.standardizedFileURL
    let name = standardized.lastPathComponent
    guard name.hasPrefix("._"), name.count > 2 else {
      return unrecognized("檔名不是可辨識的 ._ AppleDouble 側邊檔。")
    }

    let companionName = String(name.dropFirst(2))
    guard !companionName.isEmpty, companionName != ".", companionName != ".." else {
      return unrecognized("無法從檔名推導同名主檔。")
    }

    let companion = standardized.deletingLastPathComponent()
      .appendingPathComponent(companionName)
      .standardizedFileURL

    guard
      let sidecarValues = try? standardized.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey,
      ]),
      sidecarValues.isRegularFile == true,
      sidecarValues.isSymbolicLink != true
    else {
      return unrecognized(
        "._ 項目本身不是一般檔案，不能當成 AppleDouble 清理候選。",
        companionPath: companion.path
      )
    }

    guard let parsed = parseHeader(at: standardized) else {
      return unrecognized(
        "檔名前綴是 ._，但內容不是可驗證的 AppleDouble header；可能是普通使用者檔案或已損壞的中繼資料。",
        companionPath: companion.path
      )
    }

    let entries = parsed.entries
    let entryIDs = entries.map(\.id)
    let resourceForkBytes = UInt64(
      entries.first(where: { $0.id == Self.resourceForkEntryID })?.length ?? 0)
    let unknownEntryIDs = entryIDs.filter { !Self.knownMetadataEntryIDs.contains($0) }
    let carriesSensitivePayload = resourceForkBytes > 0 || !unknownEntryIDs.isEmpty

    switch companionState(at: companion) {
    case .missing:
      if carriesSensitivePayload {
        return AppleDoubleInspection(
          kind: .orphanedSensitive,
          companionPath: companion.path,
          entryIDs: entryIDs,
          resourceForkBytes: resourceForkBytes,
          unknownEntryIDs: unknownEntryIDs,
          detail: sensitiveDetail(
            prefix: "同名主檔已不存在，但側邊檔仍可能是唯一留下的 Mac 資源或未知 metadata",
            resourceForkBytes: resourceForkBytes,
            unknownEntryIDs: unknownEntryIDs
          )
        )
      }
      return AppleDoubleInspection(
        kind: .orphanedMetadataOnly,
        companionPath: companion.path,
        entryIDs: entryIDs,
        resourceForkBytes: 0,
        unknownEntryIDs: [],
        detail: "AppleDouble 格式有效、同名主檔已不存在，而且沒有非空資源分支或未知 entry。"
      )

    case .regular, .directory:
      if carriesSensitivePayload {
        return AppleDoubleInspection(
          kind: .pairedSensitive,
          companionPath: companion.path,
          entryIDs: entryIDs,
          resourceForkBytes: resourceForkBytes,
          unknownEntryIDs: unknownEntryIDs,
          detail: sensitiveDetail(
            prefix: "同名主檔仍存在，側邊檔含有不能直接當成垃圾的資料",
            resourceForkBytes: resourceForkBytes,
            unknownEntryIDs: unknownEntryIDs
          )
        )
      }
      return AppleDoubleInspection(
        kind: .pairedMetadataOnly,
        companionPath: companion.path,
        entryIDs: entryIDs,
        resourceForkBytes: 0,
        unknownEntryIDs: [],
        detail: "同名主檔仍存在；側邊檔沒有非空資源分支或未知 entry，但仍可能保存 Finder 資訊、標籤或延伸屬性。"
      )

    case .package:
      return AppleDoubleInspection(
        kind: .pairedSensitive,
        companionPath: companion.path,
        entryIDs: entryIDs,
        resourceForkBytes: resourceForkBytes,
        unknownEntryIDs: unknownEntryIDs,
        detail: "同名主檔是 package／bundle；側邊 metadata 可能參與套件完整性，僅供檢視。"
      )

    case .symbolicLink:
      return AppleDoubleInspection(
        kind: .pairedSensitive,
        companionPath: companion.path,
        entryIDs: entryIDs,
        resourceForkBytes: resourceForkBytes,
        unknownEntryIDs: unknownEntryIDs,
        detail: "同名主檔是符號連結，無法安全判定 metadata 歸屬，僅供檢視。"
      )

    case .unsupported:
      return AppleDoubleInspection(
        kind: .pairedSensitive,
        companionPath: companion.path,
        entryIDs: entryIDs,
        resourceForkBytes: resourceForkBytes,
        unknownEntryIDs: unknownEntryIDs,
        detail: "同名項目的檔案類型無法安全判定，僅供檢視。"
      )
    }
  }

  private func companionState(at url: URL) -> CompanionState {
    // `fileExists` follows symbolic links and returns false for a broken link.
    // Check the directory entry first so a dangling symlink can never be
    // downgraded to an apparently safe orphaned sidecar.
    if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
      return .symbolicLink
    }
    guard fileManager.fileExists(atPath: url.path) else { return .missing }
    guard
      let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
      ])
    else { return .unsupported }
    if values.isSymbolicLink == true { return .symbolicLink }
    if values.isPackage == true || Self.packageExtensions.contains(url.pathExtension.lowercased()) {
      return .package
    }
    if values.isRegularFile == true { return .regular }
    if values.isDirectory == true { return .directory }
    return .unsupported
  }

  private func parseHeader(at url: URL) -> (version: UInt32, entries: [EntryDescriptor])? {
    guard
      let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let fileSizeNumber = attributes[.size] as? NSNumber
    else { return nil }

    let fileSize = fileSizeNumber.uint64Value
    guard fileSize >= UInt64(Self.fixedHeaderLength) else { return nil }

    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }

    let header = handle.readData(ofLength: Self.fixedHeaderLength)
    guard header.count == Self.fixedHeaderLength,
      readUInt32BE(header, at: 0) == Self.magic,
      let version = readUInt32BE(header, at: 4),
      Self.supportedVersions.contains(version),
      let entryCount = readUInt16BE(header, at: 24),
      entryCount <= Self.maximumEntryCount
    else { return nil }

    let descriptorLength = Int(entryCount) * Self.entryDescriptorLength
    let descriptorData = handle.readData(ofLength: descriptorLength)
    guard descriptorData.count == descriptorLength else { return nil }

    let tableEnd = UInt64(Self.fixedHeaderLength + descriptorLength)
    guard tableEnd <= fileSize else { return nil }

    var entries: [EntryDescriptor] = []
    entries.reserveCapacity(Int(entryCount))
    var seenIDs = Set<UInt32>()

    for index in 0..<Int(entryCount) {
      let base = index * Self.entryDescriptorLength
      guard
        let id = readUInt32BE(descriptorData, at: base),
        let offset = readUInt32BE(descriptorData, at: base + 4),
        let length = readUInt32BE(descriptorData, at: base + 8),
        id != 0,
        id != Self.dataForkEntryID,
        seenIDs.insert(id).inserted
      else { return nil }

      let start = UInt64(offset)
      let byteCount = UInt64(length)
      guard start >= tableEnd, start <= fileSize, byteCount <= fileSize - start else {
        return nil
      }
      entries.append(EntryDescriptor(id: id, offset: offset, length: length))
    }

    let nonEmptyRanges =
      entries
      .filter { $0.length > 0 }
      .sorted { $0.offset < $1.offset }
    for index in 1..<nonEmptyRanges.count {
      let previous = nonEmptyRanges[index - 1]
      let current = nonEmptyRanges[index]
      let previousEnd = UInt64(previous.offset) + UInt64(previous.length)
      guard UInt64(current.offset) >= previousEnd else { return nil }
    }

    return (version, entries)
  }

  private func sensitiveDetail(
    prefix: String,
    resourceForkBytes: UInt64,
    unknownEntryIDs: [UInt32]
  ) -> String {
    var details: [String] = []
    if resourceForkBytes > 0 {
      details.append("資源分支 \(resourceForkBytes.formatted()) bytes")
    }
    if !unknownEntryIDs.isEmpty {
      details.append("未知 entry ID：\(unknownEntryIDs.map(String.init).joined(separator: ", "))")
    }
    return details.isEmpty ? prefix + "。" : prefix + "（" + details.joined(separator: "；") + "）。"
  }

  private func unrecognized(
    _ detail: String,
    companionPath: String? = nil
  ) -> AppleDoubleInspection {
    AppleDoubleInspection(
      kind: .unrecognized,
      companionPath: companionPath,
      entryIDs: [],
      resourceForkBytes: 0,
      unknownEntryIDs: [],
      detail: detail
    )
  }

  private func readUInt16BE(_ data: Data, at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    return data.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }
  }

  private func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return data.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      return (UInt32(bytes[offset]) << 24)
        | (UInt32(bytes[offset + 1]) << 16)
        | (UInt32(bytes[offset + 2]) << 8)
        | UInt32(bytes[offset + 3])
    }
  }

  private static let magic: UInt32 = 0x0005_1607
  private static let supportedVersions: Set<UInt32> = [0x0001_0000, 0x0002_0000]
  private static let fixedHeaderLength = 26
  private static let entryDescriptorLength = 12
  private static let maximumEntryCount: UInt16 = 128
  private static let dataForkEntryID: UInt32 = 1
  private static let resourceForkEntryID: UInt32 = 2
  private static let knownMetadataEntryIDs: Set<UInt32> = [
    2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14, 15,
  ]
  private static let packageExtensions: Set<String> = [
    "app", "bundle", "framework", "plugin", "appex", "xcodeproj", "xcworkspace",
    "photoslibrary", "photolibrary", "musiclibrary", "imovielibrary", "pages", "numbers",
    "key", "rtfd", "playground", "pkg",
  ]
}
