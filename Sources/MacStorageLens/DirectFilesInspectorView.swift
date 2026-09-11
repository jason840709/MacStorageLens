import AppKit
import SwiftUI

struct DirectFilesInspectorView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var query = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().opacity(0.55)
      content
      Divider().opacity(0.55)
      footer
    }
    .frame(minWidth: 760, idealWidth: 860, minHeight: 560, idealHeight: 660)
    .background(LensTheme.canvas(colorScheme))
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: "doc.on.doc.fill")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(LensTheme.accentSoft)
        .frame(width: 42, height: 42)
        .background(LensTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

      VStack(alignment: .leading, spacing: 5) {
        Text("直接檔案")
          .font(.title2.weight(.semibold))
        Text("這不是一個真實資料夾，而是直接位於目前資料夾、未歸入任何子資料夾的檔案總和。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text(model.directFilesInspection?.parentPath ?? model.directFilesParentPath ?? "—")
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
          .lineLimit(2)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }

      Spacer(minLength: 18)

      Button {
        dismiss()
        model.isShowingDirectFilesInspector = false
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(LensIconButtonStyle())
      .keyboardShortcut(.cancelAction)
    }
    .padding(20)
  }

  @ViewBuilder
  private var content: some View {
    if model.isInspectingDirectFiles {
      VStack(spacing: 14) {
        ProgressView()
          .controlSize(.large)
        Text("正在讀取此資料夾中的直接檔案…")
          .font(.headline)
        Text("只列出第一層檔案，不會進入子資料夾，也不會刪除任何內容。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let inspection = model.directFilesInspection {
      VStack(spacing: 12) {
        summary(inspection)

        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
          TextField("搜尋檔名或路徑", text: $query)
            .textFieldStyle(.plain)
          if !query.isEmpty {
            Button {
              query = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(LensTheme.recessed(colorScheme), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
          RoundedRectangle(cornerRadius: 11)
            .strokeBorder(LensTheme.stroke(colorScheme), lineWidth: 1)
        }
        .padding(.horizontal, 18)

        if let error = inspection.errorMessage {
          ContentUnavailableView {
            Label("無法列出直接檔案", systemImage: "lock.trianglebadge.exclamationmark")
          } description: {
            Text(error)
          } actions: {
            Button("在 Finder 開啟父資料夾") {
              model.openInFinder(inspection.parentPath)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredEntries.isEmpty {
          ContentUnavailableView {
            Label(query.isEmpty ? "沒有直接檔案" : "找不到符合項目", systemImage: "doc")
          } description: {
            Text(query.isEmpty ? "掃描當下的差額可能包含目錄 metadata、APFS 配置差異，或檔案已在之後移動。" : "請修改搜尋文字。")
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVStack(spacing: 5) {
              ForEach(filteredEntries) { entry in
                DirectFileRow(entry: entry)
                  .environmentObject(model)
              }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
          }
        }
      }
      .padding(.top, 14)
    } else {
      ContentUnavailableView("沒有可顯示的檔案資料", systemImage: "doc.questionmark")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func summary(_ inspection: DirectFilesInspection) -> some View {
    HStack(spacing: 12) {
      InspectorMetric(
        title: "圖表估計",
        value: inspection.expectedAllocatedBytes.formattedBytes,
        symbol: "chart.pie.fill",
        tint: LensTheme.accentSoft
      )
      InspectorMetric(
        title: "即時列出",
        value: inspection.liveAllocatedBytes.formattedBytes,
        symbol: "doc.on.doc",
        tint: LensTheme.sage
      )
      InspectorMetric(
        title: "檔案數",
        value: "\(inspection.entries.count)",
        symbol: "number",
        tint: LensTheme.sand
      )
    }
    .padding(.horizontal, 18)
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Label("直接檔案不是垃圾分類；本 App 不會整批刪除。請先在 Finder 逐項確認。", systemImage: "shield.lefthalf.filled")
        .font(.caption)
        .foregroundStyle(.secondary)

      Spacer()

      Button("開啟父資料夾") {
        if let path = model.directFilesInspection?.parentPath ?? model.directFilesParentPath {
          model.openInFinder(path)
        }
      }
      .buttonStyle(LensButtonStyle(kind: .secondary, compact: true))

      Button("完成") {
        dismiss()
        model.isShowingDirectFilesInspector = false
      }
      .buttonStyle(LensButtonStyle(kind: .primary, compact: true))
      .keyboardShortcut(.defaultAction)
    }
    .padding(16)
  }

  private var filteredEntries: [DirectFileEntry] {
    guard let entries = model.directFilesInspection?.entries else { return [] }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return entries }
    return entries.filter {
      $0.name.localizedCaseInsensitiveContains(trimmed)
        || $0.url.path.localizedCaseInsensitiveContains(trimmed)
    }
  }
}

private struct InspectorMetric: View {
  let title: String
  let value: String
  let symbol: String
  let tint: Color

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 30, height: 30)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
      VStack(alignment: .leading, spacing: 2) {
        Text(value)
          .font(.headline)
          .monospacedDigit()
        Text(title)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(LensTheme.recessed(colorScheme), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(LensTheme.stroke(colorScheme), lineWidth: 1)
    }
  }
}

private struct DirectFileRow: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  let entry: DirectFileEntry

  var body: some View {
    HStack(spacing: 12) {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .frame(width: 34, height: 34)

      VStack(alignment: .leading, spacing: 4) {
        Text(entry.name)
          .font(.callout.weight(.medium))
          .lineLimit(1)
        Text(entry.url.path)
          .font(.caption2.monospaced())
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer(minLength: 12)

      VStack(alignment: .trailing, spacing: 3) {
        Text(entry.allocatedBytes.formattedBytes)
          .font(.caption.weight(.semibold))
          .monospacedDigit()
        if entry.logicalBytes != entry.allocatedBytes {
          Text("邏輯 \(entry.logicalBytes.formattedBytes)")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      Button {
        model.openInFinder(entry.url.path)
      } label: {
        Image(systemName: "finder")
      }
      .buttonStyle(LensIconButtonStyle())
      .help("在 Finder 顯示")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      isHovered ? LensTheme.hoveredNavigation(colorScheme) : Color.clear,
      in: RoundedRectangle(cornerRadius: 11)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .contextMenu {
      Button("在 Finder 中顯示") { model.openInFinder(entry.url.path) }
      Button("打開所在資料夾") { model.openPathInFinder(entry.url.path) }
      Button("複製完整路徑") { model.copyPath(entry.url.path) }
    }
  }

  private var icon: NSImage {
    let image = NSWorkspace.shared.icon(forFile: entry.url.path)
    image.size = NSSize(width: 34, height: 34)
    return image
  }
}
