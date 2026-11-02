import SwiftUI

struct AboutView: View {
  @EnvironmentObject private var model: AppModel
  @LensState private var showsReleaseHistory = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        hero
        productAndSafetyPanel

        HStack {
          Text(AppMetadata.copyright)
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
        model.copyText(versionSummary, status: "已複製版本資訊")
      } label: {
        Label("複製版本資訊", systemImage: "doc.on.doc")
      }
      .buttonStyle(LensButtonStyle(kind: .primary, compact: true))

      Button {
        model.openPathInFinder(model.library.rootURL.path)
      } label: {
        Label("資料存放位置", systemImage: "folder")
      }
      .buttonStyle(LensButtonStyle(kind: .secondary, compact: true))

      Link(
        "清理規則",
        destination: URL(
          string: "https://github.com/jason840709/MacStorageLens/blob/main/docs/cleanup-logic.md")!
      )
      .buttonStyle(LensButtonStyle(kind: .quiet, compact: true))
    }
  }

  private var productAndSafetyPanel: some View {
    LensPanel(padding: 0, elevated: true) {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .top) {
            LensSectionHeading(
              "開發與資料處理",
              symbol: "info.square.fill"
            )
            Spacer()
          }

          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 230), spacing: 10)],
            alignment: .leading,
            spacing: 10
          ) {
            AboutCopyFact(
              title: "開發者", value: AppMetadata.developer,
              detail: "", symbol: "person.fill", tint: LensTheme.accentSoft)
            AboutCopyFact(
              title: "開發協作", value: AppMetadata.developmentAssistant,
              detail: "早期版本與 GPT‑5.6 Pro 協作。", symbol: "wand.and.stars", tint: LensTheme.plum)
            AboutCopyFact(
              title: "資料處理", value: "本機處理，不上傳掃描資料",
              detail: "不傳送使用統計。", symbol: "lock.fill", tint: LensTheme.sage)
            AboutCopyFact(
              title: "清理方式", value: "一鍵清理與手動選取",
              detail: "一鍵清理直接移除符合規則的快取與舊診斷；手動選取的項目移到垃圾桶。進階規則另有直接刪除選項。", symbol: "checkmark.shield",
              tint: LensTheme.sand)
          }
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
              Text("版本更新")
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
  @LensState private var hovered = false

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
    .lensHoverHelp(
      title: title, detail: detail.isEmpty ? "點擊複製。" : "\(detail) 點擊複製。", value: value, tint: tint)
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
