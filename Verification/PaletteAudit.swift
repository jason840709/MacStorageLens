import Foundation

private struct PaletteSample: Codable {
  let family: Int
  let depth: Int
  let role: String
  let dark: Bool
  let components: StorageColorComponents
}

private struct PaletteAuditOutput: Codable {
  let version: String
  let branchFamilies: Int
  let assertions: [String]
  let samples: [PaletteSample]
}

private enum PaletteAuditFailure: LocalizedError {
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .failed(let message): return message
    }
  }
}

@main
struct PaletteAudit {
  static func main() throws {
    var assertions: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
      guard condition() else { throw PaletteAuditFailure.failed("Assertion failed: \(name)") }
      assertions.append(name)
    }

    let epsilon = 0.000_000_1
    let structuralRoles: [StorageColorRole] = [
      .branch, .directFiles, .otherChildren, .otherVolume,
    ]
    let semanticRoles: [StorageColorRole] = [
      .selectedVolume, .mappedTree, .accountingGap, .containerAccounting, .scanDelta,
      .freeSpace, .purgeable,
    ]

    try check(StorageColorModel.branchFamilyCount == 12, "twelve_restrained_branch_families")
    try check(
      StorageColorModel.stableHash("") == 14_695_981_039_346_656_037,
      "fnv1a_empty_known_vector"
    )
    try check(
      StorageColorModel.stableHash("a") == 12_638_187_200_555_641_996,
      "fnv1a_ascii_known_vector"
    )
    try check(
      StorageColorModel.stableHash("/Users/example")
        == StorageColorModel.stableHash("/Users/example"),
      "stable_hash_is_deterministic"
    )
    try check(
      StorageColorModel.stableHash("/Users/example")
        != StorageColorModel.stableHash("/Users/another"),
      "stable_hash_separates_typical_paths"
    )

    for isDark in [false, true] {
      for family in 0..<StorageColorModel.branchFamilyCount {
        for role in structuralRoles {
          let familyHue = StorageColorModel.components(
            index: family,
            depth: 0,
            seed: 0,
            role: role,
            isDark: isDark
          ).hue

          var previousBrightness = -Double.infinity
          var previousSaturation = Double.infinity
          for depth in 0...7 {
            let components = StorageColorModel.components(
              index: family,
              depth: depth,
              seed: UInt64(depth * 13 + family),
              role: role,
              isDark: isDark
            )
            try check(
              abs(components.hue - familyHue) <= epsilon,
              "hue_constant_\(isDark ? "dark" : "light")_f\(family)_\(role.rawValue)_d\(depth)"
            )
            try check(
              components.brightness + epsilon >= previousBrightness,
              "outward_brightness_non_decreasing_\(isDark ? "dark" : "light")_f\(family)_\(role.rawValue)_d\(depth)"
            )
            try check(
              components.saturation <= previousSaturation + epsilon,
              "outward_saturation_non_increasing_\(isDark ? "dark" : "light")_f\(family)_\(role.rawValue)_d\(depth)"
            )
            try check(
              components.saturation >= 0.16 - epsilon,
              "descendant_chroma_floor_\(isDark ? "dark" : "light")_f\(family)_\(role.rawValue)_d\(depth)"
            )
            previousBrightness = components.brightness
            previousSaturation = components.saturation
          }
        }
      }
    }

    // The first real folder families must be categorically distinct. The selected
    // APFS/Data volume remains a structural semantic blue; mapped-tree children
    // are reseeded into these branch families by SunburstChart.
    let familyHues = (0..<StorageColorModel.branchFamilyCount).map {
      StorageColorModel.components(
        index: $0,
        depth: 0,
        seed: 0,
        role: .branch,
        isDark: true
      ).hue
    }
    try check(Set(familyHues).count == familyHues.count, "all_branch_family_hues_are_distinct")

    for family in 0..<StorageColorModel.branchFamilyCount {
      for isDark in [false, true] {
        for depth in 0...3 {
          let parent = StorageColorModel.components(
            index: family,
            depth: depth,
            seed: 0,
            role: .branch,
            isDark: isDark
          )
          let child = StorageColorModel.components(
            index: family,
            depth: depth + 1,
            seed: 0,
            role: .branch,
            isDark: isDark
          )
          let minimumStep = isDark ? 0.050 : 0.040
          try check(
            child.brightness - parent.brightness >= minimumStep - epsilon,
            "perceptible_depth_step_\(isDark ? "dark" : "light")_f\(family)_d\(depth)"
          )
        }
      }
    }

    for isDark in [false, true] {
      let selectedVolume = StorageColorModel.components(
        index: 0,
        depth: 0,
        seed: 0,
        role: .selectedVolume,
        isDark: isDark
      )
      let mappedTree = StorageColorModel.components(
        index: 11,
        depth: 7,
        seed: UInt64.max,
        role: .mappedTree,
        isDark: isDark
      )
      try check(
        abs(selectedVolume.hue - mappedTree.hue) <= epsilon,
        "structural_volume_and_mapped_bridge_share_hue_\(isDark ? "dark" : "light")"
      )
      try check(
        mappedTree.brightness > selectedVolume.brightness,
        "mapped_bridge_is_brighter_than_selected_volume_\(isDark ? "dark" : "light")"
      )
      try check(
        mappedTree.saturation < selectedVolume.saturation,
        "mapped_bridge_is_quieter_than_selected_volume_\(isDark ? "dark" : "light")"
      )
    }

    // The positive-only sibling lift must never overpower the next depth step.
    for isDark in [false, true] {
      for family in 0..<StorageColorModel.branchFamilyCount {
        for depth in 0...5 {
          let brightestParent = StorageColorModel.components(
            index: family,
            depth: depth,
            seed: 4,
            role: .branch,
            isDark: isDark
          )
          let darkestChild = StorageColorModel.components(
            index: family,
            depth: depth + 1,
            seed: 0,
            role: .branch,
            isDark: isDark
          )
          try check(
            darkestChild.brightness + epsilon >= brightestParent.brightness,
            "depth_step_dominates_sibling_variation_\(isDark ? "dark" : "light")_f\(family)_d\(depth)"
          )
        }
      }
    }

    for isDark in [false, true] {
      for role in semanticRoles {
        let reference = StorageColorModel.components(
          index: 0,
          depth: 0,
          seed: 0,
          role: role,
          isDark: isDark
        )
        let varied = StorageColorModel.components(
          index: 11,
          depth: 7,
          seed: UInt64.max,
          role: role,
          isDark: isDark
        )
        try check(
          reference == varied,
          "semantic_color_ignores_hierarchy_\(isDark ? "dark" : "light")_\(role.rawValue)"
        )
      }
    }

    let freeSpace = StorageColorModel.components(
      index: 0,
      depth: 0,
      seed: 0,
      role: .freeSpace,
      isDark: true
    )
    try check(freeSpace.saturation <= 0.11, "free_space_is_neutral")

    let semanticValues = semanticRoles.map {
      StorageColorModel.components(index: 0, depth: 0, seed: 0, role: $0, isDark: true)
    }
    try check(Set(semanticValues).count == semanticValues.count, "semantic_roles_are_distinct")

    var samples: [PaletteSample] = []
    for family in 0..<StorageColorModel.branchFamilyCount {
      for depth in 0...4 {
        samples.append(
          PaletteSample(
            family: family,
            depth: depth,
            role: StorageColorRole.branch.rawValue,
            dark: true,
            components: StorageColorModel.components(
              index: family,
              depth: depth,
              seed: StorageColorModel.stableHash("sample-\(family)-\(depth)"),
              role: .branch,
              isDark: true
            )
          )
        )
      }
    }

    let output = PaletteAuditOutput(
      version: "1.6.8",
      branchFamilies: StorageColorModel.branchFamilyCount,
      assertions: assertions,
      samples: samples
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
