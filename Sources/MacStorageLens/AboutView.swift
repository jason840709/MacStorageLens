import SwiftUI

struct AboutView: View {
  @EnvironmentObject private var model: AppModel
  @State private var showsReleaseHistory = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        LensPageHeader(
          eyebrow: "關於",
          title: "關於磁碟透視",
          subtitle: "版本、開發責任、隱私邊界與容量模型集中在同一個可操作頁面。"
        )

        hero
        productAndSafetyPanel

        HStack {
          Text(AppMetadata.copyright)
          Spacer()
          Text("本機分析 · 無遙測 · 清理候選逐項確認")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 2)
      }
      .padding(26)
      .frame(maxWidth: 1120)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .navigationTitle("關於")
  }

  private var hero: some View {
    LensPanel(padding: 22, elevated: true) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 22) {
          heroIdentity
          Spacer(minLength: 22)
          heroActions
        }

        VStack(alignment: .leading, spacing: 18) {
          heroIdentity
          heroActions
        }
      }
    }
  }

  private var heroIdentity: some View {
    HStack(spacing: 19) {
      if let icon = AppMetadata.applicationIcon() {
        Image(nsImage: icon)
          .resizable()
          .interpolation(.high)
          .frame(width: 78, height: 78)
      } else {
        LensMark(size: 78)
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(AppMetadata.displayName)
            .font(.system(size: 29, weight: .semibold))
            .tracking(-0.45)
          Text(AppMetadata.productName)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
        }

        Text("由 \(AppMetadata.developer) 開發，與 \(AppMetadata.developmentAssistant) 協作。")
          .font(.callout)
          .foregroundStyle(.secondary)

        HStack(spacing: 8) {
          LensStatusBadge(
            title: AppMetadata.versionLine,
            symbol: "number",
            tint: LensTheme.accentSoft
          )
          LensStatusBadge(
            title: "掃描器 v\(AppMetadata.scannerVersion)",
            symbol: "magnifyingglass",
            tint: LensTheme.sage
          )
        }
      }
    }
  }

  private var heroActions: some View {
    HStack(spacing: 8) {
      Button {
        model.copyText(versionSummary, status: "已複製版本與開發資訊")
      } label: {
        Label("複製版本", systemImage: "doc.on.doc")
      }
      .buttonStyle(LensButtonStyle(kind: .primary, compact: true))

      Button {
        model.openPathInFinder(model.library.rootURL.path)
      } label: {
        Label("本機資料", systemImage: "folder")
      }
      .buttonStyle(LensButtonStyle(kind: .secondary, compact: true))

      Button("設定") { model.destination = .settings }
        .buttonStyle(LensButtonStyle(kind: .quiet, compact: true))
    }
  }

  private var productAndSafetyPanel: some View {
    LensPanel(padding: 0, elevated: true) {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .top) {
            LensSectionHeading(
              "產品與開發資料",
              subtitle: "每個欄位都可點擊複製，方便回報、接手與核對版本。",
              symbol: "info.square.fill"
            )
            Spacer()
            LensStatusBadge(
              title: "點擊欄位即可複製", symbol: "cursorarrow.click", tint: LensTheme.accentSoft)
          }

          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 230), spacing: 10)],
            alignment: .leading,
            spacing: 10
          ) {
            AboutCopyFact(
              title: "開發者", value: AppMetadata.developer,
              detail: "產品與程式碼主要負責人。", symbol: "person.fill", tint: LensTheme.accentSoft)
            AboutCopyFact(
              title: "AI 協作", value: AppMetadata.developmentAssistant,
              detail: "用於研究、程式實作、檢查與文件整理。", symbol: "wand.and.stars", tint: LensTheme.plum)
            AboutCopyFact(
              title: "App", value: AppMetadata.versionLine,
              detail: "目前安裝的 App 版本與 build。", symbol: "app.badge", tint: LensTheme.sand)
            AboutCopyFact(
              title: "掃描器", value: "v\(AppMetadata.scannerVersion)",
              detail: "內附的唯讀容量樹掃描核心版本。", symbol: "externaldrive", tint: LensTheme.sage)
            AboutCopyFact(
              title: "介面", value: "Native SwiftUI / AppKit",
              detail: "原生 macOS 介面與 Finder／系統設定整合。", symbol: "macwindow", tint: LensTheme.accentSoft
            )
            AboutCopyFact(
              title: "資料處理", value: "完全在本機",
              detail: "掃描報告、候選與操作紀錄不會上傳。", symbol: "lock.fill", tint: LensTheme.sage)
            AboutCopyFact(
              title: "網路與遙測", value: "無",
              detail: "App 沒有分析遙測或雲端回傳。", symbol: "antenna.radiowaves.left.and.right.slash",
              tint: LensTheme.clay)
            AboutCopyFact(
              title: "清理模型", value: "六級掃描／逐項確認",
              detail: "候選預設不勾選；可逆操作只進 Finder 可見垃圾桶，直接刪除則不經垃圾桶。", symbol: "checkmark.shield",
              tint: LensTheme.sand)
          }
        }
        .padding(18)

        Divider().padding(.leading, 64).opacity(0.62)

        VStack(alignment: .leading, spacing: 13) {
          HStack(alignment: .top) {
            LensSectionHeading(
              "容量與安全模型",
              subtitle: "下列入口直接連到會影響判讀或清理的功能。",
              symbol: "arrow.triangle.branch"
            )
            Spacer()
          }

          HStack(spacing: 8) {
            Button("容量帳務") { model.destination = .overview }
              .buttonStyle(LensButtonStyle(kind: .primary, compact: true))
            Button("資料樹") { model.destination = .browser }
              .buttonStyle(LensButtonStyle(kind: .secondary, compact: true))
            Button("安全清理") { model.destination = .cleaner }
              .buttonStyle(LensButtonStyle(kind: .secondary, compact: true))
            Button("完整磁碟權限") { ScannerLauncher.openFullDiskAccessSettings() }
              .buttonStyle(LensButtonStyle(kind: .quiet, compact: true))
          }

          Text("一般檔案、APFS／快照／其他卷與未解析差額會分層顯示；未知容量不會被推定為垃圾。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)

        Divider().padding(.leading, 64).opacity(0.62)

        DisclosureGroup(isExpanded: $showsReleaseHistory) {
          VStack(spacing: 0) {
            ForEach(Array(AppMetadata.releases.enumerated()), id: \.element.id) { index, release in
              ReleaseHistoryRow(release: release, isLast: index == AppMetadata.releases.count - 1)
            }
          }
          .padding(.top, 14)
        } label: {
          HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(LensTheme.accentSoft)
              .frame(width: 34, height: 34)
              .background(LensTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
              Text("開發歷程")
                .font(.headline)
              Text(latestReleaseSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(showsReleaseHistory ? nil : 2)
            }

            Spacer()
            Text(showsReleaseHistory ? "收合" : "查看全部")
              .font(.caption.weight(.semibold))
              .foregroundStyle(LensTheme.accentSoft)
          }
        }
        .padding(18)
      }
    }
  }

  private var latestReleaseSummary: String {
    guard let release = AppMetadata.releases.first else { return "尚無版本紀錄" }
    return "v\(release.version) · \(release.title)"
  }

  private var versionSummary: String {
    "\(AppMetadata.displayName) / \(AppMetadata.productName) · \(AppMetadata.versionLine) · 掃描器 v\(AppMetadata.scannerVersion) · 開發者 \(AppMetadata.developer) · AI 協作 \(AppMetadata.developmentAssistant)"
  }
}

private struct AboutCopyFact: View {
  @EnvironmentObject private var model: AppModel

  let title: String
  let value: String
  let detail: String
  let symbol: String
  let tint: Color

  @Environment(\.colorScheme) private var colorScheme
  @State private var hovered = false

  var body: some View {
    Button {
      model.copyText("\(title)：\(value)", status: "已複製「\(title)」")
    } label: {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 30, height: 30)
          .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(value)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }

        Spacer(minLength: 6)
        Image(systemName: hovered ? "doc.on.doc.fill" : "doc.on.doc")
          .font(.caption)
          .foregroundStyle(hovered ? tint : Color.secondary.opacity(0.45))
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        hovered ? LensTheme.hoveredNavigation(colorScheme) : LensTheme.recessed(colorScheme),
        in: RoundedRectangle(cornerRadius: 11)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 11)
          .strokeBorder(hovered ? tint.opacity(0.32) : LensTheme.stroke(colorScheme), lineWidth: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .lensHoverHelp(title: title, detail: "\(detail) 點擊即可複製。", value: value, tint: tint)
  }
}

private struct ReleaseHistoryRow: View {
  let release: AppRelease
  let isLast: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(spacing: 0) {
        Circle()
          .fill(LensTheme.accent)
          .frame(width: 8, height: 8)
        if !isLast {
          Rectangle()
            .fill(LensTheme.accent.opacity(0.22))
            .frame(width: 1, height: 44)
        }
      }
      .padding(.top, 5)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text("v\(release.version)")
            .font(.caption.weight(.bold).monospaced())
            .foregroundStyle(LensTheme.accentSoft)
          Text(release.title)
            .font(.callout.weight(.semibold))
        }
        Text(release.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.bottom, isLast ? 0 : 12)

      Spacer(minLength: 0)
    }
  }
}
