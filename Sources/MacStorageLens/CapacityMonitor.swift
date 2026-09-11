import Foundation

struct CapacityMonitor {
  func read(volumeContainingPath path: String = "/System/Volumes/Data") throws -> LiveCapacity {
    let requestedURL = URL(fileURLWithPath: path, isDirectory: true)
    #if os(macOS)
      let keys: Set<URLResourceKey> = [
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityForOpportunisticUsageKey,
      ]
      let values = try requestedURL.resourceValues(forKeys: keys)

      let total = Int64(values.volumeTotalCapacity ?? 0)
      let available = Int64(values.volumeAvailableCapacity ?? 0)
      let important = values.volumeAvailableCapacityForImportantUsage ?? available
      let opportunistic = values.volumeAvailableCapacityForOpportunisticUsage ?? available
    #else
      let values = try requestedURL.resourceValues(forKeys: [
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
      ])
      let total = Int64(values.volumeTotalCapacity ?? 0)
      let available = Int64(values.volumeAvailableCapacity ?? 0)
      let important = available
      let opportunistic = available
    #endif

    return LiveCapacity(
      totalBytes: total,
      availableBytes: available,
      importantUsageAvailableBytes: important,
      opportunisticUsageAvailableBytes: opportunistic,
      updatedAt: Date()
    )
  }
}
