import SwiftUI

struct HistoryView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        LensPageHeader(
          eyebrow: "報告管理",
          title: "掃描紀錄",
          subtitle: "每個系統、磁碟或資料夾各自保存最新一份完整報告；同一位置的新掃描會取代舊紀錄。"
        ) {
          HStack(spacing: 8) {
            Button("開啟資料夾") { model.openReportsFolder() }
              .buttonStyle(LensButtonStyle(kind: .secondary))
              .help("在 Finder 打開 MacStorageLens 的掃描與匯入報告資料夾")
            Button("重新整理") { model.refreshReportHistory() }
              .buttonStyle(LensButtonStyle(kind: .primary))
              .help("重新索引所有掃描位置，並移除同一位置較舊的 App 報告")
          }
        }

        if model.reportHistory.isEmpty {
          LensPanel(padding: 28, elevated: true) {
            HStack(spacing: 22) {
              Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(LensTheme.accentSoft)
                .frame(width: 68, height: 68)
                .background(LensTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
              VStack(alignment: .leading, spacing: 7) {
                Text("沒有掃描報告")
                  .font(.title3.weight(.semibold))
                Text("先執行完整掃描，或從工具列匯入既有 Markdown 報告。不同位置完成後會各自出現在這裡。")
                  .font(.callout)
                  .foregroundStyle(.secondary)
              }
              Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
          }
        } else {
          HStack(spacing: 8) {
            LensStatusBadge(
              title: "\(model.reportHistory.count) 個掃描位置",
              symbol: "clock.arrow.circlepath",
              tint: LensTheme.accentSoft
            )
            Text("同一位置永遠只保留最新完整報告")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          VStack(spacing: 12) {
            ForEach(model.reportHistory) { record in
              ReportCard(record: record, isLoaded: isLoaded(record))
            }
          }
        }
      }
      .padding(26)
      .frame(maxWidth: 1120)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .navigationTitle("掃描紀錄")
  }

  private func isLoaded(_ record: ReportRecord) -> Bool {
    model.document?.url.standardizedFileURL == record.url.standardizedFileURL
  }
}

private struct ReportCard: View {
  @EnvironmentObject private var model: AppModel
  let record: ReportRecord
  let isLoaded: Bool

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    LensPanel(padding: 18, elevated: isLoaded) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 16) {
          reportIdentity
          Spacer(minLength: 18)
          actionButtons
        }

        VStack(alignment: .leading, spacing: 14) {
          reportIdentity
          actionButtons
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
    }
    .contextMenu {
      Button("在 Finder 中顯示報告") { model.openInFinder(record.url.path) }
      Button("打開報告") { model.openFile(record.url.path) }
      Button("複製報告路徑") { model.copyPath(record.url.path) }
      Divider()
      Button(isLoaded ? "重新載入目前地圖" : "顯示這個位置的容量地圖") { loadReport() }
    }
  }

  private var reportIdentity: some View {
    HStack(spacing: 16) {
      Image(systemName: isLoaded ? "\(record.locationSymbol).fill" : record.locationSymbol)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(isLoaded ? LensTheme.accentSoft : Color.secondary)
        .frame(width: 48, height: 48)
        .background(
          (isLoaded ? LensTheme.accent.opacity(0.14) : LensTheme.recessed(colorScheme)),
          in: RoundedRectangle(cornerRadius: 14)
        )

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(record.locationTitle)
            .font(.headline)
            .lineLimit(1)
          if isLoaded {
            LensStatusBadge(
              title: "目前顯示",
              symbol: "checkmark",
              tint: LensTheme.sage
            )
          }
          LensStatusBadge(
            title: record.sourceTitle,
            symbol: record.isImported ? "square.and.arrow.down" : "magnifyingglass",
            tint: record.isImported ? LensTheme.plum : LensTheme.accentSoft
          )
        }

        Text(record.target.path)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)

        Text(reportMetadata)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var actionButtons: some View {
    HStack(spacing: 8) {
      Button("Finder 顯示") { model.openInFinder(record.url.path) }
        .buttonStyle(LensButtonStyle(kind: .secondary, compact: true))
        .help("在 Finder 中選取這份 Markdown 報告")

      Button(isLoaded ? "重新載入" : "顯示地圖") { loadReport() }
        .buttonStyle(LensButtonStyle(kind: .primary, compact: true))
        .help("把這份報告設為總覽與資料樹目前顯示的容量地圖")
    }
    .fixedSize()
  }

  private func loadReport() {
    model.displayReport(record)
  }

  private var reportMetadata: String {
    let date = record.modifiedAt.formatted(date: .abbreviated, time: .shortened)
    let generated = record.generatedAt == "未知" ? date : record.generatedAt
    return
      "\(record.fileSize.formattedBytes) · 生成 \(generated) · 掃描器 \(record.scannerVersion) · \(record.url.lastPathComponent)"
  }
}

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var showsCleanupBoundary = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        LensPageHeader(
          eyebrow: "偏好設定",
          title: "設定與安全邊界",
          subtitle: "只保留能改變工作流程、開啟資料或解釋目前狀態的設定。"
        )

        LensPanel(padding: 0, elevated: true) {
          VStack(spacing: 0) {
            fullDiskAccessSection
            settingsDivider
            accountingSection
            settingsDivider
            cleanupSection
            settingsDivider
            localDataSection
          }
        }

        HStack(spacing: 8) {
          Text("MacStorageLens \(AppMetadata.versionLine)")
          Text("·")
          Text("掃描器 v\(AppMetadata.scannerVersion)")
          Spacer()
          Button("查看關於與版本歷程") { model.destination = .about }
            .buttonStyle(LensButtonStyle(kind: .quiet, compact: true))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
      }
      .padding(26)
      .frame(maxWidth: 1120)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .navigationTitle("設定")
  }

  private var fullDiskAccessSection: some View {
    SettingsActionRow(
      symbol: "lock.shield.fill",
      tint: probeTint,
      title: "完整磁碟存取權",
      subtitle: "由 MacStorageLens App 本身核對受 TCC 保護的測試路徑。"
    ) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          LensStatusBadge(title: probeTitle, symbol: probeSymbol, tint: probeTint)
          if let checkedAt = model.appFullDiskAccessProbe.checkedAt {
            Text("上次核對 \(checkedAt.formatted(date: .omitted, time: .shortened))")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }

        Text(model.appFullDiskAccessProbe.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
          Button("重新檢查") { model.refreshFullDiskAccessProbe() }
            .buttonStyle(LensButtonStyle(kind: .secondary, compact: true))
          Button("開啟系統設定") { ScannerLauncher.openFullDiskAccessSettings() }
            .buttonStyle(LensButtonStyle(kind: .primary, compact: true))
        }
      }
    }
  }

  private var accountingSection: some View {
    SettingsActionRow(
      symbol: "arrow.triangle.branch",
      tint: LensTheme.accentSoft,
      title: "APFS 帳務模型",
      subtitle: "路徑資料、磁碟帳務、快照與真正空閒會分開顯示。"
    ) {
      VStack(alignment: .leading, spacing: 10) {
        Text("未歸屬差額不會被猜成垃圾；Data 資料樹、df／APFS 已用容量、其他卷與 snapshot 會各自保留語意。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
          Button("查看帳務核對") { model.destination = .overview }
            .buttonStyle(LensButtonStyle(kind: .primary, compact: true))
          Button("macOS 儲存空間") { ScannerLauncher.openStorageSettings() }
            .buttonStyle(LensButtonStyle(kind: .secondary, compact: true))
        }
      }
    }
  }

  private var cleanupSection: some View {
    SettingsActionRow(
      symbol: "trash.slash.fill",
      tint: LensTheme.clay,
      title: "清理安全邊界",
      subtitle: "在這裡設定預設掃描等級，並直接前往候選與操作紀錄。"
    ) {
      VStack(alignment: .leading, spacing: 11) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) {
            cleanupProfilePicker
            Spacer(minLength: 8)
            cleanupActions
          }
          VStack(alignment: .leading, spacing: 10) {
            cleanupProfilePicker
            cleanupActions
          }
        }

        Text(model.cleanupProfile.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        DisclosureGroup(isExpanded: $showsCleanupBoundary) {
          VStack(alignment: .leading, spacing: 7) {
            Label("一般候選預設不勾選；可逆操作只進 Finder 可見垃圾桶，直接刪除不經垃圾桶。", systemImage: "checkmark.circle")
            Label("受管理命令與高影響項目必須額外確認。", systemImage: "exclamationmark.bubble")
            Label(
              "系統磁碟的 CloudKit、Application Support、VM、Preboot、Spotlight、snapshot 與系統資料庫永久禁止直接清理。一般位置的 .Spotlight-V100／.fseventsd 只在 L5 逐項手動開放，且不參與全選。",
              systemImage: "nosign"
            )
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.top, 7)
        } label: {
          Label(
            showsCleanupBoundary ? "收合永久安全邊界" : "查看永久安全邊界",
            systemImage: "checkmark.shield"
          )
          .font(.caption.weight(.semibold))
          .foregroundStyle(LensTheme.clay)
        }
      }
    }
  }

  private var cleanupProfilePicker: some View {
    HStack(spacing: 9) {
      Text("預設清理等級")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Picker(
        "預設清理等級",
        selection: Binding(
          get: { model.cleanupProfile.rawValue },
          set: { rawValue in
            guard let profile = CleanupProfile(rawValue: rawValue) else { return }
            model.selectCleanupProfile(profile)
          }
        )
      ) {
        ForEach(CleanupProfile.allCases) { profile in
          Text(profile.rawValue).tag(profile.rawValue)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 150)
    }
  }

  private var cleanupActions: some View {
    HStack(spacing: 8) {
      Button("前往安全清理") { model.destination = .cleaner }
        .buttonStyle(LensButtonStyle(kind: .primary, compact: true))
      Button("清理紀錄") { model.openCleanupHistoryFolder() }
        .buttonStyle(LensButtonStyle(kind: .secondary, compact: true))
    }
  }

  private var localDataSection: some View {
    SettingsActionRow(
      symbol: "internaldrive.fill",
      tint: LensTheme.plum,
      title: "本機資料",
      subtitle: "報告、掃描工作與清理紀錄都只保存在這台 Mac。"
    ) {
      VStack(alignment: .leading, spacing: 11) {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 230), spacing: 10)],
          alignment: .leading,
          spacing: 8
        ) {
          SettingsInfoButton(
            title: "程式資料夾",
            value: model.library.rootURL.path,
            actionTitle: "在 Finder 中打開",
            symbol: "folder"
          ) {
            model.openPathInFinder(model.library.rootURL.path)
          }
          SettingsInfoButton(
            title: "掃描報告",
            value: "\(model.reportHistory.count) 份／每個位置最多 1 份",
            actionTitle: "打開報告資料夾",
            symbol: "doc.text"
          ) {
            model.openPathInFinder(model.library.scansURL.path)
          }
          SettingsInfoButton(
            title: "網路與遙測",
            value: "無",
            actionTitle: "查看隱私與版本資料",
            symbol: "lock.shield"
          ) {
            model.destination = .about
          }
          SettingsInfoButton(
            title: "清理紀錄",
            value: model.library.cleanupHistoryURL.lastPathComponent,
            actionTitle: "打開清理紀錄",
            symbol: "doc.badge.gearshape"
          ) {
            model.openCleanupHistoryFolder()
          }
        }
      }
    }
  }

  private var settingsDivider: some View {
    Divider()
      .padding(.leading, 66)
      .opacity(0.62)
  }

  private var probeTitle: String {
    switch model.appFullDiskAccessProbe.state {
    case .checking: return "正在檢查"
    case .available: return "App 可讀"
    case .blocked: return "尚未授權"
    case .indeterminate: return "無法判定"
    case .notApplicable: return "所選位置不需要"
    }
  }

  private var probeSymbol: String {
    switch model.appFullDiskAccessProbe.state {
    case .checking: return "arrow.triangle.2.circlepath"
    case .available: return "checkmark"
    case .blocked: return "lock.fill"
    case .indeterminate: return "questionmark"
    case .notApplicable: return "externaldrive.badge.checkmark"
    }
  }

  private var probeTint: Color {
    switch model.appFullDiskAccessProbe.state {
    case .checking, .indeterminate: return LensTheme.sand
    case .notApplicable: return LensTheme.sage
    case .available: return LensTheme.sage
    case .blocked: return LensTheme.clay
    }
  }
}

private struct SettingsActionRow<Content: View>: View {
  let symbol: String
  let tint: Color
  let title: String
  let subtitle: String
  private let content: Content

  @Environment(\.colorScheme) private var colorScheme
  @State private var hovered = false

  init(
    symbol: String,
    tint: Color,
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
  ) {
    self.symbol = symbol
    self.tint = tint
    self.title = title
    self.subtitle = subtitle
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 38, height: 38)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.headline)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 16)
    .background(
      hovered ? LensTheme.hoveredNavigation(colorScheme) : Color.clear,
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
  }
}

private struct SettingsInfoButton: View {
  let title: String
  let value: String
  let actionTitle: String
  let symbol: String
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(hovered ? LensTheme.accentSoft : Color.secondary)
          .frame(width: 28, height: 28)
          .background(
            LensTheme.accent.opacity(hovered ? 0.16 : 0.09), in: RoundedRectangle(cornerRadius: 8))

        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(value)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer(minLength: 6)
        Image(systemName: "arrow.up.forward")
          .font(.caption2.weight(.bold))
          .foregroundStyle(hovered ? LensTheme.accentSoft : Color.secondary.opacity(0.42))
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        hovered ? LensTheme.hoveredNavigation(colorScheme) : LensTheme.recessed(colorScheme),
        in: RoundedRectangle(cornerRadius: 10)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(
            hovered ? LensTheme.accent.opacity(0.30) : LensTheme.stroke(colorScheme), lineWidth: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .help(actionTitle)
    .accessibilityHint(Text(actionTitle))
  }
}
