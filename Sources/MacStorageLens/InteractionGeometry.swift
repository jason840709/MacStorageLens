import Foundation

struct SegmentedBarLayoutValue: Hashable, Codable, Sendable {
  let id: String
  let value: Int64
}

struct SegmentedBarLayoutFrame: Identifiable, Hashable, Codable, Sendable {
  let id: String
  let minX: Double
  let maxX: Double

  var width: Double { max(0, maxX - minX) }
}

enum SegmentedBarLayout {
  static func frames(
    values: [SegmentedBarLayoutValue],
    width: Double,
    total: Int64,
    padding: Double = 2,
    gap: Double = 2
  ) -> [SegmentedBarLayoutFrame] {
    let visibleValues = values.filter { $0.value > 0 }
    guard width > padding * 2, !visibleValues.isEmpty else { return [] }

    let safePadding = max(0, padding)
    let safeGap = max(0, gap)
    let gaps = Double(max(0, visibleValues.count - 1)) * safeGap
    let availableTrack = max(0, width - safePadding * 2 - gaps)
    guard availableTrack > 0 else { return [] }

    let visibleTotal = visibleValues.reduce(Int64(0)) { partial, value in
      let (sum, overflow) = partial.addingReportingOverflow(value.value)
      return overflow ? Int64.max : sum
    }
    let denominator = max(Int64(1), max(total, visibleTotal))

    var cursor = safePadding
    return visibleValues.map { value in
      let segmentWidth = availableTrack * Double(value.value) / Double(denominator)
      let frame = SegmentedBarLayoutFrame(
        id: value.id,
        minX: cursor,
        maxX: cursor + segmentWidth
      )
      cursor += segmentWidth + safeGap
      return frame
    }
  }

  static func hit(at x: Double, frames: [SegmentedBarLayoutFrame]) -> String? {
    guard x.isFinite else { return nil }
    return frames.first { x >= $0.minX && x <= $0.maxX }?.id
  }
}
