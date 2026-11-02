import SwiftUI

struct ScanFlowSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @LensState private var isConfirmingCancellation = false
  @LensState private var showsTimingDetails = false

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().opacity(0.55)
      ZStack {
        phaseContent
          .id(phaseIdentity)
          .transition(phaseTransition)
      }
      .animation(reduceMotion ? nil : LensMotion.phase, value: phaseIdentity)
    }
    .frame(minWidth: 760, idealWidth: 760, maxWidth: 760, minHeight: 690, idealHeight: 760)
    .background(LensTheme.canvas(colorScheme))
    .interactiveDismissDisabled(model.isFullScanRunning || model.isLoadingReport)
    .alert("停止本次掃描？", isPresented: $isConfirmingCancellation) {
      Button("繼續掃描", role: .cancel) {}
      Button("停止掃描", role: .destructive) { model.cancelFullScan() }
    } message: {
      Text("App 會停止目前的唯讀工作、移除本次未完成報告，並保留上一份完成報告。")
    }
  }

  private var header: some View {
    HStack(spacing: 13) {
      LensMark(size: 42)
      VStack(alignment: .leading, spacing: 2) {
        Text(scanTitle)
          .font(.title2.weight(.semibold))
        if case .authorization = model.scanSheetPhase {
          Text("完成後自動顯示容量地圖。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      if !model.isFullScanRunning && !model.isLoadingReport {
        Button {
          close()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(LensIconButtonStyle())
        .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
  }

  private var phaseIdentity: String {
    switch model.scanSheetPhase {
    case .authorization: return "authorization"
    case .running: return "running"
    case .completed: return "completed"
    case .cancelled: return "cancelled"
    case .failed: return "failed"
    }
  }

  private var phaseTransition: AnyTransition {
    if reduceMotion { return .opacity }
    return .asymmetric(
      insertion: .opacity.combined(with: .scale(scale: 0.985)),
      removal: .opacity
    )
  }

  private var scanTitle: String {
    switch model.selectedScanTarget.kind {
    case .system: return "系統儲存空間掃描"
    case .volume: return "磁碟掃描"
    case .folder: return "資料夾掃描"
    }
  }

  @ViewBuilder
  private var phaseContent: some View {
    switch model.scanSheetPhase {
    case .authorization:
      authorization
    case .running:
      running
    case .completed(let report):
      completed(report)
    case .cancelled(let message):
      cancelled(message)
    case .failed(let message):
      failed(message)
    }
  }

  private var authorization: some View {
    VStack(alignment: .leading, spacing: 14) {
      LensPanel(padding: 14, radius: 14) {
        HStack(spacing: 12) {
          Image(systemName: model.selectedScanTarget.kind.symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(LensTheme.accentSoft)
            .frame(width: 38, height: 38)
            .background(LensTheme.accentSoft.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

          VStack(alignment: .leading, spacing: 3) {
            Text("掃描目標")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(model.selectedScanTarget.displayName)
              .font(.headline)
            Text(model.selectedScanTarget.path)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }

          Spacer()

          Menu {
            NextScanTargetMenuContent(includesDisplayedLocationShortcut: false)
              .environmentObject(model)
          } label: {
            LensMenuControlLabel(
              caption: "掃描位置 · \(model.selectedScanTargetStateTitle)",
              title: model.selectedScanTarget.compactLocationTitle,
              symbol: "scope",
              tint: LensTheme.sage,
              compact: true
            )
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .help("切換本次掃描的位置；不會改變總覽目前顯示的既有容量地圖")
        }
      }

      appPermissionPanel

      PermissionExplanationRow(
        symbol: "eye.fill", tint: LensTheme.accentSoft,
        title: "唯讀掃描",
        detail: "掃描只讀取容量與檔案資訊，不會刪除、移動或修改資料。"
      )
      if model.selectedScanTarget.kind == .system {
        PermissionExplanationRow(
          symbol: "person.badge.shield.checkmark.fill", tint: LensTheme.sage,
          title: "管理員授權由 macOS 處理",
          detail: "選擇管理員掃描後，macOS 會要求授權；密碼只交給 macOS。"
        )
      }
      PermissionExplanationRow(
        symbol: "waveform.path.ecg", tint: LensTheme.sand,
        title: "App 掃描進度",
        detail: "使用 App 掃描時，畫面會顯示目前階段與位置；長時間沒有進展時，App 會提醒並停止掃描。"
      )

      LensPanel(padding: 13, radius: 13) {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "info.circle.fill")
            .foregroundStyle(LensTheme.accentSoft)
          Text(scanModeExplanation)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: 2)

      HStack {
        if model.selectedScanTarget.kind == .system {
          Button("完整磁碟存取設定") { ScannerLauncher.openFullDiskAccessSettings() }
            .buttonStyle(LensButtonStyle(kind: .secondary, compact: true))
        }
        Spacer()
        Button("Terminal 掃描") { model.runFullScanInTerminal() }
          .buttonStyle(LensButtonStyle(kind: .quiet))
          .help("在 Terminal 執行相同掃描，使用 Terminal 的磁碟存取權，可用來檢查 App 掃描失敗是否與權限有關。")

        if model.selectedScanTarget.kind == .system {
          Button("只用 App 權限") { model.startIntegratedScan(mode: .currentUser) }
            .buttonStyle(LensButtonStyle(kind: .secondary))
          Button("App + 管理員掃描") { model.startIntegratedScan(mode: .administrator) }
            .buttonStyle(LensButtonStyle(kind: .primary))
            .keyboardShortcut(.defaultAction)

        } else {
          Button("使用 App 權限掃描") { model.startIntegratedScan(mode: .currentUser) }
            .buttonStyle(LensButtonStyle(kind: .primary))
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(20)
  }

  @ViewBuilder
  private var appPermissionPanel: some View {
    if model.selectedScanTarget.kind == .system {
      LensPanel(padding: 13, radius: 14) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 11) {
            Image(systemName: appProbeSymbol)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(appProbeTint)
              .frame(width: 34, height: 34)
              .background(appProbeTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
              Text("MacStorageLens App 權限")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
              Text(appProbeTitle)
                .font(.headline)
            }

            Spacer()

            if model.appFullDiskAccessProbe.state == .checking {
              ProgressView()
                .controlSize(.small)
            } else {
              Button {
                model.refreshFullDiskAccessProbe()
              } label: {
                Image(systemName: "arrow.clockwise")
              }
              .buttonStyle(LensIconButtonStyle())
              .help("重新由 MacStorageLens App 本身核對受保護路徑讀取權")
            }
          }

          Text(model.appFullDiskAccessProbe.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          codeSigningPermissionNote
        }
      }
    } else {
      LensPanel(padding: 13, radius: 14) {
        HStack(alignment: .top, spacing: 11) {
          Image(systemName: "externaldrive.badge.checkmark")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(LensTheme.sage)
            .frame(width: 34, height: 34)
            .background(LensTheme.sage.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

          VStack(alignment: .leading, spacing: 4) {
            Text("掃描範圍與權限")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(
              "使用 App 對「\(model.selectedScanTarget.displayName)」的讀取權限掃描此位置；所在磁碟的容量資訊會另外顯示。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var codeSigningPermissionNote: some View {
    if AppMetadata.codeSigningMode == "ad-hoc" {
      Label(
        "這份本機版重新建立後，macOS 可能要求重新授予完整磁碟存取權。",
        systemImage: "signature"
      )
      .font(.caption2)
      .foregroundStyle(LensTheme.sand)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var appProbeTitle: String {
    switch model.appFullDiskAccessProbe.state {
    case .checking: return "正在核對完整磁碟存取…"
    case .available: return "可讀取受保護資料"
    case .blocked: return "macOS 拒絕讀取"
    case .indeterminate: return "無法自動判定"
    case .notApplicable: return "未檢查系統資料權限"
    }
  }

  private var appProbeSymbol: String {
    switch model.appFullDiskAccessProbe.state {
    case .checking: return "hourglass"
    case .available: return "checkmark.shield.fill"
    case .blocked: return "exclamationmark.shield.fill"
    case .indeterminate: return "questionmark.diamond.fill"
    case .notApplicable: return "externaldrive.badge.checkmark"
    }
  }

  private var appProbeTint: Color {
    switch model.appFullDiskAccessProbe.state {
    case .checking, .indeterminate: return LensTheme.sand
    case .notApplicable: return LensTheme.sage
    case .available: return LensTheme.sage
    case .blocked: return LensTheme.clay
    }
  }

  private var scanModeExplanation: String {
    if model.selectedScanTarget.kind == .system {
      return
        "建議選「App + 管理員掃描」：App 先讀取已獲授權的受保護資料，再由管理員權限掃描系統其他位置，最後合併結果。"
    }
    return "若要比對權限或診斷掃描問題，可使用 Terminal 掃描。Terminal 使用自己的存取權限。"
  }

  @ViewBuilder
  private var running: some View {
    if model.isTerminalScanRunning {
      terminalRunning
    } else {
      integratedRunning
    }
  }

  private var terminalRunning: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("正在等待 Terminal 的完成報告", systemImage: "terminal")
        .font(.title3.weight(.semibold))
      Text("掃描在 Terminal 中執行，請在該視窗查看進度。App 會等待完成報告，找到後自動載入容量地圖。")
        .foregroundStyle(.secondary)
      LensPanel(padding: 16, radius: 14) {
        Text("App 無法停止 Terminal 中的掃描。要停止，請在 Terminal 視窗按 Control-C；App 也不會代為清除該次未完成報告。")
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text("Terminal 使用自己的磁碟存取權；MacStorageLens 的授權不會自動套用。App 最多等待 30 分鐘，停止等待不會停止 Terminal 中的掃描。")
        .font(.caption)
        .foregroundStyle(.secondary)
      Button("返回主畫面") { close() }
        .buttonStyle(LensButtonStyle(kind: .secondary))
        .help("關閉這個畫面，App 仍會繼續等待完成報告。")
      Spacer(minLength: 0)
    }
    .padding(24)
  }

  private var integratedRunning: some View {
    let progress = model.scanProgress

    return VStack(spacing: 18) {
      HStack(alignment: .center, spacing: 22) {
        progressRing(progress)
        VStack(alignment: .leading, spacing: 9) {
          HStack(spacing: 8) {
            Text(progress.stage)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .textCase(.uppercase)
            healthBadge(progress.health)
          }
          Text(progress.message)
            .font(.title3.weight(.semibold))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          if let detail = progress.detail {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .truncationMode(.middle)
          }
          if let path = progress.currentPath, !path.isEmpty {
            Label(path, systemImage: "folder")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }
          if let current = progress.currentStep, let total = progress.totalSteps, total > 0 {
            Text("目前步驟 \(current)／\(total)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      progressBar(progress)

      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
        alignment: .leading,
        spacing: 10
      ) {
        metricTile(title: "已經過", value: formatDuration(progress.elapsedSeconds), symbol: "clock")
        metricTile(
          title: "估計剩餘",
          value: progress.estimatedRemainingSeconds.map(formatDuration) ?? "計算中",
          symbol: "hourglass")
        metricTile(
          title: "最近回報",
          value: heartbeatValue(progress.secondsSinceUpdate, health: progress.health),
          symbol: "waveform.path.ecg")
        metricTile(
          title: "目錄節點", value: progress.nodeCount.map(formatInteger) ?? "—",
          symbol: "folder.fill")
        metricTile(
          title: "無法讀取或警告", value: progress.errorCount.map(formatInteger) ?? "—",
          symbol: "shield.lefthalf.filled")
        metricTile(
          title: "目前步驟", value: stepValue(progress),
          symbol: "list.number")
      }

      if let warningCount = progress.errorCount, warningCount > 0 {
        Text("部分路徑可能因 macOS 權限限制而無法計算大小；這些項目會標為未知，不代表整次掃描失敗。")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if progress.health == .delayed || progress.health == .stalled {
        LensPanel(padding: 13, radius: 13) {
          HStack(alignment: .top, spacing: 10) {
            Image(
              systemName: progress.health == .stalled
                ? "exclamationmark.triangle.fill" : "clock.badge.exclamationmark"
            )
            .foregroundStyle(progress.health == .stalled ? LensTheme.clay : LensTheme.sand)
            VStack(alignment: .leading, spacing: 3) {
              Text(progress.health == .stalled ? "掃描回報延遲" : "暫時沒有新回報")
                .font(.caption.weight(.semibold))
              Text(staleExplanation(progress.secondsSinceUpdate))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("診斷資料") { model.openScanDiagnosticsFolder() }
              .buttonStyle(LensButtonStyle(kind: .quiet, compact: true))
          }
        }
      }

      if !progress.recentMessages.isEmpty {
        LensPanel(padding: 13, radius: 13) {
          VStack(alignment: .leading, spacing: 8) {
            Label("最近進展", systemImage: "list.bullet.rectangle")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            ForEach(Array(progress.recentMessages.suffix(4).enumerated()), id: \.offset) {
              _, message in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                  .fill(LensTheme.accentSoft.opacity(0.75))
                  .frame(width: 5, height: 5)
                Text(message)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      HStack(spacing: 12) {
        Label(
          "目前只讀取磁碟與檔案資訊，不會清理任何資料。",
          systemImage: "shield.checkered"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Spacer()
        Button(
          model.isLoadingReport
            ? "正在建立畫面…"
            : (progress.health == .cancelling ? "正在停止…" : "取消掃描"),
          role: .destructive
        ) {
          isConfirmingCancellation = true
        }
        .buttonStyle(LensButtonStyle(kind: .destructive, compact: true))
        .disabled(model.isLoadingReport || progress.health == .cancelling)
        .help(
          model.isLoadingReport
            ? "掃描器已完成；App 正在讀取報告並建立容量地圖。"
            : "停止目前的唯讀掃描"
        )
      }

      Spacer(minLength: 0)
    }
    .padding(24)
  }

  private func progressRing(_ progress: ScanProgressSnapshot) -> some View {
    ZStack {
      Circle()
        .stroke(LensTheme.recessed(colorScheme), lineWidth: 9)
      if let fraction = progress.fraction {
        Circle()
          .trim(from: 0, to: max(0.01, min(1, fraction)))
          .stroke(
            LinearGradient(
              colors: [LensTheme.accentSoft, LensTheme.accentDeep],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            style: StrokeStyle(lineWidth: 9, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))
      } else {
        ProgressView()
          .controlSize(.large)
      }

      VStack(spacing: 3) {
        if let fraction = progress.fraction {
          Text(String(format: "%.0f%%", fraction * 100))
            .font(.title2.weight(.semibold))
            .monospacedDigit()
        } else {
          Image(systemName: "ellipsis")
            .font(.title3.weight(.semibold))
        }
        Text(progress.isEstimated ? "估計進度" : "進度")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: 112, height: 112)
  }

  private func progressBar(_ progress: ScanProgressSnapshot) -> some View {
    VStack(spacing: 7) {
      if let fraction = progress.fraction {
        ProgressView(value: fraction, total: 1)
          .progressViewStyle(.linear)
          .tint(LensTheme.accentSoft)
      } else {
        ProgressView()
          .progressViewStyle(.linear)
      }

      HStack {
        Text(progress.fraction == nil ? "等待授權或掃描器啟動" : "依掃描階段與完成步驟估算")
        Spacer()
        Text(progress.fraction.map { String(format: "%.1f%%", $0 * 100) } ?? "尚未開始")
          .monospacedDigit()
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)
    }
  }

  private func completed(_ report: URL) -> some View {
    ScrollView {
      VStack(spacing: 18) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 58, weight: .semibold))
          .foregroundStyle(LensTheme.sage)
        VStack(spacing: 6) {
          Text("掃描與容量地圖已完成")
            .font(.title2.weight(.semibold))
          Text("報告已儲存，容量地圖可在總覽查看。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          Text(report.lastPathComponent)
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        if let timing = timing(for: report) {
          Text("本次掃描耗時 \(formatTiming(timing.requestToReadySeconds))（從開始掃描到容量地圖可用）")
            .font(.callout)
            .foregroundStyle(.secondary)
          DisclosureGroup("查看詳細耗時與診斷", isExpanded: $showsTimingDetails) {
            timingSummary(timing)
              .padding(.top, 8)
          }
        }

        HStack(spacing: 10) {
          Button("開啟報告資料夾") { model.openReportsFolder() }
            .buttonStyle(LensButtonStyle(kind: .secondary))
          if let timing = timing(for: report), let diagnostics = timing.diagnosticDirectoryURL {
            Button("本次診斷") { model.openPathInFinder(diagnostics.path) }
              .buttonStyle(LensButtonStyle(kind: .quiet))
              .help("開啟這次掃描保留的 session-summary、progress 與 scanner log")
          }
          Button("查看總覽") {
            model.destination = .overview
            close()
          }
          .buttonStyle(LensButtonStyle(kind: .primary))
          .keyboardShortcut(.defaultAction)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(26)
    }
  }

  private func timingSummary(_ timing: ScanTimingSnapshot) -> some View {
    LensPanel(padding: 14, radius: 14) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Label("本次耗時拆解", systemImage: "stopwatch.fill")
            .font(.headline)
          Spacer()
          Text(timing.usedTerminalFallback ? "Terminal 掃描" : "App 掃描")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(timing.usedTerminalFallback ? LensTheme.sand : LensTheme.sage)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
              (timing.usedTerminalFallback ? LensTheme.sand : LensTheme.sage).opacity(0.12),
              in: Capsule()
            )
        }

        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3),
          alignment: .leading,
          spacing: 9
        ) {
          timingMetric(
            title: "開始至地圖可用",
            value: formatTiming(timing.requestToReadySeconds),
            symbol: "stopwatch.fill"
          )
          timingMetric(
            title: "Scanner 核心",
            value: formatTiming(Double(timing.scannerTotalSeconds)),
            symbol: "externaldrive.fill"
          )
          timingMetric(
            title: "Scanner 外等待",
            value: formatTiming(timing.appOutsideScannerSeconds),
            symbol: "hourglass"
          )
          timingMetric(
            title: timing.presentationIndexSource == .persistentCache
              ? "讀取容量索引"
              : "建立容量索引",
            value: formatTiming(timing.reportParseSeconds),
            symbol: timing.presentationIndexSource == .persistentCache
              ? "bolt.horizontal.circle.fill"
              : "doc.text.magnifyingglass"
          )
          timingMetric(
            title: "初始容量圖",
            value: formatTiming(timing.initialViewBuildSeconds),
            symbol: "chart.pie.fill"
          )
          if timing.presentationIndexSource == .markdownSinglePass {
            timingMetric(
              title: "索引寫入",
              value: formatTiming(timing.presentationIndexWriteSeconds),
              symbol: "internaldrive.fill"
            )
          }
          timingMetric(
            title: "Scanner 未歸因",
            value: formatTiming(Double(timing.scannerUnattributedSeconds)),
            symbol: "questionmark.circle"
          )
        }

        Divider().opacity(0.55)

        VStack(alignment: .leading, spacing: 7) {
          Text("Scanner 2.5.4 階段")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          HStack(spacing: 7) {
            timingPhaseBadge("預檢", seconds: timing.scannerPreflightSeconds)
            timingPhaseBadge("準備", seconds: timing.scannerPrepareSeconds)
            timingPhaseBadge("資料樹", seconds: timing.scannerPathSeconds)
            timingPhaseBadge("磁碟狀態", seconds: timing.scannerMetadataSeconds)
            timingPhaseBadge("寫報告", seconds: timing.scannerReportWriteSeconds)
          }
        }

        if let target = timing.targetResolutionSeconds,
          let install = timing.scannerInstallationSeconds,
          let probe = timing.permissionProbeSeconds,
          let preparation = timing.sessionPreparationSeconds
        {
          Text(
            "App 啟動前置：目標解析 \(formatTiming(target)) · 安裝掃描器 \(formatTiming(install)) · 權限探測 \(formatTiming(probe)) · 建立工作階段 \(formatTiming(preparation))"
          )
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
        }

        Text(
          "總耗時包含掃描、讀取報告與建立容量地圖；報告內的掃描器耗時只計掃描工作。"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func timingMetric(title: String, value: String, symbol: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(title, systemImage: symbol)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(9)
    .background(LensTheme.recessed(colorScheme), in: RoundedRectangle(cornerRadius: 10))
  }

  private func timingPhaseBadge(_ title: String, seconds: Int) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(formatTiming(Double(seconds)))
        .font(.caption.weight(.semibold))
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .background(LensTheme.recessed(colorScheme), in: RoundedRectangle(cornerRadius: 9))
  }

  private func timing(for report: URL) -> ScanTimingSnapshot? {
    guard let timing = model.lastScanTiming,
      timing.reportURL.standardizedFileURL == report.standardizedFileURL
    else { return nil }
    return timing
  }

  private func formatTiming(_ seconds: TimeInterval) -> String {
    let safe = max(0, seconds)
    if safe < 10 { return String(format: "%.2f 秒", safe) }
    if safe < 60 { return String(format: "%.1f 秒", safe) }
    return formatDuration(Int(safe.rounded()))
  }

  private func cancelled(_ message: String) -> some View {
    VStack(spacing: 19) {
      Image(systemName: "stop.circle.fill")
        .font(.system(size: 58, weight: .semibold))
        .foregroundStyle(LensTheme.sand)
      VStack(spacing: 7) {
        Text("掃描已停止")
          .font(.title2.weight(.semibold))
        Text(message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 500)
      }
      LensPanel(padding: 13, radius: 13) {
        Text("本次未完成報告與工作暫存會被移除；上一份完成報告不受影響。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 10) {
        Button("關閉") { close() }
          .buttonStyle(LensButtonStyle(kind: .secondary))
        Button("重新設定掃描") { model.scanSheetPhase = .authorization }
          .buttonStyle(LensButtonStyle(kind: .primary))
          .keyboardShortcut(.defaultAction)
      }
      Spacer(minLength: 0)
    }
    .padding(28)
  }

  private func failed(_ message: String) -> some View {
    VStack(spacing: 18) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 52, weight: .semibold))
        .foregroundStyle(LensTheme.clay)
      VStack(spacing: 7) {
        Text("掃描沒有完成")
          .font(.title2.weight(.semibold))
        Text(message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
          .frame(maxWidth: 510)
      }
      LensPanel(padding: 13, radius: 13) {
        Text("上一份完成報告仍保留。App 執行的掃描若失敗，診斷資料會保留最多 24 小時。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 10) {
        Button("關閉") { close() }
          .buttonStyle(LensButtonStyle(kind: .secondary))
        if !model.reportHistory.isEmpty {
          Button("載入已完成報告") {
            model.loadLatestReport()
            close()
          }
          .buttonStyle(LensButtonStyle(kind: .secondary))
        }
        Button("診斷資料") { model.openScanDiagnosticsFolder() }
          .buttonStyle(LensButtonStyle(kind: .quiet))
        Button("在 Terminal 重試") { model.runFullScanInTerminal() }
          .buttonStyle(LensButtonStyle(kind: .secondary))
          .help("Terminal 使用自己的磁碟存取權限；App 的授權不會自動套用。")
        Button("重新設定掃描") { model.scanSheetPhase = .authorization }
          .buttonStyle(LensButtonStyle(kind: .primary))
          .keyboardShortcut(.defaultAction)
      }
      Spacer(minLength: 0)
    }
    .padding(26)
  }

  private func healthBadge(_ health: ScanProgressHealth) -> some View {
    let configuration: (String, String, Color)
    switch health {
    case .waitingForAuthorization:
      configuration = ("等待授權", "lock.fill", LensTheme.sand)
    case .active:
      configuration = ("持續回報", "waveform.path.ecg", LensTheme.sage)
    case .delayed:
      configuration = ("回報延遲", "clock.badge.exclamationmark", LensTheme.sand)
    case .stalled:
      configuration = ("可能無回應", "exclamationmark.triangle.fill", LensTheme.clay)
    case .cancelling:
      configuration = ("正在停止", "stop.fill", LensTheme.clay)
    }

    return Label(configuration.0, systemImage: configuration.1)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(configuration.2)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(configuration.2.opacity(0.12), in: Capsule())
  }

  private func metricTile(title: String, value: String, symbol: String) -> some View {
    LensPanel(padding: 10, radius: 12) {
      VStack(alignment: .leading, spacing: 5) {
        Label(title, systemImage: symbol)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.callout.weight(.semibold))
          .monospacedDigit()
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func heartbeatValue(_ seconds: Int?, health: ScanProgressHealth) -> String {
    if health == .waitingForAuthorization { return "等待授權" }
    guard let seconds else { return "尚未收到" }
    if seconds <= 1 { return "剛剛" }
    return "\(seconds) 秒前"
  }

  private func staleExplanation(_ seconds: Int?) -> String {
    let value = seconds ?? 0
    if value >= 60 {
      return "已經 \(value) 秒沒有收到掃描回報。若達 120 秒，掃描會停止並移除未完成報告。"
    }
    return "已經 \(value) 秒沒有新的掃描回報。大型資料夾或磁碟查詢可能暫時沒有進展；App 仍會持續監看。"
  }

  private func formatDuration(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let remaining = seconds % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remaining) }
    return String(format: "%d:%02d", minutes, remaining)
  }

  private func formatInteger(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic))
  }

  private func stepValue(_ progress: ScanProgressSnapshot) -> String {
    guard let current = progress.currentStep, let total = progress.totalSteps, total > 0 else {
      return progress.stage
    }
    return "\(current)／\(total)"
  }

  private func close() {
    model.dismissScanSheet()
    dismiss()
  }
}

private struct PermissionExplanationRow: View {
  let symbol: String
  let tint: Color
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 13) {
      Image(systemName: symbol)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 34, height: 34)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
