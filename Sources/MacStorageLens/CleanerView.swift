import SwiftUI

struct AdvancedCleanupView: View {
  @EnvironmentObject private var model: AppModel
  @LensState private var pendingExecutionMode: CleanupExecutionMode?

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          LensPageHeader(
            title: "進階規則",
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
    .navigationTitle("進階規則")
    .sheet(item: $pendingExecutionMode) { executionMode in
      CleanupConfirmationSheet(executionMode: executionMode)
        .environmentObject(model)
    }
  }

  private var headerSubtitle: String {
    switch model.cleanupMode {
    case .system:
      return "依等級選擇要掃描的資料；結果需逐項勾選。"
    case .generalLocation:
      return "選擇沿用既有容量報告，或重新掃描整個位置。"
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
      .help("掃描目前等級包含的資料；不會移除檔案。")
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
      return "只檢查所選等級允許的項目；雲端同步、虛擬機、快照與系統資料庫不列入清理。"
    case .generalLocation:
      if model.cleanupPrioritizesExternalAppleDouble {
        let recycleNote =
          model.cleanupTargetIsRemote
          ? "；遠端 #recycle 由 NAS 管理並整棵略過"
          : ""
        return
          "此位置會較早列出已驗證、不含資源分支的 ._ 側邊檔；含資源分支、未知內容或格式不明的檔案只供檢視\(recycleNote)。"
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
          Text("快速模式沿用既有容量報告的資料夾位置；完整模式重新讀取整個目標。")
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
            "快速模式可能漏掉容量報告建立後新增的整個資料夾；若目標有這類變動，請選完整模式。候選仍會依目前檔案狀態驗證。"
          )
          .font(.caption2)
          .foregroundStyle(.tertiary)
        } else {
          Text("資料夾在上次容量掃描後有新增或大量變動時，請選完整模式。")
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
      return "等級越高，檢查的資料類型越多；備份、垃圾桶及系統管理項目需另外開啟。"
    case .generalLocation:
      return "等級越高，檢查的隱藏顯示資料類型越多；預設不因檔案小就略過。"
    }
  }
}

private struct CleanupProfileSummaryStrip: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @LensState private var showsRules = false

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
              Button("查看清理限制") {
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
        ("trash.slash", "廢紙簍只能永久清空"),
        ("terminal", "官方命令另行確認"),
        ("doc.badge.gearshape", "每次操作都會留下紀錄"),
      ]
    }
    return [
      ("checkmark.circle", "候選預設不勾選"),
      ("exclamationmark.triangle", "高風險項目只可逐項選取"),
      ("link", "不跟隨符號連結"),
      ("doc.text.magnifyingglass", "核對 ._ 側邊檔內容"),
      ("app.badge.checkmark", "不進入 App 與套件"),
    ]
  }

  private var safetyBoundaryText: String {
    if model.cleanupMode == .system {
      return
        "雲端同步、虛擬機、系統啟動資料、Spotlight 搜尋索引、快照與系統資料庫不列入清理。垃圾桶清理只處理本次列出的目前使用者項目。"
    }
    return
      "一般隱藏文件與設定檔不會只因名稱以句點開頭就列為候選。含資源分支、未知內容或格式不明的 ._ 側邊檔只供檢視。Spotlight 搜尋索引與檔案變更紀錄須在最高等級逐項選取；整個磁碟垃圾桶與文件版本不可選。"
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

      Text("這三類資料需另外開啟。備份與垃圾桶結果需逐項選取；系統管理項目只供檢視。")
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
    case .trashBins: return "目前使用者的垃圾桶；再次確認後永久清空"
    case .systemManagedReview: return "系統管理項目；只提供容量與位置檢視"
    default: return ""
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
                if !behavior(for: scope).isEmpty {
                  Text(behavior(for: scope))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
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
    default: return ""
    }
  }
}

private struct CleanupProfileCard: View {
  let profile: CleanupProfile
  let mode: CleanupMode
  let selected: Bool
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @LensState private var hovered = false

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
        Text("正在掃描清理項目，不會移除檔案。")
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
          CleanupScanActionButtons(compact: true)
        }
        Spacer()
      }
      .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
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
        ? "沿用既有容量報告，候選已依目前檔案狀態驗證"
        : "已重新掃描目前檔案系統"
      return "掃描位置：\(result.target.path)。\(source)。"
    }
    return "顯示容量是檔案占用量的估計，實際可用空間可能不同。"
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
  @LensState private var hovered = false

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
    return "\(candidate.reason)\n清除後：\(candidate.impact)\n還原或處理：\(candidate.recovery)\(manualNote)"
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
    return "所選項目會移到 Finder 垃圾桶；清空前仍占用磁碟空間。"
  }

  private var directDeleteHelp: String {
    if !model.cleanupDirectDeletionAvailableForTarget {
      return "目前目標是唯讀檔案系統，不能直接刪除。"
    }
    if model.cleanupTargetIsRemote {
      return
        "所選項目會直接從 \(model.cleanupTargetFilesystemDisplayName) 刪除，無法從 Finder 還原；伺服器是否保留副本由 NAS 設定決定。"
    }
    if trashBinCount > 0 {
      return
        "所選項目會直接永久刪除，無法從 Finder 還原；其中垃圾桶項目只處理本次掃描列出的內容。"
    }
    return "所選項目會直接刪除，不經垃圾桶，無法從 Finder 還原。"
  }

  private var actionSummary: String {
    if selected.isEmpty { return "請先勾選要清理的項目。" }
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
      return "所選項目只能直接刪除；其中 \(trashBinCount) 個廢紙簍分類只處理本次掃描列出的目前使用者項目。"
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
      return "選擇移到 Finder 垃圾桶，或直接永久刪除。"
    }
    return "選擇移到 Finder 垃圾桶，或直接永久刪除。"
  }
}

private struct CleanupConfirmationSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss

  let executionMode: CleanupExecutionMode

  @LensState private var acknowledgedAppsClosed = false
  @LensState private var acknowledgedHighImpact = false
  @LensState private var acknowledgedManagedVolumeMetadata = false
  @LensState private var acknowledgedPermanentDeletion = false

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
              if !permanentDeletionExplanation.isEmpty {
                Text(permanentDeletionExplanation)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
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

      Toggle("已關閉使用這些資料的 App，並確認此位置沒有進行複製、備份或同步。", isOn: $acknowledgedAppsClosed)
        .toggleStyle(.checkbox)

      if needsElevatedAcknowledgement {
        Toggle("已確認所選項目的歷史資料或 Mac 專用資訊可能遺失。", isOn: $acknowledgedHighImpact)
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
    "將處理 \(selected.count) 個選取的分類，共 \(selectedItemCount) 個項目，估計涉及 \(model.selectedCleanupBytes.formattedBytes)。"
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
    "我了解所選項目會直接刪除，無法從 Finder 垃圾桶還原。"
  }

  private var managedVolumeAcknowledgementText: String {
    var effects: [String] = []
    if selected.contains(where: { $0.ruleID == .folderSpotlightMetadata }) {
      effects.append("移除 Spotlight 搜尋索引後，搜尋可能暫時變慢，macOS 可能重建索引")
    }
    if selected.contains(where: { $0.ruleID == .folderFSEventsMetadata }) {
      effects.append("移除檔案變更紀錄後，備份或同步工具可能需要完整重新掃描")
    }
    if selected.contains(where: {
      $0.ruleID == .folderLegacySpotlightTrashResidue
        || $0.ruleID == .folderLegacyFSEventsTrashResidue
    }) {
      effects.append("垃圾桶中的舊索引或變更紀錄副本會永久刪除，無法還原")
    }
    return "我了解：" + effects.joined(separator: "；") + "。"
  }

  private var permanentDeletionExplanation: String {
    var details: [String] = []
    if includesTrashBins {
      details.append("所選項目會直接刪除。其中垃圾桶項目只處理本次掃描列出的目前使用者內容；掃描後新增的項目不在此次範圍。")
    }
    if model.cleanupTargetIsRemote {
      details.append("NAS 可能另有回收筒、快照或版本紀錄；實際是否保留副本由伺服器設定決定。")
    }
    if selected.contains(where: { $0.action == .managedCommand }) {
      details.append("將執行畫面列出的套件管理器清理命令。")
    }
    return details.joined(separator: "\n")
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
    case .ultraConservative: return "Finder 顯示資訊；清除後顯示方式可能重設。"
    case .conservative: return "加入 Windows 縮圖與資料夾外觀檔。"
    case .balanced: return "加入 __MACOSX 與主檔已不存在的 ._ 側邊檔。"
    case .aggressive: return "加入主檔仍存在、不含資源分支的 ._ 側邊檔。"
    case .ultraAggressive:
      return "含資源分支的 ._ 僅檢視；索引與變更紀錄可逐項選取。"
    case .custom: return "自行選類型與最低容量。"
    }
  }
  switch profile {
  case .ultraConservative: return "第三方 App 的標準快取；最低 20 MiB。"
  case .conservative: return "加入 Apple、共用 App 與繪圖快取。"
  case .balanced: return "加入開發工具與套件下載快取。"
  case .aggressive: return "加入診斷日誌、App 殘留與損壞的偏好設定。"
  case .ultraAggressive: return "加入舊安裝檔；備份與垃圾桶另行開啟。"
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
