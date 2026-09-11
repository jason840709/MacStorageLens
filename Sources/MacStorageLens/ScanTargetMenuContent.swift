import SwiftUI

/// Shared menu content for selecting the next scan target. The first level stays
/// compact; older locations move into a nested menu instead of making the menu
/// grow without bounds.
struct NextScanTargetMenuContent: View {
  @EnvironmentObject private var model: AppModel

  var includesDisplayedLocationShortcut = true

  var body: some View {
    Button {
      model.useSystemScanTarget()
    } label: {
      Label(
        ScanTarget.systemStorage.locationTitle,
        systemImage: model.selectedScanTarget.kind == .system
          ? "checkmark.circle.fill" : ScanTarget.systemStorage.kind.symbol
      )
    }

    if !model.pendingRecentScanTargets.isEmpty {
      Divider()
      Section("最近指定（尚未掃描）") {
        targetEntries(
          model.pendingRecentScanTargets,
          overflowTitle: "更多最近位置"
        )
      }
    }

    if !model.savedNonSystemTargetRecords.isEmpty {
      Divider()
      Section("已保存的位置") {
        savedEntries(
          model.savedNonSystemTargetRecords,
          overflowTitle: "更多已保存位置"
        )
      }
    }

    if includesDisplayedLocationShortcut,
      let displayed = model.displayedScanTarget,
      displayed.reportRetentionKey != model.selectedScanTarget.reportRetentionKey
    {
      Divider()
      Button {
        model.useDisplayedLocationAsScanTarget()
      } label: {
        Label("使用目前顯示的位置", systemImage: "arrow.right.circle")
      }
    }

    Divider()
    Button {
      model.chooseVolumeScanTarget()
    } label: {
      Label("選擇其他磁碟…", systemImage: "externaldrive")
    }
    Button {
      model.chooseFolderScanTarget()
    } label: {
      Label("選擇資料夾…", systemImage: "folder")
    }
  }

  @ViewBuilder
  private func targetEntries(_ targets: [ScanTarget], overflowTitle: String) -> some View {
    let inline = Array(targets.prefix(ReportRetentionPolicy.inlineMenuItems))
    let overflow = Array(targets.dropFirst(ReportRetentionPolicy.inlineMenuItems))

    ForEach(inline) { target in
      targetButton(target)
    }

    if !overflow.isEmpty {
      Menu {
        ForEach(overflow) { target in
          targetButton(target)
        }
      } label: {
        Label("\(overflowTitle)（\(overflow.count)）", systemImage: "ellipsis.circle")
      }
    }
  }

  @ViewBuilder
  private func savedEntries(_ records: [ReportRecord], overflowTitle: String) -> some View {
    let inline = Array(records.prefix(ReportRetentionPolicy.inlineMenuItems))
    let overflow = Array(records.dropFirst(ReportRetentionPolicy.inlineMenuItems))

    ForEach(inline) { record in
      targetButton(record.target)
        .help(record.target.path)
    }

    if !overflow.isEmpty {
      Menu {
        ForEach(overflow) { record in
          targetButton(record.target)
            .help(record.target.path)
        }
      } label: {
        Label("\(overflowTitle)（\(overflow.count)）", systemImage: "ellipsis.circle")
      }
    }
  }

  private func targetButton(_ target: ScanTarget) -> some View {
    Button {
      model.selectScanTarget(target)
    } label: {
      Label(
        target.locationTitle,
        systemImage: target.reportRetentionKey == model.selectedScanTarget.reportRetentionKey
          ? "checkmark.circle.fill" : target.kind.symbol
      )
    }
    .help(target.path)
  }
}

/// Shared report menu for switching the currently displayed capacity map.
struct DisplayedReportMenuContent: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    if model.reportHistory.isEmpty {
      Button("尚無已保存的掃描位置") {}
        .disabled(true)
    } else {
      reportEntries(model.reportHistory)
      Divider()
      Button {
        model.destination = .history
      } label: {
        Label("管理掃描紀錄…", systemImage: "clock.arrow.circlepath")
      }
    }
  }

  @ViewBuilder
  private func reportEntries(_ records: [ReportRecord]) -> some View {
    let inline = Array(records.prefix(ReportRetentionPolicy.inlineMenuItems))
    let overflow = Array(records.dropFirst(ReportRetentionPolicy.inlineMenuItems))

    ForEach(inline) { record in
      reportButton(record)
    }

    if !overflow.isEmpty {
      Menu {
        ForEach(overflow) { record in
          reportButton(record)
        }
      } label: {
        Label("更多已保存位置（\(overflow.count)）", systemImage: "ellipsis.circle")
      }
    }
  }

  private func reportButton(_ record: ReportRecord) -> some View {
    Button {
      model.displayReport(record)
    } label: {
      Label(
        record.locationTitle,
        systemImage: isDisplayed(record) ? "checkmark.circle.fill" : record.locationSymbol
      )
    }
    .help(record.target.path)
  }

  private func isDisplayed(_ record: ReportRecord) -> Bool {
    model.document?.url.standardizedFileURL == record.url.standardizedFileURL
  }
}
