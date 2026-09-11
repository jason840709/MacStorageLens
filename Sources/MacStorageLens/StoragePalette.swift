import AppKit
import SwiftUI

enum StoragePalette {
  static func accountingGap(colorScheme: ColorScheme) -> Color {
    color(
      index: 0,
      familyDepth: 0,
      seed: 0,
      kind: .accountingGap,
      colorHint: nil,
      colorScheme: colorScheme
    )
  }

  static func visibleData(colorScheme: ColorScheme) -> Color {
    color(
      index: 0,
      familyDepth: 0,
      seed: StorageColorModel.stableHash("visible-data"),
      kind: nil,
      colorHint: nil,
      colorScheme: colorScheme
    )
  }

  static func color(
    index: Int,
    familyDepth: Int,
    seed: UInt64,
    kind: VirtualNodeKind?,
    colorHint: SunburstColorHint? = nil,
    colorScheme: ColorScheme
  ) -> Color {
    let role = role(for: kind, colorHint: colorHint)
    let components = StorageColorModel.components(
      index: index,
      depth: familyDepth,
      seed: seed,
      role: role,
      isDark: colorScheme == .dark
    )
    return Color(
      nsColor: NSColor(
        deviceHue: CGFloat(components.hue),
        saturation: CGFloat(components.saturation),
        brightness: CGFloat(components.brightness),
        alpha: 1
      ))
  }

  static func branchColor(
    index: Int,
    familyDepth: Int,
    seed: UInt64,
    colorScheme: ColorScheme
  ) -> Color {
    color(
      index: index,
      familyDepth: familyDepth,
      seed: seed,
      kind: nil,
      colorHint: nil,
      colorScheme: colorScheme
    )
  }

  static func topLevelColor(
    index: Int,
    itemID: String,
    kind: VirtualNodeKind?,
    colorHint: SunburstColorHint? = nil,
    colorScheme: ColorScheme
  ) -> Color {
    color(
      index: index,
      familyDepth: 0,
      seed: StorageColorModel.stableHash(itemID),
      kind: kind,
      colorHint: colorHint,
      colorScheme: colorScheme
    )
  }

  private static func role(
    for kind: VirtualNodeKind?,
    colorHint: SunburstColorHint?
  ) -> StorageColorRole {
    switch colorHint {
    case .selectedVolume: return .selectedVolume
    case .mappedTree: return .mappedTree
    case .none: break
    }

    switch kind {
    case .accountingGap: return .accountingGap
    case .containerAccounting: return .containerAccounting
    case .scanDelta: return .scanDelta
    case .freeSpace: return .freeSpace
    case .purgeable: return .purgeable
    case .directFiles: return .directFiles
    case .otherChildren: return .otherChildren
    case .otherVolume: return .otherVolume
    case .none: return .branch
    }
  }
}
