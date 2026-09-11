import Foundation

private enum InteractionGeometryAuditFailure: Error, CustomStringConvertible {
  case failed(String)

  var description: String {
    switch self {
    case .failed(let message): return message
    }
  }
}

private struct InteractionGeometryAuditOutput: Encodable {
  let version: String
  let build: Int
  let assertions: [String]
  let sampleFrames: [SegmentedBarLayoutFrame]
  let passed: Int
  let total: Int
}

@main
struct InteractionGeometryAudit {
  static func main() throws {
    var assertions: [String] = []

    func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
      guard condition() else { throw InteractionGeometryAuditFailure.failed(name) }
      assertions.append(name)
    }

    let frames = SegmentedBarLayout.frames(
      values: [
        SegmentedBarLayoutValue(id: "mapped", value: 60),
        SegmentedBarLayoutValue(id: "gap", value: 30),
        SegmentedBarLayoutValue(id: "free", value: 10),
      ],
      width: 104,
      total: 100
    )

    try check(frames.count == 3, "three_positive_segments_have_frames")
    try check(frames[0].minX == 2, "track_starts_after_padding")
    try check(abs(frames[0].width - 57.6) < 0.000_001, "first_segment_width_uses_available_track")
    try check(abs(frames[1].width - 28.8) < 0.000_001, "second_segment_width_uses_available_track")
    try check(abs(frames[2].width - 9.6) < 0.000_001, "third_segment_width_uses_available_track")
    try check(
      SegmentedBarLayout.hit(at: (frames[0].minX + frames[0].maxX) / 2, frames: frames)
        == "mapped",
      "first_segment_midpoint_hits_first"
    )
    try check(
      SegmentedBarLayout.hit(at: (frames[1].minX + frames[1].maxX) / 2, frames: frames)
        == "gap",
      "second_segment_midpoint_hits_second"
    )
    try check(
      SegmentedBarLayout.hit(at: (frames[2].minX + frames[2].maxX) / 2, frames: frames)
        == "free",
      "third_segment_midpoint_hits_third"
    )
    try check(
      SegmentedBarLayout.hit(at: frames[0].maxX + 1, frames: frames) == nil,
      "visual_gap_is_not_misattributed"
    )
    try check(
      SegmentedBarLayout.hit(at: 0, frames: frames) == nil,
      "left_track_padding_is_not_misattributed"
    )
    try check(
      SegmentedBarLayout.hit(at: 103, frames: frames) == nil,
      "right_track_padding_is_not_misattributed"
    )
    try check(
      SegmentedBarLayout.hit(at: .nan, frames: frames) == nil,
      "nonfinite_pointer_is_rejected"
    )

    let zeroFiltered = SegmentedBarLayout.frames(
      values: [
        SegmentedBarLayoutValue(id: "zero", value: 0),
        SegmentedBarLayoutValue(id: "negative", value: -5),
        SegmentedBarLayoutValue(id: "visible", value: 10),
      ],
      width: 100,
      total: 10
    )
    try check(zeroFiltered.map(\.id) == ["visible"], "zero_and_negative_segments_are_hidden")
    try check(abs(zeroFiltered[0].width - 96) < 0.000_001, "single_segment_uses_full_track")

    let underfilled = SegmentedBarLayout.frames(
      values: [SegmentedBarLayoutValue(id: "used", value: 40)],
      width: 100,
      total: 100
    )
    try check(
      abs(underfilled[0].width - 38.4) < 0.000_001, "underfilled_total_leaves_unallocated_track")
    try check(
      SegmentedBarLayout.hit(at: 80, frames: underfilled) == nil,
      "unallocated_track_has_no_false_tooltip"
    )

    let overfilled = SegmentedBarLayout.frames(
      values: [
        SegmentedBarLayoutValue(id: "a", value: 80),
        SegmentedBarLayoutValue(id: "b", value: 80),
      ],
      width: 102,
      total: 100
    )
    try check(
      overfilled.last?.maxX ?? .infinity <= 100, "overfilled_values_are_normalized_to_visible_sum")

    let empty = SegmentedBarLayout.frames(values: [], width: 100, total: 100)
    try check(empty.isEmpty, "empty_input_has_no_frames")
    let tooNarrow = SegmentedBarLayout.frames(
      values: [SegmentedBarLayoutValue(id: "a", value: 1)], width: 4, total: 1)
    try check(tooNarrow.isEmpty, "track_without_drawable_width_has_no_frames")

    let output = InteractionGeometryAuditOutput(
      version: "1.6.8",
      build: 25,
      assertions: assertions,
      sampleFrames: frames,
      passed: assertions.count,
      total: assertions.count
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(output)
    if CommandLine.arguments.count >= 2 {
      try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}
