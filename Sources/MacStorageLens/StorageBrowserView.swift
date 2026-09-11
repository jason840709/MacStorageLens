import SwiftUI

struct StorageBrowserView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      LensPageHeader(
        eyebrow: "路徑瀏覽",
        title: "資料樹",
        subtitle: "從 Data volume 或其他掃描根節點逐層深入；圖表與清單使用同一份報告索引。"
      ) {
        HStack(spacing: 8) {
          Button {
            model.goUp()
          } label: {
            Label("上一層", systemImage: "arrow.up")
          }
          .buttonStyle(LensButtonStyle(kind: .secondary))
          .disabled(!model.canGoUp)

          Button {
            model.openInFinder(model.currentPath)
          } label: {
            Label("Finder 顯示", systemImage: "finder")
          }
          .buttonStyle(LensButtonStyle(kind: .secondary))
        }
      }

      BrowserBreadcrumbBar()

      HSplitView {
        BrowserChildrenPanel()
          .frame(minWidth: 400, idealWidth: 470)

        BrowserChartPanel()
          .frame(minWidth: 480, idealWidth: 650)
      }
    }
    .padding(26)
    .navigationTitle("資料樹")
  }
}

private struct BrowserBreadcrumb: Identifiable {
  let label: String
  let path: String
  var id: String { path }
}

private struct BrowserBreadcrumbBar: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    LensPanel(padding: 10, radius: 14) {
      HStack(spacing: 8) {
        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(LensTheme.accentSoft)
          .frame(width: 28, height: 28)
          .background(LensTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 5) {
            ForEach(Array(breadcrumbs.enumerated()), id: \.element.id) { index, crumb in
              if index > 0 {
                Image(systemName: "chevron.right")
                  .font(.caption2.weight(.bold))
                  .foregroundStyle(.quaternary)
              }

              Button {
                model.loadPath(crumb.path)
              } label: {
                Text(crumb.label)
                  .font(.caption.weight(index == breadcrumbs.count - 1 ? .semibold : .medium))
                  .foregroundStyle(index == breadcrumbs.count - 1 ? Color.primary : Color.secondary)
                  .padding(.horizontal, 8)
                  .padding(.vertical, 5)
                  .background(
                    index == breadcrumbs.count - 1
                      ? LensTheme.selectedNavigation(colorScheme)
                      : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                  )
              }
              .buttonStyle(LensRowButtonStyle())
            }
          }
        }

        Spacer(minLength: 8)

        Text(
          model.isShowingAggregateFocus
            ? "\(model.currentPath) · \(model.aggregateFocusLabel ?? "合併項目")"
            : model.currentPath
        )
        .font(.caption2.monospaced())
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .frame(maxWidth: 310, alignment: .trailing)
      }
    }
  }

  private var breadcrumbs: [BrowserBreadcrumb] {
    guard let section = model.document?.section(containing: model.currentPath) else {
      return [BrowserBreadcrumb(label: model.currentPath, path: model.currentPath)]
    }

    let root = section.root
    var result = [BrowserBreadcrumb(label: rootLabel(root), path: root)]
    guard model.currentPath != root else { return result }

    let suffix = String(model.currentPath.dropFirst(root.count))
    let components = suffix.split(separator: "/").map(String.init)
    var path = root
    for component in components {
      path += "/" + component
      result.append(BrowserBreadcrumb(label: component, path: path))
    }
    return result
  }

  private func rootLabel(_ root: String) -> String {
    if root == "/System/Volumes/Data" { return "Data" }
    let name = URL(fileURLWithPath: root).lastPathComponent
    return name.isEmpty ? root : name
  }
}

private struct BrowserChildrenPanel: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    LensPanel(padding: 0, radius: 17) {
      VStack(spacing: 0) {
        HStack(alignment: .center) {
          VStack(alignment: .leading, spacing: 3) {
            Text(model.isShowingAggregateFocus ? "合併項目內容" : "本層內容")
              .font(.headline)
            Text(
              model.isShowingAggregateFocus
                ? "這些子資料夾原本因同層項目極多而收在其他項目；此處完整列出，可逐項深入"
                : "直接檔案與子資料夾，依配置區塊用量排列"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          Text("\(model.children.count + (model.currentDirectFilesItem == nil ? 0 : 1)) 項")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(17)

        Divider().opacity(0.55)

        if model.isLoadingTree {
          ProgressView("讀取資料樹…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.children.isEmpty && model.currentDirectFilesItem == nil {
          ContentUnavailableView {
            Label("沒有子資料夾", systemImage: "folder")
          } description: {
            Text("此節點沒有可讀取的直接子資料夾，或其內容低於報告的可見範圍。")
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVStack(spacing: 4) {
              if let directFiles = model.currentDirectFilesItem, let parentPath = directFiles.path {
                let directFilesIndex =
                  model.sunburst?.children.firstIndex(where: { $0.id == directFiles.id }) ?? 0
                Button {
                  model.inspectDirectFiles(parentPath: parentPath, expectedBytes: directFiles.bytes)
                } label: {
                  DirectFilesNodeRow(item: directFiles, index: directFilesIndex)
                }
                .buttonStyle(LensRowButtonStyle())
                .contextMenu {
                  Button("列出直接檔案") {
                    model.inspectDirectFiles(
                      parentPath: parentPath, expectedBytes: directFiles.bytes)
                  }
                  Divider()
                  Button("在 Finder 中顯示父資料夾") { model.openInFinder(parentPath) }
                  Button("在 Finder 中打開父資料夾") { model.openPathInFinder(parentPath) }
                  Button("複製父資料夾路徑") { model.copyPath(parentPath) }
                }
              }

              ForEach(Array(model.children.enumerated()), id: \.element.id) { index, node in
                let chartIndex =
                  model.sunburst?.children.firstIndex(where: { $0.path == node.path }) ?? index
                Button {
                  model.loadPath(node.path)
                } label: {
                  StorageNodeRow(
                    node: node,
                    index: chartIndex,
                    parentBytes: model.sunburst?.bytes ?? 0
                  )
                }
                .buttonStyle(LensRowButtonStyle())
                .contextMenu {
                  Button("在 Finder 中顯示") { model.openInFinder(node.path) }
                  Button("在 Finder 中打開") { model.openPathInFinder(node.path) }
                  Button("複製完整路徑") { model.copyPath(node.path) }
                  Divider()
                  Button("進入此資料夾") { model.loadPath(node.path) }
                }
              }
            }
            .padding(9)
          }
        }
      }
    }
  }
}

private struct DirectFilesNodeRow: View {
  let item: SunburstItem
  let index: Int

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 11) {
      Image(systemName: "doc.on.doc.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(color)
        .frame(width: 31, height: 31)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))

      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline) {
          Text("直接檔案")
            .font(.callout.weight(.medium))
          Spacer()
          Text(item.bytes.formattedBytes)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        Text("直接位於目前資料夾；點一下列出檔名與完整路徑")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }

      Image(systemName: "list.bullet.rectangle")
        .font(.caption.weight(.semibold))
        .foregroundStyle(LensTheme.accentSoft)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .background(
      isHovered ? LensTheme.hoveredNavigation(colorScheme) : Color.clear,
      in: RoundedRectangle(cornerRadius: 11)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
  }

  private var color: Color {
    StoragePalette.topLevelColor(
      index: index,
      itemID: item.id,
      kind: item.kind,
      colorHint: item.colorHint,
      colorScheme: colorScheme
    )
  }
}

private struct StorageNodeRow: View {
  let node: StorageNode
  let index: Int
  let parentBytes: Int64

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 11) {
      Image(systemName: "folder.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(color)
        .frame(width: 31, height: 31)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline) {
          Text(node.name)
            .font(.callout.weight(.medium))
            .lineLimit(1)
          Spacer()
          Text(node.allocatedBytes.formattedBytes)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }

        GeometryReader { proxy in
          let ratio =
            parentBytes > 0
            ? min(1, Double(node.allocatedBytes) / Double(parentBytes))
            : 0
          ZStack(alignment: .leading) {
            Capsule().fill(LensTheme.recessed(colorScheme))
            Capsule().fill(color).frame(width: proxy.size.width * ratio)
          }
        }
        .frame(height: 4)

        Text(node.path)
          .font(.caption2.monospaced())
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Image(systemName: "chevron.right")
        .font(.caption2.weight(.bold))
        .foregroundStyle(.quaternary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .background(
      isHovered ? LensTheme.hoveredNavigation(colorScheme) : Color.clear,
      in: RoundedRectangle(cornerRadius: 11)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(reduceMotion ? nil : LensMotion.hover, value: isHovered)
  }

  private var color: Color {
    StoragePalette.branchColor(
      index: index,
      familyDepth: 0,
      seed: StorageColorModel.stableHash(node.path),
      colorScheme: colorScheme
    )
  }
}

private struct BrowserChartPanel: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    LensPanel(padding: 16, radius: 17) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text(model.sunburst?.label ?? "容量地圖")
              .font(.headline)
            Text(
              model.isShowingAggregateFocus
                ? "已展開原本合併的所有子項；點擊任一扇區可繼續深入，上一層可返回原本容量地圖"
                : "第一層子項各自使用支系色；同一分支往外保持色相並以更明顯的明度階差呈現深度。點擊深入，右鍵可在 Finder 操作"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          if let chart = model.sunburst {
            Text(chart.bytes.formattedBytes)
              .font(.caption.weight(.semibold))
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 4)

        if model.isLoadingTree, model.sunburst == nil {
          ProgressView("建立容量地圖…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let chart = model.sunburst {
          SunburstChart(
            root: chart,
            onSelect: { item in
              model.selectSunburstItem(item, navigateToBrowser: false)
            },
            onRevealInFinder: { model.openInFinder($0) },
            onOpenInFinder: { model.openPathInFinder($0) },
            onCopyPath: { model.copyPath($0) }
          )
          .padding(4)
        } else {
          ContentUnavailableView("沒有圖表資料", systemImage: "chart.pie")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
  }
}
