import SwiftUI

struct OverviewView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    let activeTarget = model.document?.summary.target ?? model.selectedScanTarget
    return ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        LensPageHeader(
          eyebrow: activeTarget.displayName,
          title: "儲存空間總覽",
          subtitle: activeTarget.kind == .system
            ? "把 APFS 容量帳務、可遍歷資料樹、受保護差額與安全清理分開呈現。"
            : "目前報告目標為\(activeTarget.kind == .volume ? "磁碟" : "資料夾")；容量帳務與路徑資料樹會依目標語意分開顯示。"
        ) {
          overviewActions
        }

        if let document = model.document {
          if let sunburst = model.overviewSunburst {
            overviewWorkspace(document: document, sunburst: sunburst)
          } else {
            VStack(alignment: .leading, spacing: 16) {
              liveCapacityCard(document: document)
              LensPanel {
                ProgressView("正在建立完整容量地圖…")
                  .frame(maxWidth: .infinity, minHeight: 420)
              }
              ScanQualityCard(summary: document.summary)
              ReconciliationCard(summary: document.summary)
            }
          }
        } else {
          liveCapacityCard(document: nil)
          EmptyReportView()
        }
      }
      .padding(26)
      .frame(maxWidth: 1580, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .navigationTitle("儲存空間總覽")
  }

  private var overviewActions: some View {
    HStack(spacing: 8) {
      Menu {
        DisplayedReportMenuContent()
          .environmentObject(model)
      } label: {
        LensMenuControlLabel(
          caption: "目前顯示",
          title: currentDisplayTitle,
          symbol: "eye",
          tint: LensTheme.accentSoft,
          compact: true
        )
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("切換目前畫面使用的容量地圖；不會改變下一次掃描位置")

      Menu {
        NextScanTargetMenuContent()
          .environmentObject(model)
      } label: {
        LensMenuControlLabel(
          caption: "下次掃描 · \(model.selectedScanTargetStateTitle)",
          title: model.selectedScanTarget.compactLocationTitle,
          symbol: "scope",
          tint: LensTheme.sage,
          compact: true
        )
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help(
        "下次按下「\(model.scanActionTitle)」時分析：\(model.selectedScanTarget.path)"
      )

      Button {
        model.reloadDisplayedReport()
      } label: {
        Label("重新載入", systemImage: "arrow.clockwise")
      }
      .buttonStyle(LensButtonStyle(kind: .secondary))
      .disabled(model.isLoadingReport)
      .help("重新解析目前顯示的報告；尚無報告時載入最新一份")

      Button {
        model.runFullScan()
      } label: {
        Label(model.scanActionTitle, systemImage: "magnifyingglass")
      }
      .buttonStyle(LensButtonStyle(kind: .primary))
      .help(model.scanActionAccessibilityHint)
    }
  }

  private var currentDisplayTitle: String {
    model.displayedReportRecord?.target.displayName
      ?? model.document?.summary.target.displayName
      ?? "尚無報告"
  }

  private func overviewWorkspace(document: ReportDocument, sunburst: SunburstItem) -> some View {
    // The primary chart stays in the first viewport. The horizontal form gives it
    // more visual weight; the narrow fallback places it before diagnostics.
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 18) {
        overviewDetailsColumn(document: document)
          .frame(minWidth: 350, idealWidth: 385, maxWidth: 420, alignment: .top)

        OverviewChartPanel(root: sunburst)
          .frame(minWidth: 600, maxWidth: .infinity, alignment: .top)
      }

      VStack(alignment: .leading, spacing: 18) {
        OverviewChartPanel(root: sunburst)
          .frame(maxWidth: .infinity, minHeight: 620, alignment: .top)
        overviewDetailsColumn(document: document)
      }
    }
  }

  private func overviewDetailsColumn(document: ReportDocument) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      liveCapacityCard(document: document)
      ScanQualityCard(summary: document.summary)
      ReconciliationCard(summary: document.summary)
    }
  }

  @ViewBuilder
  private func liveCapacityCard(document: ReportDocument?) -> some View {
    if let capacity = model.liveCapacity {
      CapacityHeroCard(capacity: capacity, document: document)
    } else {
      LensPanel {
        HStack(spacing: 12) {
          ProgressView()
          Text("正在讀取即時磁碟容量…")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
      }
    }
  }
}

private struct CapacityHeroCard: View {
  @EnvironmentObject private var model: AppModel

  let capacity: LiveCapacity
  let document: ReportDocument?

  var body: some View {
    LensPanel(padding: 22, elevated: true) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 30) {
          capacityStory
            .frame(maxWidth: .infinity, alignment: .leading)
          Divider()
            .frame(height: 126)
          metricGrid
            .frame(width: 420)
        }

        VStack(alignment: .leading, spacing: 20) {
          capacityStory
          metricGrid
        }
      }
    }
  }

  private var capacityStory: some View {
    VStack(alignment: .leading, spacing: 17) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text("目前已用")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(capacity.usedBytes.formattedBytes)
            .font(.system(size: 40, weight: .semibold))
            .tracking(-1.1)
            .monospacedDigit()
          Text("總容量 \(capacity.totalBytes.formattedBytes)")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        Spacer()

        LensStatusBadge(
          title: usagePercent,
          symbol: "chart.pie.fill",
          tint: LensTheme.accentSoft
        )
      }

      CapacityCompositionBar(capacity: capacity)

      HStack(spacing: 10) {
        CapacityLegendItem(
          title: "固定占用",
          value: committedBytes,
          color: LensTheme.accentDeep,
          detail: "目前已用容量扣除可回收估計後的部分；它不會因游標停留而改變容量。"
        )
        CapacityLegendItem(
          title: "可回收估計",
          value: reclaimableBytes,
          color: LensTheme.sage,
          detail: "macOS 可能在需要時回收的估計容量，不等於同容量的可刪除檔案。"
        )
        CapacityLegendItem(
          title: "真正空閒",
          value: freeBytes,
          color: LensTheme.slate,
          detail: "目前沒有配置給任何檔案的空間，不是隱藏資料。"
        )
      }

      if let document {
        ReportStatusBanner(
          message: model.statusMessage,
          kind: model.reportStatusKind,
          isBusy: model.isFullScanRunning || model.isLoadingReport,
          primaryActionTitle: "Finder 顯示",
          primaryActionSymbol: "finder",
          primaryAction: { model.openInFinder(document.url.path) },
          secondaryActionTitle: "打開報告",
          secondaryActionSymbol: "doc.text",
          secondaryAction: { model.openFile(document.url.path) }
        )

        Text("最新完成報告：\(document.summary.generatedAt) · 掃描器 \(document.summary.scannerVersion)")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
  }

  private var metricGrid: some View {
    LazyVGrid(
      columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
      spacing: 12
    ) {
      CompactMetric(
        title: "真正空閒",
        value: capacity.availableBytes.formattedBytes,
        symbol: "square.dashed",
        tint: LensTheme.slate,
        detail: "檔案系統目前沒有配置給任何檔案的空間。這不是隱藏資料，也不需要清理。"
      )
      CompactMetric(
        title: "重要用途可用",
        value: capacity.importantUsageAvailableBytes.formattedBytes,
        symbol: "arrow.down.circle",
        tint: LensTheme.sage,
        detail: "macOS 估算重要用途可使用的容量，可能包含系統可自行回收的空間。"
      )
      CompactMetric(
        title: "可回收估計",
        value: capacity.reclaimableEstimateBytes.formattedBytes,
        symbol: "arrow.triangle.2.circlepath",
        tint: LensTheme.sand,
        detail: "由可用容量差額推算的估計值，不代表存在同等大小、可直接刪除的資料夾。"
      )
      CompactMetric(
        title: "更新時間",
        value: capacity.updatedAt.formatted(date: .omitted, time: .shortened),
        symbol: "clock",
        tint: LensTheme.plum,
        detail: "即時容量每 30 秒更新；完整資料樹只在執行掃描後更新。"
      )
    }
  }

  private var reclaimableBytes: Int64 {
    min(capacity.usedBytes, max(0, capacity.reclaimableEstimateBytes))
  }

  private var committedBytes: Int64 {
    max(0, capacity.usedBytes - reclaimableBytes)
  }

  private var freeBytes: Int64 {
    max(0, capacity.totalBytes - committedBytes - reclaimableBytes)
  }

  private var usagePercent: String {
    guard capacity.totalBytes > 0 else { return "—" }
    return String(
      format: "%.1f%% 已用", Double(capacity.usedBytes) / Double(capacity.totalBytes) * 100)
  }
}

private struct CapacityCompositionBar: View {
  let capacity: LiveCapacity

  var body: some View {
    let total = max(Int64(1), capacity.totalBytes)
    let reclaimable = min(capacity.usedBytes, max(0, capacity.reclaimableEstimateBytes))
    let committed = max(0, capacity.usedBytes - reclaimable)
    let free = max(0, total - committed - reclaimable)

    LensSegmentedBar(
      segments: [
        LensBarSegment(
          id: "committed",
          title: "固定占用",
          value: committed,
          color: LensTheme.accentDeep,
          detail: "目前已用空間扣除可回收估計後的固定占用。"
        ),
        LensBarSegment(
          id: "reclaimable",
          title: "可回收估計",
          value: reclaimable,
          color: LensTheme.sage,
          detail: "macOS 可能在需要時回收的估計容量，不等於可直接刪除的檔案。"
        ),
        LensBarSegment(
          id: "free",
          title: "真正空閒",
          value: free,
          color: LensTheme.slate.opacity(0.62),
          detail: "目前未配置給檔案的空間。"
        ),
      ],
      total: total,
      height: 15,
      accessibilityTitle: "磁碟容量組成"
    )
  }
}

private struct CapacityLegendItem: View {
  let title: String
  let value: Int64
  let color: Color
  let detail: String

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(color).frame(width: 7, height: 7)
      Text(title)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
      Image(systemName: "info.circle")
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(isHovered ? color : Color.secondary.opacity(0.42))
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 5)
    .background(
      isHovered ? LensTheme.hoveredNavigation(colorScheme) : Color.clear,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(reduceMotion ? nil : LensMotion.hover, value: isHovered)
    .lensHoverHelp(title: title, detail: detail, value: value.formattedBytes, tint: color)
  }
}

private struct CompactMetric: View {
  let title: String
  let value: String
  let symbol: String
  let tint: Color
  let detail: String

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: symbol)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 25, height: 25)
          .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        Spacer()
        Image(systemName: "info.circle")
          .font(.caption2)
          .foregroundStyle(hovered ? tint : Color.secondary.opacity(0.55))
      }

      Text(value)
        .font(.title3.weight(.semibold))
        .tracking(-0.2)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.78)

      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(13)
    .frame(maxWidth: .infinity, minHeight: 102, alignment: .leading)
    .background(
      hovered ? LensTheme.hoveredNavigation(colorScheme) : LensTheme.recessed(colorScheme),
      in: RoundedRectangle(cornerRadius: 13)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 13)
        .strokeBorder(hovered ? tint.opacity(0.34) : LensTheme.stroke(colorScheme), lineWidth: 1)
    }
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .animation(reduceMotion ? nil : LensMotion.hover, value: hovered)
    .lensHoverHelp(title: title, detail: detail, value: value, tint: tint)
  }
}

private struct ScanQualityCard: View {
  let summary: ScanSummary

  @State private var showsTechnicalDetails = false

  private var coverageTitle: String {
    summary.hasPartialCoverage ? "部分" : "完整"
  }

  private var badgeIsPositive: Bool {
    summary.targetKind != .system || summary.usedAppTCCOverlay || summary.fullDiskAccessAvailable
  }

  private var accessBadgeTitle: String {
    if summary.targetKind != .system {
      return "所選位置可讀"
    }
    if summary.hasAmbiguousLegacyAdministratorProbe {
      return "舊報告只測到管理員子程序"
    }
    if summary.usedAppTCCOverlay {
      return "App 權限已合併"
    }
    switch summary.scannerPrivilegeChannel {
    case "app_direct":
      return summary.appFullDiskAccessAvailable ? "App 權限已生效" : "App 權限探針未通過"
    case "terminal":
      return summary.scannerFullDiskAccessAvailable ? "Terminal TCC 已生效" : "Terminal TCC 受限"
    case "administrator_only":
      return summary.scannerFullDiskAccessAvailable
        ? "管理員子程序可讀受保護路徑"
        : "管理員子程序 TCC 受限"
    default:
      return summary.fullDiskAccessAvailable ? "本次掃描 TCC 已生效" : "本次掃描 TCC 受限"
    }
  }

  private var accessExplanation: String {
    if summary.targetKind != .system {
      return
        "外接磁碟與指定資料夾只讀取使用者明確選擇的位置；Scanner 2.5.3 不再為這類掃描探測 Mail、Messages、Safari 或 AddressBook，因此完整磁碟存取狀態標示為不適用。"
    }
    if summary.hasAmbiguousLegacyAdministratorProbe {
      return
        "這是 scanner 2.5.0 的舊報告。它只記錄獨立管理員／root 子程序的探針，因此該探針失敗不能用來判定 MacStorageLens App 是否已獲完整磁碟存取。請用目前版本重新掃描，App 與掃描子程序會分開記錄。"
    }
    if summary.usedAppTCCOverlay {
      let delta = signedBytes(summary.tccOverlayDeltaBytes)
      return
        "MacStorageLens App 先以自己的 TCC 權限讀取受保護的使用者資料，再把該資料樹合併到管理員唯讀系統掃描。管理員子程序即使無法直接讀取 Mail／Messages，也不代表 App 授權失敗。本次合併容量變化為 \(delta)。"
    }
    if summary.scannerPrivilegeChannel == "administrator_only" {
      if summary.appFullDiskAccessAvailable {
        return "App 權限探針已通過，但這次沒有成功建立／合併 App TCC 覆蓋；畫面顯示的是管理員子程序自己的受限狀態。請查看 App 覆蓋狀態與診斷後重新掃描。"
      }
      return "這次只有獨立管理員子程序完成掃描。root 權限不等於完整磁碟存取；受 TCC 保護的路徑可能仍不可讀。"
    }
    if summary.scannerPrivilegeChannel == "app_direct" {
      return summary.appFullDiskAccessAvailable
        ? "本次由 MacStorageLens App 直接掃描，App 自身的受保護路徑探針已通過。資料是否完整仍以診斷行與資料覆蓋狀態為準。"
        : "本次由 MacStorageLens App 直接掃描，但 App 自身的受保護路徑探針沒有通過；請完全退出 App、核對完整磁碟存取後重新開啟。"
    }
    if summary.scannerPrivilegeChannel == "terminal" || summary.launcherMode == "terminal" {
      return summary.scannerFullDiskAccessAvailable
        ? "本次由 Terminal 啟動，使用的是 Terminal 自己的完整磁碟存取權；它與 MacStorageLens App 的授權互相獨立。"
        : "本次由 Terminal 啟動，但 Terminal 的受保護路徑探針沒有通過；請核對 Terminal 的完整磁碟存取權。"
    }
    return summary.fullDiskAccessAvailable
      ? "本次報告的有效 TCC 覆蓋已通過。報告生成、管理員權限與每個路徑是否可讀仍分開計算。"
      : "本次報告沒有取得可驗證的完整磁碟存取覆蓋；請依掃描通道、探針與診斷行判讀，不要只看 root 權限。"
  }

  private func probeTitle(_ value: String) -> String {
    switch value {
    case "LIKELY_AVAILABLE": return "可讀"
    case "LIKELY_MISSING_OR_TCC_BLOCKED": return "受阻"
    case "NOT_APPLICABLE": return "不適用"
    default: return "未判定"
    }
  }

  private func signedBytes(_ value: Int64) -> String {
    let prefix = value > 0 ? "+" : value < 0 ? "−" : ""
    return prefix + abs(value).formattedBytes
  }

  var body: some View {
    LensPanel {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .top) {
          LensSectionHeading(
            "掃描品質",
            subtitle: "App、管理員子程序、Terminal 與資料覆蓋分開判讀",
            symbol: badgeIsPositive ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
          )
          Spacer()
          LensStatusBadge(
            title: accessBadgeTitle,
            symbol: badgeIsPositive ? "checkmark" : "exclamationmark",
            tint: badgeIsPositive ? LensTheme.sage : LensTheme.sand
          )
        }

        Text(accessExplanation)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 118), spacing: 8)],
          alignment: .leading,
          spacing: 8
        ) {
          DetailPill(title: "掃描通道", value: summary.scanChannelDisplayName)
          DetailPill(title: "App TCC", value: probeTitle(summary.appFullDiskAccessProbe))
          DetailPill(title: "掃描子程序 TCC", value: probeTitle(summary.scannerFullDiskAccessProbe))
          DetailPill(title: "管理員", value: summary.administratorReadAccess ? "已取得" : "未取得")
          DetailPill(title: "報告生成", value: summary.reportComplete ? "完成" : "未完成")
          DetailPill(title: "資料覆蓋", value: coverageTitle)
          DetailPill(title: "診斷行", value: "\(summary.duErrorLineCount)")
          DetailPill(title: "權限／TCC", value: "\(summary.errorCount)")
        }

        DisclosureGroup(isExpanded: $showsTechnicalDetails) {
          VStack(alignment: .leading, spacing: 6) {
            if summary.appFullDiskAccessProbePath != "NONE" {
              Text("App 探針：\(summary.appFullDiskAccessProbePath)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            if summary.scannerFullDiskAccessProbePath != "NONE" {
              Text("掃描子程序探針：\(summary.scannerFullDiskAccessProbePath)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            if summary.usedAppTCCOverlay {
              Text(
                "App TCC 覆蓋：\(summary.tccOverlayTreeBytes.formattedBytes)；取代 \(summary.tccOverlayReplacedBytes.formattedBytes)；差額 \(signedBytes(summary.tccOverlayDeltaBytes))"
              )
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.tertiary)
            } else if summary.tccOverlayStatus != "NOT_REQUESTED" {
              Text("App TCC 覆蓋狀態：\(summary.tccOverlayStatus)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            }
          }
          .padding(.top, 7)
        } label: {
          Label("技術診斷與探針路徑", systemImage: "wrench.and.screwdriver")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }

        if summary.targetKind == .system {
          Button("開啟完整磁碟存取權設定") {
            ScannerLauncher.openFullDiskAccessSettings()
          }
          .buttonStyle(LensButtonStyle(kind: .secondary, compact: true))
        }
      }
    }
  }
}

private struct ReconciliationCard: View {
  let summary: ScanSummary

  var body: some View {
    LensPanel {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .top) {
          LensSectionHeading(
            headingTitle,
            subtitle: headingSubtitle,
            symbol: "arrow.triangle.branch"
          )
          Spacer()
          snapshotBadge
        }

        if summary.targetKind == .folder {
          HStack(spacing: 10) {
            ReconciliationMetric(
              title: "資料夾資料樹",
              value: summary.targetTreeBytes.formattedBytes,
              tint: LensTheme.sage,
              detail: "目前所選資料夾及其可讀子項目的掃描快照。"
            )
            ReconciliationMetric(
              title: "所在磁碟容量",
              value: summary.targetVolumeCapacityBytes.formattedBytes,
              tint: LensTheme.accentSoft,
              detail: "所選資料夾所在磁碟的完整容量，不是資料夾本身的大小。"
            )
            ReconciliationMetric(
              title: "所在磁碟可用",
              value: summary.targetVolumeAvailableBytes.formattedBytes,
              tint: LensTheme.slate,
              detail: "所在磁碟目前未使用或可供重要用途使用的容量。"
            )
          }

          Text("資料夾模式只把所選路徑畫成可深入的資料樹；所在磁碟的剩餘空間屬於磁碟帳務，不會被畫成資料夾的子節點。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          HStack(spacing: 10) {
            ReconciliationMetric(
              title: usedLabel,
              value: usedBytes.formattedBytes,
              tint: LensTheme.accentSoft,
              detail: "df／APFS 回報的已用容量；等於下方可映射資料樹與未解析差額的合計。"
            )
            ReconciliationMetric(
              title: visibleTreeTitle,
              value: treeBytes.formattedBytes,
              tint: LensTheme.sage,
              detail: visibleTreeDetail
            )
            ReconciliationMetric(
              title: gapTitle,
              value: gapBytes.formattedBytes,
              tint: LensTheme.plum,
              detail: gapDetail
            )
          }

          AccountingBar(
            visible: treeBytes,
            gap: gapBytes,
            visibleTitle: visibleTreeTitle,
            visibleDetail: visibleTreeDetail,
            gapTitle: gapTitle,
            gapDetail: gapDetail,
            accessibilityTitle: headingTitle + "帳務核對"
          )

          if usesStableVolumeTree {
            VStack(alignment: .leading, spacing: 10) {
              Text("卷宗根目錄狀態")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

              LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 148), spacing: 8)],
                alignment: .leading,
                spacing: 8
              ) {
                LensStatusBadge(
                  title: "Spotlight：\(volatileStatusTitle(summary.targetSpotlightRootStatus))",
                  symbol: summary.targetSpotlightRootStatus == "PRESENT"
                    ? "magnifyingglass" : "checkmark",
                  tint: summary.targetSpotlightRootStatus == "PRESENT"
                    ? LensTheme.sand : LensTheme.sage
                )
                LensStatusBadge(
                  title: "FSEvents：\(volatileStatusTitle(summary.targetFSEventsRootStatus))",
                  symbol: summary.targetFSEventsRootStatus == "PRESENT"
                    ? "waveform.path.ecg" : "checkmark",
                  tint: summary.targetFSEventsRootStatus == "PRESENT"
                    ? LensTheme.sand : LensTheme.sage
                )
                LensStatusBadge(
                  title: "卷宗垃圾桶：\(volatileStatusTitle(summary.targetTrashRootStatus))",
                  symbol: summary.targetTrashRootStatus == "PRESENT" ? "trash" : "checkmark",
                  tint: summary.targetTrashRootStatus == "PRESENT"
                    ? LensTheme.sand : LensTheme.sage
                )
              }

              HStack(alignment: .firstTextBaseline, spacing: 10) {
                if summary.totalDurationSeconds > 0 {
                  Label(
                    "Scanner 2.5.3：總計 \(summary.totalDurationSeconds) 秒 · 資料樹 \(summary.pathScanDurationSeconds) 秒",
                    systemImage: "stopwatch"
                  )
                  .font(.caption2.monospacedDigit())
                  .foregroundStyle(.tertiary)
                  .help(
                    "預檢 \(summary.preflightDurationSeconds) 秒 · 準備 \(summary.prepareDurationSeconds) 秒 · 資料樹 \(summary.pathScanDurationSeconds) 秒 · 磁碟狀態 \(summary.metadataDurationSeconds) 秒 · 寫報告 \(summary.reportWriteDurationSeconds) 秒 · Scanner 總計 \(summary.totalDurationSeconds) 秒"
                  )
                }
                Spacer(minLength: 4)
                Button("Spotlight 搜尋隱私權") {
                  ScannerLauncher.openSpotlightSettings()
                }
                .buttonStyle(LensButtonStyle(kind: .quiet, compact: true))
                .help("對只在手機、相機或 Windows 使用的外接磁碟，可在 macOS Spotlight 的『搜尋隱私權』中排除，避免索引被反覆重建。")
              }
            }
          }

          if scanDeltaBytes != 0 {
            Label(
              "掃描期間帳務變化：\(signedBytes(scanDeltaBytes))",
              systemImage: "clock.arrow.2.circlepath"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          }

          DisclosureGroup {
            Text(gapExplanation)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.top, 6)
          } label: {
            Label(gapDisclosureTitle, systemImage: "questionmark.circle")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var headingTitle: String {
    switch summary.targetKind {
    case .system: return "Data volume 核對"
    case .volume: return "磁碟容量核對"
    case .folder: return "資料夾掃描範圍"
    }
  }

  private var headingSubtitle: String {
    switch summary.targetKind {
    case .system: return "Data 的 df 帳務與可映射資料樹"
    case .volume: return "磁碟已用帳務與可映射資料樹"
    case .folder: return "資料夾大小與所在磁碟容量分開呈現"
    }
  }

  private var usedLabel: String {
    summary.targetKind == .system ? "Data 帳務已用" : "磁碟帳務已用"
  }

  private var usedBytes: Int64 {
    summary.targetKind == .system ? summary.dataUsedBytes : summary.targetVolumeUsedBytes
  }

  private var usesStableVolumeTree: Bool {
    summary.targetKind == .volume && summary.volumeVolatileMetadataExcluded
  }

  private var visibleTreeTitle: String {
    usesStableVolumeTree ? "可映射穩定資料樹" : "可映射資料樹"
  }

  private var visibleTreeDetail: String {
    if usesStableVolumeTree {
      return "可對應到一般使用者路徑的穩定資料樹；為避免重複清理後越掃越慢，深度掃描會略過 .Trashes、Spotlight、FSEvents 與其他會重建的卷宗中繼資料。"
    }
    return "掃描器可對應到真實路徑與資料夾樹的容量，對應下方綠色區段。"
  }

  private var gapTitle: String {
    usesStableVolumeTree ? "卷宗中繼資料／垃圾桶" : "帳務差額（未解析）"
  }

  private var gapDetail: String {
    if usesStableVolumeTree {
      return "完整 df 已用帳務中，未做深度資料樹展開的卷宗垃圾桶、Spotlight／FSEvents 等中繼資料，以及其他檔案系統差額；它仍計入容量，但不會拖慢每次重掃。"
    }
    return "已用容量中無法直接映射成一般路徑的部分，對應下方紫色區段；它不等於垃圾。"
  }

  private var gapExplanation: String {
    if usesStableVolumeTree {
      let names =
        summary.volumeVolatileMetadataNames.isEmpty
        ? ".Trashes、.Spotlight-V100、.fseventsd 等"
        : summary.volumeVolatileMetadataNames.joined(separator: "、")
      return
        "外接卷宗的完整已用容量仍由 df 保留；為避免垃圾桶內的舊索引、Spotlight／FSEvents 重建資料在每次掃描時被再次遞迴遍歷，Scanner 2.5.3 不展開 \(names)。這些容量會留在紫色帳務區，不代表全部可清理；安全清理頁會另外辨識精確候選。"
    }
    return "未解析差額可能混合不可讀路徑、快照專屬區塊、APFS metadata、clone／hard-link 語意與開啟中的檔案；它不等於可清理容量。"
  }

  private var gapDisclosureTitle: String {
    usesStableVolumeTree ? "為什麼卷宗中繼資料不展開？" : "為什麼會有帳務差額？"
  }

  private var treeBytes: Int64 {
    summary.targetKind == .system ? summary.dataVisibleBytes : summary.targetTreeBytes
  }

  private var gapBytes: Int64 {
    summary.targetKind == .system ? summary.accountingGapBytes : summary.targetAccountingGapBytes
  }

  private var scanDeltaBytes: Int64 {
    summary.targetKind == .system ? summary.dataScanDeltaBytes : summary.targetVolumeScanDeltaBytes
  }

  private func signedBytes(_ value: Int64) -> String {
    let prefix = value > 0 ? "+" : value < 0 ? "−" : ""
    return prefix + abs(value).formattedBytes
  }

  private func volatileStatusTitle(_ value: String) -> String {
    switch value {
    case "PRESENT": return "已存在（未展開）"
    case "ABSENT": return "掃描時不存在"
    case "NOT_APPLICABLE": return "不適用"
    default: return "未判定"
    }
  }

  @ViewBuilder
  private var snapshotBadge: some View {
    if summary.targetKind == .system {
      LensStatusBadge(
        title:
          "快照：系統 \(summary.systemSnapshotCount) · Time Machine \(summary.timeMachineSnapshotCount)",
        symbol: "clock.arrow.circlepath",
        tint: LensTheme.plum
      )
    } else {
      LensStatusBadge(
        title: summary.targetKind.title,
        symbol: summary.targetKind.symbol,
        tint: LensTheme.accentSoft
      )
    }
  }
}

private struct ReconciliationMetric: View {
  let title: String
  let value: String
  let tint: Color
  let detail: String

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 7) {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(tint)
          .frame(width: 11, height: 11)
        Text(title)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Image(systemName: "info.circle")
          .font(.caption2)
          .foregroundStyle(hovered ? tint : Color.secondary.opacity(0.5))
      }

      Text(value)
        .font(.headline.weight(.semibold))
        .monospacedDigit()
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      hovered ? LensTheme.hoveredNavigation(colorScheme) : Color.clear,
      in: RoundedRectangle(cornerRadius: 11)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .strokeBorder(hovered ? tint.opacity(0.32) : Color.clear, lineWidth: 1)
    }
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .animation(reduceMotion ? nil : LensMotion.hover, value: hovered)
    .lensHoverHelp(title: title, detail: detail, value: value, tint: tint)
  }
}

struct AccountingBar: View {
  let visible: Int64
  let gap: Int64
  var visibleTitle = "可映射資料樹"
  var visibleDetail = "掃描器能對應到真實路徑的容量。"
  var gapTitle = "帳務差額（未解析）"
  var gapDetail = "快照、權限限制、APFS metadata 或共享區塊等未能映射成一般路徑的容量。"
  var accessibilityTitle = "Data volume 帳務核對"

  var body: some View {
    LensSegmentedBar(
      segments: [
        LensBarSegment(
          id: "visible",
          title: visibleTitle,
          value: visible,
          color: LensTheme.sage,
          detail: visibleDetail
        ),
        LensBarSegment(
          id: "gap",
          title: gapTitle,
          value: gap,
          color: LensTheme.plum,
          detail: gapDetail
        ),
      ],
      total: max(Int64(1), visible + gap),
      height: 14,
      accessibilityTitle: accessibilityTitle
    )
  }
}

private struct DetailPill: View {
  let title: String
  let value: String

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .foregroundStyle(.secondary)
      Text(value)
        .fontWeight(.semibold)
      Image(systemName: "info.circle")
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(isHovered ? LensTheme.accentSoft : Color.secondary.opacity(0.42))
    }
    .font(.caption2)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(
      isHovered ? LensTheme.hoveredNavigation(colorScheme) : LensTheme.recessed(colorScheme),
      in: Capsule()
    )
    .overlay {
      Capsule()
        .strokeBorder(
          isHovered ? LensTheme.accent.opacity(0.32) : Color.clear,
          lineWidth: 1
        )
    }
    .contentShape(Capsule())
    .onHover { isHovered = $0 }
    .animation(reduceMotion ? nil : LensMotion.hover, value: isHovered)
    .lensHoverHelp(title: title, detail: detail, value: value, tint: LensTheme.accentSoft)
  }

  private var detail: String {
    switch title {
    case "掃描通道":
      return "顯示這份報告由 App、管理員授權或 Terminal 相容模式中的哪一條責任鏈產生。"
    case "App TCC":
      return "MacStorageLens App 本身對受保護使用者資料的完整磁碟存取權探測結果。"
    case "掃描子程序 TCC":
      return "實際執行唯讀掃描的子程序對受保護路徑的讀取結果；它與 App 權限是不同責任鏈。"
    case "管理員":
      return "表示本次掃描是否取得管理員唯讀權限；管理員權限不能取代 TCC 完整磁碟存取權。"
    case "報告生成":
      return "只有尾端含 report_complete=true 的完整 Markdown 才會加入掃描紀錄。"
    case "資料覆蓋":
      return "綜合 App TCC、掃描子程序與覆蓋合併後，這份報告可讀資料的完整程度。"
    case "診斷行":
      return "掃描過程記錄的受限或診斷訊息數；有診斷行不代表整份掃描失敗。"
    case "權限／TCC":
      return "與 Permission denied、Operation not permitted 或 TCC 限制相關的訊息數。"
    default:
      return "這是掃描品質的診斷欄位，用來判斷容量地圖的來源與完整度。"
    }
  }
}

private struct OverviewChartPanel: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  let root: SunburstItem

  var body: some View {
    LensPanel(padding: 20, elevated: true) {
      VStack(alignment: .leading, spacing: 17) {
        HStack(alignment: .top, spacing: 14) {
          LensSectionHeading(
            "完整容量地圖",
            subtitle: chartSubtitle,
            symbol: "circle.hexagongrid.fill"
          )
          Spacer(minLength: 8)
          LensStatusBadge(
            title: "游標檢視 · 右鍵 Finder · 點擊深入",
            symbol: "cursorarrow.motionlines",
            tint: LensTheme.accentSoft
          )
        }

        ViewThatFits(in: .horizontal) {
          HStack(alignment: .center, spacing: 18) {
            chart
              .frame(minWidth: 380, idealWidth: 500, maxWidth: 650)
            legend
              .frame(minWidth: 210, idealWidth: 270, maxWidth: 330)
          }

          VStack(spacing: 18) {
            chart.frame(minHeight: 500, idealHeight: 590, maxHeight: 680)
            legend
          }
        }
      }
    }
  }

  private var chartSubtitle: String {
    guard let summary = model.document?.summary else {
      return "容量帳務與可深入的資料夾樹分層顯示。"
    }
    switch summary.targetKind {
    case .system:
      return "掃描快照：內圈維持 APFS 帳務語意；進入 Data 的真實資料夾層後重新分配支系色相，外圈依深度明顯漸亮。"
    case .volume:
      return "掃描快照：磁碟帳務使用固定語意色；可深入的資料夾層使用低飽和支系色，外圈依層級漸亮。"
    case .folder:
      return "掃描快照：所選資料夾的第一層子項各自取得支系色；同一分支往外保持色相並逐層漸亮。"
    }
  }

  private var chart: some View {
    SunburstChart(
      root: root,
      onSelect: { item in
        model.selectSunburstItem(item, navigateToBrowser: item.isNavigable)
      },
      onRevealInFinder: { model.openInFinder($0) },
      onOpenInFinder: { model.openPathInFinder($0) },
      onCopyPath: { model.copyPath($0) }
    )
  }

  private var legend: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("最大項目")
          .font(.headline)
        Spacer()
        Text(root.bytes.formattedBytes)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

      Text("帳務節點會清楚標示；有真實路徑的項目可右鍵在 Finder 顯示、打開或複製路徑。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Divider().opacity(0.55)

      ForEach(Array(root.children.prefix(12).enumerated()), id: \.element.id) { index, item in
        Group {
          if item.isInteractive {
            Button {
              model.selectSunburstItem(item, navigateToBrowser: item.isNavigable)
            } label: {
              OverviewLegendRow(item: item, index: index, totalBytes: root.bytes)
            }
            .buttonStyle(.plain)
          } else {
            OverviewLegendRow(item: item, index: index, totalBytes: root.bytes)
          }
        }
        .contextMenu {
          if let path = item.finderPath {
            Button(item.finderActionTitle) { model.openInFinder(path) }
            Button(item.finderOpenActionTitle) { model.openPathInFinder(path) }
            Button(item.finderCopyActionTitle) { model.copyPath(path) }
            if item.isNavigable {
              Divider()
              Button("在資料樹中深入") {
                model.selectSunburstItem(item, navigateToBrowser: true)
              }
            }
          } else {
            Button("此項目沒有 Finder 路徑") {}
              .disabled(true)
          }
        }
      }
    }
    .padding(14)
    .background(LensTheme.recessed(colorScheme), in: RoundedRectangle(cornerRadius: 15))
    .overlay {
      RoundedRectangle(cornerRadius: 15)
        .strokeBorder(LensTheme.stroke(colorScheme), lineWidth: 1)
    }
  }
}

private struct OverviewLegendRow: View {
  let item: SunburstItem
  let index: Int
  let totalBytes: Int64

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: 3)
        .fill(tint)
        .frame(width: 8, height: 30)

      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(item.label)
            .font(.callout.weight(.medium))
            .lineLimit(1)
          Spacer()
          Text(item.bytes.formattedBytes)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }

        GeometryReader { proxy in
          ZStack(alignment: .leading) {
            Capsule().fill(LensTheme.recessed(colorScheme))
            Capsule()
              .fill(tint)
              .frame(width: proxy.size.width * ratio)
          }
        }
        .frame(height: 4)
      }

      Image(systemName: item.isInteractive ? "chevron.right" : "info.circle")
        .font(.caption2.weight(.bold))
        .foregroundStyle(
          isHovered ? tint : Color.secondary.opacity(item.isInteractive ? 0.55 : 0.42)
        )
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 8)
    .background(
      isHovered ? LensTheme.hoveredNavigation(colorScheme) : Color.clear,
      in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(isHovered ? tint.opacity(0.26) : Color.clear, lineWidth: 1)
    }
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(reduceMotion ? nil : LensMotion.hover, value: isHovered)
    .lensHoverHelp(
      title: item.label,
      detail: tooltipDetail,
      value: item.bytes.formattedBytes,
      tint: tint
    )
  }

  private var tint: Color {
    StoragePalette.topLevelColor(
      index: index,
      itemID: item.id,
      kind: item.kind,
      colorHint: item.colorHint,
      colorScheme: colorScheme
    )
  }

  private var ratio: CGFloat {
    guard totalBytes > 0 else { return 0 }
    return CGFloat(min(1, max(0, Double(item.bytes) / Double(totalBytes))))
  }

  private var tooltipDetail: String {
    let percent = totalBytes > 0 ? Double(item.bytes) / Double(totalBytes) * 100 : 0
    let prefix = String(format: "占目前容量地圖 %.1f%%。", percent)
    let explanation: String
    switch item.kind {
    case .directFiles:
      explanation = "這是父資料夾第一層非資料夾項目的虛擬合計；點擊可查看真實檔名、路徑與配置大小。"
    case .otherChildren:
      explanation = "只有同層超過 2,048 個子資料夾時才會自動合併；點擊可展開完整清單並逐項繼續深入，右鍵仍可前往父資料夾。"
    case .accountingGap:
      explanation =
        item.label.contains("卷宗中繼資料")
        ? "這是完整已用帳務中未做深度展開的卷宗垃圾桶、Spotlight／FSEvents 等中繼資料與檔案系統差額；容量仍被核對，但不會拖慢每次重掃。"
        : "這是已用容量中無法映射成一般 Finder 路徑的帳務差額，可能含快照、權限限制與 APFS metadata；它不等於垃圾。"
    case .containerAccounting:
      explanation = "這是 APFS 容器層的帳務或 metadata，不是可直接開啟或清理的資料夾。"
    case .scanDelta:
      explanation = "這是掃描前後磁碟使用量變化的診斷節點，不代表固定存在的檔案。"
    case .freeSpace:
      explanation = "這是真正未配置的空間，不是檔案，也不需要清理。"
    case .purgeable:
      explanation = "這是 macOS 估算可在需要時回收的容量，不能等同於一個可直接刪除的資料夾。"
    case .otherVolume:
      explanation =
        item.finderPath == nil
        ? "這是獨立的 APFS／系統卷帳務；沒有一般 Finder 路徑。"
        : "這是另一個已掛載卷；可使用右鍵 Finder 操作查看其位置。"
    case .none:
      explanation =
        item.isNavigable
        ? "這是真實資料夾；點擊可在資料樹深入，右鍵可使用 Finder 操作。"
        : "這是容量地圖中的資料節點，目前沒有可執行的 Finder 路徑。"
    }
    return prefix + explanation
  }
}

struct EmptyReportView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    LensPanel(padding: 28, elevated: true) {
      HStack(spacing: 28) {
        ZStack {
          Circle()
            .fill(LensTheme.accent.opacity(0.10))
            .frame(width: 122, height: 122)
          LensMark(size: 62)
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("建立第一份完整容量地圖")
            .font(.title2.weight(.semibold))
          Text("App 會顯示 macOS 原生授權視窗，在背景進行唯讀分析，完成後自動載入最新報告。它不會自動刪除或移動任何系統與使用者資料。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          ReportStatusBanner(
            message: model.statusMessage,
            kind: model.reportStatusKind,
            isBusy: model.isFullScanRunning || model.isLoadingReport
          )

          HStack(spacing: 10) {
            Button {
              model.runFullScan()
            } label: {
              Label("開始完整掃描", systemImage: "magnifyingglass")
            }
            .buttonStyle(LensButtonStyle(kind: .primary))

            Button {
              model.loadLatestReport()
            } label: {
              Label("載入最新報告", systemImage: "arrow.clockwise")
            }
            .buttonStyle(LensButtonStyle(kind: .secondary))
          }
        }

        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
    }
  }
}

private struct ReportStatusBanner: View {
  let message: String
  let kind: ReportStatusKind
  let isBusy: Bool
  var primaryActionTitle: String? = nil
  var primaryActionSymbol: String? = nil
  var primaryAction: (() -> Void)? = nil
  var secondaryActionTitle: String? = nil
  var secondaryActionSymbol: String? = nil
  var secondaryAction: (() -> Void)? = nil

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered = false

  private var hasActions: Bool {
    !isBusy && (primaryAction != nil || secondaryAction != nil)
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 12) {
        statusIdentity
        Spacer(minLength: 10)
        actionButtons
      }

      VStack(alignment: .leading, spacing: 10) {
        statusIdentity
        actionButtons
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      hovered && hasActions
        ? LensTheme.hoveredNavigation(colorScheme) : LensTheme.recessed(colorScheme),
      in: RoundedRectangle(cornerRadius: 12)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(hovered && hasActions ? tint.opacity(0.34) : tint.opacity(0.22), lineWidth: 1)
    }
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .animation(reduceMotion ? nil : LensMotion.hover, value: hovered)
  }

  private var statusIdentity: some View {
    HStack(alignment: .top, spacing: 10) {
      if isBusy {
        ProgressView()
          .controlSize(.small)
          .tint(tint)
          .padding(.top, 1)
      } else {
        Image(systemName: symbol)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 26, height: 26)
          .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.caption.weight(.semibold))
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var actionButtons: some View {
    if hasActions {
      HStack(spacing: 7) {
        if let secondaryActionTitle, let secondaryAction {
          Button {
            secondaryAction()
          } label: {
            Label(
              secondaryActionTitle, systemImage: secondaryActionSymbol ?? "arrow.up.forward.app")
          }
          .buttonStyle(LensButtonStyle(kind: .quiet, compact: true))
        }

        if let primaryActionTitle, let primaryAction {
          Button {
            primaryAction()
          } label: {
            Label(primaryActionTitle, systemImage: primaryActionSymbol ?? "finder")
          }
          .buttonStyle(LensButtonStyle(kind: .secondary, compact: true))
        }
      }
      .fixedSize()
    }
  }

  private var title: String {
    switch kind {
    case .empty: return "尚無掃描報告"
    case .loading: return "正在載入報告"
    case .scanning: return "完整掃描進行中"
    case .ready: return "掃描報告已就緒"
    case .cancelled: return "掃描已取消"
    case .failed: return "掃描未完成"
    }
  }

  private var symbol: String {
    switch kind {
    case .empty: return "doc.badge.plus"
    case .loading: return "arrow.clockwise"
    case .scanning: return "magnifyingglass"
    case .ready: return "checkmark.circle.fill"
    case .cancelled: return "stop.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    }
  }

  private var tint: Color {
    switch kind {
    case .empty, .loading, .scanning: return LensTheme.accentSoft
    case .ready: return LensTheme.sage
    case .cancelled: return LensTheme.sand
    case .failed: return LensTheme.clay
    }
  }
}
