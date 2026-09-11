import AppKit
import SwiftUI

enum LensTheme {
  static let accent = Color(lensHex: "#8192B8")
  static let accentDeep = Color(lensHex: "#687AA4")
  static let accentSoft = Color(lensHex: "#AAB6D0")
  static let sage = Color(lensHex: "#81988F")
  static let sand = Color(lensHex: "#B09A75")
  static let plum = Color(lensHex: "#927E96")
  static let clay = Color(lensHex: "#AA8581")
  static let slate = Color(lensHex: "#727C8D")

  static func canvas(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(lensHex: "#101218") : Color(lensHex: "#F2F4F7")
  }

  static func sidebar(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(lensHex: "#151820") : Color(lensHex: "#E9EDF2")
  }

  static func panel(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(lensHex: "#191C24") : Color(lensHex: "#FCFDFE")
  }

  static func elevatedPanel(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(lensHex: "#1E222C") : Color.white
  }

  static func recessed(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.035)
  }

  static func stroke(_ scheme: ColorScheme, strong: Bool = false) -> Color {
    if scheme == .dark {
      return Color.white.opacity(strong ? 0.14 : 0.085)
    }
    return Color.black.opacity(strong ? 0.13 : 0.075)
  }

  static func shadow(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.black.opacity(0.34) : Color.black.opacity(0.10)
  }

  static func mutedText(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.white.opacity(0.62) : Color.black.opacity(0.58)
  }

  static func faintText(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.white.opacity(0.42) : Color.black.opacity(0.42)
  }

  static func selectedNavigation(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? accent.opacity(0.20) : accent.opacity(0.16)
  }

  static func hoveredNavigation(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.045)
  }
}

enum LensMotion {
  static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)
  static let hover = Animation.easeOut(duration: 0.10)
  static let reveal = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.20)
  static let phase = Animation.spring(response: 0.26, dampingFraction: 1.0)
}

struct LensBackdrop: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    ZStack {
      LensTheme.canvas(colorScheme)

      if !reduceTransparency {
        RadialGradient(
          colors: [LensTheme.accent.opacity(colorScheme == .dark ? 0.15 : 0.11), .clear],
          center: UnitPoint(x: 0.82, y: 0.02),
          startRadius: 8,
          endRadius: 560
        )

        RadialGradient(
          colors: [LensTheme.sage.opacity(colorScheme == .dark ? 0.09 : 0.07), .clear],
          center: UnitPoint(x: 0.06, y: 0.92),
          startRadius: 20,
          endRadius: 480
        )
      }
    }
    .ignoresSafeArea()
  }
}

struct LensPanel<Content: View>: View {
  private let content: Content
  private let padding: CGFloat
  private let radius: CGFloat
  private let elevated: Bool

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  init(
    padding: CGFloat = 18,
    radius: CGFloat = 18,
    elevated: Bool = false,
    @ViewBuilder content: () -> Content
  ) {
    self.content = content()
    self.padding = padding
    self.radius = radius
    self.elevated = elevated
  }

  var body: some View {
    content
      .padding(padding)
      .background {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(panelStyle)
      }
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(LensTheme.stroke(colorScheme, strong: elevated), lineWidth: 1)
      }
      .shadow(
        color: elevated ? LensTheme.shadow(colorScheme) : .clear,
        radius: elevated ? 24 : 0,
        y: elevated ? 10 : 0
      )
  }

  private var panelStyle: AnyShapeStyle {
    if reduceTransparency {
      return AnyShapeStyle(
        elevated ? LensTheme.elevatedPanel(colorScheme) : LensTheme.panel(colorScheme))
    }
    return AnyShapeStyle(elevated ? .thickMaterial : .regularMaterial)
  }
}

enum LensButtonKind: Equatable {
  case primary
  case secondary
  case quiet
  case destructive
}

struct LensButtonStyle: ButtonStyle {
  let kind: LensButtonKind
  var compact = false

  func makeBody(configuration: Configuration) -> some View {
    LensButtonStyleBody(
      label: configuration.label,
      isPressed: configuration.isPressed,
      kind: kind,
      compact: compact
    )
  }
}

private struct LensButtonStyleBody<Label: View>: View {
  let label: Label
  let isPressed: Bool
  let kind: LensButtonKind
  let compact: Bool

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  var body: some View {
    label
      .font(.callout.weight(.semibold))
      .foregroundStyle(foreground)
      .padding(.horizontal, compact ? 11 : 14)
      .padding(.vertical, compact ? 7 : 9)
      .background {
        RoundedRectangle(cornerRadius: compact ? 9 : 11, style: .continuous)
          .fill(background)
          .brightness(isHovered && isEnabled && kind != .quiet ? 0.035 : 0)
      }
      .overlay {
        RoundedRectangle(cornerRadius: compact ? 9 : 11, style: .continuous)
          .strokeBorder(border, lineWidth: 1)
      }
      .shadow(
        color: isHovered && isEnabled && (kind == .primary || kind == .destructive)
          ? LensTheme.shadow(colorScheme).opacity(0.48) : .clear,
        radius: 7,
        y: 2
      )
      .scaleEffect(isPressed && !reduceMotion ? 0.975 : 1)
      .opacity(isEnabled ? (isPressed ? 0.92 : 1) : 0.46)
      .contentShape(RoundedRectangle(cornerRadius: compact ? 9 : 11, style: .continuous))
      .onHover { isHovered = $0 }
      .animation(reduceMotion ? nil : LensMotion.hover, value: isHovered)
      .animation(reduceMotion ? nil : LensMotion.press, value: isPressed)
  }

  private var foreground: Color {
    switch kind {
    case .primary, .destructive:
      return .white
    case .secondary, .quiet:
      return isHovered && isEnabled ? LensTheme.accentSoft : .primary
    }
  }

  private var background: AnyShapeStyle {
    switch kind {
    case .primary:
      return AnyShapeStyle(
        LinearGradient(
          colors: [LensTheme.accent, LensTheme.accentDeep],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ))
    case .secondary:
      return AnyShapeStyle(
        isHovered && isEnabled
          ? LensTheme.hoveredNavigation(colorScheme)
          : LensTheme.recessed(colorScheme))
    case .quiet:
      return AnyShapeStyle(
        isHovered && isEnabled ? LensTheme.hoveredNavigation(colorScheme) : Color.clear)
    case .destructive:
      return AnyShapeStyle(
        LinearGradient(
          colors: [Color(lensHex: "#B86C6C"), Color(lensHex: "#955858")],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        ))
    }
  }

  private var border: Color {
    switch kind {
    case .primary, .destructive:
      return Color.white.opacity(isHovered && isEnabled ? 0.28 : 0.16)
    case .secondary:
      return isHovered && isEnabled
        ? LensTheme.accent.opacity(0.42)
        : LensTheme.stroke(colorScheme, strong: true)
    case .quiet:
      return isHovered && isEnabled ? LensTheme.stroke(colorScheme, strong: true) : .clear
    }
  }
}

struct LensIconButtonStyle: ButtonStyle {
  var prominent = false

  func makeBody(configuration: Configuration) -> some View {
    LensIconButtonStyleBody(
      label: configuration.label,
      isPressed: configuration.isPressed,
      prominent: prominent
    )
  }
}

private struct LensIconButtonStyleBody<Label: View>: View {
  let label: Label
  let isPressed: Bool
  let prominent: Bool

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  var body: some View {
    label
      .font(.system(size: 13, weight: .semibold))
      .frame(width: 31, height: 31)
      .foregroundStyle(
        prominent ? Color.white : (isHovered && isEnabled ? LensTheme.accentSoft : Color.primary)
      )
      .background {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(background)
          .brightness(isHovered && isEnabled && prominent ? 0.04 : 0)
      }
      .overlay {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(border, lineWidth: 1)
      }
      .scaleEffect(isPressed && !reduceMotion ? 0.96 : 1)
      .opacity(isEnabled ? (isPressed ? 0.90 : 1) : 0.42)
      .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
      .onHover { isHovered = $0 }
      .animation(reduceMotion ? nil : LensMotion.hover, value: isHovered)
      .animation(reduceMotion ? nil : LensMotion.press, value: isPressed)
  }

  private var background: AnyShapeStyle {
    if prominent {
      return AnyShapeStyle(LensTheme.accent)
    }
    return AnyShapeStyle(
      isHovered && isEnabled
        ? LensTheme.hoveredNavigation(colorScheme)
        : LensTheme.recessed(colorScheme))
  }

  private var border: Color {
    if prominent {
      return Color.white.opacity(isHovered && isEnabled ? 0.28 : 0.16)
    }
    return isHovered && isEnabled
      ? LensTheme.accent.opacity(0.42)
      : LensTheme.stroke(colorScheme)
  }
}

struct LensMenuControlLabel: View {
  let caption: String
  let title: String
  let symbol: String
  var tint: Color = LensTheme.accentSoft
  var compact = false

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: compact ? 8 : 10) {
      Image(systemName: symbol)
        .font(.system(size: compact ? 12 : 13, weight: .semibold))
        .foregroundStyle(isHovered ? tint : Color.secondary)
        .frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
        .background(tint.opacity(isHovered ? 0.17 : 0.10), in: RoundedRectangle(cornerRadius: 8))

      VStack(alignment: .leading, spacing: 1) {
        Text(caption)
          .font(.system(size: compact ? 9 : 10, weight: .semibold))
          .foregroundStyle(.secondary)
        Text(title)
          .font(.system(size: compact ? 11 : 12, weight: .semibold))
          .foregroundStyle(isHovered ? Color.primary : Color.primary.opacity(0.90))
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer(minLength: compact ? 2 : 5)

      Image(systemName: "chevron.up.chevron.down")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(isHovered ? tint : Color.secondary.opacity(0.55))
    }
    .padding(.horizontal, compact ? 9 : 11)
    .padding(.vertical, compact ? 6 : 7)
    .frame(
      minWidth: compact ? 132 : 168,
      idealWidth: compact ? 152 : 196,
      maxWidth: compact ? 180 : 232,
      alignment: .leading
    )
    .background(
      isHovered ? LensTheme.hoveredNavigation(colorScheme) : LensTheme.recessed(colorScheme),
      in: RoundedRectangle(cornerRadius: compact ? 9 : 11, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: compact ? 9 : 11, style: .continuous)
        .strokeBorder(
          isHovered ? tint.opacity(0.40) : LensTheme.stroke(colorScheme),
          lineWidth: 1
        )
    }
    .contentShape(RoundedRectangle(cornerRadius: compact ? 9 : 11, style: .continuous))
    .onHover { isHovered = $0 }
    .animation(reduceMotion ? nil : LensMotion.hover, value: isHovered)
  }
}

struct LensPageHeader<Actions: View>: View {
  let eyebrow: String
  let title: String
  let subtitle: String
  private let actions: Actions

  init(
    eyebrow: String,
    title: String,
    subtitle: String,
    @ViewBuilder actions: () -> Actions
  ) {
    self.eyebrow = eyebrow
    self.title = title
    self.subtitle = subtitle
    self.actions = actions()
  }

  var body: some View {
    HStack(alignment: .bottom, spacing: 24) {
      VStack(alignment: .leading, spacing: 7) {
        Text(eyebrow.uppercased())
          .font(.caption2.weight(.bold))
          .tracking(1.15)
          .foregroundStyle(LensTheme.accentSoft)

        Text(title)
          .font(.system(size: 31, weight: .semibold))
          .tracking(-0.5)

        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 16)
      actions
    }
  }
}

extension LensPageHeader where Actions == EmptyView {
  init(eyebrow: String, title: String, subtitle: String) {
    self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
  }
}

struct LensMark: View {
  var size: CGFloat = 34

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        .fill(
          LinearGradient(
            colors: [Color(lensHex: "#AFBBD2"), Color(lensHex: "#697A9E")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ))

      Circle()
        .fill(Color(lensHex: "#273044").opacity(0.22))
        .padding(size * 0.17)

      // A complete base ring keeps the mark visually closed at every size.
      Circle()
        .stroke(Color.white.opacity(0.82), lineWidth: max(1.4, size * 0.055))
        .padding(size * 0.23)

      Circle()
        .trim(from: 0.03, to: 0.20)
        .stroke(
          LensTheme.sand.opacity(0.95),
          style: StrokeStyle(lineWidth: max(1.8, size * 0.085), lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
        .padding(size * 0.13)

      Circle()
        .trim(from: 0.28, to: 0.47)
        .stroke(
          LensTheme.sage.opacity(0.96),
          style: StrokeStyle(lineWidth: max(1.8, size * 0.085), lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
        .padding(size * 0.13)

      Circle()
        .trim(from: 0.55, to: 0.72)
        .stroke(
          LensTheme.plum.opacity(0.95),
          style: StrokeStyle(lineWidth: max(1.8, size * 0.085), lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
        .padding(size * 0.13)

      Circle()
        .trim(from: 0.80, to: 0.96)
        .stroke(
          LensTheme.clay.opacity(0.94),
          style: StrokeStyle(lineWidth: max(1.8, size * 0.085), lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
        .padding(size * 0.13)

      Circle()
        .fill(Color.white.opacity(0.95))
        .frame(width: size * 0.19, height: size * 0.19)
        .overlay {
          Circle()
            .fill(LensTheme.accentDeep.opacity(0.72))
            .frame(width: size * 0.075, height: size * 0.075)
        }
    }
    .frame(width: size, height: size)
    .overlay {
      RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
    }
    .accessibilityHidden(true)
  }
}

struct LensStatusBadge: View {
  let title: String
  let symbol: String
  let tint: Color

  var body: some View {
    Label(title, systemImage: symbol)
      .font(.caption.weight(.semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(tint.opacity(0.12), in: Capsule())
      .overlay {
        Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 1)
      }
  }
}

struct LensHoverTip: View {
  let title: String
  let detail: String
  var value: String? = nil
  var tint: Color = LensTheme.accentSoft

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(tint)
        .frame(width: 5, height: 34)

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(title)
            .font(.caption.weight(.semibold))
          if let value {
            Spacer(minLength: 8)
            Text(value)
              .font(.caption.weight(.semibold).monospacedDigit())
              .foregroundStyle(tint)
          }
        }

        Text(detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .background {
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .fill(
          reduceTransparency
            ? AnyShapeStyle(LensTheme.elevatedPanel(colorScheme))
            : AnyShapeStyle(.thickMaterial)
        )
    }
    .overlay {
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .strokeBorder(LensTheme.stroke(colorScheme, strong: true), lineWidth: 1)
    }
    .shadow(color: LensTheme.shadow(colorScheme), radius: 14, y: 6)
    .allowsHitTesting(false)
  }
}

private struct LensHoverHelpModifier: ViewModifier {
  let title: String
  let detail: String
  let value: String?
  let tint: Color
  let placement: LensHoverHelpPlacement

  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .onHover { isHovered = $0 }
      .overlay(alignment: placement.alignment) {
        if isHovered {
          LensHoverTip(title: title, detail: detail, value: value, tint: tint)
            .frame(width: 250)
            .offset(x: placement.offset.width, y: placement.offset.height)
            .zIndex(50)
        }
      }
      .zIndex(isHovered ? 50 : 0)
      .accessibilityHint(Text(detail))
  }
}

enum LensHoverHelpPlacement {
  case above
  case belowTrailing

  fileprivate var alignment: Alignment {
    switch self {
    case .above: return .top
    case .belowTrailing: return .bottomTrailing
    }
  }

  fileprivate var offset: CGSize {
    switch self {
    case .above: return CGSize(width: 0, height: -76)
    case .belowTrailing: return CGSize(width: 0, height: 68)
    }
  }
}

extension View {
  func lensHoverHelp(
    title: String,
    detail: String,
    value: String? = nil,
    tint: Color = LensTheme.accentSoft,
    placement: LensHoverHelpPlacement = .above
  ) -> some View {
    modifier(
      LensHoverHelpModifier(
        title: title,
        detail: detail,
        value: value,
        tint: tint,
        placement: placement
      )
    )
  }
}

struct LensBarSegment: Identifiable {
  let id: String
  let title: String
  let value: Int64
  let color: Color
  let detail: String
}

struct LensSegmentedBar: View {
  let segments: [LensBarSegment]
  let total: Int64
  var height: CGFloat = 14
  var accessibilityTitle: String = "容量組成"

  @Environment(\.colorScheme) private var colorScheme
  @State private var hoveredID: String?
  @State private var hoverLocation: CGPoint?

  var body: some View {
    GeometryReader { proxy in
      let safeTotal = max(Int64(1), total)
      let trackHeight = max(1, height - Self.trackPadding * 2)
      let segmentLookup = segments.reduce(into: [String: LensBarSegment]()) {
        $0[$1.id] = $1
      }
      let frames = SegmentedBarLayout.frames(
        values: segments.map { SegmentedBarLayoutValue(id: $0.id, value: $0.value) },
        width: Double(proxy.size.width),
        total: safeTotal,
        padding: Double(Self.trackPadding),
        gap: Double(Self.segmentGap)
      )
      let tooltipWidth = min(270, max(210, proxy.size.width * 0.56))
      let hovered = hoveredID.flatMap { segmentLookup[$0] }

      HStack(spacing: Self.segmentGap) {
        ForEach(frames) { frame in
          if let segment = segmentLookup[frame.id] {
            Capsule()
              .fill(segment.color)
              .brightness(hoveredID == frame.id ? 0.07 : 0)
              .opacity(hoveredID == nil || hoveredID == frame.id ? 1 : 0.78)
              .frame(width: CGFloat(frame.width), height: trackHeight)
          }
        }
      }
      .padding(.horizontal, Self.trackPadding)
      .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
      .background(LensTheme.recessed(colorScheme), in: Capsule())
      .clipShape(Capsule())
      .contentShape(Rectangle())
      .overlay(alignment: .topLeading) {
        if let hovered, let hoverLocation {
          LensHoverTip(
            title: hovered.title,
            detail: hovered.detail,
            value: hovered.value.formattedBytes,
            tint: hovered.color
          )
          .frame(width: tooltipWidth)
          .offset(
            x: min(
              max(0, hoverLocation.x - tooltipWidth / 2),
              max(0, proxy.size.width - tooltipWidth)
            ),
            y: -78
          )
          .zIndex(20)
        }
      }
      .onContinuousHover { phase in
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
          switch phase {
          case .active(let location):
            if let id = SegmentedBarLayout.hit(at: Double(location.x), frames: frames) {
              hoverLocation = location
              hoveredID = id
            } else {
              hoverLocation = nil
              hoveredID = nil
            }
          case .ended:
            hoverLocation = nil
            hoveredID = nil
          }
        }
      }
    }
    .frame(height: height)
    .zIndex(hoveredID == nil ? 0 : 60)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityTitle)
    .accessibilityValue(
      segments.map { "\($0.title) \($0.value.formattedBytes)" }.joined(separator: "，")
    )
  }

  private static let trackPadding: CGFloat = 2
  private static let segmentGap: CGFloat = 2
}

struct LensSectionHeading: View {
  let title: String
  let subtitle: String?
  let symbol: String?

  init(_ title: String, subtitle: String? = nil, symbol: String? = nil) {
    self.title = title
    self.subtitle = subtitle
    self.symbol = symbol
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      if let symbol {
        Image(systemName: symbol)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(LensTheme.accentSoft)
          .frame(width: 26, height: 26)
          .background(LensTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
        if let subtitle {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

extension Color {
  init(lensHex value: String) {
    self.init(nsColor: NSColor(lensHex: value) ?? .systemGray)
  }
}

extension NSColor {
  convenience init?(lensHex value: String) {
    let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard cleaned.count == 6, let number = UInt64(cleaned, radix: 16) else { return nil }

    self.init(
      deviceRed: CGFloat((number >> 16) & 0xFF) / 255,
      green: CGFloat((number >> 8) & 0xFF) / 255,
      blue: CGFloat(number & 0xFF) / 255,
      alpha: 1
    )
  }
}

struct LensRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    LensRowButtonStyleBody(
      label: configuration.label,
      isPressed: configuration.isPressed
    )
  }
}

private struct LensRowButtonStyleBody<Label: View>: View {
  let label: Label
  let isPressed: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  var body: some View {
    label
      .brightness(isHovered && isEnabled ? 0.025 : 0)
      .scaleEffect(isPressed && !reduceMotion ? 0.992 : 1)
      .opacity(isEnabled ? (isPressed ? 0.90 : 1) : 0.46)
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
      .animation(reduceMotion ? nil : LensMotion.hover, value: isHovered)
      .animation(reduceMotion ? nil : LensMotion.press, value: isPressed)
  }
}
