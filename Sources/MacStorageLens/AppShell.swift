import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @EnvironmentObject private var model: AppModel
  @State private var showingImporter = false

  var body: some View {
    NavigationSplitView {
      LensSidebar()
        .navigationSplitViewColumnWidth(min: 208, ideal: 228, max: 264)
    } detail: {
      ZStack {
        LensBackdrop()
        detailView
      }
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          Button {
            model.runFullScan()
          } label: {
            Label(model.scanActionTitle, systemImage: "magnifyingglass")
          }
          .help(model.scanActionAccessibilityHint)
          .lensHoverHelp(
            title: model.scanActionTitle,
            detail: model.scanTargetMatchesDisplayedReport
              ? "重新分析目前顯示的位置，完成後替換同一位置的舊紀錄。"
              : "分析新的下次掃描位置；目前畫面會保留到新報告完成。",
            value:
              "\(model.selectedScanTarget.displayName) · \(model.selectedScanTargetStateTitle)",
            tint: LensTheme.accentSoft,
            placement: .belowTrailing
          )
          .accessibilityLabel(model.scanActionTitle)
          .accessibilityHint(model.scanActionAccessibilityHint)

          Button {
            model.reloadDisplayedReport()
          } label: {
            Label("重新載入", systemImage: "arrow.clockwise")
          }
          .disabled(model.isLoadingReport)
          .help("重新載入目前顯示的報告；尚無報告時載入最新一份")
          .lensHoverHelp(
            title: "重新載入目前報告",
            detail: "重新解析目前顯示的 Markdown；不會開始掃描，也不會改變下次掃描位置。",
            tint: LensTheme.sage,
            placement: .belowTrailing
          )
          .accessibilityLabel("重新載入目前報告")
          .accessibilityHint("重新解析目前畫面的容量地圖")

          Button {
            showingImporter = true
          } label: {
            Label("匯入報告", systemImage: "square.and.arrow.down")
          }
          .help("匯入既有的 MacStorageLens Markdown 掃描報告；原始檔不會被修改")
          .lensHoverHelp(
            title: "匯入掃描報告",
            detail: "從 Finder 選擇既有 Markdown。App 只保存自己的副本，原始檔不會被修改。",
            tint: LensTheme.plum,
            placement: .belowTrailing
          )
          .accessibilityLabel("匯入掃描報告")
          .accessibilityHint("從 Finder 選擇既有的 Markdown 報告")
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .tint(LensTheme.accent)
    .fileImporter(
      isPresented: $showingImporter,
      allowedContentTypes: [UTType(filenameExtension: "md") ?? .plainText, .plainText],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let url = urls.first { model.importReport(url) }
      case .failure(let error):
        model.errorMessage = error.localizedDescription
      }
    }
    .sheet(isPresented: $model.isShowingScanSheet) {
      ScanFlowSheet()
        .environmentObject(model)
    }
    .sheet(isPresented: $model.isShowingDirectFilesInspector) {
      DirectFilesInspectorView()
        .environmentObject(model)
    }
    .alert(
      "發生錯誤",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("好", role: .cancel) { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "未知錯誤")
    }
  }

  @ViewBuilder
  private var detailView: some View {
    switch model.destination {
    case .overview: OverviewView()
    case .browser: StorageBrowserView()
    case .cleaner: CleanerView()
    case .history: HistoryView()
    case .settings: SettingsView()
    case .about: AboutView()
    }
  }
}

private struct LensSidebar: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 11) {
        LensMark(size: 36)
        VStack(alignment: .leading, spacing: 1) {
          Text("磁碟透視")
            .font(.headline.weight(.semibold))
          Text("MacStorageLens")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(.horizontal, 14)
      .padding(.top, 16)
      .padding(.bottom, 18)

      VStack(spacing: 4) {
        ForEach(SidebarDestination.allCases) { destination in
          SidebarNavigationRow(
            destination: destination,
            isSelected: model.destination == destination
          ) {
            model.destination = destination
          }
        }
      }
      .padding(.horizontal, 10)

      Spacer(minLength: 18)

      Button {
        model.destination = .overview
      } label: {
        SidebarCapacityCard(capacity: model.liveCapacity)
      }
      .buttonStyle(SidebarPressButtonStyle())
      .help("前往儲存空間總覽")
      .padding(.horizontal, 10)
      .padding(.bottom, 12)
    }
    .background(LensTheme.sidebar(colorScheme))
  }
}

private struct SidebarNavigationRow: View {
  let destination: SidebarDestination
  let isSelected: Bool
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 11) {
        Image(systemName: destination.symbol)
          .font(.system(size: 13, weight: .semibold))
          .frame(width: 20)
          .foregroundStyle(isSelected ? LensTheme.accentSoft : Color.secondary)

        Text(destination.rawValue)
          .font(.callout.weight(isSelected ? .semibold : .medium))

        Spacer()

        if isSelected {
          Circle()
            .fill(LensTheme.accent)
            .frame(width: 5, height: 5)
        }
      }
      .padding(.horizontal, 11)
      .frame(height: 38)
      .contentShape(Rectangle())
      .background {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(background)
      }
      .overlay(alignment: .leading) {
        if isSelected {
          Capsule()
            .fill(LensTheme.accent)
            .frame(width: 3, height: 17)
            .offset(x: 1)
        }
      }
    }
    .buttonStyle(SidebarPressButtonStyle())
    .onHover { isHovered = $0 }
    .animation(reduceMotion ? nil : LensMotion.hover, value: isHovered)
  }

  private var background: Color {
    if isSelected { return LensTheme.selectedNavigation(colorScheme) }
    if isHovered { return LensTheme.hoveredNavigation(colorScheme) }
    return .clear
  }
}

private struct SidebarPressButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
      .opacity(configuration.isPressed ? 0.88 : 1)
      .animation(reduceMotion ? nil : LensMotion.press, value: configuration.isPressed)
  }
}

private struct SidebarCapacityCard: View {
  let capacity: LiveCapacity?

  @Environment(\.colorScheme) private var colorScheme
  @State private var hovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("即時容量", systemImage: "internaldrive.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        if let capacity {
          Text(percentText(capacity))
            .font(.caption2.weight(.bold))
            .foregroundStyle(LensTheme.accentSoft)
        }
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.bold))
          .foregroundStyle(hovered ? LensTheme.accentSoft : Color.secondary.opacity(0.42))
      }

      if let capacity {
        GeometryReader { proxy in
          let ratio =
            capacity.totalBytes > 0
            ? min(1, max(0, Double(capacity.usedBytes) / Double(capacity.totalBytes)))
            : 0
          ZStack(alignment: .leading) {
            Capsule().fill(LensTheme.recessed(colorScheme))
            Capsule()
              .fill(
                LinearGradient(
                  colors: [LensTheme.accentSoft, LensTheme.accentDeep],
                  startPoint: .leading,
                  endPoint: .trailing
                )
              )
              .frame(width: proxy.size.width * ratio)
          }
        }
        .frame(height: 6)

        HStack(alignment: .firstTextBaseline) {
          Text(capacity.usedBytes.formattedBytes)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
          Spacer()
          Text("空閒 \(capacity.availableBytes.formattedBytes)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      } else {
        ProgressView()
          .controlSize(.small)
      }
    }
    .padding(12)
    .background(
      hovered ? LensTheme.hoveredNavigation(colorScheme) : LensTheme.recessed(colorScheme),
      in: RoundedRectangle(cornerRadius: 13)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 13)
        .strokeBorder(
          hovered ? LensTheme.accent.opacity(0.32) : LensTheme.stroke(colorScheme),
          lineWidth: 1
        )
    }
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
  }

  private func percentText(_ capacity: LiveCapacity) -> String {
    guard capacity.totalBytes > 0 else { return "—" }
    return String(format: "%.0f%%", Double(capacity.usedBytes) / Double(capacity.totalBytes) * 100)
  }
}
