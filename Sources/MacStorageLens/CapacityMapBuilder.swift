import Foundation

enum CapacityMapBuilder {
  private static func volumeGapLabel(_ summary: ScanSummary) -> String {
    summary.volumeVolatileMetadataExcluded
      ? "卷宗中繼資料／垃圾桶（未展開）"
      : "磁碟帳務差額（未解析）"
  }

  static func buildOverview(
    summary: ScanSummary,
    presentation: SunburstItem,
    targetPath: String
  ) -> SunburstItem {
    let normalized = normalize(presentation)

    switch summary.targetKind {
    case .system:
      if let container = summary.primaryAPFSContainer {
        return buildAPFSContainer(
          summary: summary,
          container: container,
          selectedVolume: summary.targetAPFSVolume,
          presentation: normalized,
          targetPath: targetPath,
          gapBytes: summary.accountingGapBytes,
          gapLabel: "Data 帳務差額（未解析）"
        )
      }
      return buildLegacySystemOverview(
        summary: summary,
        presentation: normalized,
        targetPath: targetPath
      )

    case .volume:
      if let container = summary.primaryAPFSContainer,
        let selectedVolume = summary.targetAPFSVolume
      {
        return buildAPFSContainer(
          summary: summary,
          container: container,
          selectedVolume: selectedVolume,
          presentation: normalized,
          targetPath: targetPath,
          gapBytes: summary.targetAccountingGapBytes,
          gapLabel: volumeGapLabel(summary)
        )
      }
      return buildStandaloneVolumeOverview(
        summary: summary,
        presentation: normalized,
        targetPath: targetPath
      )

    case .folder:
      return SunburstItem(
        id: normalized.id,
        label: summary.targetDisplayName,
        path: normalized.path,
        bytes: normalized.bytes,
        kind: normalized.kind,
        children: normalized.children,
        colorHint: normalized.colorHint
      )
    }
  }

  static func reconcileTargetTree(
    summary: ScanSummary,
    presentation: SunburstItem
  ) -> SunburstItem {
    let normalized = normalize(presentation)
    guard summary.targetKind != .folder else {
      return SunburstItem(
        id: normalized.id,
        label: summary.targetDisplayName,
        path: normalized.path,
        bytes: normalized.bytes,
        kind: normalized.kind,
        children: normalized.children,
        colorHint: normalized.colorHint
      )
    }

    let usedBytes = max(
      normalized.bytes,
      summary.targetKind == .system
        ? summary.dataAPFSVolumeUsedBytes : summary.targetVolumeUsedBytes
    )
    let requestedGap =
      summary.targetKind == .system
      ? summary.accountingGapBytes
      : summary.targetAccountingGapBytes
    let gapBytes = min(requestedGap, max(0, usedBytes - normalized.bytes))
    let samplingBytes = max(0, usedBytes - normalized.bytes - gapBytes)

    var children = normalized.children
    if gapBytes > 0 {
      children.append(
        SunburstItem(
          id: normalized.id + "#accounting-gap",
          label: summary.targetKind == .system
            ? "Data 帳務差額（未解析）"
            : volumeGapLabel(summary),
          path: nil,
          bytes: gapBytes,
          kind: .accountingGap,
          children: []
        )
      )
    }
    if samplingBytes > 0 {
      children.append(
        SunburstItem(
          id: normalized.id + "#sampling-delta",
          label: "掃描／容量取樣差額",
          path: nil,
          bytes: samplingBytes,
          kind: .scanDelta,
          children: []
        )
      )
    }

    return SunburstItem(
      id: normalized.id,
      label: normalized.label,
      path: normalized.path,
      bytes: usedBytes,
      kind: normalized.kind,
      children: children.sorted { $0.bytes > $1.bytes },
      colorHint: normalized.colorHint
    )
  }

  static func accountingCloses(_ item: SunburstItem) -> Bool {
    guard !item.children.isEmpty else { return true }
    let childTotal = item.children.reduce(Int64(0)) { $0 + $1.bytes }
    guard childTotal == item.bytes else { return false }
    return item.children.allSatisfy(accountingCloses)
  }

  private static func buildAPFSContainer(
    summary: ScanSummary,
    container: APFSContainerRecord,
    selectedVolume: APFSVolumeRecord?,
    presentation: SunburstItem,
    targetPath: String,
    gapBytes: Int64,
    gapLabel: String
  ) -> SunburstItem {
    var children: [SunburstItem] = []

    for volume in container.volumes where volume.consumedBytes > 0 {
      if let selectedVolume, volume.deviceIdentifier == selectedVolume.deviceIdentifier {
        children.append(
          selectedVolumeItem(
            volume: volume,
            presentation: presentation,
            targetPath: targetPath,
            requestedGapBytes: gapBytes,
            gapLabel: gapLabel
          )
        )
      } else {
        children.append(
          SunburstItem(
            id: "apfs-volume-\(container.reference)-\(volume.deviceIdentifier)",
            label: volume.displayName,
            path: nil,
            bytes: volume.consumedBytes,
            kind: .otherVolume,
            children: []
          )
        )
      }
    }

    if container.accountingRemainderBytes > 0 {
      children.append(
        SunburstItem(
          id: "apfs-container-\(container.reference)-accounting",
          label: "APFS 容器帳務／metadata",
          path: nil,
          bytes: container.accountingRemainderBytes,
          kind: .containerAccounting,
          children: []
        )
      )
    }

    // APFS volume consumption and the `du` tree are sampled at different times.
    // If the later tree is slightly larger than the selected volume sample, reduce
    // the displayed free slice by that overage instead of making the whole chart
    // exceed the container's fixed capacity. The unadjusted value remains present
    // in the report and reconciliation card.
    let representedUsed = children.reduce(Int64(0)) { $0 + $1.bytes }
    let maximumFreeWithinCapacity = max(0, container.totalBytes - representedUsed)
    let displayedFree = min(container.freeBytes, maximumFreeWithinCapacity)
    if displayedFree > 0 {
      children.append(
        SunburstItem(
          id: "apfs-container-\(container.reference)-free",
          label: displayedFree == container.freeBytes ? "真正空閒" : "真正空閒（取樣調整）",
          path: nil,
          bytes: displayedFree,
          kind: .freeSpace,
          children: []
        )
      )
    }

    let represented = children.reduce(Int64(0)) { $0 + $1.bytes }
    if represented < container.totalBytes {
      children.append(
        SunburstItem(
          id: "apfs-container-\(container.reference)-sampling",
          label: "APFS 容量取樣差額",
          path: nil,
          bytes: container.totalBytes - represented,
          kind: .scanDelta,
          children: []
        )
      )
    }

    let rootBytes = max(container.totalBytes, children.reduce(Int64(0)) { $0 + $1.bytes })
    return SunburstItem(
      id: "apfs-container-\(container.reference)",
      label: summary.targetDisplayName,
      path: nil,
      bytes: rootBytes,
      kind: nil,
      children: children.sorted { $0.bytes > $1.bytes }
    )
  }

  private static func selectedVolumeItem(
    volume: APFSVolumeRecord,
    presentation: SunburstItem,
    targetPath: String,
    requestedGapBytes: Int64,
    gapLabel: String
  ) -> SunburstItem {
    // `du` and `diskutil apfs list` are sampled at different points in time.
    // Keep the visible tree intact even if it briefly exceeds the APFS volume sample.
    // The selected-volume node adopts the represented sample; the enclosing container
    // first absorbs that cross-time difference by reducing its displayed free slice.
    let mappedBytes = presentation.bytes
    let representedVolumeBytes = max(volume.consumedBytes, mappedBytes)
    let gapBytes = min(requestedGapBytes, max(0, representedVolumeBytes - mappedBytes))
    let samplingBytes = max(0, representedVolumeBytes - mappedBytes - gapBytes)

    var children: [SunburstItem] = []
    if mappedBytes > 0 {
      children.append(
        SunburstItem(
          id: "apfs-volume-\(volume.deviceIdentifier)-mapped",
          label: "可映射資料樹",
          path: targetPath,
          bytes: mappedBytes,
          kind: nil,
          children: presentation.children,
          colorHint: .mappedTree
        )
      )
    }
    if gapBytes > 0 {
      children.append(
        SunburstItem(
          id: "apfs-volume-\(volume.deviceIdentifier)-gap",
          label: gapLabel,
          path: nil,
          bytes: gapBytes,
          kind: .accountingGap,
          children: []
        )
      )
    }
    if samplingBytes > 0 {
      children.append(
        SunburstItem(
          id: "apfs-volume-\(volume.deviceIdentifier)-sampling",
          label: "掃描／APFS 取樣差額",
          path: nil,
          bytes: samplingBytes,
          kind: .scanDelta,
          children: []
        )
      )
    }

    return SunburstItem(
      id: "apfs-volume-\(volume.deviceIdentifier)",
      label: volume.displayName,
      path: targetPath,
      bytes: representedVolumeBytes,
      kind: nil,
      children: children.sorted { $0.bytes > $1.bytes },
      colorHint: .selectedVolume
    )
  }

  private static func buildStandaloneVolumeOverview(
    summary: ScanSummary,
    presentation: SunburstItem,
    targetPath: String
  ) -> SunburstItem {
    let usedBytes = max(summary.targetVolumeUsedBytes, presentation.bytes)
    let availableBytes = max(0, summary.targetVolumeAvailableBytes)
    let capacityBytes = max(summary.targetVolumeCapacityBytes, usedBytes + availableBytes)
    let mappedBytes = min(presentation.bytes, usedBytes)
    let gapBytes = min(summary.targetAccountingGapBytes, max(0, usedBytes - mappedBytes))
    let samplingBytes = max(0, usedBytes - mappedBytes - gapBytes)

    var usedChildren: [SunburstItem] = []
    if mappedBytes > 0 {
      usedChildren.append(
        SunburstItem(
          id: "standalone-volume-mapped",
          label: "可映射資料樹",
          path: targetPath,
          bytes: mappedBytes,
          kind: nil,
          children: presentation.children,
          colorHint: .mappedTree
        )
      )
    }
    if gapBytes > 0 {
      usedChildren.append(
        SunburstItem(
          id: "standalone-volume-gap",
          label: volumeGapLabel(summary),
          path: nil,
          bytes: gapBytes,
          kind: .accountingGap,
          children: []
        )
      )
    }
    if samplingBytes > 0 {
      usedChildren.append(
        SunburstItem(
          id: "standalone-volume-sampling",
          label: "掃描／容量取樣差額",
          path: nil,
          bytes: samplingBytes,
          kind: .scanDelta,
          children: []
        )
      )
    }

    var rootChildren: [SunburstItem] = [
      SunburstItem(
        id: "standalone-volume-used",
        label: summary.targetDisplayName,
        path: targetPath,
        bytes: usedBytes,
        kind: nil,
        children: usedChildren.sorted { $0.bytes > $1.bytes },
        colorHint: .selectedVolume
      )
    ]

    if availableBytes > 0 {
      rootChildren.append(
        SunburstItem(
          id: "standalone-volume-free",
          label: "可用空間",
          path: nil,
          bytes: availableBytes,
          kind: .freeSpace,
          children: []
        )
      )
    }

    let reservedBytes = max(0, capacityBytes - usedBytes - availableBytes)
    if reservedBytes > 0 {
      rootChildren.append(
        SunburstItem(
          id: "standalone-volume-reserved",
          label: "檔案系統保留／metadata",
          path: nil,
          bytes: reservedBytes,
          kind: .containerAccounting,
          children: []
        )
      )
    }

    return SunburstItem(
      id: "standalone-volume",
      label: summary.targetDisplayName,
      path: nil,
      bytes: rootChildren.reduce(Int64(0)) { $0 + $1.bytes },
      kind: nil,
      children: rootChildren.sorted { $0.bytes > $1.bytes }
    )
  }

  private static func buildLegacySystemOverview(
    summary: ScanSummary,
    presentation: SunburstItem,
    targetPath: String
  ) -> SunburstItem {
    let dataBytes = max(summary.dataAPFSVolumeUsedBytes, presentation.bytes)
    let mappedBytes = min(presentation.bytes, dataBytes)
    let gapBytes = min(summary.accountingGapBytes, max(0, dataBytes - mappedBytes))
    let samplingBytes = max(0, dataBytes - mappedBytes - gapBytes)

    var dataChildren: [SunburstItem] = []
    if mappedBytes > 0 {
      dataChildren.append(
        SunburstItem(
          id: "legacy-data-mapped",
          label: "可映射資料樹",
          path: targetPath,
          bytes: mappedBytes,
          kind: nil,
          children: presentation.children,
          colorHint: .mappedTree
        )
      )
    }
    if gapBytes > 0 {
      dataChildren.append(
        SunburstItem(
          id: "legacy-data-gap",
          label: "Data 帳務差額（未解析）",
          path: nil,
          bytes: gapBytes,
          kind: .accountingGap,
          children: []
        )
      )
    }
    if samplingBytes > 0 {
      dataChildren.append(
        SunburstItem(
          id: "legacy-data-sampling",
          label: "掃描／容量取樣差額",
          path: nil,
          bytes: samplingBytes,
          kind: .scanDelta,
          children: []
        )
      )
    }

    var rootChildren: [SunburstItem] = [
      SunburstItem(
        id: "legacy-data-volume",
        label: "Data",
        path: targetPath,
        bytes: dataBytes,
        kind: nil,
        children: dataChildren.sorted { $0.bytes > $1.bytes },
        colorHint: .selectedVolume
      )
    ]

    appendLegacyVolume(
      id: "legacy-system-volume", label: "macOS 系統卷",
      bytes: summary.systemVolumeUsedBytes, to: &rootChildren)
    appendLegacyVolume(
      id: "legacy-preboot-volume", label: "Preboot",
      bytes: summary.prebootVolumeUsedBytes, to: &rootChildren)
    appendLegacyVolume(
      id: "legacy-recovery-volume", label: "Recovery",
      bytes: summary.recoveryVolumeUsedBytes, to: &rootChildren)
    appendLegacyVolume(
      id: "legacy-vm-volume", label: "VM／Swap",
      bytes: summary.vmVolumeUsedBytes, to: &rootChildren)
    appendLegacyVolume(
      id: "legacy-update-volume", label: "Update",
      bytes: summary.updateVolumeUsedBytes, to: &rootChildren)

    if summary.otherContainerBytes > 0 {
      rootChildren.append(
        SunburstItem(
          id: "legacy-container-accounting",
          label: "APFS metadata／其他卷",
          path: nil,
          bytes: summary.otherContainerBytes,
          kind: .containerAccounting,
          children: []
        )
      )
    }
    if summary.availableBytes > 0 {
      rootChildren.append(
        SunburstItem(
          id: "legacy-free-space",
          label: "真正空閒",
          path: nil,
          bytes: summary.availableBytes,
          kind: .freeSpace,
          children: []
        )
      )
    }

    let represented = rootChildren.reduce(Int64(0)) { $0 + $1.bytes }
    let totalBytes = max(summary.capacityBytes, represented)
    if represented < totalBytes {
      rootChildren.append(
        SunburstItem(
          id: "legacy-capacity-sampling",
          label: "容量取樣差額",
          path: nil,
          bytes: totalBytes - represented,
          kind: .scanDelta,
          children: []
        )
      )
    }

    return SunburstItem(
      id: "legacy-system-container",
      label: summary.targetDisplayName,
      path: nil,
      bytes: totalBytes,
      kind: nil,
      children: rootChildren.sorted { $0.bytes > $1.bytes }
    )
  }

  private static func appendLegacyVolume(
    id: String,
    label: String,
    bytes: Int64,
    to children: inout [SunburstItem]
  ) {
    guard bytes > 0 else { return }
    children.append(
      SunburstItem(
        id: id,
        label: label,
        path: nil,
        bytes: bytes,
        kind: .otherVolume,
        children: []
      )
    )
  }

  private static func normalize(_ item: SunburstItem) -> SunburstItem {
    guard !item.children.isEmpty else { return item }

    var children = item.children.map(normalize)
    let childTotal = children.reduce(Int64(0)) { $0 + $1.bytes }
    let normalizedBytes = max(item.bytes, childTotal)

    if childTotal < normalizedBytes {
      let residual = normalizedBytes - childTotal
      children.append(
        SunburstItem(
          id: item.id + "#unclassified-direct",
          label: item.path == nil ? "其他未細分內容" : "其他直接檔案",
          path: item.path,
          bytes: residual,
          kind: item.path == nil ? .otherChildren : .directFiles,
          children: []
        )
      )
    }

    return SunburstItem(
      id: item.id,
      label: item.label,
      path: item.path,
      bytes: normalizedBytes,
      kind: item.kind,
      children: children.sorted { $0.bytes > $1.bytes },
      colorHint: item.colorHint
    )
  }
}
