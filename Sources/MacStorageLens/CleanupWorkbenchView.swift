import AppKit
import SwiftUI

struct CleanerView: View {
  @EnvironmentObject private var app: AppModel
  @StateObject private var workbench = CleanupWorkbenchModel()
  @LensState private var showAdvanced = false
  @LensState private var showHistory = false
  @LensState private var confirmManual = false
  @LensState private var search = ""
  @LensState private var showProtection = false
  @LensState private var decision: CleanupWorkbenchDecision = .automatic
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      navigation
      if showAdvanced {
        AdvancedCleanupView()
      } else if showHistory {
        history
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 22) {
            LensPageHeader(
              title: workbench.tool.title,
              subtitle: workbench.tool == .smart ? "" : subtitle)
            if workbench.tool == .smart { smartHero } else { detailHeader }
            if workbench.isBusy { progressPanel }
            if let execution = workbench.execution {
              WorkbenchExecutionSummary(execution: execution)
            }
            if let result = workbench.result {
              results(result)
            }
          }
          .padding(28)
          .frame(maxWidth: 1240)
          .frame(maxWidth: .infinity, alignment: .top)
        }
        if !workbench.selectedItems.isEmpty && workbench.tool != .smart { selectionBar }
        if !workbench.selectedItems.isEmpty && workbench.tool == .smart && decision == .review {
          selectionBar
        }
      }
    }
    .navigationTitle(showAdvanced ? "進階規則" : showHistory ? "清理紀錄" : workbench.tool.title)
    .sheet(item: $workbench.inspectedItem) { item in
      WorkbenchItemInspector(item: item, engine: workbench.engine)
    }
    .sheet(isPresented: $showProtection) { protectionManager }
    .sheet(isPresented: $confirmManual) { manualConfirmation }
    .alert(
      "這次沒有完成",
      isPresented: Binding(
        get: { workbench.error != nil }, set: { if !$0 { workbench.error = nil } })
    ) {
      Button("知道了", role: .cancel) { workbench.error = nil }
    } message: {
      Text(workbench.error ?? "請重新掃描確認目前狀態。")
    }
    .onAppear {
      workbench.busyChanged = { [weak app = app] in
        app?.isWorkbenchBusy = CleanupWorkbenchCoordinator.shared.isBusy
      }
      app.isWorkbenchBusy = CleanupWorkbenchCoordinator.shared.isBusy
    }
    .onChange(of: workbench.execution?.id) { _, _ in
      app.cleanupWorkbenchDidFinish()
    }
  }

  private var blockedByOtherWork: Bool {
    app.isFullScanRunning || app.isLoadingReport || app.isScanningCleanup || app.isCleaning
      || (app.isWorkbenchBusy && !workbench.isBusy)
  }

  private var navigation: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 5) {
        ForEach(CleanupWorkbenchTool.allCases) { tool in
          Button {
            showAdvanced = false
            showHistory = false
            workbench.changeTool(tool)
            decision = tool == .smart ? .automatic : .review
            search = ""
          } label: {
            Label(tool.title, systemImage: tool.symbol).font(
              .callout.weight(
                workbench.tool == tool && !showAdvanced && !showHistory ? .semibold : .regular))
          }
          .buttonStyle(
            LensButtonStyle(
              kind: workbench.tool == tool && !showAdvanced && !showHistory ? .secondary : .quiet,
              compact: true))
        }
        Divider().frame(height: 20).padding(.horizontal, 4)
        Button("保留清單", systemImage: "lock.shield") { showProtection = true }
          .buttonStyle(LensButtonStyle(kind: .quiet, compact: true))
        Button("清理紀錄", systemImage: "clock.arrow.circlepath") {
          showHistory = true
          showAdvanced = false
          workbench.loadHistory()
        }
        .buttonStyle(LensButtonStyle(kind: showHistory ? .secondary : .quiet, compact: true))
        Button("進階規則", systemImage: "slider.horizontal.3") {
          showAdvanced = true
          showHistory = false
        }
        .buttonStyle(LensButtonStyle(kind: showAdvanced ? .secondary : .quiet, compact: true))
      }
      .padding(.horizontal, 24).padding(.vertical, 14)
      .disabled(workbench.isBusy)
    }
    .background(.bar)
  }

  private var subtitle: String {
    switch workbench.tool {
    case .smart: return ""
    case .projects: return "依專案設定找出建置資料與下載套件；移除後需重新建置或下載。"
    case .installers: return "列出七天未修改的安裝檔，以及一天未修改的未完成下載。"
    case .largeFiles: return "列出至少 100 MiB，或一百八十天未修改的檔案。"
    case .duplicates: return "完整內容相同才列為副本；每組保留一份。"
    case .applications: return "程式本體與設定、離線資料分開選取；使用中或共用的資料會保留。"
    }
  }

  private var smartHero: some View {
    LensPanel(padding: 28) {
      HStack(alignment: .center, spacing: 28) {
        Image(
          systemName: workbench.execution?.removedFiles ?? 0 > 0
            ? "checkmark.seal.fill" : "externaldrive.badge.checkmark"
        )
        .font(.system(size: 58, weight: .light))
        .foregroundStyle(LensTheme.sage)
        .frame(width: 104, height: 112)
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 10) {
          if let result = workbench.result {
            Text("可一鍵清理 \(result.automaticBytes.formattedBytes)")
              .font(.system(size: 27, weight: .semibold)).tracking(-0.4)
          }
          Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
            GridRow {
              Text("已知程式快取")
              Text("至少一天未修改").foregroundStyle(.secondary)
            }
            GridRow {
              Text("套件下載快取")
              Text("至少三十天未修改").foregroundStyle(.secondary)
            }
            GridRow {
              Text("診斷紀錄")
              Text("至少三十天未修改").foregroundStyle(.secondary)
            }
          }.font(.callout)
          Text("一鍵清理會重新掃描，再直接移除符合條件的檔案，不經垃圾桶。診斷紀錄無法重新產生。")
            .font(.callout).foregroundStyle(.secondary)
          HStack(spacing: 10) {
            Button {
              workbench.scan(andClean: true)
            } label: {
              Label(workbench.isExecuting ? "正在清理…" : "一鍵清理", systemImage: "sparkles")
            }
            .buttonStyle(LensButtonStyle(kind: .primary))
            .disabled(workbench.isBusy || blockedByOtherWork)
            Button("先查看可清項目") { workbench.scan() }
              .buttonStyle(LensButtonStyle(kind: .secondary))
              .disabled(workbench.isBusy || blockedByOtherWork)
          }.padding(.top, 3)
        }
        Spacer(minLength: 0)
      }
    }
  }

  private var detailHeader: some View {
    LensPanel(padding: 22) {
      HStack(spacing: 18) {
        Image(systemName: workbench.tool.symbol).font(.system(size: 30, weight: .light))
          .foregroundStyle(LensTheme.accentSoft)
        VStack(alignment: .leading, spacing: 5) {
          Text(
            workbench.tool == .applications
              ? "範圍：系統與目前帳號的「應用程式」資料夾" : workbench.root.path
          )
          .font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
        }
        Spacer()
        if workbench.tool != .applications {
          Button("選擇資料夾", systemImage: "folder") { workbench.chooseRoot() }.buttonStyle(
            LensButtonStyle(kind: .secondary))
        }
        Button("開始掃描", systemImage: "magnifyingglass") { workbench.scan() }.buttonStyle(
          LensButtonStyle(kind: .primary))
      }
      .disabled(workbench.isBusy || blockedByOtherWork)
    }
  }

  private var progressPanel: some View {
    LensPanel(padding: 20) {
      HStack(spacing: 15) {
        ProgressView().controlSize(.small)
        VStack(alignment: .leading, spacing: 5) {
          Text(workbench.progress.message).font(.callout.weight(.semibold))
          if let path = workbench.progress.path {
            Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(
              .middle)
          }
          if let total = workbench.progress.total, total > 0 {
            ProgressView(
              value: Double(min(workbench.progress.completed, total)), total: Double(total)
            ).frame(maxWidth: 420)
          }
        }
        Spacer()
        Button("停止", role: .cancel) { workbench.cancel() }.buttonStyle(
          LensButtonStyle(kind: .quiet))
      }
    }
  }

  private func results(_ result: CleanupWorkbenchScan) -> some View {
    let visible = result.items.filter { item in
      let matchesDecision = item.decision == decision
      let matchesSearch =
        search.isEmpty
        || (item.name + item.path + item.reason + (item.ownerName ?? ""))
          .localizedCaseInsensitiveContains(search)
      return matchesDecision && matchesSearch
    }
    return VStack(alignment: .leading, spacing: 15) {
      HStack(spacing: 20) {
        ForEach(
          [CleanupWorkbenchDecision.automatic, .review, .protected, .unavailable], id: \.rawValue
        ) { value in
          let count = result.items.filter { $0.decision == value }.count
          if workbench.tool == .smart || count > 0 {
            Button {
              decision = value
            } label: {
              VStack(alignment: .leading, spacing: 5) {
                Text(value.title).font(.caption).foregroundStyle(.secondary)
                Text("\(count) 項").font(.title3.weight(.semibold))
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) {
              if workbench.tool == .smart && value == decision {
                Rectangle().fill(LensTheme.accent).frame(height: 2)
              }
            }
          }
        }
      }
      HStack {
        Text(result.complete ? "已完成本次檢查" : "已顯示完成讀取的部分").font(.caption).foregroundStyle(.secondary)
        Spacer()
        TextField("搜尋名稱、位置或原因", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
      }
      if !result.notices.isEmpty {
        DisclosureGroup("保護與讀取提示（\(result.notices.count)）") {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(result.notices, id: \.self) {
              Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        }.font(.callout)
      }
      if visible.isEmpty {
        ContentUnavailableView(
          search.isEmpty ? "目前沒有這類項目" : "沒有符合搜尋的項目", systemImage: "checkmark.circle",
          description: Text(search.isEmpty ? "" : "試著縮短名稱或改用部分路徑。")
        )
        .frame(minHeight: 180)
      } else {
        LazyVStack(spacing: 0) {
          ForEach(visible) { item in
            WorkbenchResultRow(
              item: item, selected: workbench.selected.contains(item.id),
              allowsSelection: workbench.tool != .smart || item.decision == .review,
              toggle: { workbench.toggle(item) }, inspect: { workbench.inspectedItem = item }
            )
            .contextMenu {
              Button("加入保留清單", systemImage: "lock.shield") { workbench.protect(item) }
                .disabled(workbench.isBusy || blockedByOtherWork)
            }
            Divider().opacity(0.5)
          }
        }
      }
    }
  }

  private var selectionBar: some View {
    HStack(spacing: 15) {
      Text("已選 \(workbench.selectedItems.count) 項").font(.callout.weight(.semibold))
      Text("清空垃圾桶前仍占磁碟空間。").font(.caption).foregroundStyle(.secondary)
      Spacer()
      Button("取消選取") { workbench.selected.removeAll() }.buttonStyle(LensButtonStyle(kind: .quiet))
      Button("移到垃圾桶", systemImage: "trash") { confirmManual = true }.buttonStyle(
        LensButtonStyle(kind: .primary))
    }.padding(20).background(.bar).disabled(workbench.isBusy || blockedByOtherWork)
  }

  private var manualConfirmation: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("移到 Finder 垃圾桶？").font(.title2.weight(.semibold))
      Text("共 \(workbench.selectedItems.count) 個項目，移動後可從 Finder 垃圾桶取回。")
      if workbench.selectedItems.contains(where: { $0.rule == "application-data" }) {
        Label("所選程式資料可能包含設定、登入狀態與離線文件。", systemImage: "exclamationmark.triangle")
          .foregroundStyle(LensTheme.sand)
      }
      if workbench.selectedItems.contains(where: { $0.tool == .projects }) {
        Label("若直接修改過這些套件或建置資料夾，修改內容也會一起移到垃圾桶。", systemImage: "exclamationmark.triangle")
          .foregroundStyle(LensTheme.sand)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(workbench.selectedItems) { Text($0.path).font(.caption).textSelection(.enabled) }
        }
      }.frame(maxHeight: 230)
      HStack {
        Spacer()
        Button("取消", role: .cancel) { confirmManual = false }
        Button("移到垃圾桶") {
          confirmManual = false
          workbench.executeManual()
        }.buttonStyle(.borderedProminent)
      }
    }.padding(28).frame(width: 620)
  }

  private var protectionManager: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("保留清單").font(.title2.weight(.semibold))
        Spacer()
        Button("新增位置", systemImage: "plus") { workbench.chooseProtection() }
          .disabled(workbench.isBusy)
        Button("完成") { showProtection = false }
      }
      Text("加入的位置及其內容不會被清理。其他已保留項目可在掃描結果查看原因。")
        .font(.callout).foregroundStyle(.secondary)
      if workbench.protectedPaths.isEmpty {
        ContentUnavailableView(
          "尚未加入位置", systemImage: "lock.shield", description: Text("按「新增位置」，或在掃描結果上按右鍵加入。"))
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(workbench.protectedPaths, id: \.self) { path in
              HStack {
                Text(path).font(.caption).textSelection(.enabled)
                Spacer()
                Button("移出清單") { workbench.removeProtection(path) }
              }
            }
          }
        }
      }
    }.padding(28).frame(width: 700, height: 380)
  }

  private var history: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        LensPageHeader(title: "清理紀錄")
        if workbench.history.isEmpty { ContentUnavailableView("尚無清理紀錄", systemImage: "clock") }
        ForEach(workbench.history) { WorkbenchExecutionSummary(execution: $0) }
      }.padding(28).frame(maxWidth: 1240).frame(maxWidth: .infinity, alignment: .top)
    }
  }
}

private struct WorkbenchResultRow: View {
  let item: CleanupWorkbenchItem
  let selected: Bool
  let allowsSelection: Bool
  let toggle: () -> Void
  let inspect: () -> Void
  var body: some View {
    HStack(alignment: .top, spacing: 13) {
      if allowsSelection && item.canSelect {
        Toggle("選取 \(item.name)", isOn: Binding(get: { selected }, set: { _ in toggle() }))
          .labelsHidden().toggleStyle(.checkbox).padding(.top, 4)
      } else {
        Image(systemName: item.decision == .automatic ? "checkmark.shield" : "lock.shield")
          .foregroundStyle(item.decision == .automatic ? LensTheme.sage : LensTheme.slate).frame(
            width: 18
          ).padding(.top, 4)
      }
      VStack(alignment: .leading, spacing: 7) {
        Text(item.name).font(.callout.weight(.semibold)).lineLimit(2)
        Text(item.reason).font(.callout).foregroundStyle(.secondary).fixedSize(
          horizontal: false, vertical: true)
        Text(item.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(
          .middle
        ).textSelection(.enabled)
      }
      Spacer(minLength: 15)
      VStack(alignment: .trailing, spacing: 8) {
        Text(item.bytes?.formattedBytes ?? "容量未取得").font(.callout.weight(.semibold))
          .monospacedDigit()
        Button("檢視", action: inspect).buttonStyle(LensButtonStyle(kind: .quiet, compact: true))
      }
    }.padding(.vertical, 16).padding(.horizontal, 7)
  }
}

private struct WorkbenchExecutionSummary: View {
  let execution: CleanupWorkbenchExecution
  private var failureMessages: [String] { execution.entries.flatMap(\.failures) }
  private var title: String {
    if execution.cancelled { return "已停止，保留已完成的操作" }
    if execution.removedFiles == 0 {
      return failureMessages.isEmpty ? "本次未清除項目" : "未移除檔案，請查看原因"
    }
    if !failureMessages.isEmpty { return "已處理部分項目，其餘已保留" }
    return execution.automatic ? "已直接清除" : "已移到垃圾桶"
  }
  var body: some View {
    LensPanel(padding: 20) {
      VStack(alignment: .leading, spacing: 10) {
        Label(
          title,
          systemImage: execution.cancelled
            ? "pause.circle" : execution.removedFiles == 0 ? "info.circle" : "checkmark.circle"
        )
        .font(.headline).foregroundStyle(LensTheme.sage)
        Text("\(execution.removedFiles) 個項目 · \(execution.processedBytes.formattedBytes)")
          .font(.title3.weight(.semibold))
        let unknownSizes = execution.entries.filter { $0.removedFiles > 0 && $0.sizeKnown == false }
          .count
        if unknownSizes > 0 {
          Text("另有 \(unknownSizes) 個已處理項目未能完整量得容量，未加入上方容量。")
            .font(.caption).foregroundStyle(.secondary)
        }
        if execution.removedFiles > 0 {
          Text(
            execution.automatic
              ? "這是已移除檔案占用的容量；系統可用空間還會受到快照與其他程式的影響。"
              : "已移到垃圾桶的項目，清空前仍占用磁碟空間。"
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        if let after = execution.availableBytesAfter {
          Text("目前系統回報可用空間：\(after.formattedBytes)").font(.caption).foregroundStyle(.secondary)
        }
        if let warning = execution.persistenceWarning {
          Label(warning, systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(LensTheme.sand).textSelection(.enabled)
        }
        let failures = failureMessages
        if !failures.isEmpty {
          DisclosureGroup("查看未完成的原因（列出 \(failures.count) 筆）") {
            ForEach(Array(failures.enumerated()), id: \.offset) {
              Text($0.element).font(.caption).foregroundStyle(.secondary)
            }
          }.font(.callout)
        }
        let receipts = execution.entries.flatMap(\.receipts)
        if !receipts.isEmpty {
          Button("顯示垃圾桶裡的項目", systemImage: "trash") { _ = FinderVisibleTrash.reveal(receipts) }
            .buttonStyle(LensButtonStyle(kind: .secondary, compact: true))
        }
        Text(execution.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
  }
}

private struct WorkbenchItemInspector: View {
  let item: CleanupWorkbenchItem
  let engine: CleanupWorkbenchEngine
  @Environment(\.dismiss) private var dismiss
  @LensState private var bytes: Int64?
  @LensState private var children: [CleanupFileSnapshot] = []
  @LensState private var loading = true
  @LensState private var error: String?
  private let token = CleanupWorkCancellation()
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(item.name).font(.title2.weight(.semibold))
        Spacer()
        Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
      }
      Text(item.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
      Text(item.reason).font(.callout)
      Label(item.impact, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
      if let reference = item.referencePath {
        Text(item.tool == .duplicates ? "保留的檔案：\(reference)" : "所屬程式：\(reference)")
          .font(.caption).textSelection(.enabled)
      }
      HStack {
        if loading {
          ProgressView().controlSize(.small)
          Text("正在查看容量與內容…").font(.caption)
        } else {
          Text(bytes?.formattedBytes ?? "容量無法完整讀取").font(.title3.weight(.semibold))
        }
        Spacer()
        Button("在 Finder 顯示", systemImage: "folder") {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
        }
      }
      if let error { Text(error).font(.caption).foregroundStyle(LensTheme.sand) }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 9) {
          ForEach(children, id: \.path) { child in
            HStack {
              Text(URL(fileURLWithPath: child.path).lastPathComponent).lineLimit(1)
              Spacer()
              Text(child.isDirectory ? "資料夾" : child.allocatedBytes.formattedBytes).foregroundStyle(
                .secondary)
            }.font(.caption)
          }
        }
      }.frame(minHeight: 120, maxHeight: 330)
      if children.count >= 200 {
        Text("先顯示前二百個直接項目；可到 Finder 查看全部內容。").font(.caption).foregroundStyle(.secondary)
      }
    }.padding(28).frame(width: 720)
      .onAppear {
        DispatchQueue.global(qos: .utility).async {
          let result = Result { try engine.inspectItem(item, cancellation: token) }
          DispatchQueue.main.async {
            loading = false
            switch result {
            case .success(let value):
              bytes = value.0
              children = value.1
            case .failure(let failure): error = failure.localizedDescription
            }
          }
        }
      }
      .onDisappear { token.cancel() }
  }
}
