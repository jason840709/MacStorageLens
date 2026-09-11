import SwiftUI

struct CleanerView: View {
  @EnvironmentObject private var model: AppModel
  @State private var pendingExecutionMode: CleanupExecutionMode?

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          LensPageHeader(
            eyebrow: "分級掃描 · 逐項確認",
            title: "安全清理",
            subtitle: headerSubtitle
          ) {
            Menu {
              NextScanTargetMenuContent()
            } label: {
              LensMenuControlLabel(
                caption: "清理位置 · \(model.selectedScanTargetStateTitle)",
                title: model.selectedScanTarget.compactLocationTitle,
                symbol: model.cleanupMode.symbol,
                tint: cleanupModeTint(model.cleanupMode),
                compact: true
              )
              .frame(width: 230)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.isScanningCleanup || model.isCleaning)
            .help("安全清理會使用下次掃描位置：\(model.selectedScanTarget.path)")

            CleanupScanActionButtons()
          }

          CleanupTargetStrip()
          if model.cleanupMode == .generalLocation {
            CleanupRemovalCapabilityNotice()
            CleanupScanSourceSelector()
          }
          if model.cleanupIndexDescription != nil {
            CleanupIncrementalIndexNotice()
          }
          CleanupProfileSelector()

          if model.cleanupProfile == .custom {
            CustomCleanupConfigurationCard()
          }

          if model.isScanningCleanup {
            CleanupScanProgressCard(progress: model.cleanupScanProgress)
          } else if let result = model.cleanupLastResult {
            CleanupResultSummary(result: result)
            if result.candidates.isEmpty {
              CleanupNoResultsState(result: result)
            } else {
              candidateGroups
            }
          } else {
            CleanupEmptyState()
          }
        }
        .padding(26)
        .padding(.bottom, 8)
        .frame(maxWidth: 1320)
        .frame(maxWidth: .infinity, alignment: .top)
      }

      CleanupActionBar(pendingExecutionMode: $pendingExecutionMode)
    }
    .navigationTitle("安全清理")
    .sheet(item: $pendingExecutionMode) { executionMode in
      CleanupConfirmationSheet(executionMode: executionMode)
        .environmentObject(model)
    }
  }

  private var headerSubtitle: String {
    switch model.cleanupMode {
    case .system:
      return "依風險逐層擴大 macOS 白名單候選；所選等級會直接顯示對應範圍，掃描後仍由你逐項確認。"
    case .generalLocation:
      return "可重用儲存空間總覽的容量報告快速建立候選，也可選擇重新完整掃描；._ 檔仍會即時驗證 AppleDouble 內容與同名主檔。"
    }
  }

  private var candidateGroups: some View {
    VStack(alignment: .leading, spacing: 18) {
      ForEach(CleanupCategory.allCases, id: \.rawValue) { category in
        let candidates = model.cleanupCandidates.filter { $0.category == category }
        if !candidates.isEmpty {
          CleanupCategorySection(category: category, candidates: candidates)
        }
      }
    }
  }
}

private struct CleanupScanActionButtons: View {
  @EnvironmentObject private var model: AppModel
  var compact = false

  var body: some View {
    if model.cleanupHasReusableIndex {
      HStack(spacing: 8) {
        Button {
          model.scanCleanupCandidates()
        } label: {
          Label("補充掃描", systemImage: "plus.magnifyingglass")
        }
        .buttonStyle(LensButtonStyle(kind: .primary, compact: compact))
        .help(model.cleanupSupplementalScanDetail)

        Button {
          model.rescanCleanupCandidatesFully()
        } label: {
          Label("完整重新掃描", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(LensButtonStyle(kind: .secondary, compact: compact))
        .help(model.cleanupFullRescanDetail)
      }
      .disabled(scanDisabled)
    } else {
      Button {
        model.scanCleanupCandidates()
      } label: {
        Label("開始掃描", systemImage: "sparkles.rectangle.stack")
      }
      .buttonStyle(LensButtonStyle(kind: .primary, compact: compact))
      .help("第一次掃描會建立目前等級的清理索引；完成後可選補充掃描或完整重新掃描。")
      .disabled(scanDisabled)
    }
  }

  private var scanDisabled: Bool {
    model.isScanningCleanup || model.isCleaning
      || (model.cleanupProfile == .custom && !model.hasActiveCustomCleanupScopes)
  }
}

private struct CleanupTargetStrip: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    LensPanel(padding: 14) {
      HStack(alignment: .center, spacing: 13) {
        Image(systemName: model.cleanupMode.symbol)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(cleanupModeTint(model.cleanupMode))
          .frame(width: 38, height: 38)
          .background(
            cleanupModeTint(model.cleanupMode).opacity(0.13),
            in: RoundedRectangle(cornerRadius: 11)
          )

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            Text(model.cleanupMode.title)
              .font(.headline)
            LensStatusBadge(
              title: model.selectedScanTargetStateTitle,
              symbol: model.selectedScanTargetStateTitle == "已保存"
                ? "checkmark.circle" : "clock",
              tint: model.selectedScanTargetStateTitle == "已保存"
                ? LensTheme.sage : LensTheme.sand
            )
          }
          Text(model.selectedScanTarget.locationTitle)
            .font(.callout.weight(.semibold))
          Text(model.selectedScanTarget.path)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }

        Spacer(minLength: 16)

        Text(modeExplanation)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 390, alignment: .trailing)

        if model.cleanupMode == .generalLocation {
          Button {
            model.openPathInFinder(model.selectedScanTarget.path)
          } label: {
            Label("打開位置", systemImage: "folder")
          }
          .buttonStyle(LensButtonStyle(kind: .secondary, compact: true))
        }
      }
    }
    .lensHoverHelp(
      title: model.cleanupMode.title,
      detail: modeExplanation,
      value: model.selectedScanTarget.compactLocationTitle,
      tint: cleanupModeTint(model.cleanupMode),
      placement: .belowTrailing
    )
  }

  private var modeExplanation: String {
    switch model.cleanupMode {
    case .system:
      return "只檢查 macOS 白名單候選；CloudKit、VM、快照與系統資料庫仍永久封鎖。"
    case .generalLocation:
      if model.cleanupPrioritizesExternalAppleDouble {
        let recycleNote =
          model.cleanupTargetIsRemote
          ? "；遠端 #recycle 由 NAS 管理並整棵略過"
          : ""
        return
          "非本機儲存會提高可驗證 metadata-only ._ 檔的清理優先級；resource fork、未知 payload、package／symlink companion 與格式不明項目仍只供檢視\(recycleNote)。"
      }
      return "只找精確命名的 Finder、Windows 與 AppleDouble 中繼資料；._ 檔不會只憑名稱判定，也不跟隨符號連結。"
    }
  }
}

private struct CleanupRemovalCapabilityNotice: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    if let notice = model.cleanupTargetRemovalNotice {
      LensPanel(padding: 14) {
        HStack(alignment: .top, spacing: 11) {
          Image(systemName: capabilitySymbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(model.cleanupTargetIsRemote ? LensTheme.sand : LensTheme.accentSoft)

          VStack(alignment: .leading, spacing: 4) {
            Text(capabilityTitle)
              .font(.callout.weight(.semibold))
            Text(notice)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
        }
      }
    }
  }

  private var capabilityTitle: String {
    guard let capabilities = model.cleanupTargetCapabilities else {
      return "正在確認清理能力"
    }
    if capabilities.isReadOnly {
      return "唯讀儲存空間：清理已停用"
    }
    if capabilities.isRemote {
      return "網路儲存空間：Finder 垃圾桶已停用"
    }
    return "Finder 垃圾桶能力未確認"
  }

  private var capabilitySymbol: String {
    guard let capabilities = model.cleanupTargetCapabilities else { return "info.circle" }
    if capabilities.isReadOnly { return "lock.fill" }
    if capabilities.isRemote { return "network" }
    return "exclamationmark.triangle"
  }
}

private struct CleanupScanSourceSelector: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    LensPanel(padding: 18, elevated: true) {
      VStack(alignment: .leading, spacing: 13) {
        VStack(alignment: .leading, spacing: 4) {
          Text("選擇候選資料來源")
            .font(.headline)
          Text("容量報告可以省掉再次遞迴發現整棵 NAS；已掃描過的清理規則也會建立可重用索引，切換等級時只補掃新增範圍。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 10) {
          Button {
            model.selectCleanupScanSource(.existingStorageReport)
          } label: {
            Label("使用既有容量報告（快速）", systemImage: "doc.text.magnifyingglass")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(
            LensButtonStyle(
              kind: model.cleanupScanSource == .existingStorageReport ? .primary : .secondary
            )
          )
          .disabled(!model.canReuseCleanupReport || model.isScanningCleanup || model.isCleaning)

          Button {
            model.selectCleanupScanSource(.liveFilesystem)
          } label: {
            Label("重新掃描目標（完整）", systemImage: "arrow.triangle.2.circlepath")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(
            LensButtonStyle(
              kind: model.cleanupScanSource == .liveFilesystem ? .primary : .secondary
            )
          )
          .disabled(model.isScanningCleanup || model.isCleaning)
        }

        HStack(alignment: .top, spacing: 8) {
          Image(systemName: model.canReuseCleanupReport ? "checkmark.circle.fill" : "info.circle")
            .foregroundStyle(model.canReuseCleanupReport ? LensTheme.sage : LensTheme.sand)
          Text(model.cleanupReusableReportDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        if model.cleanupScanSource == .existingStorageReport {
          Text(
            "快速模式不會把 Markdown 當成刪除授權：報告沒有逐一列出所有普通檔案，所以 App 仍會對已知資料夾做第一層檔名查找。掃過的規則會保存索引，完成清理後也只標記受影響資料夾待刷新；執行前仍做最後一次路徑與型別重驗證。"
          )
          .font(.caption2)
          .foregroundStyle(.tertiary)
        } else {
          Text("完整模式維持原本行為，直接重新遞迴列舉目標檔案系統；資料在容量掃描後有大量變動時，建議使用這個模式。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
    }
  }
}

private struct CleanupIncrementalIndexNotice: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    if let description = model.cleanupIndexDescription {
      LensPanel(padding: 16) {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "externaldrive.badge.checkmark")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(LensTheme.sage)
            .frame(width: 30, height: 30)
            .background(LensTheme.sage.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

          VStack(alignment: .leading, spacing: 4) {
            Text("增量清理索引")
              .font(.subheadline.weight(.semibold))
            Text(description)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
              Label("補充掃描：沿用索引，只補差異", systemImage: "plus.magnifyingglass")
              Label("完整重新掃描：從零重建索引", systemImage: "arrow.triangle.2.circlepath")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
          }
          Spacer(minLength: 0)
        }
      }
    }
  }
}

private struct CleanupProfileSelector: View {
  @EnvironmentObject private var model: AppModel

  private let columns = [
    GridItem(.adaptive(minimum: 174, maximum: 220), spacing: 10, alignment: .top)
  ]

  var body: some View {
    LensPanel(padding: 18, elevated: true) {
      VStack(alignment: .leading, spacing: 15) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 4) {
            Text("選擇掃描等級")
              .font(.title3.weight(.semibold))
            Text(selectorSubtitle)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Text("目前：\(model.cleanupProfile.rawValue)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(profileTint(model.cleanupProfile))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(profileTint(model.cleanupProfile).opacity(0.12), in: Capsule())
        }

        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
          ForEach(CleanupProfile.allCases) { profile in
            CleanupProfileCard(
              profile: profile,
              mode: model.cleanupMode,
              selected: model.cleanupProfile == profile
            ) {
              model.selectCleanupProfile(profile)
            }
          }
        }

        CleanupProfileSummaryStrip()
      }
    }
  }

  private var selectorSubtitle: String {
    switch model.cleanupMode {
    case .system:
      return "五個等級逐層增加 macOS 白名單候選；超激進的高影響範圍需明確開啟，自定義可逐類調整。"
    case .generalLocation:
      return "五個等級逐層加入不同中繼資料類型；一般預設等級不以容量過濾小型隱藏檔。"
    }
  }
}

private struct CleanupProfileSummaryStrip: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showsRules = false

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .top, spacing: 11) {
        Image(systemName: model.cleanupProfile.symbol)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(profileTint(model.cleanupProfile))
          .frame(width: 32, height: 32)
          .background(
            profileTint(model.cleanupProfile).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 9)
          )

        VStack(alignment: .leading, spacing: 4) {
          Text("目前使用「\(model.cleanupProfile.rawValue)」掃描")
            .font(.callout.weight(.semibold))
          Text(
            model.cleanupProfile.summary(
              for: model.cleanupMode,
              prioritizingExternalAppleDouble: model.cleanupPrioritizesExternalAppleDouble
            )
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 8)

        LensStatusBadge(
          title: thresholdTitle,
          symbol: "line.3.horizontal.decrease.circle",
          tint: profileTint(model.cleanupProfile)
        )
      }

      if model.cleanupMode == .system && model.cleanupProfile == .ultraAggressive {
        UltraAggressiveOptionsStrip()
          .transition(.opacity.combined(with: .move(edge: .top)))
      }

      DisclosureGroup(isExpanded: $showsRules) {
        VStack(alignment: .leading, spacing: 11) {
          CleanupProfileScopeGrid(scopes: activeScopes, mode: model.cleanupMode)

          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)],
            alignment: .leading,
            spacing: 8
          ) {
            ForEach(safetyChips.indices, id: \.self) { index in
              let chip = safetyChips[index]
              SafetyChip(symbol: chip.symbol, title: chip.title)
            }
          }

          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "nosign")
              .foregroundStyle(LensTheme.clay)
            Text(safetyBoundaryText)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          HStack {
            Spacer()
            if model.cleanupMode == .system {
              Button("在設定中檢視安全邊界") {
                model.destination = .settings
              }
              .buttonStyle(LensButtonStyle(kind: .quiet, compact: true))
            } else {
              Button("在 Finder 打開清理位置") {
                model.openPathInFinder(model.selectedScanTarget.path)
              }
              .buttonStyle(LensButtonStyle(kind: .quiet, compact: true))
            }
          }
        }
        .padding(.top, 8)
      } label: {
        HStack {
          Label("掃描範圍與安全規則", systemImage: "checkmark.shield")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Spacer()
          Text(showsRules ? "收合詳情" : "查看詳情")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(LensTheme.accentSoft)
        }
      }

      if model.cleanupMode == .system {
        CleanupResearchReferenceNote()
      }
    }
    .padding(12)
    .background(LensTheme.recessed(colorScheme), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(profileTint(model.cleanupProfile).opacity(0.20), lineWidth: 1)
    }
    .animation(reduceMotion ? nil : LensMotion.reveal, value: model.cleanupProfile)
  }

  private var activeScopes: [CleanupScope] {
    CleanupScope.cases(for: model.cleanupMode).filter { scope in
      model.cleanupConfiguration.requiresScope(
        scope,
        prioritizingExternalAppleDouble: model.cleanupPrioritizesExternalAppleDouble
      )
    }
  }

  private var thresholdTitle: String {
    if model.cleanupProfile == .custom {
      return model.cleanupCustomMinimumMiB == 0
        ? "自定義 · 不限容量"
        : "自定義 · ≥ \(model.cleanupCustomMinimumMiB) MiB"
    }
    if model.cleanupMode == .generalLocation {
      return "L\(model.cleanupProfile.tierLimit?.rawValue ?? 0) · 不限容量"
    }
    let mib = model.cleanupProfile.defaultMinimumBytes / 1_048_576
    return "L\(model.cleanupProfile.tierLimit?.rawValue ?? 0) · ≥ \(mib) MiB"
  }

  private var safetyChips: [(symbol: String, title: String)] {
    if model.cleanupMode == .system {
      return [
        ("checkmark.circle", "候選預設不勾選"),
        ("trash", "一般項目進 Finder 可見垃圾桶"),
        ("trash.slash", "廢紙簍只能永久清空"),
        ("terminal", "官方命令另行確認"),
        ("doc.badge.gearshape", "每次操作寫入 JSON"),
      ]
    }
    return [
      ("checkmark.circle", "候選預設不勾選"),
      ("trash", "精確項目進 Finder 可見垃圾桶"),
      ("exclamationmark.triangle", "高風險項目只可逐項選取"),
      ("link", "不跟隨符號連結"),
      ("doc.text.magnifyingglass", "解析 AppleDouble header"),
      ("app.badge.checkmark", "不進入 App 與套件"),
    ]
  }

  private var safetyBoundaryText: String {
    if model.cleanupMode == .system {
      return
        "CloudKit、VM、Preboot、Spotlight、snapshot 與系統資料庫永久禁止直接清理。即使開啟廢紙簍，也只處理目前 UID 的精確直接子項；其他 UID、NAS #recycle 與網路卷宗不進入候選。"
    }
    return
      "一般位置模式不會把所有隱藏檔都當垃圾；.env、.gitignore、設定檔與一般使用者 dotfile 永遠不會只因名稱以句點開頭而成為候選。含資源分支、未知 entry、格式不明、package 或符號連結 companion 的 ._ 檔仍只供檢視。Spotlight 與 FSEvents 只在 L5 顯示為高風險逐項候選，不會被批次全選；卷宗垃圾桶、文件版本與其他 marker 仍不可選。"
  }
}

private struct UltraAggressiveOptionsStrip: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 8) {
        Label("額外清理選項", systemImage: "exclamationmark.triangle")
          .font(.caption.weight(.semibold))
          .foregroundStyle(LensTheme.clay)
        Spacer()
        Text(
          "\(model.enabledPresetOptionalCleanupScopeCount)／\(model.availablePresetOptionalCleanupScopes.count) 已開啟"
        )
        .font(.caption2.weight(.semibold).monospacedDigit())
        .foregroundStyle(.tertiary)
      }

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 230), spacing: 8, alignment: .top)],
        alignment: .leading,
        spacing: 8
      ) {
        ForEach(model.availablePresetOptionalCleanupScopes) { scope in
          Toggle(
            isOn: Binding(
              get: { model.isPresetOptionalCleanupScopeEnabled(scope) },
              set: { model.setPresetOptionalCleanupScope(scope, enabled: $0) }
            )
          ) {
            HStack(alignment: .top, spacing: 9) {
              Image(systemName: scope.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(scopeTint(scope))
                .frame(width: 28, height: 28)
                .background(scopeTint(scope).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

              VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  Text(scope.title)
                    .font(.caption.weight(.semibold))
                  if let badge = cleanupScopeBadgeTitle(scope) {
                    Text(badge)
                      .font(.caption2.weight(.semibold))
                      .foregroundStyle(cleanupScopeBadgeTint(scope))
                  }
                }
                Text(status(for: scope))
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              model.isPresetOptionalCleanupScopeEnabled(scope)
                ? scopeTint(scope).opacity(0.08)
                : LensTheme.recessed(colorScheme),
              in: RoundedRectangle(cornerRadius: 10)
            )
          }
          .toggleStyle(.checkbox)
          .lensHoverHelp(
            title: scope.title,
            detail: scope.summary,
            tint: scopeTint(scope),
            placement: .above
          )
        }
      }
      .disabled(model.isScanningCleanup || model.isCleaning)

      Text("這三個範圍不會只因選到 L5 就自動掃描；開啟後仍只建立候選，項目預設不勾選。廢紙簍需再次確認且只能永久清空。")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .background(
      LensTheme.clay.opacity(colorScheme == .dark ? 0.08 : 0.055),
      in: RoundedRectangle(cornerRadius: 11)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .strokeBorder(LensTheme.clay.opacity(0.18), lineWidth: 1)
    }
  }

  private func status(for scope: CleanupScope) -> String {
    switch scope {
    case .highImpactUserData: return "備份、郵件下載與 Xcode 封存；逐項手動選取"
    case .trashBins: return "目前 UID 垃圾桶；只能在二次確認後永久清空"
    case .systemManagedReview: return "系統管理項目；只提供容量與位置檢視"
    default: return "依白名單建立候選"
    }
  }
}

private struct CleanupProfileScopeGrid: View {
  let scopes: [CleanupScope]
  let mode: CleanupMode

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(mode == .system ? "本等級掃描範圍" : "本等級中繼資料範圍")
          .font(.caption.weight(.semibold))
        Spacer()
        Text("\(scopes.count) 類")
          .font(.caption2.weight(.semibold).monospacedDigit())
          .foregroundStyle(.tertiary)
      }

      if scopes.isEmpty {
        Text("尚未開啟任何掃描範圍。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 205), spacing: 8, alignment: .top)],
          alignment: .leading,
          spacing: 8
        ) {
          ForEach(scopes) { scope in
            HStack(alignment: .top, spacing: 9) {
              Image(systemName: scope.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(scopeTint(scope))
                .frame(width: 28, height: 28)
                .background(scopeTint(scope).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

              VStack(alignment: .leading, spacing: 2) {
                Text(scope.title)
                  .font(.caption.weight(.semibold))
                Text(behavior(for: scope))
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LensTheme.recessed(colorScheme), in: RoundedRectangle(cornerRadius: 10))
            .lensHoverHelp(
              title: scope.title,
              detail: scope.summary,
              tint: scopeTint(scope),
              placement: .above
            )
          }
        }
      }
    }
  }

  private func behavior(for scope: CleanupScope) -> String {
    switch scope {
    case .trashBins: return "永久清空 · 預設不勾選"
    case .systemManagedReview, .folderAppleDoubleReview, .folderLegacyReview:
      return "只供檢視"
    case .highImpactUserData, .folderMacManagedReview:
      return "高影響 · 逐項確認"
    case .appLeftovers: return "嚴格 App 身分比對"
    case .brokenPreferences: return "只列可證明損壞"
    default: return "白名單候選"
    }
  }
}

private struct CleanupResearchReferenceNote: View {
  var body: some View {
    HStack(alignment: .top, spacing: 7) {
      Image(systemName: "book.closed")
        .foregroundStyle(.tertiary)
      Text("部分垃圾判定規則參考 MacSai 開源實作（BSD 3-Clause）。")
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.caption2)
    .foregroundStyle(.tertiary)
    .help("掃描、風險分級、候選選取與刪除前重驗證均由 MacStorageLens 自行實作。")
  }
}

private struct CleanupProfileCard: View {
  let profile: CleanupProfile
  let mode: CleanupMode
  let selected: Bool
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Image(systemName: profile.symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(profileTint(profile))
            .frame(width: 34, height: 34)
            .background(profileTint(profile).opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
          Spacer()
          if profile != .custom {
            Text("L\(profile.tierLimit?.rawValue ?? 0)")
              .font(.caption2.weight(.bold).monospacedDigit())
              .foregroundStyle(.secondary)
          }
          if selected {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(profileTint(profile))
          }
        }

        Text(profile.rawValue)
          .font(.headline)
          .foregroundStyle(.primary)
        Text(shortProfileSummary(profile, mode: mode))
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
      .padding(13)
      .background(
        selected
          ? profileTint(profile).opacity(colorScheme == .dark ? 0.17 : 0.12)
          : (hovered ? LensTheme.hoveredNavigation(colorScheme) : LensTheme.recessed(colorScheme)),
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(
            selected ? profileTint(profile).opacity(0.58) : LensTheme.stroke(colorScheme),
            lineWidth: selected ? 1.4 : 1
          )
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .animation(reduceMotion ? nil : LensMotion.hover, value: hovered)
  }
}

private struct CustomCleanupConfigurationCard: View {
  @EnvironmentObject private var model: AppModel

  private let columns = [
    GridItem(.adaptive(minimum: 280), spacing: 10, alignment: .top)
  ]
  private let minimumChoices = [0, 1, 5, 10, 20, 50, 100, 250, 500]

  var body: some View {
    LensPanel(padding: 18) {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("自定義清理範圍")
              .font(.headline)
            Text(customBoundaryText)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Picker(
            "最低容量",
            selection: Binding(
              get: { model.cleanupCustomMinimumMiB },
              set: { model.setCustomCleanupMinimumMiB($0) }
            )
          ) {
            ForEach(minimumChoices, id: \.self) { value in
              Text(value == 0 ? "不限容量" : "≥ \(value) MiB").tag(value)
            }
          }
          .pickerStyle(.menu)
          .frame(width: 150)
        }

        if model.cleanupMode == .system {
          scopeSection(
            title: "一般與可重建項目",
            detail: "快取、下載殘留、App 殘留與日誌等範圍可逐類開關。",
            scopes: standardScopes
          )

          scopeSection(
            title: "高影響與檢視項目",
            detail: "這些範圍不會因版本升級或切換到自定義而自動開啟。",
            scopes: advancedScopes
          )
        } else {
          scopeSection(title: nil, detail: nil, scopes: model.availableCleanupScopes)
        }
      }
    }
  }

  private var standardScopes: [CleanupScope] {
    model.availableCleanupScopes.filter { !$0.requiresExplicitPresetOptIn }
  }

  private var advancedScopes: [CleanupScope] {
    model.availableCleanupScopes.filter(\.requiresExplicitPresetOptIn)
  }

  @ViewBuilder
  private func scopeSection(
    title: String?,
    detail: String?,
    scopes: [CleanupScope]
  ) -> some View {
    if !scopes.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        if let title {
          VStack(alignment: .leading, spacing: 2) {
            Text(title)
              .font(.callout.weight(.semibold))
            if let detail {
              Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }

        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
          ForEach(scopes) { scope in
            CleanupScopeOptionTile(
              scope: scope,
              isOn: Binding(
                get: { model.isCustomCleanupScopeEnabled(scope) },
                set: { model.setCustomCleanupScope(scope, enabled: $0) }
              ),
              badgeTitle: cleanupScopeBadgeTitle(scope),
              badgeTint: cleanupScopeBadgeTint(scope)
            )
          }
        }
        .disabled(model.isScanningCleanup || model.isCleaning)
      }
    }
  }

  private var customBoundaryText: String {
    switch model.cleanupMode {
    case .system:
      return "只掃描你明確開啟的類型；高影響、廢紙簍與僅檢視項目預設關閉，CloudKit、系統資料庫與 VM 永久封鎖。"
    case .generalLocation:
      return "高影響 AppleDouble 與舊式 metadata 仍需額外確認；符號連結、App 套件與受保護目錄永遠跳過。"
    }
  }
}

private struct CleanupScopeOptionTile: View {
  let scope: CleanupScope
  @Binding var isOn: Bool
  let badgeTitle: String?
  let badgeTint: Color

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Toggle(isOn: $isOn) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: scope.symbol)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(scopeTint(scope))
          .frame(width: 30, height: 30)
          .background(scopeTint(scope).opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(scope.title)
              .font(.callout.weight(.semibold))
            if let badgeTitle {
              Text(badgeTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(badgeTint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(badgeTint.opacity(0.10), in: Capsule())
            }
          }
          Text(scope.summary)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isOn ? scopeTint(scope).opacity(0.08) : LensTheme.recessed(colorScheme),
        in: RoundedRectangle(cornerRadius: 11)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 11)
          .strokeBorder(
            isOn ? scopeTint(scope).opacity(0.32) : LensTheme.stroke(colorScheme),
            lineWidth: 1
          )
      }
    }
    .toggleStyle(.checkbox)
    .lensHoverHelp(
      title: scope.title,
      detail: scope.summary,
      tint: scopeTint(scope),
      placement: .above
    )
  }
}

private struct SafetyChip: View {
  let symbol: String
  let title: String

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Label(title, systemImage: symbol)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(LensTheme.recessed(colorScheme), in: Capsule())
  }
}

private struct CleanupScanProgressCard: View {
  let progress: CleanupScanProgress

  var body: some View {
    LensPanel(padding: 22, elevated: true) {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 13) {
          ProgressView()
            .controlSize(.large)
          VStack(alignment: .leading, spacing: 4) {
            Text(progress.message)
              .font(.headline)
            if let path = progress.currentPath {
              Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            }
          }
          Spacer()
          Text(
            "\(min(progress.currentStep + 1, max(1, progress.totalSteps)))／\(max(1, progress.totalSteps))"
          )
          .font(.headline.monospacedDigit())
          .foregroundStyle(LensTheme.accentSoft)
        }
        ProgressView(value: progress.fraction)
          .tint(LensTheme.accent)
        Text("目前只讀取白名單候選的容量與路徑；這個階段不會清理任何資料。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
    }
  }
}

private struct CleanupEmptyState: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    LensPanel(padding: 28) {
      HStack(spacing: 22) {
        Image(systemName: model.cleanupProfile.symbol)
          .font(.system(size: 29, weight: .semibold))
          .foregroundStyle(profileTint(model.cleanupProfile))
          .frame(width: 70, height: 70)
          .background(
            profileTint(model.cleanupProfile).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 20))

        VStack(alignment: .leading, spacing: 8) {
          Text("尚未依「\(model.cleanupProfile.rawValue)」掃描")
            .font(.title3.weight(.semibold))
          Text(emptyExplanation)
            .font(.callout)
            .foregroundStyle(.secondary)
          CleanupScanActionButtons(compact: true)
        }
        Spacer()
      }
      .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
    }
  }

  private var emptyExplanation: String {
    switch model.cleanupMode {
    case .system:
      return "掃描會在目前 Mac 上直接檢查通用白名單與已安裝工具，不依賴某一台電腦固定存在的八個路徑。"
    case .generalLocation:
      if model.cleanupScanSource == .existingStorageReport {
        return
          "快速模式會沿用「\(model.selectedScanTarget.displayName)」既有容量報告的資料夾索引，只對命中規則的檔名做即時驗證；不會再完整遞迴發現整棵資料樹。"
      }
      return
        "完整模式會重新遞迴檢查「\(model.selectedScanTarget.displayName)」內精確命名的隱藏中繼資料；不會列出一般隱藏文件、App 套件內容或符號連結外部目標。"
    }
  }
}

private struct CleanupNoResultsState: View {
  let result: CleanupScanResult

  var body: some View {
    LensPanel(padding: 26) {
      HStack(spacing: 18) {
        Image(systemName: "checkmark.seal")
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(LensTheme.sage)
          .frame(width: 62, height: 62)
          .background(LensTheme.sage.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
        VStack(alignment: .leading, spacing: 5) {
          Text("這個等級沒有找到符合門檻的候選")
            .font(.headline)
          Text(noResultsExplanation)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
    }
  }

  private var noResultsExplanation: String {
    let minimum = result.configuration.effectiveMinimumBytes(for: result.mode)
    if result.mode == .generalLocation {
      let threshold = minimum == 0 ? "不限容量" : "最低 \(minimum.formattedBytes)"
      return
        "已完成「\(result.target.displayName)」的「\(result.configuration.displayName)」掃描（\(threshold)），沒有找到符合所選中繼資料類型的項目。"
    }
    return
      "目前等級為「\(result.configuration.displayName)」，最低容量為 \(minimum.formattedBytes)。可提高等級或使用自定義調整掃描範圍。"
  }
}

private struct CleanupResultSummary: View {
  let result: CleanupScanResult

  private var selectable: [CleanupCandidate] { result.candidates.filter(\.isSelectable) }
  private var reviewOnly: [CleanupCandidate] { result.candidates.filter { !$0.isSelectable } }
  private var selectableBytes: Int64 { selectable.reduce(0) { $0 + $1.bytes } }
  private var managedCount: Int { selectable.filter { $0.action == .managedCommand }.count }
  private var effectiveMinimum: Int64 {
    result.configuration.effectiveMinimumBytes(for: result.mode)
  }

  var body: some View {
    LensPanel(padding: 18) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 3) {
            Text("「\(result.configuration.displayName)」掃描結果")
              .font(.headline)
            Text(resultSubtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Text("全部預設未勾選")
            .font(.caption.weight(.semibold))
            .foregroundStyle(LensTheme.sage)
        }

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 170), spacing: 10)],
          alignment: .leading,
          spacing: 10
        ) {
          CleanupMetric(
            title: result.mode == .generalLocation ? "匹配項目" : "可執行候選",
            value: result.mode == .generalLocation
              ? "\(result.matchedItemCount) 項" : "\(selectable.count) 項",
            detail: selectableBytes.formattedBytes)
          CleanupMetric(
            title: result.mode == .generalLocation ? "候選分類" : "官方管理命令",
            value: result.mode == .generalLocation
              ? "\(result.candidates.count) 類" : "\(managedCount) 項",
            detail: result.mode == .generalLocation ? result.target.compactLocationTitle : "不經垃圾桶")
          CleanupMetric(title: "僅檢視", value: "\(reviewOnly.count) 類", detail: "不提供刪除")
          CleanupMetric(
            title: "最低容量",
            value: effectiveMinimum == 0 ? "不限" : effectiveMinimum.formattedBytes,
            detail: "小於門檻不顯示"
          )
          CleanupMetric(
            title: "資料來源",
            value: result.scanSource.shortTitle,
            detail: result.sourceReportURL?.lastPathComponent ?? "目前檔案系統"
          )
          CleanupMetric(
            title: "候選掃描耗時",
            value: formattedDuration(result.durationSeconds),
            detail: "不含完整容量掃描"
          )
        }

        if !result.notices.isEmpty {
          DisclosureGroup("掃描提示（\(result.notices.count)）") {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(result.notices, id: \.self) { notice in
                Text("• \(notice)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
            }
            .padding(.top, 8)
          }
          .font(.caption.weight(.semibold))
        }
      }
    }
  }

  private func formattedDuration(_ seconds: TimeInterval) -> String {
    if seconds < 1 { return String(format: "%.2f 秒", seconds) }
    if seconds < 10 { return String(format: "%.1f 秒", seconds) }
    return "\(Int(seconds.rounded())) 秒"
  }

  private var resultSubtitle: String {
    if result.mode == .generalLocation {
      let source =
        result.scanSource == .existingStorageReport
        ? "既有容量報告只作導航索引；候選已向目前檔案系統驗證"
        : "已重新遞迴掃描目前檔案系統"
      return "清理根目錄：\(result.target.path)。\(source)，執行前還會再次驗證。"
    }
    return "容量是配置區塊估計；重疊候選已排除，但不承諾等於 APFS 最終回收量。"
  }
}

private struct CleanupMetric: View {
  let title: String
  let value: String
  let detail: String

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.headline.monospacedDigit())
      Text(detail)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(11)
    .background(LensTheme.recessed(colorScheme), in: RoundedRectangle(cornerRadius: 11))
  }
}

private struct CleanupCategorySection: View {
  @EnvironmentObject private var model: AppModel
  let category: CleanupCategory
  let candidates: [CleanupCandidate]

  private var bulkSelectable: [CleanupCandidate] { candidates.filter(\.isBulkSelectable) }
  private var manualOnly: [CleanupCandidate] {
    candidates.filter { $0.isSelectable && !$0.isBulkSelectable }
  }
  private var allBulkSelected: Bool {
    !bulkSelectable.isEmpty && bulkSelectable.allSatisfy(\.selected)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(category.rawValue, systemImage: categorySymbol(category))
          .font(.headline)
        Text("\(candidates.reduce(0) { $0 + $1.itemCount }) 項 · \(candidates.count) 類")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text(candidates.reduce(Int64(0)) { $0 + $1.bytes }.formattedBytes)
          .font(.caption.weight(.semibold).monospacedDigit())
          .foregroundStyle(.secondary)
        if !bulkSelectable.isEmpty {
          Button(allBulkSelected ? "取消本組" : "勾選本組安全項目") {
            model.setCandidates(in: category, selected: !allBulkSelected)
          }
          .buttonStyle(LensButtonStyle(kind: .quiet, compact: true))
        }
        if !manualOnly.isEmpty {
          Label("警告項目需逐項選取", systemImage: "exclamationmark.triangle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(LensTheme.clay)
        }
      }
      .padding(.horizontal, 3)

      LensPanel(padding: 8, radius: 17) {
        VStack(spacing: 4) {
          ForEach(candidates) { candidate in
            CleanupCandidateRow(candidate: candidate)
          }
        }
      }
    }
  }
}

private struct CleanupCandidateRow: View {
  @EnvironmentObject private var model: AppModel
  let candidate: CleanupCandidate

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered = false

  private var hasFinderPath: Bool {
    finderPath.hasPrefix("/") && FileManager.default.fileExists(atPath: finderPath)
  }

  private var finderPath: String { candidate.matchedPaths.first ?? candidate.path }

  private var isAggregate: Bool { !candidate.matchedPaths.isEmpty }

  private var tooltipDetail: String {
    let manualNote =
      candidate.requiresManualSelection
      ? "\n選取方式：只可逐項勾選，不會被任何全選或分類批次操作自動選取。"
      : ""
    return "\(candidate.reason)\n清除後：\(candidate.impact)\n不建議清除時：\(candidate.recovery)\(manualNote)"
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      if candidate.isSelectable {
        HStack(spacing: 6) {
          if candidate.requiresManualSelection {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(LensTheme.clay)
              .help("高風險項目：只能逐項勾選，不會被全選。")
          }
          Toggle(
            "",
            isOn: Binding(
              get: { candidate.selected },
              set: { model.setCandidate(candidate.id, selected: $0) }
            )
          )
          .labelsHidden()
          .toggleStyle(.checkbox)
          .tint(candidate.requiresManualSelection ? LensTheme.clay : LensTheme.accentSoft)
        }
        .padding(.top, 8)
      } else {
        Image(systemName: "eye")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 18, height: 18)
          .padding(.top, 7)
      }

      Image(systemName: candidate.scope.symbol)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(scopeTint(candidate.scope))
        .frame(width: 34, height: 34)
        .background(
          scopeTint(candidate.scope).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 7) {
          Text(candidate.displayName)
            .font(.callout.weight(.semibold))
            .lineLimit(2)
          TierBadge(tier: candidate.tier)
          RiskBadge(risk: candidate.risk)
          ActionBadge(action: candidate.action)
          if candidate.requiresManualSelection {
            ManualSelectionBadge()
          }
        }

        if isAggregate {
          VStack(alignment: .leading, spacing: 2) {
            Text("根目錄：\(candidate.cleanupRootPath ?? candidate.path)")
            if let sample = candidate.matchedPaths.first {
              Text("範例：\(sample)")
            }
          }
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(2)
          .truncationMode(.middle)
        } else {
          Text(candidate.path)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(2)
            .truncationMode(.middle)
        }

        Text(candidate.reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(alignment: .top, spacing: 14) {
          Label(candidate.impact, systemImage: "exclamationmark.circle")
          Label(candidate.recovery, systemImage: "arrow.clockwise.circle")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 14)

      VStack(alignment: .trailing, spacing: 5) {
        Text(candidate.bytes == 0 ? "大小未知" : candidate.bytes.formattedBytes)
          .font(.headline.monospacedDigit())
          .foregroundStyle(candidate.selected ? LensTheme.accentSoft : Color.secondary)
        if candidate.action == .managedCommand {
          Text("估計上限")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        } else if isAggregate {
          Text("\(candidate.itemCount) 個匹配項目")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.top, 2)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 12)
    .background(
      candidate.selected
        ? LensTheme.selectedNavigation(colorScheme)
        : (hovered ? LensTheme.hoveredNavigation(colorScheme) : Color.clear),
      in: RoundedRectangle(cornerRadius: 12)
    )
    .contentShape(Rectangle())
    .onTapGesture {
      if candidate.isBulkSelectable {
        model.setCandidate(candidate.id, selected: !candidate.selected)
      }
    }
    .onHover { hovered = $0 }
    .animation(reduceMotion ? nil : LensMotion.hover, value: hovered)
    .lensHoverHelp(
      title: candidate.displayName,
      detail: tooltipDetail,
      value: candidate.bytes == 0
        ? "\(candidate.itemCount) 項"
        : "\(candidate.itemCount) 項 · \(candidate.bytes.formattedBytes)",
      tint: scopeTint(candidate.scope),
      placement: .above
    )
    .contextMenu {
      if hasFinderPath {
        Button(isAggregate ? "顯示第一個匹配項目" : "在 Finder 中顯示") {
          model.openInFinder(finderPath)
        }
        if let root = candidate.cleanupRootPath {
          Button("打開清理根目錄") { model.openPathInFinder(root) }
          Button("複製清理根目錄") { model.copyPath(root) }
        } else {
          Button("在 Finder 中打開") { model.openPathInFinder(candidate.path) }
        }
        Button("複製範例路徑") { model.copyPath(finderPath) }
      } else {
        Button("複製說明") { model.copyPath(candidate.reason) }
      }
    }
  }
}

private struct CleanupActionBar: View {
  @EnvironmentObject private var model: AppModel
  @Binding var pendingExecutionMode: CleanupExecutionMode?

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private var selected: [CleanupCandidate] { model.selectedCleanupCandidates }
  private var managedCount: Int { selected.filter { $0.action == .managedCommand }.count }
  private var trashBinCount: Int { selected.filter { $0.ruleID == .trashBinContents }.count }
  private var onlyTrashBinsSelected: Bool {
    !selected.isEmpty && selected.allSatisfy { $0.ruleID == .trashBinContents }
  }
  private var elevatedCount: Int { selected.filter(\.requiresElevatedConfirmation).count }
  private var manualOnlyCount: Int { selected.filter(\.requiresManualSelection).count }
  private var selectedItemCount: Int { selected.reduce(0) { $0 + $1.itemCount } }
  private var directDeleteAvailable: Bool {
    !selected.isEmpty && selected.allSatisfy(\.supportsDirectDeletion)
      && model.cleanupDirectDeletionAvailableForTarget
  }

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(
          "已選 \(selected.count) 類 · \(selectedItemCount) 項 · \(model.selectedCleanupBytes.formattedBytes)"
        )
        .font(.headline)
        .monospacedDigit()
        Text(actionSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if model.isCleaning {
        ProgressView()
          .controlSize(.small)
      }

      Button("取消全選") { model.deselectAllCleanupCandidates() }
        .buttonStyle(LensButtonStyle(kind: .quiet))
        .disabled(selected.isEmpty || model.isCleaning)

      Button(model.cleanupTrashTitle) { model.openTrash() }
        .buttonStyle(LensButtonStyle(kind: .secondary))

      Button {
        pendingExecutionMode = .moveToTrash
      } label: {
        Label("移到 Finder 可見垃圾桶", systemImage: "trash")
      }
      .buttonStyle(LensButtonStyle(kind: .secondary))
      .disabled(
        selected.isEmpty || selected.contains(where: \.requiresDirectDeletion)
          || !model.cleanupFinderVisibleTrashAvailable || model.isCleaning
      )
      .help(trashButtonHelp)

      Button {
        pendingExecutionMode = .forceDelete
      } label: {
        Label(
          onlyTrashBinsSelected ? "永久清空廢紙簍…" : "直接徹底刪除…",
          systemImage: "trash.slash"
        )
      }
      .buttonStyle(LensButtonStyle(kind: .destructive))
      .disabled(!directDeleteAvailable || model.isCleaning)
      .help(directDeleteHelp)
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 13)
    .background {
      Rectangle()
        .fill(
          reduceTransparency
            ? AnyShapeStyle(LensTheme.elevatedPanel(colorScheme))
            : AnyShapeStyle(.thickMaterial)
        )
        .overlay(alignment: .top) {
          LinearGradient(
            colors: [LensTheme.stroke(colorScheme, strong: true), .clear],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(height: 1)
        }
    }
  }

  private var trashButtonHelp: String {
    if !model.cleanupFinderVisibleTrashAvailable {
      return model.cleanupFinderTrashHelp
    }
    if !selected.allSatisfy(\.supportsFinderVisibleTrash) {
      return "目前選取內容含只能直接清理的官方命令、廢紙簍內容或舊版隱藏垃圾桶殘留；請改用『直接徹底刪除』。"
    }
    return
      "只使用 Finder 的系統垃圾桶語意。點號或 hidden 項目會先改成可見名稱；只有目的地名稱非點號、hidden=false，且位於 Finder 管理的垃圾桶直接子項時才回報成功；成功後立即要求 Finder 選取該項目。"
  }

  private var directDeleteHelp: String {
    if !model.cleanupDirectDeletionAvailableForTarget {
      return "目前目標是唯讀檔案系統，不能直接刪除。"
    }
    if model.cleanupTargetIsRemote {
      return
        "直接向 \(model.cleanupTargetFilesystemDisplayName) 遠端掛載刪除精確驗證來源，不經 Finder 垃圾桶。NAS／伺服器若另有 recycle bin、snapshot 或版本保護，實際保留與空間釋放由伺服器設定決定。"
    }
    if trashBinCount > 0 {
      return
        "永久移除掃描結果明列的 ~/.Trash 與本機可寫外接卷宗 .Trashes/<目前 UID> 直接子項；不會再搬進另一個垃圾桶，也不處理其他 UID、整棵 .Trashes、NAS #recycle 或網路卷宗。"
    }
    return
      "直接從每個精確驗證來源永久移除，不經任何垃圾桶，也不建立隱藏暫存、no_log 或其他標記。一般候選會重新驗證白名單路徑；官方管理命令只使用固定 executable 與參數。"
  }

  private var actionSummary: String {
    if selected.isEmpty { return "先逐項勾選；掃描等級不會替你做決定。" }
    if !model.cleanupDirectDeletionAvailableForTarget {
      return "目前目標是唯讀檔案系統，清理動作已停用。"
    }
    if model.cleanupTargetIsRemote {
      return
        "目前是 \(model.cleanupTargetFilesystemDisplayName) 網路卷宗；Finder 垃圾桶不可用，只提供直接刪除。NAS 端是否另有回收筒或快照由伺服器設定決定。"
    }
    if managedCount > 0 {
      return "含 \(managedCount) 個官方管理命令；它們只會在『直接徹底刪除』流程中執行，Finder 可見垃圾桶按鈕會停用。"
    }
    if trashBinCount > 0 {
      return "含 \(trashBinCount) 個廢紙簍分類；只會永久移除掃描時列出的目前使用者直接子項，不會再搬進另一個垃圾桶。"
    }
    if selected.contains(where: \.requiresDirectDeletion) {
      return "所選內容含舊版不可見垃圾桶殘留，只能逐項直接徹底刪除；不會再搬進另一個垃圾桶。"
    }
    if model.cleanupMode == .generalLocation,
      selected.contains(where: \.supportsExternalVolumeDirectDeletion)
    {
      return
        "可選 Finder 可見垃圾桶或直接徹底刪除。前者清空 Finder 垃圾桶前仍占空間；後者不經垃圾桶，完成後仍要重新掃描確認 macOS 是否重建。"
    }
    if manualOnlyCount > 0 {
      return "含 \(manualOnlyCount) 個只可逐項選取的高風險項目；執行前會再次確認。"
    }
    if selected.contains(where: { !$0.matchedPaths.isEmpty }) {
      return "可選 Finder 可見垃圾桶或直接徹底刪除；兩者都會先重新驗證每個精確路徑。"
    }
    return "可選 Finder 可見垃圾桶或直接徹底刪除；不會使用任何第三種隱藏中介位置。"
  }
}

private struct CleanupConfirmationSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss

  let executionMode: CleanupExecutionMode

  @State private var acknowledgedAppsClosed = false
  @State private var acknowledgedHighImpact = false
  @State private var acknowledgedManagedVolumeMetadata = false
  @State private var acknowledgedPermanentDeletion = false

  private var selected: [CleanupCandidate] { model.selectedCleanupCandidates }
  private var selectedItemCount: Int { selected.reduce(0) { $0 + $1.itemCount } }
  private var includesSpotlight: Bool {
    selected.contains {
      $0.ruleID == .folderSpotlightMetadata
        || $0.ruleID == .folderLegacySpotlightTrashResidue
    }
  }
  private var includesFSEvents: Bool {
    selected.contains {
      $0.ruleID == .folderFSEventsMetadata
        || $0.ruleID == .folderLegacyFSEventsTrashResidue
    }
  }

  private var includesTrashBins: Bool {
    selected.contains { $0.ruleID == .trashBinContents }
  }

  private var onlyTrashBinsSelected: Bool {
    !selected.isEmpty && selected.allSatisfy { $0.ruleID == .trashBinContents }
  }

  private var needsElevatedAcknowledgement: Bool {
    selected.contains(where: \.requiresElevatedConfirmation)
  }

  private var needsManagedVolumeMetadataAcknowledgement: Bool {
    selected.contains {
      $0.ruleID == .folderSpotlightMetadata || $0.ruleID == .folderFSEventsMetadata
        || $0.ruleID == .folderLegacySpotlightTrashResidue
        || $0.ruleID == .folderLegacyFSEventsTrashResidue
    }
  }

  private var includesExternalVolumeDirectDeletion: Bool {
    selected.contains(where: \.supportsExternalVolumeDirectDeletion)
  }

  private var canExecute: Bool {
    acknowledgedAppsClosed
      && (!needsElevatedAcknowledgement || acknowledgedHighImpact)
      && (!needsManagedVolumeMetadataAcknowledgement || acknowledgedManagedVolumeMetadata)
      && (executionMode != .moveToTrash || model.cleanupFinderVisibleTrashAvailable)
      && (executionMode != .forceDelete || model.cleanupDirectDeletionAvailableForTarget)
      && (executionMode != .forceDelete || acknowledgedPermanentDeletion)
      && !selected.isEmpty
  }

  private var tint: Color {
    executionMode == .forceDelete || needsElevatedAcknowledgement
      ? LensTheme.clay : LensTheme.sage
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: executionMode == .forceDelete ? "trash.slash" : "checkmark.shield")
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 58, height: 58)
          .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        VStack(alignment: .leading, spacing: 5) {
          Text(confirmationTitle)
            .font(.title2.weight(.semibold))
          Text(summaryText)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }

      if executionMode == .forceDelete {
        LensPanel(padding: 12) {
          HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.octagon.fill")
              .foregroundStyle(LensTheme.clay)
              .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
              Text(onlyTrashBinsSelected ? "這會永久清空本次列出的廢紙簍項目" : "這是不經垃圾桶的永久刪除")
                .font(.callout.weight(.semibold))
              Text(permanentDeletionExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }

      LensPanel(padding: 12) {
        ScrollView {
          VStack(spacing: 7) {
            ForEach(selected) { candidate in
              HStack(spacing: 10) {
                Image(systemName: rowSymbol(candidate))
                  .foregroundStyle(rowTint(candidate))
                VStack(alignment: .leading, spacing: 2) {
                  Text(candidate.displayName)
                    .font(.callout.weight(.semibold))
                  Text(rowActionTitle(candidate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                  if candidate.itemCount > 1 {
                    Text("\(candidate.itemCount) 個精確匹配項目")
                      .font(.caption2)
                      .foregroundStyle(.tertiary)
                  }
                }
                Spacer()
                Text(candidate.bytes.formattedBytes)
                  .font(.caption.weight(.semibold).monospacedDigit())
              }
              .padding(8)
            }
          }
        }
        .frame(maxHeight: 230)
      }

      Toggle("我已關閉相關 App，並確認目前沒有 Finder 複製、索引、備份或同步工作。", isOn: $acknowledgedAppsClosed)
        .toggleStyle(.checkbox)

      if needsElevatedAcknowledgement {
        Toggle(
          executionMode == .forceDelete
            ? "我了解高影響項目可能失去歷史資料或 Mac 專用 metadata。"
            : "我了解高影響項目可能失去歷史資料或 Mac 專用 metadata。",
          isOn: $acknowledgedHighImpact
        )
        .toggleStyle(.checkbox)
        .foregroundStyle(LensTheme.clay)
      }

      if needsManagedVolumeMetadataAcknowledgement {
        Toggle(
          managedVolumeAcknowledgementText,
          isOn: $acknowledgedManagedVolumeMetadata
        )
        .toggleStyle(.checkbox)
        .foregroundStyle(LensTheme.clay)
      }

      if executionMode == .forceDelete {
        Toggle(
          permanentDeletionAcknowledgement,
          isOn: $acknowledgedPermanentDeletion
        )
        .toggleStyle(.checkbox)
        .foregroundStyle(LensTheme.clay)
      }

      HStack {
        Button("返回檢查") { dismiss() }
          .buttonStyle(LensButtonStyle(kind: .secondary))
        Spacer()
        Button {
          model.executeSelectedCleanup(removalMode: executionMode)
          dismiss()
        } label: {
          Label(
            confirmationButtonTitle,
            systemImage: executionMode.symbol
          )
        }
        .buttonStyle(LensButtonStyle(kind: .destructive))
        .disabled(!canExecute)
      }
    }
    .padding(24)
    .frame(minWidth: 680, minHeight: executionMode == .forceDelete ? 660 : 560)
  }

  private var summaryText: String {
    let base =
      "將處理 \(selected.count) 個明確選取的分類，共 \(selectedItemCount) 個項目，估計涉及 \(model.selectedCleanupBytes.formattedBytes)。"
    if executionMode == .forceDelete {
      if model.cleanupTargetIsRemote {
        return base
          + " 這是 \(model.cleanupTargetFilesystemDisplayName) 網路卷宗：刪除不經 Finder 垃圾桶；伺服器端 recycle bin／snapshot 是否保留資料由 NAS 設定決定。"
      }
      return base
        + (includesTrashBins
          ? " 所選廢紙簍候選只會刪除掃描時列出的目前使用者直接子項；垃圾桶根目錄、其他 UID、NAS #recycle 與網路卷宗不在操作範圍。"
          : "")
        + (includesExternalVolumeDirectDeletion
          ? " 外接卷宗永久操作會留在 MacStorageLens 本身的 removable-volume 權限責任鏈中，不會啟動獨立 root shell。" : "")
    }
    return base + " 項目只會交給 Finder 可見垃圾桶；清空 Finder 垃圾桶前仍占用原卷宗空間。"
  }

  private var confirmationTitle: String {
    if executionMode == .forceDelete, onlyTrashBinsSelected {
      return "永久清空廢紙簍前確認"
    }
    return executionMode == .forceDelete
      ? "直接徹底刪除前確認" : "移到 Finder 可見垃圾桶前確認"
  }

  private var confirmationButtonTitle: String {
    if executionMode == .forceDelete, onlyTrashBinsSelected {
      return "確認永久清空廢紙簍"
    }
    return executionMode == .forceDelete
      ? "確認直接徹底刪除" : "確認移到 Finder 可見垃圾桶"
  }

  private var permanentDeletionAcknowledgement: String {
    if model.cleanupTargetIsRemote {
      return
        "我了解『直接徹底刪除』會對目前的 \(model.cleanupTargetFilesystemDisplayName) 遠端掛載送出刪除，不經 Finder 垃圾桶、無法由 Finder 還原；NAS／伺服器可能依自己的 recycle bin、snapshot 或版本政策保留資料，MacStorageLens 不會把那種伺服器端保護冒充成 Finder 垃圾桶。"
    }
    if includesTrashBins {
      return
        "我了解『廢紙簍（永久清空）』會直接永久移除掃描時明列的目前使用者垃圾桶項目，不會再進入另一個垃圾桶、無法由 Finder 還原；新放入垃圾桶但未列在本次候選中的項目不會被刪除，其他 UID 與 NAS #recycle 也不會被處理。"
    }
    return
      "我了解『直接徹底刪除』會在檔案系統層直接永久移除畫面中列出的精確來源，不經任何垃圾桶、無法由 Finder 還原，也不會建立 no_log 或其他隱藏標記；它不是覆寫式安全抹除，並同意完成後重新掃描確認結果。"
  }

  private var managedVolumeAcknowledgementText: String {
    if executionMode == .forceDelete {
      var effects: [String] = []
      if includesSpotlight {
        effects.append("所選 Spotlight 舊索引或舊版隱藏垃圾桶殘留會直接永久刪除；macOS 之後仍可能建立新的同名索引")
      }
      if includesFSEvents {
        effects.append("所選 FSEvents 歷史或舊版隱藏垃圾桶殘留會直接永久刪除；不建立 no_log，macOS 仍可能重新建立")
      }
      return "我了解：" + effects.joined(separator: "；") + "。備份或同步工具可能需要重新完整掃描。"
    }
    return "我了解 Spotlight 索引可能完整重建，FSEvents 事件歷史會消失，備份或同步工具可能需要重新掃描；Finder 可見垃圾桶中的項目在清空前仍占用原卷宗空間。"
  }

  private var permanentDeletionExplanation: String {
    if model.cleanupTargetIsRemote {
      return
        "App 會在規則白名單、父路徑、符號連結與目前檔案身分重新驗證後，直接對 \(model.cleanupTargetFilesystemDisplayName) 掛載使用 Foundation removeItem。這不會建立或使用 Finder 垃圾桶；客戶端確認來源路徑消失後才記錄完成，但 NAS 是否把刪除內容保留在伺服器端 recycle bin、snapshot 或版本歷史中，MacStorageLens 無法替伺服器保證。"
    }
    if includesTrashBins {
      return
        "App 會重新驗證垃圾桶根目錄必須是 ~/.Trash，或本機可寫外接卷宗的 .Trashes/<目前 UID>，再逐一驗證並永久移除畫面列出的直接子項。根目錄本身、掃描後新增的項目、其他使用者目錄、整棵 .Trashes、NAS #recycle 與網路卷宗都不會被清空。"
    }
    if includesExternalVolumeDirectDeletion {
      var policyEffects: [String] = []
      if includesSpotlight {
        policyEffects.append("Spotlight：只刪除畫面中逐項選取且重新驗證過的精確路徑；不掃描或清空整個垃圾桶")
      }
      if includesFSEvents {
        policyEffects.append("FSEvents：只刪除畫面中逐項選取且重新驗證過的精確路徑；不建立 no_log 或其他隱藏目錄")
      }
      return
        "App 會在永久操作前後驗證根目錄、精確名稱、父路徑、符號連結、裝置與 inode，然後直接呼叫 Foundation removeItem 移除來源。所有操作留在 MacStorageLens 程序中；只有本機、非內置、可寫且不是 Time Machine 目的地的 /Volumes 根層卷宗可進入。網路卷宗、磁碟映像、Macintosh HD 與其他任意路徑一律拒絕。"
        + (policyEffects.isEmpty ? "" : "\n" + policyEffects.joined(separator: "\n"))
    }
    return
      "所選路徑會在規則白名單、父路徑、符號連結與目前檔案身分重新驗證後，直接由 Foundation removeItem 永久移除；官方套件管理器候選則只執行畫面明列的固定命令與參數。任何失敗都會如實寫入紀錄。"
  }

  private func rowActionTitle(_ candidate: CleanupCandidate) -> String {
    if executionMode == .forceDelete {
      switch candidate.ruleID {
      case .trashBinContents:
        return "永久清空本次掃描列出的目前使用者廢紙簍項目"
      case .folderSpotlightMetadata:
        return "直接永久刪除所選舊索引"
      case .folderFSEventsMetadata:
        return "直接永久刪除所選事件歷史"
      case .folderLegacySpotlightTrashResidue, .folderLegacyFSEventsTrashResidue:
        return "直接永久刪除舊版隱藏垃圾桶殘留"
      default:
        return candidate.action == .managedCommand
          ? "執行明列的官方直接清理命令"
          : "直接永久刪除精確驗證內容"
      }
    }
    return candidate.action.rawValue
  }

  private func rowSymbol(_ candidate: CleanupCandidate) -> String {
    if executionMode == .forceDelete { return "trash.slash" }
    if candidate.requiresManualSelection { return "exclamationmark.triangle.fill" }
    return candidate.action == .managedCommand ? "terminal" : "trash"
  }

  private func rowTint(_ candidate: CleanupCandidate) -> Color {
    if executionMode == .forceDelete || candidate.requiresManualSelection {
      return LensTheme.clay
    }
    return candidate.action == .managedCommand ? LensTheme.sand : LensTheme.accentSoft
  }
}

struct TierBadge: View {
  let tier: CleanupTier

  var body: some View {
    Text("L\(tier.rawValue) · \(tier.title)")
      .font(.caption2.weight(.semibold))
      .foregroundStyle(tierTint(tier))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(tierTint(tier).opacity(0.11), in: Capsule())
  }
}

struct RiskBadge: View {
  let risk: CleanupRisk

  var body: some View {
    Text(risk.rawValue)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(riskTint(risk))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(riskTint(risk).opacity(0.11), in: Capsule())
  }
}

private struct ActionBadge: View {
  let action: CleanupActionKind

  var body: some View {
    Label(actionTitle, systemImage: symbol)
      .labelStyle(.titleOnly)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(tint.opacity(0.10), in: Capsule())
  }

  private var actionTitle: String {
    switch action {
    case .moveContentsToTrash, .moveItemToTrash, .moveMatchedItemsToTrash:
      return "Finder 可見垃圾桶"
    case .permanentDeleteMatchedItems: return "直接刪除"
    case .managedCommand: return "官方命令"
    case .reviewOnly: return "不直刪"
    }
  }

  private var symbol: String {
    switch action {
    case .moveContentsToTrash, .moveItemToTrash, .moveMatchedItemsToTrash: return "trash"
    case .permanentDeleteMatchedItems: return "trash.slash"
    case .managedCommand: return "terminal"
    case .reviewOnly: return "eye"
    }
  }

  private var tint: Color {
    switch action {
    case .moveContentsToTrash, .moveItemToTrash, .moveMatchedItemsToTrash:
      return LensTheme.accentSoft
    case .permanentDeleteMatchedItems: return LensTheme.clay
    case .managedCommand: return LensTheme.sand
    case .reviewOnly: return LensTheme.slate
    }
  }
}

private struct ManualSelectionBadge: View {
  var body: some View {
    Label("逐項手動", systemImage: "exclamationmark.triangle.fill")
      .labelStyle(.titleAndIcon)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(LensTheme.clay)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(LensTheme.clay.opacity(0.11), in: Capsule())
      .help("這個項目不會被全選或分類批次選取。")
  }
}

private func cleanupScopeBadgeTitle(_ scope: CleanupScope) -> String? {
  switch scope {
  case .highImpactUserData: return "高影響"
  case .trashBins: return "永久刪除"
  case .systemManagedReview: return "僅檢視"
  default: return nil
  }
}

private func cleanupScopeBadgeTint(_ scope: CleanupScope) -> Color {
  switch scope {
  case .highImpactUserData, .trashBins: return LensTheme.clay
  case .systemManagedReview: return LensTheme.slate
  default: return scopeTint(scope)
  }
}

private func shortProfileSummary(_ profile: CleanupProfile, mode: CleanupMode) -> String {
  if mode == .generalLocation {
    switch profile {
    case .ultraConservative: return "找 .DS_Store 與驗證過的 ._.DS_Store。"
    case .conservative: return "加入 Windows metadata 與其驗證過的 ._ 側邊檔。"
    case .balanced: return "加入 __MACOSX 與安全的孤立 ._ metadata。"
    case .aggressive: return "加入配對中、無資源分支的 ._ metadata。"
    case .ultraAggressive:
      return "敏感 ._ 與舊式 metadata 僅檢視；Spotlight／FSEvents 可警告後逐項選取。"
    case .custom: return "自行選類型與最低容量。"
    }
  }
  switch profile {
  case .ultraConservative: return "第三方標準快取；最低 20 MiB。"
  case .conservative: return "加入 Apple／群組與純繪圖快取。"
  case .balanced: return "加入 Xcode、IDE／AI 與套件管理器精確快取。"
  case .aggressive: return "加入嚴格 App 殘留、損壞 plist 與使用者 logs。"
  case .ultraAggressive: return "加入舊安裝檔；高影響資料、廢紙簍與系統檢視另行開啟。"
  case .custom: return "自行選類型與最低容量。"
  }
}

private func profileTint(_ profile: CleanupProfile) -> Color {
  switch profile {
  case .ultraConservative: return LensTheme.sage
  case .conservative: return LensTheme.accentSoft
  case .balanced: return LensTheme.accent
  case .aggressive: return LensTheme.sand
  case .ultraAggressive: return LensTheme.clay
  case .custom: return LensTheme.plum
  }
}

private func tierTint(_ tier: CleanupTier) -> Color {
  switch tier {
  case .ultraConservative: return LensTheme.sage
  case .conservative: return LensTheme.accentSoft
  case .balanced: return LensTheme.accent
  case .aggressive: return LensTheme.sand
  case .ultraAggressive: return LensTheme.clay
  }
}

private func riskTint(_ risk: CleanupRisk) -> Color {
  switch risk {
  case .minimal: return LensTheme.sage
  case .low: return LensTheme.accentSoft
  case .moderate: return LensTheme.sand
  case .high: return LensTheme.clay
  case .reviewOnly: return LensTheme.slate
  }
}

private func scopeTint(_ scope: CleanupScope) -> Color {
  switch scope {
  case .standardCaches: return LensTheme.accentSoft
  case .sandboxAndGroupCaches: return LensTheme.sage
  case .clipboardTemporary: return LensTheme.plum
  case .applicationWebCaches: return LensTheme.accent
  case .developerCaches: return LensTheme.sand
  case .packageManagerCaches: return LensTheme.slate
  case .downloadResidue: return LensTheme.sand
  case .appLeftovers: return LensTheme.sage
  case .brokenPreferences: return LensTheme.plum
  case .diagnosticsAndLogs: return LensTheme.clay
  case .highImpactUserData: return Color(lensHex: "#B87672")
  case .trashBins: return LensTheme.clay
  case .systemManagedReview: return Color.secondary
  case .folderFinderMetadata: return LensTheme.accentSoft
  case .folderWindowsMetadata: return LensTheme.slate
  case .folderArchiveMetadata: return LensTheme.sage
  case .folderAppleDoubleRemnants: return LensTheme.sage
  case .folderAppleDouble: return LensTheme.sand
  case .folderAppleDoubleReview: return LensTheme.clay
  case .folderMacManagedReview: return LensTheme.clay
  case .folderLegacyReview: return LensTheme.plum
  }
}

private func categorySymbol(_ category: CleanupCategory) -> String {
  switch category {
  case .standardCache: return "shippingbox"
  case .sandboxCache: return "square.stack.3d.up"
  case .clipboardArchive: return "doc.on.clipboard"
  case .applicationCache: return "globe.badge.chevron.backward"
  case .developerCache: return "hammer"
  case .packageManagerCache: return "shippingbox.and.arrow.backward"
  case .downloadResidue: return "arrow.down.doc"
  case .appLeftovers: return "app.dashed"
  case .brokenPreferences: return "slider.horizontal.3"
  case .diagnosticsAndLogs: return "waveform.path.ecg"
  case .highImpactUserData: return "externaldrive.badge.exclamationmark"
  case .trashBins: return "trash.slash"
  case .systemManagedReview: return "gearshape.2"
  case .folderFinderMetadata: return "macwindow"
  case .folderWindowsMetadata: return "rectangle.on.rectangle"
  case .folderArchiveMetadata: return "archivebox"
  case .folderAppleDoubleRemnants: return "doc.badge.clock"
  case .folderAppleDouble: return "doc.badge.ellipsis"
  case .folderAppleDoubleReview: return "doc.badge.exclamationmark"
  case .folderMacManagedReview: return "externaldrive.badge.exclamationmark"
  case .folderLegacyTrashResidue: return "trash.slash"
  case .folderLegacyReview: return "eye"
  }
}

private func cleanupModeTint(_ mode: CleanupMode) -> Color {
  switch mode {
  case .system: return LensTheme.accentSoft
  case .generalLocation: return LensTheme.sage
  }
}
