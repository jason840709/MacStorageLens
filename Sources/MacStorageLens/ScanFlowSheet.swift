import SwiftUI

struct ScanFlowSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isConfirmingCancellation = false

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
    .alert("取消完整掃描？", isPresented: $isConfirmingCancellation) {
      Button("繼續掃描", role: .cancel) {}
      Button("安全停止", role: .destructive) { model.cancelFullScan() }
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
        Text("唯讀分析 · 顯示心跳與階段進度 · 完成後自動載入")
          .font(.caption)
          .foregroundStyle(.secondary)
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
    case .system: return "完整系統儲存空間掃描"
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
        title: "只讀取容量與檔案 metadata",
        detail: "掃描器不會刪除、移動、清空、修復或修改任何使用者／系統資料。"
      )
      PermissionExplanationRow(
        symbol: "person.badge.shield.checkmark.fill", tint: LensTheme.sage,
        title: model.selectedScanTarget.kind == .system ? "App TCC 與管理員權限分工" : "由 App 直接使用所選位置權限",
        detail: model.selectedScanTarget.kind == .system
          ? "先由 MacStorageLens 讀取受 TCC 保護的使用者資料，再把結果合併到管理員唯讀系統掃描；密碼仍只由 macOS 處理。"
          : "磁碟與資料夾模式不繞到獨立管理員子程序，避免遺失 App 的完整磁碟存取或使用者選取權限。"
      )
      PermissionExplanationRow(
        symbol: "waveform.path.ecg", tint: LensTheme.sand,
        title: "掃描期間持續回報心跳",
        detail: "畫面會顯示目前階段、路徑、步驟與節點數；長時間沒有心跳時會警告並安全中止。"
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
        Button("Terminal 診斷模式") { model.runFullScanInTerminal() }
          .buttonStyle(LensButtonStyle(kind: .quiet))
          .help("以 Terminal 自己的權限主體執行同一套掃描核心，供權限比對與故障診斷。")

        if model.selectedScanTarget.kind == .system {
          Button("只用 App 權限") { model.startIntegratedScan(mode: .currentUser) }
            .buttonStyle(LensButtonStyle(kind: .secondary))
          Button("App + 管理員掃描") { model.startIntegratedScan(mode: .administrator) }
            .buttonStyle(LensButtonStyle(kind: .primary))
            .keyboardShortcut(.defaultAction)
            .help("先使用 App 的完整磁碟存取，再取得管理員唯讀權限並合併兩個結果。")
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
            Text("所選位置權限")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Text("不需要探測 Mac 的受保護使用者資料")
              .font(.headline)
            Text(
              "這次只讀取「\(model.selectedScanTarget.displayName)」。Scanner 2.5.3 不會在開始外接磁碟或資料夾掃描前探測 Mail、Messages、Safari 或 AddressBook，也不會為非 APFS 目標查詢整台 Mac 的 APFS 清單。"
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
        "這份本機建立版使用臨時簽章；每次重新建立後，macOS 可能把它視為新的權限主體，屆時需重新加入完整磁碟存取列表。",
        systemImage: "signature"
      )
      .font(.caption2)
      .foregroundStyle(LensTheme.sand)
      .fixedSize(horizontal: false, vertical: true)
    } else if AppMetadata.hasStableCodeSigningIdentity {
      Label(
        "目前使用穩定的程式簽章身分；同一路徑更新時，macOS 較能持續辨識完整磁碟存取的授權主體。",
        systemImage: "checkmark.seal.fill"
      )
      .font(.caption2)
      .foregroundStyle(LensTheme.sage)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var appProbeTitle: String {
    switch model.appFullDiskAccessProbe.state {
    case .checking: return "正在核對完整磁碟存取…"
    case .available: return "App 直接讀取已通過"
    case .blocked: return "App 直接讀取被 macOS 阻擋"
    case .indeterminate: return "無法自動判定"
    case .notApplicable: return "所選位置不需要"
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
        "建議使用「App + 管理員掃描」。目前版本延續 0.7.1 的責任鏈修正，不再把獨立管理員子程序的 TCC 探針冒充為 App 權限；兩個責任鏈會分開記錄，受保護的使用者資料由 App 直接讀取後再合併。"
    }
    return "目前目標會由 MacStorageLens App 直接掃描，沿用你在選擇器與完整磁碟存取中授予的權限。Terminal 模式只保留為進階比對工具。"
  }

  private var running: some View {
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
          title: "最近心跳",
          value: heartbeatValue(progress.secondsSinceUpdate, health: progress.health),
          symbol: "waveform.path.ecg")
        metricTile(
          title: "目錄節點", value: progress.nodeCount.map(formatInteger) ?? "—",
          symbol: "folder.fill")
        metricTile(
          title: "受限／診斷行", value: progress.errorCount.map(formatInteger) ?? "—",
          symbol: "shield.lefthalf.filled")
        metricTile(
          title: "目前步驟", value: stepValue(progress),
          symbol: "list.number")
      }

      if let warningCount = progress.errorCount, warningCount > 0 {
        Text("這些通常是 macOS 拒絕讀取的個別路徑或系統警告；掃描器會把它們保留為 UNKNOWN_SIZE。數字增加不代表整體掃描失敗。")
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
              Text(progress.health == .stalled ? "掃描心跳延遲" : "暫時沒有新回報")
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
          "目前只讀取檔案系統與 APFS metadata；沒有啟用任何清理動作。",
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
            ? "掃描器已完成；App 正在解析完整報告並建立第一個容量地圖。"
            : "安全停止目前的唯讀掃描"
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
          Text("最新報告已解析，第一個容量地圖也已建立；現在看到的是完整的使用者等待時間。")
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
          timingSummary(timing)
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
          Text(timing.usedTerminalFallback ? "Terminal 相容模式" : "App 整合模式")
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
            title: "端到端",
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
          Text("Scanner 2.5.3 階段")
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
          "端到端從你按下掃描開始，直到報告索引與第一個容量地圖可操作。首次載入會用單次 Markdown 遍歷建立索引；重新載入同一份未變更報告時，會直接讀取本機容量索引。"
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
        Text("你的既有完成報告仍然保留。失敗工作的進度與 log 會暫存最多 24 小時，方便查看真正的 shell 錯誤；長時間沒有進展時仍會安全中止。")
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
        Button("Terminal 相容模式") { model.runFullScanInTerminal() }
          .buttonStyle(LensButtonStyle(kind: .secondary))
        Button("重新授權") { model.scanSheetPhase = .authorization }
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
      return "已經 \(value) 秒沒有收到核心掃描輸出。若達 120 秒，掃描監督器會終止本次工作並移除未完成報告。"
    }
    return "已經 \(value) 秒沒有新的核心輸出。大型目錄或 APFS 查詢可能短暫延遲；App 仍在監看程序與心跳檔。"
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
