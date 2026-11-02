import SwiftUI

struct OverviewView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    let activeTarget = model.document?.summary.target ?? model.selectedScanTarget
    return ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        LensPageHeader(
          eyebrow: activeTarget.displayName,
          title: "儲存空間總覽"
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
                ProgressView("正在建立容量地圖…")
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
    if let capacity = model.displayedLiveCapacity {
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
      Text(capacityScopeTitle)
        .font(.caption)
        .foregroundStyle(.secondary)
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
          title: "其餘已用空間",
          value: committedBytes,
          color: LensTheme.accentDeep,
          detail: "目前已用容量扣除可回收估計的部分。"
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
          detail: "目前未配置給檔案的空間。"
        )
      }

      if let document {
        ReportStatusBanner(
          message: model.statusMessage,
          kind: model.reportStatusKind,
          isBusy: model.isFullScanRunning || model.isLoadingReport,
          primaryActionTitle: "在 Finder 中顯示",
          primaryActionSymbol: "finder",
          primaryAction: { model.openInFinder(document.url.path) },
          secondaryActionTitle: "打開報告",
          secondaryActionSymbol: "doc.text",
          secondaryAction: { model.openFile(document.url.path) }
        )

        Text("目前報告時間：\(document.summary.generatedAt) · 掃描器 \(document.summary.scannerVersion)")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
  }

  private var capacityScopeTitle: String {
    let target = document?.summary.target ?? model.selectedScanTarget
    return target.kind == .folder
      ? "「\(target.displayName)」所在磁碟的即時容量"
      : "「\(target.displayName)」的即時容量"
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
        detail: "目前未配置給檔案的空間。"
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
          title: "其餘已用空間",
          value: committed,
          color: LensTheme.accentDeep,
          detail: "目前已用容量扣除可回收估計的部分。"
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
  @LensState private var isHovered = false

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
  @LensState private var hovered = false

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

  @LensState private var showsTechnicalDetails = false

  private var coverageTitle: String {
    summary.hasPartialCoverage ? "有記錄" : "未記錄"
  }

  private var badgeIsPositive: Bool {
    summary.targetKind != .system || summary.usedAppTCCOverlay || summary.fullDiskAccessAvailable
  }

  private var accessBadgeTitle: String {
    if summary.targetKind != .system {
      return "僅掃描所選位置"
    }
    if summary.hasAmbiguousLegacyAdministratorProbe {
      return "舊報告未記錄 App 權限"
    }
    if summary.usedAppTCCOverlay {
      return "已合併 App 讀取的資料"
    }
    switch summary.scannerPrivilegeChannel {
    case "app_direct":
      return summary.appFullDiskAccessAvailable ? "App 可讀受保護資料" : "App 讀取權限受限"
    case "terminal":
      return summary.scannerFullDiskAccessAvailable ? "Terminal 可讀受保護資料" : "Terminal 讀取權限受限"
    case "administrator_only":
      return summary.scannerFullDiskAccessAvailable
        ? "管理員程序可讀受保護資料"
        : "管理員程序讀取權限受限"
    default:
      return summary.fullDiskAccessAvailable ? "可讀受保護資料" : "讀取權限受限"
    }
  }

  private var accessExplanation: String {
    if summary.targetKind != .system {
      return "本次只掃描所選磁碟或資料夾，未測試郵件、訊息等受保護資料的讀取權限。"
    }
    if summary.hasAmbiguousLegacyAdministratorProbe {
      return "這份舊報告只測試管理員程序的讀取權限，未記錄 App 的權限。請重新掃描確認。"
    }
    if summary.usedAppTCCOverlay {
      let delta = signedBytes(summary.tccOverlayDeltaBytes)
      return "App 已將自己讀取的受保護資料合併到管理員掃描結果；合併後容量變化為 \(delta)。"
    }
    if summary.scannerPrivilegeChannel == "administrator_only" {
      if summary.appFullDiskAccessAvailable {
        return "App 已通過讀取權限測試，但資料未成功合併；目前只顯示管理員程序的掃描結果。請展開技術診斷查看合併狀態後重新掃描。"
      }
      return "本次只有管理員程序完成掃描。管理員權限無法取代完整磁碟存取權，部分受保護資料可能無法讀取。"
    }
    if summary.scannerPrivilegeChannel == "app_direct" {
      return summary.appFullDiskAccessAvailable
        ? "App 已通過受保護資料的讀取測試；是否有其他遺漏，請查看讀取限制紀錄與診斷訊息。"
        : "App 未通過受保護資料的讀取測試。請確認完整磁碟存取權已開啟，完全退出 App 後重新開啟並掃描。"
    }
    if summary.scannerPrivilegeChannel == "terminal" || summary.launcherMode == "terminal" {
      return summary.scannerFullDiskAccessAvailable
        ? "本次使用 Terminal 的完整磁碟存取權掃描；這與 App 的授權互相獨立。"
        : "Terminal 未通過受保護資料的讀取測試，請確認 Terminal 的完整磁碟存取權。"
    }
    return summary.fullDiskAccessAvailable
      ? "本次掃描已通過受保護資料的讀取測試；是否有其他遺漏，請查看讀取限制紀錄與診斷訊息。"
      : "本次未能確認受保護資料的讀取權限，請展開技術診斷查看測試結果。"
  }

  private var overlayStatusTitle: String {
    switch summary.tccOverlayStatus {
    case "READY": return "補充資料已讀取，尚未確認合併"
    case "APPLIED": return "合併完成"
    case "MERGE_FAILED": return "合併失敗，請重新掃描"
    case "FAILED": return "補充讀取失敗，請重新掃描"
    case "APP_FDA_BLOCKED": return "App 讀取受阻，請確認完整磁碟存取權後重新掃描"
    case "APP_FDA_INDETERMINATE": return "未能確認 App 讀取權限，請確認授權後重新掃描"
    default: return "未識別狀態，請重新掃描"
    }
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
          DetailPill(title: "掃描方式", value: summary.scanChannelDisplayName)
          DetailPill(title: "App 讀取權限", value: probeTitle(summary.appFullDiskAccessProbe))
          DetailPill(title: "掃描程序讀取權限", value: probeTitle(summary.scannerFullDiskAccessProbe))
          DetailPill(title: "管理員", value: summary.administratorReadAccess ? "已取得" : "未取得")
          DetailPill(title: "報告生成", value: summary.reportComplete ? "完成" : "未完成")
          DetailPill(title: "讀取限制紀錄", value: coverageTitle)
          DetailPill(title: "診斷訊息", value: "\(summary.duErrorLineCount)")
          DetailPill(title: "權限錯誤", value: "\(summary.errorCount)")
        }

        DisclosureGroup(isExpanded: $showsTechnicalDetails) {
          VStack(alignment: .leading, spacing: 6) {
            if summary.appFullDiskAccessProbePath != "NONE" {
              Text("App 讀取測試路徑：\(summary.appFullDiskAccessProbePath)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            if summary.scannerFullDiskAccessProbePath != "NONE" {
              Text("掃描程序讀取測試路徑：\(summary.scannerFullDiskAccessProbePath)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            if summary.usedAppTCCOverlay {
              Text(
                "App 補充資料：\(summary.tccOverlayTreeBytes.formattedBytes)；取代 \(summary.tccOverlayReplacedBytes.formattedBytes)；差額 \(signedBytes(summary.tccOverlayDeltaBytes))"
              )
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.tertiary)
            } else if summary.tccOverlayStatus != "NOT_REQUESTED" {
              Text("App 資料合併狀態：\(overlayStatusTitle)（\(summary.tccOverlayStatus)）")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            }
          }
          .padding(.top, 7)
        } label: {
          Label("技術診斷", systemImage: "wrench.and.screwdriver")
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
            symbol: "arrow.triangle.branch"
          )
          Spacer()
          snapshotBadge
        }

        if summary.targetKind == .folder {
          HStack(spacing: 10) {
            ReconciliationMetric(
              title: "資料夾占用空間",
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
              detail: "掃描時，所在磁碟回報的可用容量。"
            )
          }

          Text("圖表只包含所選資料夾；「所在磁碟容量」與「所在磁碟可用」是整顆磁碟的數字。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          HStack(spacing: 10) {
            ReconciliationMetric(
              title: usedLabel,
              value: usedBytes.formattedBytes,
              tint: LensTheme.accentSoft,
              detail: "檔案系統回報的已用容量，等於已列出路徑的容量與未解析差額的合計。"
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
            accessibilityTitle: headingTitle
          )

          if usesStableVolumeTree {
            VStack(alignment: .leading, spacing: 10) {
              Text("磁碟根目錄狀態")
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
                  title: "檔案變更紀錄：\(volatileStatusTitle(summary.targetFSEventsRootStatus))",
                  symbol: summary.targetFSEventsRootStatus == "PRESENT"
                    ? "waveform.path.ecg" : "checkmark",
                  tint: summary.targetFSEventsRootStatus == "PRESENT"
                    ? LensTheme.sand : LensTheme.sage
                )
                LensStatusBadge(
                  title: "磁碟垃圾桶：\(volatileStatusTitle(summary.targetTrashRootStatus))",
                  symbol: summary.targetTrashRootStatus == "PRESENT" ? "trash" : "checkmark",
                  tint: summary.targetTrashRootStatus == "PRESENT"
                    ? LensTheme.sand : LensTheme.sage
                )
              }

              HStack(alignment: .firstTextBaseline, spacing: 10) {
                if summary.totalDurationSeconds > 0 {
                  Label(
                    "掃描耗時：總計 \(summary.totalDurationSeconds) 秒 · 資料樹 \(summary.pathScanDurationSeconds) 秒",
                    systemImage: "stopwatch"
                  )
                  .font(.caption2.monospacedDigit())
                  .foregroundStyle(.tertiary)
                  .help(
                    "預檢 \(summary.preflightDurationSeconds) 秒 · 準備 \(summary.prepareDurationSeconds) 秒 · 資料樹 \(summary.pathScanDurationSeconds) 秒 · 磁碟狀態 \(summary.metadataDurationSeconds) 秒 · 寫報告 \(summary.reportWriteDurationSeconds) 秒 · 掃描總計 \(summary.totalDurationSeconds) 秒"
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
              "掃描期間已用容量變化：\(signedBytes(scanDeltaBytes))",
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
    case .system: return "macOS 資料卷容量核對"
    case .volume: return "磁碟容量核對"
    case .folder: return "資料夾掃描範圍"
    }
  }

  private var usedLabel: String {
    summary.targetKind == .system ? "資料卷已用" : "磁碟已用"
  }

  private var usedBytes: Int64 {
    summary.targetKind == .system ? summary.dataUsedBytes : summary.targetVolumeUsedBytes
  }

  private var usesStableVolumeTree: Bool {
    summary.targetKind == .volume && summary.volumeVolatileMetadataExcluded
  }

  private var visibleTreeTitle: String {
    "已列出路徑的容量"
  }

  private var visibleTreeDetail: String {
    if usesStableVolumeTree {
      return "已掃描並列出路徑的容量；不含垃圾桶、搜尋索引與檔案變更紀錄的內容。"
    }
    return "已掃描並列出檔案或資料夾路徑的容量。"
  }

  private var gapTitle: String {
    usesStableVolumeTree ? "未展開的系統資料與容量差額" : "未解析容量差額"
  }

  private var gapDetail: String {
    if usesStableVolumeTree {
      return "未展開的磁碟垃圾桶、搜尋索引、檔案變更紀錄，以及其他檔案系統差額。"
    }
    return "已用容量中未能對應到檔案或資料夾路徑的部分，不等於可清理容量。"
  }

  private var gapExplanation: String {
    if usesStableVolumeTree {
      let names =
        summary.volumeVolatileMetadataNames.isEmpty
        ? ".Trashes、.Spotlight-V100、.fseventsd 等"
        : summary.volumeVolatileMetadataNames.joined(separator: "、")
      return
        "掃描略過垃圾桶、Spotlight 搜尋索引與檔案變更紀錄的內容，以縮短重掃時間，包含 \(names)。它們仍計入已用容量；這部分也包含其他檔案系統差額，不能全部視為可刪除資料。"
    }
    return "未解析差額可能來自無法讀取的資料夾、快照、檔案系統本身的資料、檔案共用區塊，或使用中的檔案，不能全部視為可刪除資料。"
  }

  private var gapDisclosureTitle: String {
    usesStableVolumeTree ? "哪些系統資料未展開？" : "為什麼會有容量差額？"
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
  @LensState private var hovered = false

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
  var visibleTitle = "已列出路徑的容量"
  var visibleDetail = "已掃描並列出檔案或資料夾路徑的容量。"
  var gapTitle = "未解析容量差額"
  var gapDetail = "快照、讀取限制、檔案系統資料或共用區塊等未能對應到檔案路徑的容量。"
  var accessibilityTitle = "macOS 資料卷容量核對"

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
  @LensState private var isHovered = false

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
    case "掃描方式":
      return "本次掃描由 App、管理員授權或 Terminal 執行。"
    case "App 讀取權限":
      return "App 是否能讀取受完整磁碟存取權保護的資料。"
    case "掃描程序讀取權限":
      return "掃描程序是否能讀取受保護資料；它的讀取權限可能與 App 不同。"
    case "管理員":
      return "本次掃描是否取得管理員權限；它無法取代完整磁碟存取權。"
    case "報告生成":
      return "報告完成後才會加入掃描紀錄。"
    case "讀取限制紀錄":
      return "依報告中的診斷訊息與掃描狀態，顯示是否記錄讀取限制。"
    case "診斷訊息":
      return "掃描過程記錄的限制或診斷訊息數；有訊息不代表整份掃描失敗。"
    case "權限錯誤":
      return "因權限不足而無法讀取資料的訊息數。"
    default:
      return "本次掃描的來源與讀取狀態。"
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
            "容量地圖",
            subtitle: chartSubtitle,
            symbol: "circle.hexagongrid.fill"
          )
          Spacer(minLength: 8)
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
    "掃描時的容量；同色代表同一分支，越外圈代表越深的資料夾。點一下資料夾進入，按右鍵開啟 Finder 選單。"
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
  @LensState private var isHovered = false

  var body: some View {
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: 3)
        .fill(tint)
        .frame(width: 8, height: 30)

      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(item.storageDisplayLabel)
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
      title: item.storageDisplayLabel,
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
      explanation = "資料夾總占用扣除已列出子資料夾後的差額；點一下讀取目前第一層檔案。"
    case .otherChildren:
      explanation = "這些子資料夾合併顯示；點一下展開，按右鍵可前往父資料夾。"
    case .accountingGap:
      explanation =
        item.label.contains("卷宗中繼資料")
        ? "未展開的磁碟垃圾桶、搜尋索引、檔案變更紀錄與其他檔案系統差額，不等於可清理容量。"
        : "未能對應到 Finder 路徑的已用容量，可能包含快照、讀取限制與檔案系統資料，不等於可清理容量。"
    case .containerAccounting:
      explanation = "APFS 檔案系統記錄的其他用量，沒有可直接開啟或清理的資料夾。"
    case .scanDelta:
      explanation = "掃描前後已用容量的變化，沒有對應的固定檔案。"
    case .freeSpace:
      explanation = "掃描時未配置給檔案的空間。"
    case .purgeable:
      explanation = "這是 macOS 估算可在需要時回收的容量，不能等同於一個可直接刪除的資料夾。"
    case .otherVolume:
      explanation =
        item.finderPath == nil
        ? "另一個 APFS 卷的容量，沒有一般 Finder 路徑。"
        : "這是另一個已掛載卷；可使用右鍵 Finder 操作查看其位置。"
    case .none:
      explanation =
        item.isNavigable
        ? "點一下在資料樹查看此資料夾，按右鍵可使用 Finder 操作。"
        : "此項目沒有可開啟的 Finder 路徑。"
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
          Text("建立第一份容量地圖")
            .font(.title2.weight(.semibold))
          Text("掃描會依所選位置要求存取授權，完成後自動載入報告。掃描只讀取資料，不會刪除或移動檔案。")
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
              Label("開始掃描", systemImage: "magnifyingglass")
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
  @LensState private var hovered = false

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
    case .scanning: return "掃描進行中"
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
