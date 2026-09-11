import Foundation

struct StorageColorComponents: Codable, Equatable, Hashable {
  let hue: Double
  let saturation: Double
  let brightness: Double
}

enum StorageColorRole: String, CaseIterable, Codable, Hashable {
  case branch
  case directFiles
  case otherChildren
  case otherVolume
  case selectedVolume
  case mappedTree
  case accountingGap
  case containerAccounting
  case scanDelta
  case freeSpace
  case purgeable
}

enum StorageColorModel {
  private struct BranchAnchor {
    let hue: Double
    let saturation: Double
    let darkBrightness: Double
    let lightBrightness: Double
  }

  // Curated, low-saturation categorical families. The order is deliberate:
  // the largest folders in a normal Data tree usually receive sage, mist blue,
  // sand, plum and rose instead of repeating the structural Data-volume blue.
  // Descendants retain the branch hue and gain visibly more luminance by depth.
  private static let branchAnchors: [BranchAnchor] = [
    BranchAnchor(hue: 0.405, saturation: 0.30, darkBrightness: 0.58, lightBrightness: 0.52),
    BranchAnchor(hue: 0.598, saturation: 0.31, darkBrightness: 0.60, lightBrightness: 0.53),
    BranchAnchor(hue: 0.105, saturation: 0.31, darkBrightness: 0.60, lightBrightness: 0.54),
    BranchAnchor(hue: 0.760, saturation: 0.27, darkBrightness: 0.59, lightBrightness: 0.52),
    BranchAnchor(hue: 0.985, saturation: 0.26, darkBrightness: 0.60, lightBrightness: 0.53),
    BranchAnchor(hue: 0.515, saturation: 0.29, darkBrightness: 0.58, lightBrightness: 0.51),
    BranchAnchor(hue: 0.205, saturation: 0.27, darkBrightness: 0.59, lightBrightness: 0.52),
    BranchAnchor(hue: 0.665, saturation: 0.28, darkBrightness: 0.59, lightBrightness: 0.52),
    BranchAnchor(hue: 0.290, saturation: 0.26, darkBrightness: 0.58, lightBrightness: 0.51),
    BranchAnchor(hue: 0.880, saturation: 0.24, darkBrightness: 0.59, lightBrightness: 0.52),
    BranchAnchor(hue: 0.555, saturation: 0.24, darkBrightness: 0.59, lightBrightness: 0.52),
    BranchAnchor(hue: 0.070, saturation: 0.22, darkBrightness: 0.59, lightBrightness: 0.53),
  ]

  static var branchFamilyCount: Int { branchAnchors.count }

  static func stableHash(_ text: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return hash
  }

  static func components(
    index: Int,
    depth: Int,
    seed: UInt64,
    role: StorageColorRole,
    isDark: Bool
  ) -> StorageColorComponents {
    if let semantic = semanticComponents(for: role, isDark: isDark) {
      return semantic
    }

    let anchor = branchAnchors[positiveModulo(index, branchAnchors.count)]
    let normalizedDepth = Double(max(0, depth))

    // Sibling variation is deliberately tiny. Branch identity comes from hue;
    // hierarchy comes from a much larger, monotonic luminance step.
    let siblingLift = Double(seed % 4) * 0.002
    let roleBrightnessLift: Double
    let roleSaturationDrop: Double
    switch role {
    case .directFiles:
      roleBrightnessLift = 0.016
      roleSaturationDrop = 0.020
    case .otherChildren:
      roleBrightnessLift = 0.028
      roleSaturationDrop = 0.040
    case .otherVolume:
      roleBrightnessLift = 0.006
      roleSaturationDrop = 0.025
    default:
      roleBrightnessLift = 0
      roleSaturationDrop = 0
    }

    let baseBrightness = isDark ? anchor.darkBrightness : anchor.lightBrightness
    let depthStep = isDark ? 0.070 : 0.058
    let brightness = clamp(
      baseBrightness + normalizedDepth * depthStep + siblingLift + roleBrightnessLift,
      lower: isDark ? 0.54 : 0.47,
      upper: isDark ? 0.88 : 0.80
    )

    let saturation = clamp(
      anchor.saturation - normalizedDepth * 0.014 - roleSaturationDrop,
      lower: 0.16,
      upper: 0.32
    )

    return StorageColorComponents(
      hue: anchor.hue,
      saturation: saturation,
      brightness: brightness
    )
  }

  static func isSemantic(_ role: StorageColorRole) -> Bool {
    switch role {
    case .selectedVolume, .mappedTree, .accountingGap, .containerAccounting, .scanDelta,
      .freeSpace, .purgeable:
      return true
    case .branch, .directFiles, .otherChildren, .otherVolume:
      return false
    }
  }

  private static func semanticComponents(
    for role: StorageColorRole,
    isDark: Bool
  ) -> StorageColorComponents? {
    switch role {
    case .selectedVolume:
      // Structural Data/APFS volume: stable mist blue, distinct from folder families.
      return StorageColorComponents(
        hue: 0.602,
        saturation: 0.20,
        brightness: isDark ? 0.61 : 0.56
      )
    case .mappedTree:
      // A quiet bridge between capacity accounting and the categorical folder tree.
      return StorageColorComponents(
        hue: 0.602,
        saturation: 0.13,
        brightness: isDark ? 0.69 : 0.63
      )
    case .accountingGap:
      return StorageColorComponents(
        hue: 0.860,
        saturation: 0.22,
        brightness: isDark ? 0.62 : 0.58
      )
    case .containerAccounting:
      return StorageColorComponents(
        hue: 0.090,
        saturation: 0.14,
        brightness: isDark ? 0.56 : 0.60
      )
    case .scanDelta:
      return StorageColorComponents(
        hue: 0.110,
        saturation: 0.23,
        brightness: isDark ? 0.66 : 0.63
      )
    case .freeSpace:
      return StorageColorComponents(
        hue: 0.600,
        saturation: 0.09,
        brightness: isDark ? 0.43 : 0.65
      )
    case .purgeable:
      return StorageColorComponents(
        hue: 0.440,
        saturation: 0.19,
        brightness: isDark ? 0.61 : 0.59
      )
    case .branch, .directFiles, .otherChildren, .otherVolume:
      return nil
    }
  }

  private static func positiveModulo(_ value: Int, _ divisor: Int) -> Int {
    guard divisor > 0 else { return 0 }
    let remainder = value % divisor
    return remainder >= 0 ? remainder : remainder + divisor
  }

  private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
    min(upper, max(lower, value))
  }
}
