import Foundation
import SwiftUI

private struct ArcDescriptor: Identifiable {
  let id: String
  let item: SunburstItem
  let startDegrees: Double
  let endDegrees: Double
  let depth: Int
  let paletteIndex: Int
  let familyDepth: Int
}

private struct SunburstSector: Shape {
  let startAngle: Angle
  let endAngle: Angle
  let innerRadius: CGFloat
  let outerRadius: CGFloat

  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    var path = Path()
    let outerStart = point(center: center, radius: outerRadius, angle: startAngle)
    let innerEnd = point(center: center, radius: innerRadius, angle: endAngle)

    path.move(to: outerStart)
    path.addArc(
      center: center,
      radius: outerRadius,
      startAngle: startAngle,
      endAngle: endAngle,
      clockwise: false
    )
    path.addLine(to: innerEnd)
    path.addArc(
      center: center,
      radius: innerRadius,
      startAngle: endAngle,
      endAngle: startAngle,
      clockwise: true
    )
    path.closeSubpath()
    return path
  }

  private func point(center: CGPoint, radius: CGFloat, angle: Angle) -> CGPoint {
    CGPoint(
      x: center.x + cos(angle.radians) * radius,
      y: center.y + sin(angle.radians) * radius
    )
  }
}

struct SunburstChart: View {
  let root: SunburstItem
  let onSelect: (SunburstItem) -> Void
  let onRevealInFinder: (String) -> Void
  let onOpenInFinder: (String) -> Void
  let onCopyPath: (String) -> Void

  private let descriptors: [ArcDescriptor]
  private let descriptorsByDepth: [[ArcDescriptor]]
  private let descriptorByID: [String: ArcDescriptor]
  private let maximumDepth: Int

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @State private var hoveredArcID: String?
  @State private var contextArcID: String?
  @State private var hoverLocation: CGPoint?

  init(
    root: SunburstItem,
    onSelect: @escaping (SunburstItem) -> Void,
    onRevealInFinder: @escaping (String) -> Void = { _ in },
    onOpenInFinder: @escaping (String) -> Void = { _ in },
    onCopyPath: @escaping (String) -> Void = { _ in }
  ) {
    self.root = root
    self.onSelect = onSelect
    self.onRevealInFinder = onRevealInFinder
    self.onOpenInFinder = onOpenInFinder
    self.onCopyPath = onCopyPath

    let descriptors = Self.makeArcs(for: root)
    let maximumDepth = max(1, (descriptors.map(\.depth).max() ?? 0) + 1)
    var depthIndex = Array(repeating: [ArcDescriptor](), count: maximumDepth)
    for descriptor in descriptors {
      depthIndex[descriptor.depth].append(descriptor)
    }
    for index in depthIndex.indices {
      depthIndex[index].sort { $0.startDegrees < $1.startDegrees }
    }

    self.descriptors = descriptors
    descriptorsByDepth = depthIndex
    descriptorByID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    self.maximumDepth = maximumDepth
  }

  var body: some View {
    GeometryReader { geometry in
      let side = min(geometry.size.width, geometry.size.height)
      let centerRadius = side * 0.145
      let availableRadius = side * 0.485
      let ringWidth = max(16, (availableRadius - centerRadius) / CGFloat(maximumDepth))
      let hovered = hoveredArcID.flatMap { descriptorByID[$0] }
      let contextTarget = contextArcID.flatMap { descriptorByID[$0] }
      let focusedItem = hovered?.item ?? root

      ZStack(alignment: .topLeading) {
        chartCanvas(
          side: side,
          centerRadius: centerRadius,
          ringWidth: ringWidth
        )

        if let hovered {
          hoverHighlight(
            hovered,
            centerRadius: centerRadius,
            ringWidth: ringWidth
          )
        }

        centerSummary(
          focusedItem,
          centerRadius: centerRadius,
          side: side,
          isHovering: hovered != nil
        )

        if hovered != nil, let hoverLocation {
          ZStack {
            Circle()
              .fill(LensTheme.canvas(colorScheme).opacity(0.92))
              .frame(width: 12, height: 12)
            Circle()
              .fill(LensTheme.accentSoft)
              .frame(width: 6, height: 6)
          }
          .position(hoverLocation)
          .allowsHitTesting(false)
          .zIndex(9)
        }

        if let hovered {
          SunburstHoverCard(item: hovered.item, rootBytes: root.bytes)
            .frame(width: 336)
            .position(
              tooltipPosition(
                forCursor: hoverLocation,
                fallbackArc: hovered,
                side: side,
                centerRadius: centerRadius,
                ringWidth: ringWidth
              )
            )
            .allowsHitTesting(false)
            .zIndex(10)
        }
      }
      .frame(width: side, height: side)
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
          switch phase {
          case .active(let location):
            hoverLocation = location
            let nextID =
              hitTest(
                at: location,
                descriptorsByDepth: descriptorsByDepth,
                side: side,
                centerRadius: centerRadius,
                ringWidth: ringWidth
              )?.id
            if nextID != hoveredArcID { hoveredArcID = nextID }
            if nextID != contextArcID { contextArcID = nextID }
          case .ended:
            hoverLocation = nil
            if hoveredArcID != nil { hoveredArcID = nil }
          }
        }
      }
      .simultaneousGesture(
        SpatialTapGesture().onEnded { value in
          guard
            let hit = hitTest(
              at: value.location,
              descriptorsByDepth: descriptorsByDepth,
              side: side,
              centerRadius: centerRadius,
              ringWidth: ringWidth
            ), hit.item.isInteractive
          else { return }
          onSelect(hit.item)
        }
      )
      .contextMenu {
        if let item = contextTarget?.item {
          if let path = item.finderPath {
            Button {
              onRevealInFinder(path)
            } label: {
              Label(item.finderActionTitle, systemImage: "finder")
            }

            Button {
              onOpenInFinder(path)
            } label: {
              Label(item.finderOpenActionTitle, systemImage: "folder")
            }

            Button {
              onCopyPath(path)
            } label: {
              Label(item.finderCopyActionTitle, systemImage: "doc.on.doc")
            }
          }

          if item.isInteractive {
            if item.finderPath != nil { Divider() }
            Button {
              onSelect(item)
            } label: {
              Label(
                item.kind == .directFiles
                  ? "列出直接檔案"
                  : (item.kind == .otherChildren ? "展開合併項目" : "在資料樹中深入"),
                systemImage: item.kind == .directFiles
                  ? "list.bullet.rectangle"
                  : (item.kind == .otherChildren
                    ? "rectangle.stack.badge.plus" : "arrow.down.right")
              )
            }
          }

          if item.finderPath == nil && !item.isInteractive {
            Button("此項目沒有 Finder 路徑") {}
              .disabled(true)
          }
        } else {
          Button("先把游標移到一個扇區") {}
            .disabled(true)
        }
      }
      .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
    }
    .aspectRatio(1, contentMode: .fit)
    .onChange(of: root.id) { _, _ in
      hoveredArcID = nil
      contextArcID = nil
      hoverLocation = nil
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("磁碟空間放射圖")
    .accessibilityValue("\(root.label)，\(root.bytes.formattedBytes)")
  }

  private func chartCanvas(side: CGFloat, centerRadius: CGFloat, ringWidth: CGFloat) -> some View {
    Canvas(opaque: false, rendersAsynchronously: false) { context, size in
      let rect = CGRect(origin: .zero, size: size)
      let separator = LensTheme.canvas(colorScheme).opacity(colorScheme == .dark ? 0.70 : 0.44)

      for arc in descriptors {
        let path = sectorPath(
          for: arc,
          rect: rect,
          centerRadius: centerRadius,
          ringWidth: ringWidth
        )
        context.fill(path, with: .color(color(for: arc)))
        context.stroke(path, with: .color(separator), lineWidth: 0.52)
      }
    }
    .frame(width: side, height: side)
  }

  private func hoverHighlight(
    _ hovered: ArcDescriptor,
    centerRadius: CGFloat,
    ringWidth: CGFloat
  ) -> some View {
    Canvas(opaque: false, rendersAsynchronously: false) { context, size in
      let path = sectorPath(
        for: hovered,
        rect: CGRect(origin: .zero, size: size),
        centerRadius: centerRadius,
        ringWidth: ringWidth
      )
      context.fill(path, with: .color(Color.white.opacity(colorScheme == .dark ? 0.11 : 0.17)))
      context.stroke(path, with: .color(LensTheme.accentSoft.opacity(0.96)), lineWidth: 2.1)
    }
    .allowsHitTesting(false)
  }

  private func centerSummary(
    _ item: SunburstItem,
    centerRadius: CGFloat,
    side: CGFloat,
    isHovering: Bool
  ) -> some View {
    ZStack {
      Circle()
        .fill(centerStyle)
        .overlay {
          Circle().strokeBorder(LensTheme.stroke(colorScheme, strong: true), lineWidth: 1)
        }
        .shadow(color: LensTheme.shadow(colorScheme), radius: 18, y: 8)

      VStack(spacing: 7) {
        Image(systemName: symbol(for: item))
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(LensTheme.accentSoft)
          .frame(width: 27, height: 27)
          .background(LensTheme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))

        Text(item.bytes.formattedBytes)
          .font(.system(size: max(17, side * 0.039), weight: .semibold))
          .tracking(-0.35)
          .monospacedDigit()

        Text(item.label)
          .font(.caption.weight(.medium))
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)

        if isHovering, item.isInteractive {
          Text(
            item.kind == .directFiles
              ? "點一下檢視檔案"
              : (item.kind == .otherChildren ? "點一下展開" : "點一下深入")
          )
          .font(.caption2.weight(.semibold))
          .foregroundStyle(LensTheme.accentSoft)
        }
      }
      .padding(12)
      .frame(width: centerRadius * 1.68)
    }
    .frame(width: centerRadius * 1.86, height: centerRadius * 1.86)
    .position(x: side / 2, y: side / 2)
    .allowsHitTesting(false)
  }

  private var centerStyle: AnyShapeStyle {
    reduceTransparency
      ? AnyShapeStyle(LensTheme.elevatedPanel(colorScheme))
      : AnyShapeStyle(.thickMaterial)
  }

  private static func makeArcs(for root: SunburstItem) -> [ArcDescriptor] {
    var result: [ArcDescriptor] = []
    layout(
      items: root.children,
      start: -90,
      end: 270,
      depth: 0,
      inheritedPaletteIndex: nil,
      familyDepth: 0,
      result: &result
    )
    return result
  }

  private static func layout(
    items: [SunburstItem],
    start: Double,
    end: Double,
    depth: Int,
    inheritedPaletteIndex: Int?,
    familyDepth: Int,
    result: inout [ArcDescriptor]
  ) {
    let total = max(1, items.reduce(Int64(0)) { $0 + max(0, $1.bytes) })
    var cursor = start

    for (siblingIndex, item) in items.enumerated() where item.bytes > 0 {
      let span = (end - start) * Double(item.bytes) / Double(total)
      let itemEnd = cursor + span
      let paletteIndex = inheritedPaletteIndex ?? siblingIndex
      let descriptor = ArcDescriptor(
        id: "\(item.id)#\(depth)#\(result.count)",
        item: item,
        startDegrees: cursor,
        endDegrees: itemEnd,
        depth: depth,
        paletteIndex: paletteIndex,
        familyDepth: inheritedPaletteIndex == nil ? 0 : familyDepth
      )
      result.append(descriptor)

      if !item.children.isEmpty, span >= 0.35 {
        let resetFamily = item.colorHint == .mappedTree
        layout(
          items: item.children,
          start: cursor,
          end: itemEnd,
          depth: depth + 1,
          inheritedPaletteIndex: resetFamily ? nil : paletteIndex,
          familyDepth: resetFamily ? 0 : descriptor.familyDepth + 1,
          result: &result
        )
      }

      cursor = itemEnd
    }
  }

  private func sectorPath(
    for arc: ArcDescriptor,
    rect: CGRect,
    centerRadius: CGFloat,
    ringWidth: CGFloat
  ) -> Path {
    let inner = centerRadius + CGFloat(arc.depth) * ringWidth + 0.38
    let outer = centerRadius + CGFloat(arc.depth + 1) * ringWidth - 0.38
    let span = max(0, arc.endDegrees - arc.startDegrees)
    let angularInset = min(0.24, max(0.012, span * 0.016))
    let start = min(arc.endDegrees, arc.startDegrees + angularInset)
    let end = max(start, arc.endDegrees - angularInset)

    return SunburstSector(
      startAngle: .degrees(start),
      endAngle: .degrees(end),
      innerRadius: inner,
      outerRadius: outer
    ).path(in: rect)
  }

  private func hitTest(
    at location: CGPoint,
    descriptorsByDepth: [[ArcDescriptor]],
    side: CGFloat,
    centerRadius: CGFloat,
    ringWidth: CGFloat
  ) -> ArcDescriptor? {
    let center = CGPoint(x: side / 2, y: side / 2)
    let dx = location.x - center.x
    let dy = location.y - center.y
    let radius = hypot(dx, dy)
    let outerLimit = centerRadius + CGFloat(descriptorsByDepth.count) * ringWidth
    guard radius >= centerRadius, radius <= outerLimit else { return nil }

    let depth = Int(floor((radius - centerRadius) / ringWidth))
    guard descriptorsByDepth.indices.contains(depth) else { return nil }

    var degrees = atan2(Double(dy), Double(dx)) * 180 / Double.pi
    if degrees < -90 { degrees += 360 }

    let candidates = descriptorsByDepth[depth]
    var lowerBound = 0
    var upperBound = candidates.count - 1
    while lowerBound <= upperBound {
      let middle = lowerBound + (upperBound - lowerBound) / 2
      let candidate = candidates[middle]
      if degrees < candidate.startDegrees {
        upperBound = middle - 1
      } else if degrees >= candidate.endDegrees {
        lowerBound = middle + 1
      } else {
        return candidate
      }
    }
    return nil
  }

  private func color(for arc: ArcDescriptor) -> Color {
    StoragePalette.color(
      index: arc.paletteIndex,
      familyDepth: arc.familyDepth,
      seed: StorageColorModel.stableHash(arc.item.id),
      kind: arc.item.kind,
      colorHint: arc.item.colorHint,
      colorScheme: colorScheme
    )
  }

  private func tooltipPosition(
    forCursor cursor: CGPoint?,
    fallbackArc arc: ArcDescriptor,
    side: CGFloat,
    centerRadius: CGFloat,
    ringWidth: CGFloat
  ) -> CGPoint {
    let width: CGFloat = 336
    let height: CGFloat = 170
    let margin: CGFloat = 10
    let horizontalOffset: CGFloat = 18
    let verticalOffset: CGFloat = 16

    let anchor: CGPoint
    if let cursor {
      anchor = cursor
    } else {
      let midpoint = (arc.startDegrees + arc.endDegrees) / 2 * Double.pi / 180
      let radius = centerRadius + (CGFloat(arc.depth) + 0.54) * ringWidth
      anchor = CGPoint(
        x: side / 2 + CGFloat(cos(midpoint)) * radius,
        y: side / 2 + CGFloat(sin(midpoint)) * radius
      )
    }

    // Preferred placement is the pointer's upper-right so the card never covers
    // the exact sector under the cursor. Near an edge, flip only the axis that
    // would otherwise leave the chart bounds.
    let hasRoomOnRight = anchor.x + horizontalOffset + width <= side - margin
    let hasRoomAbove = anchor.y - verticalOffset - height >= margin

    var x =
      anchor.x + (hasRoomOnRight ? horizontalOffset + width / 2 : -horizontalOffset - width / 2)
    var y = anchor.y + (hasRoomAbove ? -verticalOffset - height / 2 : verticalOffset + height / 2)

    x = min(max(width / 2 + margin, x), side - width / 2 - margin)
    y = min(max(height / 2 + margin, y), side - height / 2 - margin)
    return CGPoint(x: x, y: y)
  }

  private func symbol(for item: SunburstItem) -> String {
    switch item.kind {
    case .accountingGap: return "questionmark.folder.fill"
    case .containerAccounting: return "shippingbox.fill"
    case .scanDelta: return "clock.arrow.2.circlepath"
    case .freeSpace: return "square.dashed"
    case .purgeable: return "arrow.triangle.2.circlepath"
    case .otherVolume: return "externaldrive.fill"
    case .directFiles: return "doc.fill"
    case .otherChildren: return "ellipsis.circle.fill"
    case .none: return item.path == nil ? "internaldrive.fill" : "folder.fill"
    }
  }
}

private struct SunburstHoverCard: View {
  let item: SunburstItem
  let rootBytes: Int64

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 9) {
        Image(systemName: symbol)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(LensTheme.accentSoft)
          .frame(width: 27, height: 27)
          .background(LensTheme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))

        VStack(alignment: .leading, spacing: 1) {
          Text(item.label)
            .font(.headline)
            .lineLimit(1)
          Text(interactionHint)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      Text(pathDescription)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .truncationMode(.middle)

      HStack(alignment: .firstTextBaseline) {
        Text(item.bytes.formattedBytes)
          .font(.title3.weight(.semibold))
          .monospacedDigit()
        Spacer()
        Text(percentageText)
          .font(.caption.weight(.semibold))
          .foregroundStyle(LensTheme.accentSoft)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(LensTheme.accent.opacity(0.12), in: Capsule())
      }
    }
    .padding(13)
    .background {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(
          reduceTransparency
            ? AnyShapeStyle(LensTheme.elevatedPanel(colorScheme))
            : AnyShapeStyle(.thickMaterial))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(LensTheme.stroke(colorScheme, strong: true), lineWidth: 1)
    }
    .shadow(color: LensTheme.shadow(colorScheme), radius: 18, y: 8)
  }

  private var interactionHint: String {
    if item.kind == .otherChildren {
      return "點一下展開完整項目 · 右鍵可顯示父資料夾"
    }
    if item.isNavigable {
      return "點一下深入 · 右鍵可在 Finder 顯示"
    }
    if item.kind == .directFiles {
      return "點一下列出檔案 · 右鍵可顯示父資料夾"
    }
    if item.finderPath != nil {
      return "右鍵可在 Finder 顯示"
    }
    return "帳務或合併節點"
  }

  private var percentageText: String {
    guard rootBytes > 0 else { return "—" }
    let percentage = Double(item.bytes) / Double(rootBytes) * 100
    return String(format: "%.1f%%", percentage)
  }

  private var symbol: String {
    switch item.kind {
    case .accountingGap: return "questionmark.folder.fill"
    case .containerAccounting: return "shippingbox.fill"
    case .scanDelta: return "clock.arrow.2.circlepath"
    case .freeSpace: return "square.dashed"
    case .purgeable: return "arrow.triangle.2.circlepath"
    case .otherVolume: return "externaldrive.fill"
    case .directFiles: return "doc.fill"
    case .otherChildren: return "ellipsis.circle.fill"
    case .none: return "folder.fill"
    }
  }

  private var pathDescription: String {
    if item.kind == .directFiles, let path = item.path {
      return "直接位於：\(path)"
    }
    if let path = item.path { return path }
    switch item.kind {
    case .accountingGap:
      return item.label.contains("卷宗中繼資料")
        ? "沒有單一 Finder 路徑（卷宗垃圾桶／Spotlight／FSEvents 等未展開帳務）"
        : "沒有單一 Finder 路徑（不可讀／快照／APFS 帳務差額）"
    case .containerAccounting:
      return "沒有單一 Finder 路徑（APFS 容器 metadata／帳務）"
    case .scanDelta:
      return "不同取樣時點造成的容量變化；不是可直接清理的路徑"
    case .freeSpace:
      return "沒有檔案路徑（真正空閒空間）"
    case .purgeable:
      return "沒有固定路徑（macOS 可回收容量估計）"
    case .otherVolume:
      return "獨立 APFS 卷或容器帳務項目"
    case .directFiles:
      return "此資料夾內未歸入子資料夾的檔案"
    case .otherChildren:
      return "僅在同層項目極多時合併；點一下可展開完整清單"
    case .none:
      return "沒有一般檔案路徑"
    }
  }
}
