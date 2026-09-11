import AppKit
import Combine
import Foundation

final class AppModel: ObservableObject {
  private struct LoadedReportBundle {
    let document: ReportDocument
    let currentPath: String
    let children: [StorageNode]
    let sunburst: SunburstItem
    let overviewSunburst: SunburstItem
    let parseSeconds: TimeInterval
    let initialViewBuildSeconds: TimeInterval
    let presentationIndexSource: ReportPresentationIndexSource
    let presentationIndexWriteSeconds: TimeInterval
  }

  private final class ScanSessionBox {
    weak var value: ScanSession?
  }

  private enum PreferenceKey {
    static let cleanupProfile = "MacStorageLens.cleanupProfile"
    static let cleanupCustomScopes = "MacStorageLens.cleanupCustomScopes"
    static let cleanupPresetOptionalScopes = "MacStorageLens.cleanupPresetOptionalScopes"
    static let cleanupCustomMinimumMiB = "MacStorageLens.cleanupCustomMinimumMiB"
    static let cleanupFolderCustomScopes = "MacStorageLens.cleanupFolderCustomScopes"
    static let selectedScanTarget = "MacStorageLens.selectedScanTarget"
    static let recentScanTargets = "MacStorageLens.recentScanTargets"
  }

  @Published var destination: SidebarDestination = .overview
  @Published var document: ReportDocument?
  @Published var currentPath = "/System/Volumes/Data"
  @Published var children: [StorageNode] = []
  @Published var sunburst: SunburstItem?
  @Published var overviewSunburst: SunburstItem?
  @Published var liveCapacity: LiveCapacity?
  @Published var cleanupCandidates: [CleanupCandidate] = []
  @Published var cleanupProfile: CleanupProfile = .ultraConservative
  @Published var cleanupCustomScopes: Set<CleanupScope> = [
    .standardCaches, .sandboxAndGroupCaches, .clipboardTemporary,
    .applicationWebCaches, .developerCaches, .packageManagerCaches, .downloadResidue,
  ]
  @Published var cleanupPresetOptionalScopes: Set<CleanupScope> = []
  @Published var cleanupFolderCustomScopes: Set<CleanupScope> = [
    .folderFinderMetadata, .folderWindowsMetadata, .folderArchiveMetadata,
    .folderAppleDoubleRemnants,
  ]
  @Published var cleanupCustomMinimumMiB: Int = 5
  @Published var cleanupScanSource: CleanupScanSource = .existingStorageReport
  @Published var cleanupTargetCapabilities: CleanupTargetCapabilities?
  @Published var cleanupScanProgress = CleanupScanProgress(
    message: "尚未開始清理候選掃描", currentPath: nil, currentStep: 0, totalSteps: 1)
  @Published var cleanupLastResult: CleanupScanResult?
  @Published var cleanupIndexStatus: CleanupIncrementalIndexStatus = .empty
  @Published var reportHistory: [ReportRecord] = []
  @Published var selectedScanTarget: ScanTarget = .systemStorage
  @Published var recentScanTargets: [ScanTarget] = []
  @Published var appFullDiskAccessProbe: FullDiskAccessProbeResult = .checking

  @Published var isShowingDirectFilesInspector = false
  @Published var isInspectingDirectFiles = false
  @Published var directFilesParentPath: String?
  @Published var directFilesInspection: DirectFilesInspection?
  @Published var aggregateFocusLabel: String?

  @Published var isShowingScanSheet = false
  @Published var scanSheetPhase: ScanSheetPhase = .authorization
  @Published var scanProgress = ScanProgressSnapshot(message: "準備掃描…", stage: "準備掃描")
  @Published var lastScanTiming: ScanTimingSnapshot?
  @Published var isFullScanRunning = false

  @Published var isLoadingReport = false
  @Published var isLoadingTree = false
  @Published var isScanningCleanup = false
  @Published var isCleaning = false
  @Published var lastFinderVisibleTrashReceipts: [FinderVisibleTrashReceipt] = []
  @Published var statusMessage = "尚未載入掃描報告"
  @Published var reportStatusKind: ReportStatusKind = .empty
  @Published var errorMessage: String?

  let library: ReportLibrary
  private let reportPresentationIndexStore: ReportPresentationIndexStore
  private let cleanupIncrementalIndexStore: CleanupIncrementalIndexStore
  private let parser = ReportParser()
  private let capacityMonitor = CapacityMonitor()
  private var capacityTimer: Timer?
  private var terminationObserver: NSObjectProtocol?
  private var activationObserver: NSObjectProtocol?
  private var reportLoadGeneration = UUID()
  private var overviewLoadGeneration = UUID()
  private var treeLoadGeneration = UUID()
  private var directFilesGeneration = UUID()
  private var aggregateFocusParentPath: String?
  private var activeScanSession: ScanSession?
  private var terminalScanTimer: Timer?
  private var terminalReportsBefore = Set<String>()
  private var terminalScanDeadline: Date?
  private var terminalScanRequestedAt: Date?
  private var fullDiskAccessProbeGeneration = UUID()
  private var cleanupScanGeneration = UUID()
  private var cleanupCapabilityGeneration = UUID()
  private var cleanupIncrementalIndex: CleanupIncrementalIndex?
  private var knownReportPaths = Set<String>()

  init() {
    do {
      library = try ReportLibrary()
      reportPresentationIndexStore = try ReportPresentationIndexStore(
        directoryURL: library.reportIndexesURL
      )
      cleanupIncrementalIndexStore = try CleanupIncrementalIndexStore(
        directoryURL: library.cleanupIndexesURL
      )
    } catch {
      fatalError("無法建立 MacStorageLens 資料目錄：\(error)")
    }

    restoreCleanupPreferences()
    restoreSelectedScanTarget()
    restoreRecentScanTargets()
    if selectedScanTarget.kind != .system {
      rememberRecentScanTarget(selectedScanTarget)
    }
    try? library.pruneReportCacheKeepingLatestPerTarget(
      preservingTargets: [selectedScanTarget]
    )
    library.pruneReportIndexes()
    cleanupIncrementalIndexStore.prune()

    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.activeScanSession?.cancel(reason: "App 即將結束，正在取消本次掃描。")
      try? self.library.pruneReportCacheKeepingLatestPerTarget(
        preservingTargets: [self.selectedScanTarget, self.document?.summary.target].compactMap {
          $0
        }
      )
    }

    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.recoverLatestCompletedReportIfNeeded()
      self.refreshCleanupTargetCapabilities()
      if self.selectedScanTarget.kind == .system {
        self.refreshFullDiskAccessProbe()
      }
    }

    refreshReportHistory()
    restoreCleanupIncrementalIndexIfAvailable()
    if selectedScanTarget.kind == .system {
      refreshFullDiskAccessProbe()
    } else {
      appFullDiskAccessProbe = .notApplicableToSelectedLocation
    }
    refreshCleanupTargetCapabilities()
    refreshCapacity()
    startCapacityTimer()
    if library.latestReportURL() != nil {
      loadLatestReport()
    }
  }

  deinit {
    capacityTimer?.invalidate()
    terminalScanTimer?.invalidate()
    if let terminationObserver {
      NotificationCenter.default.removeObserver(terminationObserver)
    }
    if let activationObserver {
      NotificationCenter.default.removeObserver(activationObserver)
    }
  }

  var selectedCleanupBytes: Int64 {
    cleanupCandidates.filter(\.selected).reduce(0) { $0 + $1.bytes }
  }

  var selectedCleanupCandidates: [CleanupCandidate] {
    cleanupCandidates.filter(\.selected)
  }

  var cleanupMode: CleanupMode { CleanupMode.forTarget(selectedScanTarget) }

  var cleanupConfiguration: CleanupScanConfiguration {
    CleanupScanConfiguration(
      profile: cleanupProfile,
      customScopes: cleanupMode == .system
        ? cleanupCustomScopes
        : cleanupFolderCustomScopes,
      customMinimumBytes: Int64(cleanupCustomMinimumMiB) * 1_048_576,
      presetOptionalScopes: cleanupPresetOptionalScopes
    )
  }

  var availableCleanupScopes: [CleanupScope] {
    CleanupScope.cases(for: cleanupMode)
  }

  var availablePresetOptionalCleanupScopes: [CleanupScope] {
    cleanupMode == .system ? CleanupScope.presetOptionalCases : []
  }

  var enabledPresetOptionalCleanupScopeCount: Int {
    cleanupPresetOptionalScopes.intersection(Set(availablePresetOptionalCleanupScopes)).count
  }

  func isPresetOptionalCleanupScopeEnabled(_ scope: CleanupScope) -> Bool {
    cleanupPresetOptionalScopes.contains(scope)
  }

  var activeCustomCleanupScopes: Set<CleanupScope> {
    cleanupMode == .system ? cleanupCustomScopes : cleanupFolderCustomScopes
  }

  var hasActiveCustomCleanupScopes: Bool { !activeCustomCleanupScopes.isEmpty }

  var cleanupEffectiveMinimumBytes: Int64 {
    cleanupConfiguration.effectiveMinimumBytes(for: cleanupMode)
  }

  var cleanupReusableReportURL: URL? {
    cleanupReusableReportURL(for: selectedScanTarget)
  }

  var canReuseCleanupReport: Bool { cleanupReusableReportURL != nil }

  var cleanupReusableReportDescription: String {
    guard let url = cleanupReusableReportURL else {
      return "目前位置還沒有完整容量報告；請先完成儲存空間總覽掃描，或使用完整重新掃描。"
    }
    if let document, document.url.standardizedFileURL == url.standardizedFileURL {
      return "使用目前已載入的容量報告（\(document.summary.generatedAt)）；不再重新遞迴發現整棵資料樹。"
    }
    if let record = reportHistory.first(where: {
      $0.url.standardizedFileURL == url.standardizedFileURL
    }) {
      return "使用已保存的容量報告（\(record.generatedAt)）；候選命中仍會即時向檔案系統驗證。"
    }
    return "使用已保存的容量報告作為資料夾索引；候選命中仍會即時驗證。"
  }

  var cleanupFinderVisibleTrashAvailable: Bool {
    if cleanupMode == .system { return true }
    return cleanupTargetCapabilities?.supportsFinderVisibleTrash == true
  }

  var cleanupDirectDeletionAvailableForTarget: Bool {
    if cleanupMode == .system { return true }
    return cleanupTargetCapabilities?.supportsDirectDeletion == true
  }

  var cleanupFinderTrashHelp: String {
    if cleanupMode == .system {
      return "只使用 Finder 的系統垃圾桶語意。"
    }
    if let reason = cleanupTargetCapabilities?.finderTrashUnavailableReason {
      return reason
    }
    if cleanupTargetCapabilities == nil {
      return "正在辨識目前掛載的檔案系統；確認可使用 Finder 垃圾桶前，此選項會維持停用。"
    }
    return "只使用 Finder 的系統垃圾桶語意。"
  }

  var cleanupTargetRemovalNotice: String? {
    if cleanupMode == .system { return nil }
    if let notice = cleanupTargetCapabilities?.cleanupNotice { return notice }
    if cleanupTargetCapabilities == nil {
      return "正在辨識目前目標的檔案系統與垃圾桶能力…"
    }
    return nil
  }

  var cleanupTargetIsRemote: Bool { cleanupTargetCapabilities?.isRemote == true }

  var cleanupTargetIsExternalStorage: Bool {
    cleanupTargetCapabilities?.isExternalStorage == true
  }

  var cleanupPrioritizesExternalAppleDouble: Bool {
    cleanupTargetCapabilities?.prioritizesExternalAppleDoubleCleanup == true
  }

  var cleanupTargetFilesystemDisplayName: String {
    cleanupTargetCapabilities?.filesystemDisplayName ?? "辨識中"
  }

  func refreshCleanupTargetCapabilities(for target: ScanTarget? = nil) {
    let target = target ?? selectedScanTarget
    let generation = UUID()
    cleanupCapabilityGeneration = generation
    cleanupTargetCapabilities =
      target.kind == .system
      ? CleanupTargetCapabilityResolver.resolve(target: target)
      : nil

    guard target.kind != .system else { return }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let capabilities = CleanupTargetCapabilityResolver.resolve(target: target)
      DispatchQueue.main.async {
        guard let self, self.cleanupCapabilityGeneration == generation,
          self.selectedScanTarget.reportRetentionKey == target.reportRetentionKey
        else { return }
        self.cleanupTargetCapabilities = capabilities
      }
    }
  }

  func selectCleanupScanSource(_ source: CleanupScanSource) {
    guard cleanupScanSource != source else { return }
    cleanupScanSource = source
    cleanupIncrementalIndex = nil
    cleanupIndexStatus = .empty
    restoreCleanupIncrementalIndexIfAvailable()
    applyCleanupIncrementalIndexToCurrentConfiguration(
      fallbackMessage: "安全清理掃描來源已改為「\(source.title)」。既有索引只會在來源與容量報告仍完全相符時重用。"
    )
  }

  func isCustomCleanupScopeEnabled(_ scope: CleanupScope) -> Bool {
    scope.mode == .system
      ? cleanupCustomScopes.contains(scope)
      : cleanupFolderCustomScopes.contains(scope)
  }

  var displayedScanTarget: ScanTarget? { document?.summary.target }

  var scanTargetMatchesDisplayedReport: Bool {
    guard let displayedScanTarget else { return false }
    return displayedScanTarget.reportRetentionKey == selectedScanTarget.reportRetentionKey
  }

  var scanActionTitle: String {
    scanTargetMatchesDisplayedReport ? "重新掃描" : "開始掃描"
  }

  var scanActionAccessibilityHint: String {
    if scanTargetMatchesDisplayedReport {
      return "重新掃描目前顯示的位置：\(selectedScanTarget.displayName)"
    }
    return "開始掃描新的位置：\(selectedScanTarget.displayName)；完成前保留目前畫面"
  }

  var selectedScanTargetStateTitle: String {
    reportHistory.contains { $0.targetKey == selectedScanTarget.reportRetentionKey }
      ? "已保存"
      : "尚未掃描"
  }

  var savedNonSystemTargetRecords: [ReportRecord] {
    reportHistory.filter { $0.target.kind != .system }
  }

  var pendingRecentScanTargets: [ScanTarget] {
    let savedKeys = Set(reportHistory.map(\.targetKey))
    return RecentScanTargetPolicy.pending(from: recentScanTargets, savedKeys: savedKeys)
  }

  var currentDirectFilesItem: SunburstItem? {
    sunburst?.children.first(where: { $0.kind == .directFiles })
  }

  var canGoUp: Bool {
    if aggregateFocusParentPath != nil { return true }
    guard let section = document?.section(containing: currentPath) else { return false }
    return currentPath != section.root
  }

  var isShowingAggregateFocus: Bool { aggregateFocusParentPath != nil }

  func refreshFullDiskAccessProbe() {
    let generation = UUID()
    fullDiskAccessProbeGeneration = generation
    appFullDiskAccessProbe = .checking
    FullDiskAccessProbe.inspectCurrentApp { [weak self] result in
      guard let self, self.fullDiskAccessProbeGeneration == generation else { return }
      self.appFullDiskAccessProbe = result
    }
  }

  func refreshReportHistory() {
    let preservedTargets = [selectedScanTarget, document?.summary.target].compactMap { $0 }
    do {
      try library.pruneReportCacheKeepingLatestPerTarget(
        preservingTargets: preservedTargets
      )
    } catch {
      errorMessage = "無法依掃描位置收斂報告快取：\(error.localizedDescription)"
    }
    reportHistory = library.reportRecords()
    knownReportPaths = Set(reportHistory.map { $0.url.standardizedFileURL.path })
    library.pruneReportIndexes()
    reconcileRecentScanTargetsWithReports()
  }

  func importReport(_ source: URL) {
    do {
      let destination = try library.importReport(from: source)
      resetLoadedReportState()
      refreshReportHistory()
      loadReport(destination)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func loadLatestReport() {
    refreshReportHistory()
    guard let latest = reportHistory.first?.url ?? library.latestReportURL() else {
      statusMessage = "尚無掃描報告；請先執行完整掃描或匯入既有報告。"
      reportStatusKind = .empty
      return
    }
    loadReport(latest)
  }

  func loadReport(
    _ url: URL,
    scanSession: ScanSession? = nil,
    workflowRequestedAt: Date? = nil,
    usedTerminalFallback: Bool = false
  ) {
    let generation = UUID()
    reportLoadGeneration = generation
    treeLoadGeneration = UUID()
    overviewLoadGeneration = UUID()
    isLoadingReport = true
    isLoadingTree = true
    statusMessage = "正在建立報告索引：\(url.lastPathComponent)"
    reportStatusKind = .loading

    let parseStartedAt = Date()
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let result = Result { () -> LoadedReportBundle in
        let indexReadStartedAt = Date()
        let cachedPayload = try? self.reportPresentationIndexStore.load(for: url)
        let indexReadFinishedAt = Date()
        let document: ReportDocument
        let presentationIndexSource: ReportPresentationIndexSource
        let reportIndexSeconds: TimeInterval
        var presentationIndexWriteSeconds: TimeInterval = 0
        if let cachedPayload {
          document = cachedPayload.document(for: url)
          presentationIndexSource = .persistentCache
          reportIndexSeconds = max(
            0,
            indexReadFinishedAt.timeIntervalSince(indexReadStartedAt)
          )
          DispatchQueue.main.async {
            guard self.reportLoadGeneration == generation else { return }
            self.statusMessage = "正在從本機容量索引還原畫面：\(url.lastPathComponent)"
          }
        } else {
          DispatchQueue.main.async {
            guard self.reportLoadGeneration == generation else { return }
            self.statusMessage = "正在解析報告並建立快速索引：\(url.lastPathComponent)"
          }
          let markdownParseStartedAt = Date()
          document = try self.parser.parse(url: url) { progress in
            DispatchQueue.main.async {
              guard self.reportLoadGeneration == generation else { return }
              let percent = Int((progress.fraction * 100).rounded())
              self.statusMessage =
                "\(progress.stage) \(percent)%：\(url.lastPathComponent)"
              if scanSession != nil || workflowRequestedAt != nil {
                self.scanProgress = ScanProgressSnapshot(
                  message: "\(progress.stage)…",
                  detail: "單次遍歷會同時建立區段索引與第一個四層容量地圖，不再重讀大型 Markdown。",
                  fraction: 0.98 + progress.fraction * 0.013,
                  stage: "建立報告索引",
                  elapsedSeconds: Int(Date().timeIntervalSince(parseStartedAt).rounded()),
                  health: .active,
                  isEstimated: true
                )
              }
            }
          }
          reportIndexSeconds = max(0, Date().timeIntervalSince(markdownParseStartedAt))
          guard document.summary.reportComplete else {
            throw ReportParserError.invalidReport("報告尚未完成；請等待掃描顯示完成後再載入")
          }
          let indexWriteStartedAt = Date()
          _ = try? self.reportPresentationIndexStore.save(document: document, for: url)
          presentationIndexWriteSeconds = max(
            0,
            Date().timeIntervalSince(indexWriteStartedAt)
          )
          presentationIndexSource = .markdownSinglePass
        }
        guard document.summary.reportComplete else {
          throw ReportParserError.invalidReport("報告尚未完成；請等待掃描顯示完成後再載入")
        }
        let currentPath =
          document.sections[document.summary.targetPath] != nil
          ? document.summary.targetPath
          : (document.sections["/System/Volumes/Data"] != nil
            ? "/System/Volumes/Data"
            : (document.sections.keys.sorted().first ?? "/"))

        // The old workflow streamed the same root section twice: once for the
        // overview chart and once for the file-tree page. Build both initial views
        // from one presentation so large reports do not pay duplicate I/O before
        // the scan sheet can truthfully say the result is ready.
        DispatchQueue.main.async {
          guard self.reportLoadGeneration == generation else { return }
          self.statusMessage = "正在套用容量地形地圖：\(url.lastPathComponent)"
          if scanSession != nil || workflowRequestedAt != nil {
            self.scanProgress = ScanProgressSnapshot(
              message: "報告索引已完成，正在核對容量帳務並套用地圖…",
              detail: "這一步只組裝總覽與資料樹，不會再次遍歷完整 Markdown。",
              fraction: 0.994,
              stage: "套用容量地圖",
              elapsedSeconds: Int(Date().timeIntervalSince(parseStartedAt).rounded()),
              health: .active,
              isEstimated: true
            )
          }
        }
        let presentationStartedAt = Date()
        let presentation = try self.parser.loadPresentation(
          document: document,
          parentPath: currentPath,
          maximumDepth: SunburstPresentationPolicy.maximumDepth,
          maximumChildren: SunburstPresentationPolicy.visibleChildBudgetWhenAggregated
        )
        var treeChart = presentation.1
        if currentPath == document.summary.targetPath {
          treeChart = CapacityMapBuilder.reconcileTargetTree(
            summary: document.summary,
            presentation: treeChart
          )
        }
        let overviewChart = CapacityMapBuilder.buildOverview(
          summary: document.summary,
          presentation: presentation.1,
          targetPath: currentPath
        )
        let readyAt = Date()
        return LoadedReportBundle(
          document: document,
          currentPath: currentPath,
          children: presentation.0,
          sunburst: treeChart,
          overviewSunburst: overviewChart,
          parseSeconds: reportIndexSeconds,
          initialViewBuildSeconds: max(0, readyAt.timeIntervalSince(presentationStartedAt)),
          presentationIndexSource: presentationIndexSource,
          presentationIndexWriteSeconds: presentationIndexWriteSeconds
        )
      }

      DispatchQueue.main.async {
        guard self.reportLoadGeneration == generation else { return }
        self.isLoadingReport = false
        self.isLoadingTree = false
        switch result {
        case .success(let bundle):
          self.document = bundle.document
          self.currentPath = bundle.currentPath
          self.children = bundle.children
          self.sunburst = bundle.sunburst
          self.overviewSunburst = bundle.overviewSunburst
          self.statusMessage =
            "已載入 \(url.lastPathComponent) · \(bundle.presentationIndexSource.compactTitle)"
          self.reportStatusKind = .ready
          if bundle.document.summary.target.reportRetentionKey
            == self.selectedScanTarget.reportRetentionKey
          {
            self.refreshCleanupIncrementalIndexContext()
            self.applyCleanupIncrementalIndexToCurrentConfiguration(
              fallbackMessage: "容量報告已更新；舊報告綁定的清理索引不會沿用到新快照。"
            )
          }
          self.refreshCapacity()
          let appliedAt = Date()

          if let scanSession {
            let timing = scanSession.makeTimingSnapshot(
              reportURL: url,
              summary: bundle.document.summary,
              reportParseSeconds: bundle.parseSeconds,
              initialViewBuildSeconds: bundle.initialViewBuildSeconds,
              presentationIndexSource: bundle.presentationIndexSource,
              presentationIndexWriteSeconds: bundle.presentationIndexWriteSeconds,
              readyAt: appliedAt
            )
            self.lastScanTiming = timing
            scanSession.recordPostProcessing(timing)
            if self.activeScanSession === scanSession { self.activeScanSession = nil }
            self.scanSheetPhase = .completed(url)
            self.scanProgress = ScanProgressSnapshot(
              message: "掃描、報告解析與容量地圖已完成。",
              detail: "端到端耗時 \(self.formattedTimingDuration(timing.requestToReadySeconds))。",
              fraction: 1,
              stage: "完成",
              elapsedSeconds: Int(timing.requestToReadySeconds.rounded()),
              health: .active,
              isEstimated: false
            )
          } else if let workflowRequestedAt {
            let scannerCompletedAt = self.reportModificationDate(url)
            let timing = ScanTimingSnapshot(
              target: bundle.document.summary.target,
              reportURL: url,
              diagnosticDirectoryURL: nil,
              requestedAt: workflowRequestedAt,
              scannerCompletedAt: scannerCompletedAt,
              readyAt: appliedAt,
              targetResolutionSeconds: nil,
              scannerInstallationSeconds: nil,
              permissionProbeSeconds: nil,
              sessionPreparationSeconds: nil,
              launchToScannerStartSeconds: nil,
              requestToScannerCompletionSeconds: max(
                0,
                scannerCompletedAt.timeIntervalSince(workflowRequestedAt)
              ),
              scannerPreflightSeconds: bundle.document.summary.preflightDurationSeconds,
              scannerPrepareSeconds: bundle.document.summary.prepareDurationSeconds,
              scannerPathSeconds: bundle.document.summary.pathScanDurationSeconds,
              scannerMetadataSeconds: bundle.document.summary.metadataDurationSeconds,
              scannerReportWriteSeconds: bundle.document.summary.reportWriteDurationSeconds,
              scannerTotalSeconds: bundle.document.summary.totalDurationSeconds,
              reportParseSeconds: bundle.parseSeconds,
              initialViewBuildSeconds: bundle.initialViewBuildSeconds,
              presentationIndexSource: bundle.presentationIndexSource,
              presentationIndexWriteSeconds: bundle.presentationIndexWriteSeconds,
              usedTerminalFallback: usedTerminalFallback
            )
            self.lastScanTiming = timing
            self.terminalScanRequestedAt = nil
            self.scanSheetPhase = .completed(url)
            self.scanProgress = ScanProgressSnapshot(
              message: "掃描、報告解析與容量地圖已完成。",
              detail: "端到端耗時 \(self.formattedTimingDuration(timing.requestToReadySeconds))。",
              fraction: 1,
              stage: "完成",
              elapsedSeconds: Int(timing.requestToReadySeconds.rounded()),
              health: .active,
              isEstimated: false
            )
          }
        case .failure(let error):
          self.errorMessage = error.localizedDescription
          self.statusMessage = "報告載入失敗：\(error.localizedDescription)"
          self.reportStatusKind = .failed
          if let scanSession {
            if self.activeScanSession === scanSession { self.activeScanSession = nil }
            self.scanSheetPhase = .failed(
              "掃描器已產生報告，但 App 無法完成解析或容量地圖：\(error.localizedDescription)"
            )
          } else if workflowRequestedAt != nil {
            self.terminalScanRequestedAt = nil
            self.scanSheetPhase = .failed(
              "Terminal 已產生報告，但 App 無法完成解析或容量地圖：\(error.localizedDescription)"
            )
          }
        }
      }
    }
  }

  func loadPath(_ path: String) {
    guard let document else { return }
    clearAggregateFocus()
    let generation = UUID()
    treeLoadGeneration = generation
    isLoadingTree = true
    currentPath = path
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let result = Result {
        let presentation = try self.parser.loadPresentation(
          document: document,
          parentPath: path,
          maximumDepth: SunburstPresentationPolicy.maximumDepth,
          maximumChildren: SunburstPresentationPolicy.visibleChildBudgetWhenAggregated
        )
        let children = presentation.0
        var chart = presentation.1
        if path == document.summary.targetPath {
          chart = CapacityMapBuilder.reconcileTargetTree(
            summary: document.summary,
            presentation: chart
          )
        }
        return (children, chart)
      }
      DispatchQueue.main.async {
        guard self.treeLoadGeneration == generation else { return }
        self.isLoadingTree = false
        switch result {
        case .success(let value):
          self.children = value.0
          self.sunburst = value.1
        case .failure(let error):
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }

  func goUp() {
    guard canGoUp else { return }
    if let aggregateParent = aggregateFocusParentPath {
      loadPath(aggregateParent)
      return
    }
    let parent = (currentPath as NSString).deletingLastPathComponent
    loadPath(parent.isEmpty ? "/" : parent)
  }

  func reloadDisplayedReport() {
    if let url = document?.url {
      loadReport(url)
    } else {
      loadLatestReport()
    }
  }

  func displayReport(_ record: ReportRecord) {
    loadReport(record.url)
    destination = .overview
  }

  var displayedReportRecord: ReportRecord? {
    guard let url = document?.url.standardizedFileURL else { return nil }
    return reportHistory.first { $0.url.standardizedFileURL == url }
  }

  func runFullScan() {
    guard !isScanningCleanup, !isCleaning, !isLoadingReport else {
      statusMessage = "另一個磁碟工作或報告解析仍在進行；完成後再啟動容量掃描，避免同時讀取同一個磁碟。"
      return
    }
    if selectedScanTarget.kind == .system {
      refreshFullDiskAccessProbe()
    } else {
      appFullDiskAccessProbe = .notApplicableToSelectedLocation
    }
    if isFullScanRunning {
      scanSheetPhase = .running
      isShowingScanSheet = true
      return
    }
    scanProgress = ScanProgressSnapshot(message: "準備掃描…", stage: "準備掃描")
    scanSheetPhase = .authorization
    isShowingScanSheet = true
  }

  func startIntegratedScan(mode: ScanPrivilegeMode) {
    guard !isFullScanRunning, !isLoadingReport, !isScanningCleanup, !isCleaning else {
      statusMessage = "另一個磁碟工作仍在執行；目前不會同時啟動容量掃描。"
      return
    }
    lastScanTiming = nil
    isFullScanRunning = true
    scanSheetPhase = .running
    scanProgress = ScanProgressSnapshot(
      message: mode == .administrator
        ? "正在以 App 權限準備受保護資料覆蓋…"
        : "正在以 MacStorageLens App 權限啟動唯讀掃描…",
      detail: mode == .administrator
        ? "完成 App-owned TCC 掃描後，才會顯示 macOS 管理員授權對話框。"
        : "此通道由 App 直接啟動，會使用 MacStorageLens 自己的完整磁碟存取權。",
      stage: mode == .administrator ? "App 權限預掃描" : "啟動掃描器",
      health: .active
    )
    statusMessage = "完整掃描正在背景執行；完成後會自動載入。"
    reportStatusKind = .scanning

    do {
      let sessionBox = ScanSessionBox()
      let session = try ScannerLauncher(library: library).startIntegratedScan(
        mode: mode,
        target: selectedScanTarget,
        onProgress: { [weak self] progress in
          guard let self else { return }
          self.scanProgress = progress
          self.statusMessage = progress.message
          self.reportStatusKind = .scanning
        },
        completion: { [weak self, weak sessionBox] result in
          guard let self else { return }
          let completedSession = sessionBox?.value ?? self.activeScanSession
          self.isFullScanRunning = false
          switch result {
          case .success(let report):
            self.refreshReportHistory()
            self.scanProgress = ScanProgressSnapshot(
              message: "掃描器已完成，正在解析報告並建立容量地圖…",
              detail: "完成畫面後會列出 Scanner 與 App 各階段耗時。",
              fraction: 0.99,
              stage: "解析與建立畫面",
              health: .active,
              isEstimated: true
            )
            self.scanSheetPhase = .running
            self.statusMessage = "掃描器已完成；正在解析 \(report.lastPathComponent)"
            self.reportStatusKind = .loading
            self.loadReport(report, scanSession: completedSession)
            if self.selectedScanTarget.kind == .system {
              self.refreshFullDiskAccessProbe()
            } else {
              self.appFullDiskAccessProbe = .notApplicableToSelectedLocation
            }
          case .failure(let error):
            if let completedSession, self.activeScanSession === completedSession {
              self.activeScanSession = nil
            }
            if case ScannerLauncherError.scanCancelled(let message) = error {
              self.scanSheetPhase = .cancelled(message)
              self.statusMessage = "完整掃描已取消；上一份完成報告仍保留。"
              self.reportStatusKind = .cancelled
            } else if case ScannerLauncherError.authorizationCancelled = error {
              self.scanSheetPhase = .cancelled(error.localizedDescription)
              self.statusMessage = "管理員授權已取消；磁碟內容沒有被修改。"
              self.reportStatusKind = .cancelled
            } else {
              self.scanSheetPhase = .failed(error.localizedDescription)
              self.statusMessage = "完整掃描未完成：\(error.localizedDescription)"
              self.reportStatusKind = .failed
            }
          }
        }
      )
      sessionBox.value = session
      activeScanSession = session
      adoptResolvedScanTarget(session.target)
    } catch {
      activeScanSession = nil
      isFullScanRunning = false
      scanSheetPhase = .failed(error.localizedDescription)
      statusMessage = "無法啟動完整掃描：\(error.localizedDescription)"
      reportStatusKind = .failed
    }
  }

  func cancelFullScan() {
    guard isFullScanRunning else { return }
    guard let activeScanSession else {
      errorMessage = "目前是 Terminal 相容模式。請在 Terminal 視窗按 Control-C 取消掃描。"
      return
    }
    scanProgress = ScanProgressSnapshot(
      message: "正在安全取消掃描…",
      detail: "等待目前的唯讀系統呼叫結束；本次未完成報告不會保留。",
      currentPath: scanProgress.currentPath,
      fraction: scanProgress.fraction,
      stage: "正在取消",
      currentStep: scanProgress.currentStep,
      totalSteps: scanProgress.totalSteps,
      elapsedSeconds: scanProgress.elapsedSeconds,
      estimatedRemainingSeconds: nil,
      secondsSinceUpdate: 0,
      nodeCount: scanProgress.nodeCount,
      errorCount: scanProgress.errorCount,
      health: .cancelling,
      recentMessages: Array((scanProgress.recentMessages + ["已提出取消要求。"]).suffix(7)),
      isEstimated: true
    )
    statusMessage = "正在安全取消完整掃描…"
    reportStatusKind = .scanning
    activeScanSession.cancel()
  }

  func dismissScanSheet() {
    isShowingScanSheet = false
  }

  func openScanDiagnosticsFolder() {
    NSWorkspace.shared.open(library.scanWorkURL)
  }

  func runFullScanInTerminal() {
    guard !isFullScanRunning, !isLoadingReport, !isScanningCleanup, !isCleaning else {
      statusMessage = "另一個磁碟工作仍在執行；目前不會同時啟動 Terminal 容量掃描。"
      return
    }
    do {
      lastScanTiming = nil
      terminalScanRequestedAt = Date()
      terminalReportsBefore = Set(library.scanReportURLs().map { $0.standardizedFileURL.path })
      terminalScanDeadline = Date().addingTimeInterval(30 * 60)
      let resolvedTarget = try ScannerLauncher(library: library).launchInTerminal(
        target: selectedScanTarget)
      adoptResolvedScanTarget(resolvedTarget)
      scanSheetPhase = .running
      scanProgress = ScanProgressSnapshot(
        message: "Terminal 相容模式已啟動；完成後 App 仍會自動偵測報告。",
        detail: "此模式使用 Terminal 自己的完整磁碟存取權；MacStorageLens 的授權不會自動套用到 Terminal。",
        stage: "Terminal 相容模式"
      )
      isShowingScanSheet = true
      isFullScanRunning = true
      startTerminalReportWatcher()
      statusMessage = "Terminal 相容模式掃描中；完成後會自動載入。"
      reportStatusKind = .scanning
    } catch {
      terminalScanRequestedAt = nil
      isFullScanRunning = false
      scanSheetPhase = .failed(error.localizedDescription)
      statusMessage = "Terminal 相容模式無法啟動：\(error.localizedDescription)"
      reportStatusKind = .failed
    }
  }

  func selectScanTarget(_ target: ScanTarget) {
    let previousKey = selectedScanTarget.reportRetentionKey
    selectedScanTarget = target
    persistSelectedScanTarget()
    if target.kind == .system {
      refreshFullDiskAccessProbe()
    } else {
      appFullDiskAccessProbe = .notApplicableToSelectedLocation
    }
    if target.kind != .system {
      rememberRecentScanTarget(target)
    }
    switch target.kind {
    case .system:
      statusMessage = "下次掃描位置：Macintosh HD 系統儲存空間"
    case .volume:
      statusMessage = "下次掃描位置：磁碟「\(target.displayName)」"
    case .folder:
      statusMessage = "下次掃描位置：資料夾「\(target.displayName)」"
    }
    if previousKey != target.reportRetentionKey {
      cleanupScanGeneration = UUID()
      isScanningCleanup = false
      cleanupIncrementalIndex = nil
      cleanupIndexStatus = .empty
      restoreCleanupIncrementalIndexIfAvailable()
      applyCleanupIncrementalIndexToCurrentConfiguration(
        fallbackMessage: target.kind == .system
          ? "清理目標已切回 Macintosh HD；目前沒有可重用的系統清理索引。"
          : "清理目標已切換為「\(target.displayName)」；若這個位置已有同一份容量報告建立的清理索引，會直接恢復使用。"
      )
    }
    refreshCleanupTargetCapabilities(for: target)
    refreshCapacityWhenNoReportIsDisplayed()
  }

  func useSystemScanTarget() {
    selectScanTarget(.systemStorage)
  }

  func useDisplayedLocationAsScanTarget() {
    guard let target = document?.summary.target else { return }
    selectScanTarget(target)
    statusMessage = "下次掃描位置已設為目前顯示的「\(target.displayName)」"
  }

  func chooseVolumeScanTarget() {
    guard let target = ScanTargetPicker.chooseVolume() else { return }
    selectScanTarget(target)
  }

  func chooseFolderScanTarget() {
    guard let target = ScanTargetPicker.chooseFolder() else { return }
    selectScanTarget(target)
  }

  func selectSunburstItem(_ item: SunburstItem, navigateToBrowser: Bool) {
    if item.kind == .directFiles, let parentPath = item.path {
      inspectDirectFiles(parentPath: parentPath, expectedBytes: item.bytes)
      return
    }
    if item.kind == .otherChildren, let parentPath = item.path {
      expandAggregatedChildren(
        parentPath: parentPath,
        label: item.label,
        expectedBytes: item.bytes,
        navigateToBrowser: navigateToBrowser
      )
      return
    }
    guard item.isNavigable, let path = item.path else { return }
    if navigateToBrowser { destination = .browser }
    loadPath(path)
  }

  private func expandAggregatedChildren(
    parentPath: String,
    label: String,
    expectedBytes: Int64,
    navigateToBrowser: Bool
  ) {
    guard let document else { return }
    let generation = UUID()
    treeLoadGeneration = generation
    isLoadingTree = true
    if navigateToBrowser { destination = .browser }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let result = Result { () -> ([StorageNode], SunburstItem) in
        let allChildren = try self.parser.loadChildren(document: document, parentPath: parentPath)
        let visibleCount = SunburstPresentationPolicy.visibleChildCount(
          childCount: allChildren.count,
          budget: SunburstPresentationPolicy.visibleChildBudgetWhenAggregated
        )
        guard visibleCount < allChildren.count else {
          throw ReportParserError.invalidReport("合併節點已不需要展開；請重新載入目前報告")
        }
        let omitted = Array(allChildren.dropFirst(visibleCount))
        let members = omitted.map { node in
          SunburstItem(
            id: node.path,
            label: node.name,
            path: node.path,
            bytes: node.allocatedBytes,
            kind: nil,
            children: []
          )
        }
        let representedBytes = members.reduce(Int64(0)) { $0 + $1.bytes }
        let root = SunburstItem(
          id: parentPath + "#other-expanded",
          label: label,
          path: parentPath,
          bytes: max(expectedBytes, representedBytes),
          kind: .otherChildren,
          children: members
        )
        return (omitted, root)
      }
      DispatchQueue.main.async {
        guard self.treeLoadGeneration == generation else { return }
        self.isLoadingTree = false
        switch result {
        case .success(let value):
          self.aggregateFocusParentPath = parentPath
          self.aggregateFocusLabel = label
          self.currentPath = parentPath
          self.children = value.0
          self.sunburst = value.1
          self.statusMessage = "已展開 \(label)；點擊任一項可繼續深入。"
        case .failure(let error):
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func clearAggregateFocus() {
    aggregateFocusParentPath = nil
    aggregateFocusLabel = nil
  }

  func inspectDirectFiles(parentPath: String, expectedBytes: Int64) {
    let generation = UUID()
    directFilesGeneration = generation
    directFilesParentPath = parentPath
    directFilesInspection = nil
    isInspectingDirectFiles = true
    isShowingDirectFilesInspector = true

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let result = self.readDirectFiles(parentPath: parentPath, expectedBytes: expectedBytes)
      DispatchQueue.main.async {
        guard self.directFilesGeneration == generation else { return }
        self.isInspectingDirectFiles = false
        self.directFilesInspection = result
      }
    }
  }

  private func readDirectFiles(parentPath: String, expectedBytes: Int64) -> DirectFilesInspection {
    let fileManager = FileManager.default
    let parentURL = URL(fileURLWithPath: parentPath, isDirectory: true)
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
    ]

    do {
      let urls = try fileManager.contentsOfDirectory(
        at: parentURL,
        includingPropertiesForKeys: Array(keys),
        options: []
      )
      var entries: [DirectFileEntry] = []
      entries.reserveCapacity(urls.count)
      for url in urls {
        let values = try url.resourceValues(forKeys: keys)
        if values.isDirectory == true, values.isSymbolicLink != true { continue }
        let logical = Int64(values.fileSize ?? 0)
        let allocated = Int64(
          values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        entries.append(
          DirectFileEntry(
            url: url,
            logicalBytes: max(0, logical),
            allocatedBytes: max(0, allocated),
            modifiedAt: values.contentModificationDate,
            isSymbolicLink: values.isSymbolicLink == true
          )
        )
      }
      entries.sort {
        if $0.allocatedBytes == $1.allocatedBytes {
          return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return $0.allocatedBytes > $1.allocatedBytes
      }
      return DirectFilesInspection(
        parentPath: parentPath, expectedAllocatedBytes: expectedBytes, entries: entries,
        scannedAt: Date(), errorMessage: nil)
    } catch {
      return DirectFilesInspection(
        parentPath: parentPath, expectedAllocatedBytes: expectedBytes, entries: [],
        scannedAt: Date(), errorMessage: error.localizedDescription)
    }
  }

  private func startTerminalReportWatcher() {
    terminalScanTimer?.invalidate()
    terminalScanTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
      [weak self] timer in
      guard let self else {
        timer.invalidate()
        return
      }
      let candidates = self.library.scanReportURLs()
        .filter { !self.terminalReportsBefore.contains($0.standardizedFileURL.path) }
        .sorted { self.reportModificationDate($0) > self.reportModificationDate($1) }
      if let report = candidates.first(where: self.reportLooksComplete) {
        timer.invalidate()
        self.terminalScanTimer = nil
        self.terminalScanDeadline = nil
        self.isFullScanRunning = false
        try? self.library.keepLatestReportForLocation(report)
        self.refreshReportHistory()
        let requestedAt = self.terminalScanRequestedAt ?? Date()
        self.scanSheetPhase = .running
        self.scanProgress = ScanProgressSnapshot(
          message: "Terminal 掃描器已完成，正在解析報告並建立容量地圖…",
          detail: "完成畫面後會列出 Scanner 與 App 各階段耗時。",
          fraction: 0.99,
          stage: "解析與建立畫面",
          health: .active,
          isEstimated: true
        )
        self.statusMessage = "Terminal 掃描器已完成；正在解析 \(report.lastPathComponent)"
        self.reportStatusKind = .loading
        self.loadReport(
          report,
          workflowRequestedAt: requestedAt,
          usedTerminalFallback: true
        )
        return
      }

      if let deadline = self.terminalScanDeadline, Date() > deadline {
        timer.invalidate()
        self.terminalScanTimer = nil
        self.terminalScanDeadline = nil
        self.terminalScanRequestedAt = nil
        self.isFullScanRunning = false
        self.scanSheetPhase = .failed("Terminal 相容模式在 30 分鐘內沒有產生完成報告。")
        self.statusMessage = "Terminal 相容模式未在期限內完成。"
        self.reportStatusKind = .failed
      }
    }
  }

  private func formattedTimingDuration(_ seconds: TimeInterval) -> String {
    let safe = max(0, seconds)
    if safe < 10 { return String(format: "%.2f 秒", safe) }
    if safe < 60 { return String(format: "%.1f 秒", safe) }
    let wholeSeconds = Int(safe.rounded())
    let hours = wholeSeconds / 3600
    let minutes = (wholeSeconds % 3600) / 60
    let remaining = wholeSeconds % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remaining) }
    return String(format: "%d:%02d", minutes, remaining)
  }

  private func reportModificationDate(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate ?? .distantPast
  }

  private func reportLooksComplete(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    do {
      let size = try handle.seekToEnd()
      try handle.seek(toOffset: size > 131_072 ? size - 131_072 : 0)
      let data = try handle.readToEnd() ?? Data()
      let text = String(decoding: data, as: UTF8.self)
      return text.contains("\nreport_complete=true\n") || text.hasSuffix("report_complete=true\n")
    } catch {
      return false
    }
  }

  private func recoverLatestCompletedReportIfNeeded() {
    guard !isFullScanRunning, !isLoadingReport else { return }
    do {
      try library.pruneReportCacheKeepingLatestPerTarget(
        preservingTargets: [selectedScanTarget, document?.summary.target].compactMap { $0 }
      )
    } catch {
      errorMessage = "無法依掃描位置收斂新完成報告：\(error.localizedDescription)"
    }
    let records = library.reportRecords()
    let newRecords = records.filter { !knownReportPaths.contains($0.url.standardizedFileURL.path) }
    reportHistory = records
    knownReportPaths = Set(records.map { $0.url.standardizedFileURL.path })
    reconcileRecentScanTargetsWithReports()

    guard !newRecords.isEmpty else { return }
    let latest = newRecords.max { $0.modifiedAt < $1.modifiedAt }!
    statusMessage = "偵測到「\(latest.target.displayName)」的新完成報告，正在自動載入。"
    reportStatusKind = .loading
    loadReport(latest.url)
  }

  private func refreshCapacityWhenNoReportIsDisplayed() {
    if document == nil { refreshCapacity() }
  }

  func refreshCapacity() {
    // Keep the live capacity card aligned with the report currently on screen.
    // Choosing a new target changes the next scan, but must not mix that volume's
    // live capacity with an older report and chart.
    let capacityPath = document?.summary.targetPath ?? selectedScanTarget.path
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      let result = Result { try self.capacityMonitor.read(volumeContainingPath: capacityPath) }
      DispatchQueue.main.async {
        if case .success(let capacity) = result {
          self.liveCapacity = capacity
        }
      }
    }
  }

  var cleanupHasReusableIndex: Bool {
    cleanupIndexStatus.available
  }

  var cleanupScanActionTitle: String {
    cleanupHasReusableIndex ? "補充掃描" : "開始掃描"
  }

  var cleanupSupplementalScanDetail: String {
    guard let index = cleanupIncrementalIndex else {
      return "建立目前等級的第一份清理索引。"
    }
    let missing = index.missingScopes(
      for: cleanupConfiguration,
      prioritizingExternalAppleDouble: cleanupPrioritizesExternalAppleDouble
    )
    if !missing.isEmpty {
      return "只補掃目前等級新增的 \(missing.count) 個規則範圍，不重做已覆蓋規則。"
    }
    if !index.dirtyDirectoryPaths.isEmpty {
      return "只刷新清理後變更的 \(index.dirtyDirectoryPaths.count) 個資料夾，不重新走完整目標。"
    }
    return "目前索引已覆蓋此等級；補充掃描會直接重用索引，不重新讀取磁碟。"
  }

  var cleanupFullRescanDetail: String {
    "不合併舊候選，重新掃描目前等級的全部規則並建立新索引；新掃描成功後才替換舊索引。"
  }

  var cleanupIndexDescription: String? {
    guard let index = cleanupIncrementalIndex else { return nil }
    let missing = index.missingScopes(
      for: cleanupConfiguration,
      prioritizingExternalAppleDouble: cleanupPrioritizesExternalAppleDouble
    )
    let covered = index.coveredScopes.count
    let persisted = index.scanSource == .existingStorageReport ? "已保存到本機" : "僅本次 App 工作階段"
    if !missing.isEmpty {
      return
        "清理索引已覆蓋 \(covered) 個規則範圍（\(persisted)）；目前等級還有 \(missing.count) 個新範圍未掃描。可選『補充掃描』只處理新增範圍，也可選『完整重新掃描』從零重建目前等級。"
    }
    if !index.dirtyDirectoryPaths.isEmpty {
      return
        "清理索引已覆蓋目前等級；清理後有 \(index.dirtyDirectoryPaths.count) 個受影響資料夾待刷新。可用『補充掃描』只重查這些位置，或用『完整重新掃描』從頭建立新索引。"
    }
    return "目前等級可直接重用清理索引的 \(covered) 個規則範圍（\(persisted)）。仍可隨時選擇『完整重新掃描』重新驗證全部規則。"
  }

  func selectCleanupProfile(_ profile: CleanupProfile) {
    guard cleanupProfile != profile else { return }
    cleanupProfile = profile
    persistCleanupPreferences()
    applyCleanupIncrementalIndexToCurrentConfiguration(
      fallbackMessage: "已選擇「\(profile.rawValue)」。可用補充掃描只處理未覆蓋規則，也可完整重新掃描目前等級。"
    )
  }

  func setPresetOptionalCleanupScope(_ scope: CleanupScope, enabled: Bool) {
    guard scope.requiresExplicitPresetOptIn else { return }
    if enabled {
      cleanupPresetOptionalScopes.insert(scope)
    } else {
      cleanupPresetOptionalScopes.remove(scope)
    }
    persistCleanupPreferences()
    if cleanupProfile == .ultraAggressive {
      applyCleanupIncrementalIndexToCurrentConfiguration(
        fallbackMessage:
          "超激進附加項目已變更；既有索引仍保留。可補充掃描新增範圍，也可完整重新掃描。"
      )
    }
  }

  func setCustomCleanupScope(_ scope: CleanupScope, enabled: Bool) {
    if scope.mode == .system {
      if enabled {
        cleanupCustomScopes.insert(scope)
      } else {
        cleanupCustomScopes.remove(scope)
      }
    } else {
      if enabled {
        cleanupFolderCustomScopes.insert(scope)
      } else {
        cleanupFolderCustomScopes.remove(scope)
      }
    }
    persistCleanupPreferences()
    if cleanupProfile == .custom {
      applyCleanupIncrementalIndexToCurrentConfiguration(
        fallbackMessage: "自定義範圍已變更；既有索引仍保留。可補充掃描新增範圍，也可完整重新掃描。"
      )
    }
  }

  func setCustomCleanupMinimumMiB(_ value: Int) {
    cleanupCustomMinimumMiB = Self.clampCleanupMinimumMiB(value)
    persistCleanupPreferences()
    if cleanupProfile == .custom {
      // The index always stores unthresholded candidates for covered scopes, so
      // changing only the display threshold never needs new disk I/O.
      applyCleanupIncrementalIndexToCurrentConfiguration(
        fallbackMessage: "自定義容量門檻已變更；已掃描索引會直接重新篩選。若要重新驗證全部規則，仍可選完整重新掃描。"
      )
    }
  }

  func scanCleanupCandidates() {
    scanCleanupCandidates(rebuildFromScratch: false)
  }

  func rescanCleanupCandidatesFully() {
    scanCleanupCandidates(rebuildFromScratch: true)
  }

  private func scanCleanupCandidates(rebuildFromScratch: Bool) {
    guard !isFullScanRunning, !isLoadingReport else {
      cleanupScanProgress = CleanupScanProgress(
        message: "容量掃描或報告解析正在執行；為避免同時讀取同一個磁碟，清理候選掃描尚未啟動。",
        currentPath: nil,
        currentStep: 0,
        totalSteps: 1
      )
      return
    }
    guard !isScanningCleanup, !isCleaning else { return }
    let configuration = cleanupConfiguration
    guard let target = ScanTargetResolver.resolveMountedTarget(selectedScanTarget) else {
      cleanupScanProgress = CleanupScanProgress(
        message: "找不到已掛載的「\(selectedScanTarget.displayName)」；請重新插入磁碟或重新選擇位置。",
        currentPath: selectedScanTarget.path,
        currentStep: 0,
        totalSteps: 1
      )
      return
    }
    adoptResolvedScanTarget(target)
    refreshCleanupTargetCapabilities(for: target)
    let targetCapabilities =
      cleanupTargetCapabilities ?? CleanupTargetCapabilityResolver.resolve(target: target)
    cleanupTargetCapabilities = targetCapabilities
    let mode = CleanupMode.forTarget(target)
    let scanSource: CleanupScanSource = mode == .system ? .liveFilesystem : cleanupScanSource
    let reportURL =
      scanSource == .existingStorageReport ? cleanupReusableReportURL(for: target) : nil
    if scanSource == .existingStorageReport, reportURL == nil {
      cleanupScanProgress = CleanupScanProgress(
        message: "目前位置沒有可重用的完整容量報告；請先完成容量掃描，或改用『重新掃描目標（完整）』。",
        currentPath: target.path,
        currentStep: 0,
        totalSteps: 1
      )
      return
    }

    let sourceReportSignature = reportURL.flatMap { try? ReportFileSignature.read(from: $0) }
    if cleanupIncrementalIndex?.isValid(
      for: target,
      scanSource: scanSource,
      sourceReportURL: reportURL,
      sourceReportSignature: sourceReportSignature
    ) != true {
      cleanupIncrementalIndex =
        cleanupIncrementalIndexStore.load(
          target: target,
          scanSource: scanSource,
          sourceReportURL: reportURL
        )
        ?? CleanupIncrementalIndex(
          target: target,
          scanSource: scanSource,
          sourceReportURL: reportURL,
          sourceReportSignature: sourceReportSignature
        )
    }
    guard let reusableIndex = cleanupIncrementalIndex else { return }

    let previousIndex = reusableIndex
    var index = rebuildFromScratch ? reusableIndex.resettingDiscovery() : reusableIndex
    let missing = index.missingScopes(
      for: configuration,
      prioritizingExternalAppleDouble: targetCapabilities.prioritizesExternalAppleDoubleCleanup
    )
    let scopesToScan = expandedCleanupIndexScopes(missing, mode: mode)
    let dirtyDirectories =
      rebuildFromScratch ? [] : (mode == .generalLocation ? index.dirtyDirectoryPaths : [])

    if !rebuildFromScratch, scopesToScan.isEmpty, dirtyDirectories.isEmpty {
      cleanupIncrementalIndex = index
      updateCleanupIndexStatus()
      applyCleanupIncrementalIndexToCurrentConfiguration(
        fallbackMessage: "目前等級已由既有清理索引完整覆蓋，不需要重新掃描。"
      )
      return
    }

    let currentDocument = document
    let generation = UUID()
    cleanupScanGeneration = generation
    isScanningCleanup = true
    if rebuildFromScratch {
      cleanupIncrementalIndex = nil
      updateCleanupIndexStatus()
    }
    cleanupCandidates = []
    cleanupLastResult = nil
    cleanupScanProgress = CleanupScanProgress(
      message: rebuildFromScratch
        ? "完整重新掃描目前等級的 \(scopesToScan.count) 個規則範圍"
        : scopesToScan.isEmpty
          ? "補充掃描：只刷新清理後受影響的 \(dirtyDirectories.count) 個資料夾"
          : "補充掃描：只處理 \(scopesToScan.count) 個尚未建立索引的規則範圍",
      currentPath: reportURL?.path ?? target.path,
      currentStep: 0,
      totalSteps: 1
    )

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let result = Result { () -> (CleanupIncrementalIndex, [String]) in
        var workingIndex = index
        var notices: [String] = []
        let engine = CleanupEngine(library: self.library)

        let reusableDocument: ReportDocument?
        if !scopesToScan.isEmpty, let reportURL {
          if let currentDocument,
            currentDocument.url.standardizedFileURL == reportURL.standardizedFileURL
          {
            reusableDocument = currentDocument
          } else if let payload = try self.reportPresentationIndexStore.load(for: reportURL) {
            reusableDocument = payload.document(for: reportURL)
          } else {
            reusableDocument = try self.parser.parse(url: reportURL)
          }
        } else {
          reusableDocument = nil
        }

        if !scopesToScan.isEmpty {
          let deltaConfiguration = CleanupScanConfiguration.indexScan(scopes: scopesToScan)
          let deltaResult = try engine.scanCandidates(
            configuration: deltaConfiguration,
            target: target,
            scanSource: scanSource,
            reportDocument: reusableDocument,
            reportParser: scanSource == .existingStorageReport ? self.parser : nil
          ) { progress in
            DispatchQueue.main.async { [weak self] in
              guard let self, self.cleanupScanGeneration == generation else { return }
              self.cleanupScanProgress = CleanupScanProgress(
                message: rebuildFromScratch
                  ? "完整重新掃描 · \(progress.message)"
                  : "補充掃描 · \(progress.message)",
                currentPath: progress.currentPath,
                currentStep: progress.currentStep,
                totalSteps: max(1, progress.totalSteps)
              )
            }
          }
          workingIndex.merge(scanResult: deltaResult, coveredScopes: scopesToScan)
          notices.append(contentsOf: deltaResult.notices)
          notices.append("已新增索引覆蓋：\(scopesToScan.map(\.title).sorted().joined(separator: "、"))。")
        }

        if !dirtyDirectories.isEmpty {
          let refreshScopes = workingIndex.coveredScopes
          let refreshConfiguration = CleanupScanConfiguration.indexScan(scopes: refreshScopes)
          workingIndex.removeCandidatesInDirtyDirectories(dirtyDirectories)
          let refreshResult = try engine.refreshGeneralLocationDirectories(
            configuration: refreshConfiguration,
            target: target,
            directoryPaths: dirtyDirectories,
            scanSource: scanSource
          ) { progress in
            DispatchQueue.main.async { [weak self] in
              guard let self, self.cleanupScanGeneration == generation else { return }
              self.cleanupScanProgress = progress
            }
          }
          workingIndex.merge(scanResult: refreshResult, coveredScopes: [])
          workingIndex.clearDirtyDirectories(dirtyDirectories)
          notices.append(contentsOf: refreshResult.notices)
        }

        return (workingIndex, notices)
      }

      DispatchQueue.main.async {
        guard self.cleanupScanGeneration == generation else { return }
        self.isScanningCleanup = false
        switch result {
        case .success(let value):
          self.cleanupIncrementalIndex = value.0
          self.persistCleanupIncrementalIndexIfEligible()
          self.updateCleanupIndexStatus()
          self.applyCleanupIncrementalIndexToCurrentConfiguration(
            extraNotices: value.1,
            fallbackMessage: rebuildFromScratch
              ? "完整重新掃描完成；已建立新的清理索引。"
              : "補充掃描完成；增量清理索引已更新。"
          )
        case .failure(let error):
          if rebuildFromScratch {
            self.cleanupIncrementalIndex = previousIndex
            self.updateCleanupIndexStatus()
          }
          self.errorMessage = error.localizedDescription
          self.cleanupScanProgress = CleanupScanProgress(
            message: rebuildFromScratch
              ? "完整重新掃描失敗；舊索引仍保留，沒有被失敗結果覆寫。"
              : "補充掃描失敗；既有索引未被丟棄。",
            currentPath: nil,
            currentStep: 0,
            totalSteps: 1
          )
        }
      }
    }
  }

  func setCandidate(_ id: UUID, selected: Bool) {
    guard let index = cleanupCandidates.firstIndex(where: { $0.id == id }),
      cleanupCandidates[index].isSelectable
    else { return }
    cleanupCandidates[index].selected = selected
  }

  func setCandidates(in category: CleanupCategory, selected: Bool) {
    for index in cleanupCandidates.indices where cleanupCandidates[index].category == category {
      if selected {
        guard cleanupCandidates[index].isBulkSelectable else { continue }
        cleanupCandidates[index].selected = true
      } else if cleanupCandidates[index].isSelectable {
        cleanupCandidates[index].selected = false
      }
    }
  }

  func deselectAllCleanupCandidates() {
    for index in cleanupCandidates.indices { cleanupCandidates[index].selected = false }
  }

  func executeSelectedCleanup(removalMode: CleanupExecutionMode = .moveToTrash) {
    guard !isFullScanRunning, !isLoadingReport, !isScanningCleanup, !isCleaning else {
      statusMessage = "另一個磁碟工作仍在執行；目前不會同時啟動清理。"
      return
    }
    let selected = cleanupCandidates.filter(\.selected)
    guard !selected.isEmpty else { return }

    let target = cleanupLastResult?.target ?? selectedScanTarget
    let targetCapabilities = CleanupTargetCapabilityResolver.resolve(target: target)
    cleanupTargetCapabilities = targetCapabilities

    switch removalMode {
    case .moveToTrash:
      guard targetCapabilities.supportsFinderVisibleTrash else {
        errorMessage =
          targetCapabilities.finderTrashUnavailableReason
          ?? "目前目標無法使用 Finder 可見垃圾桶；請改用直接刪除。"
        return
      }
      let directOnly = selected.filter { !$0.supportsFinderVisibleTrash }
      guard directOnly.isEmpty else {
        errorMessage =
          "下列項目不能假裝進入垃圾桶，請改用『直接徹底刪除』："
          + directOnly.map(\.displayName).joined(separator: "、")
        return
      }
    case .forceDelete:
      guard targetCapabilities.supportsDirectDeletion else {
        errorMessage = "目前目標是唯讀檔案系統，不能執行直接刪除。"
        return
      }
      guard selected.allSatisfy(\.supportsDirectDeletion) else {
        errorMessage = "選取內容含不可執行的僅檢視項目。"
        return
      }
    }

    isCleaning = true
    lastFinderVisibleTrashReceipts = []
    let profile = cleanupLastResult?.configuration.profile ?? cleanupProfile
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let result = Result {
        try CleanupEngine(library: self.library).executeSelected(
          selected,
          profile: profile,
          target: target,
          removalMode: removalMode
        )
      }
      DispatchQueue.main.async {
        self.isCleaning = false
        switch result {
        case .success(let value):
          let entries = value.0.entries
          let failureCount = entries.reduce(0) { $0 + $1.failures.count }
          let completedCount = entries.reduce(0) { partial, entry in
            let fileOperations = entry.movedItems.count + entry.permanentlyDeletedItems.count
            let managedCommandSuccess =
              entry.command != nil && entry.commandExitStatus == 0 && entry.failures.isEmpty ? 1 : 0
            return partial + fileOperations + managedCommandSuccess
          }
          let recreatedCount = entries.reduce(0) { $0 + $1.recreatedItems.count }
          let finderReceipts = entries.flatMap { $0.finderVisibleTrashItems ?? [] }
          self.lastFinderVisibleTrashReceipts = finderReceipts
          let finderRevealRequested =
            removalMode == .moveToTrash && FinderVisibleTrash.reveal(finderReceipts)

          if removalMode == .moveToTrash, !finderReceipts.isEmpty {
            self.statusMessage =
              finderRevealRequested
              ? "已驗證 \(finderReceipts.count) 個可見垃圾桶目的地，並已要求 Finder 選取；清空 Finder 垃圾桶前仍占用原卷宗空間。"
              : "已驗證 \(finderReceipts.count) 個 Finder 可見垃圾桶項目；清空 Finder 垃圾桶前仍占用原卷宗空間。"
          } else if removalMode == .forceDelete {
            if targetCapabilities.isRemote {
              self.statusMessage =
                "已向 \(targetCapabilities.filesystemDisplayName) 遠端掛載直接刪除 \(completedCount) 項；不經 Finder 垃圾桶。NAS／伺服器若啟用自己的 recycle bin、snapshot 或版本保護，實際保留與空間釋放由伺服器端政策決定。"
            } else {
              self.statusMessage =
                "已直接徹底刪除 \(completedCount) 項；沒有經過任何垃圾桶，也沒有建立隱藏暫存或標記。"
            }
          }

          if recreatedCount > 0 {
            self.statusMessage +=
              " macOS 已以不同 inode 重新建立 \(recreatedCount) 個同名目錄；這些是新資料，請重新掃描確認容量。"
          }
          self.statusMessage += " 操作紀錄：\(value.1.lastPathComponent)"

          if failureCount > 0 {
            self.errorMessage =
              "\(removalMode.title)完成 \(completedCount) 項，但有 \(failureCount) 筆未完成；已成功的項目不會被冒充為失敗，詳細紀錄：\(value.1.path)"
          }

          // Keep the expensive discovery work. Successful paths are removed from
          // the index immediately; only their parent directories become dirty.
          // The next explicit scan refreshes those directories (and any newly
          // enabled scopes) instead of traversing the whole target again.
          if var index = self.cleanupIncrementalIndex {
            index.markCleanupResult(selected: selected, log: value.0)
            self.cleanupIncrementalIndex = index
            self.persistCleanupIncrementalIndexIfEligible()
            self.updateCleanupIndexStatus()
            self.applyCleanupIncrementalIndexToCurrentConfiguration(
              extraNotices: [
                "已成功處理的路徑已從清理索引扣除；未選取與未完成項目仍保留。",
                index.dirtyDirectoryPaths.isEmpty
                  ? "目前沒有需要重新讀取的受影響資料夾。"
                  : "已將 \(index.dirtyDirectoryPaths.count) 個受影響資料夾標記為待刷新；補充掃描只重查這些位置，完整重新掃描則會從零建立新索引。",
              ],
              fallbackMessage: "清理完成；既有索引已更新。可補充掃描變更位置，也可完整重新掃描。"
            )
          } else {
            self.cleanupCandidates = []
            self.cleanupLastResult = nil
            self.cleanupScanProgress = CleanupScanProgress(
              message: "清理完成；這次掃描沒有可重用索引，需要時請重新掃描候選。",
              currentPath: target.path,
              currentStep: 0,
              totalSteps: 1
            )
          }
          self.refreshCapacity()
        case .failure(let error):
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }

  func openInFinder(_ path: String) {
    guard FinderActions.reveal(path: path) else {
      errorMessage = "Finder 找不到這個路徑：\(path)"
      return
    }
  }

  func openPathInFinder(_ path: String) {
    guard FinderActions.open(path: path) else {
      errorMessage = "無法在 Finder 開啟：\(path)"
      return
    }
  }

  func openFile(_ path: String) {
    guard FinderActions.launch(path: path) else {
      errorMessage = "無法開啟檔案：\(path)"
      return
    }
  }

  func copyPath(_ path: String) {
    copyText(path, status: "已複製路徑：\(path)")
  }

  func copyText(_ text: String, status: String) {
    FinderActions.copy(path: text)
    statusMessage = status
  }

  func openReportsFolder() {
    NSWorkspace.shared.open(library.rootURL)
  }

  func openCleanupHistoryFolder() {
    NSWorkspace.shared.open(library.cleanupHistoryURL)
  }

  var cleanupTrashTitle: String {
    lastFinderVisibleTrashReceipts.isEmpty
      ? "開啟 Finder 垃圾桶" : "顯示剛移入 Finder 垃圾桶的項目"
  }

  func openTrash() {
    if FinderVisibleTrash.reveal(lastFinderVisibleTrashReceipts) {
      statusMessage = "已要求 Finder 選取這次移入垃圾桶的可見項目。"
      return
    }

    let fileManager = FileManager.default
    if let trashURL = fileManager.urls(for: .trashDirectory, in: .userDomainMask).first {
      NSWorkspace.shared.open(trashURL)
      statusMessage = "已開啟 Finder 垃圾桶；MacStorageLens 不會開啟或建立不可見的卷宗垃圾桶。"
    } else {
      errorMessage = "macOS 沒有回傳可開啟的 Finder 垃圾桶位置。"
    }
  }

  private func restoreRecentScanTargets() {
    guard let data = UserDefaults.standard.data(forKey: PreferenceKey.recentScanTargets),
      let targets = try? JSONDecoder().decode([ScanTarget].self, from: data)
    else { return }

    recentScanTargets = RecentScanTargetPolicy.normalized(targets)
  }

  private func rememberRecentScanTarget(_ target: ScanTarget) {
    guard target.kind != .system else { return }
    recentScanTargets = RecentScanTargetPolicy.inserting(target, into: recentScanTargets)
    persistRecentScanTargets()
  }

  private func reconcileRecentScanTargetsWithReports() {
    let savedKeys = Set(reportHistory.map(\.targetKey))
    let filtered = RecentScanTargetPolicy.pending(
      from: recentScanTargets,
      savedKeys: savedKeys
    )
    guard filtered != recentScanTargets else { return }
    recentScanTargets = filtered
    persistRecentScanTargets()
  }

  private func persistRecentScanTargets() {
    guard let data = try? JSONEncoder().encode(recentScanTargets) else { return }
    UserDefaults.standard.set(data, forKey: PreferenceKey.recentScanTargets)
  }

  private func restoreSelectedScanTarget() {
    guard let data = UserDefaults.standard.data(forKey: PreferenceKey.selectedScanTarget),
      let target = try? JSONDecoder().decode(ScanTarget.self, from: data)
    else { return }
    selectedScanTarget = target
  }

  private func adoptResolvedScanTarget(_ target: ScanTarget) {
    guard target != selectedScanTarget else { return }
    selectedScanTarget = target
    persistSelectedScanTarget()
    if target.kind != .system {
      rememberRecentScanTarget(target)
    }
    refreshCleanupTargetCapabilities(for: target)
  }

  private func persistSelectedScanTarget() {
    guard let data = try? JSONEncoder().encode(selectedScanTarget) else { return }
    UserDefaults.standard.set(data, forKey: PreferenceKey.selectedScanTarget)
  }

  private func expandedCleanupIndexScopes(
    _ missingScopes: Set<CleanupScope>,
    mode: CleanupMode
  ) -> Set<CleanupScope> {
    guard mode == .generalLocation else { return missingScopes }
    var scopes = missingScopes
    let listingFamily: Set<CleanupScope> = [
      .folderAppleDoubleRemnants,
      .folderAppleDouble,
      .folderAppleDoubleReview,
    ]
    if !missingScopes.intersection(listingFamily).isEmpty {
      // Once a directory listing is already required for arbitrary ._ names,
      // classify the full AppleDouble family in the same pass. Do not pull in
      // unrelated macOS-managed or legacy-directory review rules here: those can
      // be probed separately without making Balanced unexpectedly more expensive.
      scopes.formUnion(listingFamily)
    }
    return scopes
  }

  private func updateCleanupIndexStatus() {
    cleanupIndexStatus = cleanupIncrementalIndex?.status ?? .empty
  }

  private func persistCleanupIncrementalIndexIfEligible() {
    guard let cleanupIncrementalIndex else { return }
    _ = try? cleanupIncrementalIndexStore.save(cleanupIncrementalIndex)
  }

  private func restoreCleanupIncrementalIndexIfAvailable() {
    cleanupIncrementalIndex = nil
    refreshCleanupIncrementalIndexContext()
  }

  private func refreshCleanupIncrementalIndexContext() {
    let target = selectedScanTarget
    let mode = CleanupMode.forTarget(target)
    let scanSource: CleanupScanSource = mode == .system ? .liveFilesystem : cleanupScanSource
    let reportURL =
      scanSource == .existingStorageReport ? cleanupReusableReportURL(for: target) : nil
    let reportSignature = reportURL.flatMap { try? ReportFileSignature.read(from: $0) }

    if cleanupIncrementalIndex?.isValid(
      for: target,
      scanSource: scanSource,
      sourceReportURL: reportURL,
      sourceReportSignature: reportSignature
    ) == true {
      updateCleanupIndexStatus()
      return
    }

    cleanupIncrementalIndex = cleanupIncrementalIndexStore.load(
      target: target,
      scanSource: scanSource,
      sourceReportURL: reportURL
    )
    updateCleanupIndexStatus()
  }

  private func applyCleanupIncrementalIndexToCurrentConfiguration(
    extraNotices: [String] = [],
    fallbackMessage: String
  ) {
    cleanupScanGeneration = UUID()
    isScanningCleanup = false
    refreshCleanupIncrementalIndexContext()
    guard let index = cleanupIncrementalIndex else {
      cleanupCandidates = []
      cleanupLastResult = nil
      cleanupScanProgress = CleanupScanProgress(
        message: fallbackMessage,
        currentPath: selectedScanTarget.path,
        currentStep: 0,
        totalSteps: 1
      )
      updateCleanupIndexStatus()
      return
    }

    let configuration = cleanupConfiguration
    let missing = index.missingScopes(
      for: configuration,
      prioritizingExternalAppleDouble: cleanupPrioritizesExternalAppleDouble
    )
    guard missing.isEmpty else {
      cleanupCandidates = []
      cleanupLastResult = nil
      cleanupScanProgress = CleanupScanProgress(
        message:
          "既有索引已保留；目前等級新增 \(missing.count) 個尚未覆蓋的規則範圍。可選補充掃描只處理新增規則，或選完整重新掃描從零重建。",
        currentPath: selectedScanTarget.path,
        currentStep: 0,
        totalSteps: 1
      )
      updateCleanupIndexStatus()
      return
    }

    let mode = CleanupMode.forTarget(index.target)
    let visible = CleanupEngine(library: library).visibleCandidates(
      from: index.candidates,
      configuration: configuration,
      mode: mode
    )
    var notices = extraNotices
    notices.insert(
      "候選來自可重用清理索引；已覆蓋 \(index.coveredScopes.count) 個規則範圍。切換到已覆蓋的清理等級只重新篩選，不重新讀取磁碟。",
      at: 0
    )
    if !index.dirtyDirectoryPaths.isEmpty {
      notices.append(
        "清理後有 \(index.dirtyDirectoryPaths.count) 個資料夾標記為待增量刷新；目前仍保留未刪除候選，真正執行前會逐項重驗證。可選補充掃描只刷新這些資料夾，或完整重新掃描。"
      )
    }

    let sourceReportURL = index.sourceReportPath.map { URL(fileURLWithPath: $0) }
    let scanResult = CleanupScanResult(
      configuration: configuration,
      candidates: visible,
      startedAt: index.createdAt,
      finishedAt: index.updatedAt,
      notices: notices,
      mode: mode,
      target: index.target,
      scanSource: index.scanSource,
      sourceReportURL: sourceReportURL
    )
    cleanupCandidates = visible
    cleanupLastResult = scanResult
    cleanupScanProgress = CleanupScanProgress(
      message: index.dirtyDirectoryPaths.isEmpty
        ? "已直接套用清理索引：\(visible.count) 類、\(scanResult.matchedItemCount) 個匹配項目"
        : "已保留清理索引；\(index.dirtyDirectoryPaths.count) 個受影響資料夾可再增量刷新",
      currentPath: nil,
      currentStep: 1,
      totalSteps: 1
    )
    updateCleanupIndexStatus()
  }

  private func cleanupReusableReportURL(for target: ScanTarget) -> URL? {
    guard CleanupMode.forTarget(target) == .generalLocation else { return nil }
    let key = target.reportRetentionKey
    if let document, document.summary.reportComplete,
      document.summary.target.reportRetentionKey == key,
      FileManager.default.fileExists(atPath: document.url.path)
    {
      return document.url
    }
    return reportHistory.first(where: {
      $0.targetKey == key && FileManager.default.fileExists(atPath: $0.url.path)
    })?.url
  }

  private func restoreCleanupPreferences() {
    let defaults = UserDefaults.standard
    if let rawValue = defaults.string(forKey: PreferenceKey.cleanupProfile),
      let profile = CleanupProfile(rawValue: rawValue)
    {
      cleanupProfile = profile
    }

    if let rawScopes = defaults.stringArray(forKey: PreferenceKey.cleanupCustomScopes) {
      cleanupCustomScopes = Set(
        rawScopes.compactMap(CleanupScope.init(rawValue:)).filter { $0.mode == .system }
      )
    }

    if let rawScopes = defaults.stringArray(forKey: PreferenceKey.cleanupPresetOptionalScopes) {
      cleanupPresetOptionalScopes = Set(
        rawScopes.compactMap(CleanupScope.init(rawValue:)).filter(
          \.requiresExplicitPresetOptIn
        )
      )
    }

    if let rawScopes = defaults.stringArray(forKey: PreferenceKey.cleanupFolderCustomScopes) {
      var restored = Set(
        rawScopes.compactMap(CleanupScope.init(rawValue:)).filter {
          $0.mode == .generalLocation
        }
      )
      // v1.5 used one broad AppleDouble switch. v1.6 splits it into
      // executable orphan remnants, paired metadata and review-only sensitive
      // content. Preserve the previous intent without silently enabling any
      // new destructive rule: the additional migrated scope is either safer
      // than the former rule or strictly review-only.
      if restored.contains(.folderAppleDouble) {
        restored.insert(.folderAppleDoubleRemnants)
        restored.insert(.folderAppleDoubleReview)
      }
      cleanupFolderCustomScopes = restored
    }

    if defaults.object(forKey: PreferenceKey.cleanupCustomMinimumMiB) != nil {
      cleanupCustomMinimumMiB = Self.clampCleanupMinimumMiB(
        defaults.integer(forKey: PreferenceKey.cleanupCustomMinimumMiB))
    }
  }

  private static func clampCleanupMinimumMiB(_ value: Int) -> Int {
    min(500, max(0, value))
  }

  private func persistCleanupPreferences() {
    let defaults = UserDefaults.standard
    defaults.set(cleanupProfile.rawValue, forKey: PreferenceKey.cleanupProfile)
    defaults.set(
      cleanupCustomScopes.map(\.rawValue).sorted(),
      forKey: PreferenceKey.cleanupCustomScopes
    )
    defaults.set(
      cleanupPresetOptionalScopes.map(\.rawValue).sorted(),
      forKey: PreferenceKey.cleanupPresetOptionalScopes
    )
    defaults.set(
      cleanupFolderCustomScopes.map(\.rawValue).sorted(),
      forKey: PreferenceKey.cleanupFolderCustomScopes
    )
    defaults.set(cleanupCustomMinimumMiB, forKey: PreferenceKey.cleanupCustomMinimumMiB)
  }

  private func resetLoadedReportState() {
    reportLoadGeneration = UUID()
    overviewLoadGeneration = UUID()
    treeLoadGeneration = UUID()
    document = nil
    currentPath = "/System/Volumes/Data"
    children = []
    sunburst = nil
    overviewSunburst = nil
    clearAggregateFocus()
    isLoadingReport = false
    isLoadingTree = false
  }

  private func startCapacityTimer() {
    capacityTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      self?.refreshCapacity()
    }
  }
}
