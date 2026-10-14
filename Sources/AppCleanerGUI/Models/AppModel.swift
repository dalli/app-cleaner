import CleanerCore
import Foundation
import Observation

/// 앱 전체 상태와 화면 전환 (사이드바, S1→S2→S3→S4, 단축키)
@MainActor
@Observable
final class AppModel {
    enum RuleCheckState: Equatable { case idle, checking, upToDate }

    let engine: any CleanerEngine
    let settings: AppSettings
    let isDemo: Bool
    let appList: AppListViewModel
    let orphans: OrphanViewModel
    let history: HistoryViewModel
    @ObservationIgnored let system: SystemActions

    var route: SidebarRoute {
        didSet { if route != oldValue { settings.lastRoute = route } }
    }

    /// S2 (nil이면 S1)
    var inspector: InspectorViewModel?
    /// S3 시트
    var cleanupFlow: CleanupFlowModel?
    /// S4 (정리를 시작한 화면에 표시)
    var completion: CompletionModel?

    private(set) var permissions: PermissionStatus
    private(set) var ruleInfo: RuleDataInfo
    private(set) var keepList: [KeepEntry] = []
    private(set) var ruleCheck: RuleCheckState = .idle

    var showOnboarding: Bool
    var isDropTargeted = false
    /// ⌘F 요청 (값이 바뀌면 검색 칸에 포커스)
    private(set) var searchFocusRequest = 0
    /// 설정 화면에서 권한 섹션으로 스크롤 요청
    var settingsAnchor: String?

    init(engine: any CleanerEngine, settings: AppSettings, isDemo: Bool = false,
         system: SystemActions = SystemActions(),
         pathExists: (@Sendable (String) -> Bool)? = nil) {
        self.engine = engine
        self.settings = settings
        self.isDemo = isDemo
        self.system = system
        self.appList = AppListViewModel(engine: engine)
        self.orphans = OrphanViewModel(engine: engine)
        self.history = HistoryViewModel(engine: engine, pathExists: pathExists ?? { FileManager.default.fileExists(atPath: $0) })
        self.route = settings.lastRoute
        self.permissions = engine.permissions()
        self.ruleInfo = engine.ruleDataInfo()
        self.showOnboarding = !settings.onboardingCompleted
        self.keepList = engine.keepList()
    }

    // MARK: 사이드바

    func select(_ r: SidebarRoute) {
        route = r
        if r == .settings { refreshKeepList() }
    }

    func openPermissionSettings() {
        select(.settings)
        settingsAnchor = "permissions"
    }

    // MARK: 앱 제거 흐름

    /// S1 행 선택, `.app` 드롭, Dock 아이콘 드롭, "다음으로 열기" → S2
    func openApp(at url: URL) {
        route = .apps
        if completion?.origin == .appRemoval { completion = nil }
        cleanupFlow = nil
        let vm = InspectorViewModel(appURL: url, engine: engine)
        inspector = vm
        Task { await vm.load() }
    }

    func closeInspector() {
        inspector = nil
    }

    /// 창에 놓은 파일 중 첫 `.app`을 연다
    @discardableResult
    func handleDrop(_ urls: [URL]) -> Bool {
        guard let app = urls.first(where: { $0.pathExtension.lowercased() == "app" }) else { return false }
        openApp(at: app)
        return true
    }

    // MARK: S3 미리보기

    var canOpenPreview: Bool {
        guard cleanupFlow == nil else { return false }
        switch route {
        case .apps: return inspector?.canPreview ?? false
        case .orphans: return orphans.canPreview && completion?.origin != .orphans
        default: return false
        }
    }

    /// ⌘⌫ · "정리 미리보기" — 바로 지우지 않고 항상 시트를 연다
    func openPreview() {
        guard canOpenPreview else { return }
        switch route {
        case .apps:
            guard let inspector, let plan = inspector.makePlan(resetPrivacy: settings.resetPrivacyByDefault) else { return }
            present(CleanupFlowModel(origin: .appRemoval, plan: plan, engine: engine,
                                     resetPrivacy: settings.resetPrivacyByDefault,
                                     rebuild: { [weak inspector] reset in
                                         inspector?.makePlan(resetPrivacy: reset) ?? plan
                                     }))
        case .orphans:
            guard let plan = orphans.makePlan() else { return }
            present(CleanupFlowModel(origin: .orphans, plan: plan, engine: engine))
        default:
            break
        }
    }

    private func present(_ flow: CleanupFlowModel) {
        flow.onFinished = { [weak self] flow, result in
            self?.cleanupFinished(flow, result)
        }
        cleanupFlow = flow
    }

    /// "돌아가서 수정" / Esc (진행 중에는 닫지 않는다)
    func dismissPreview() {
        guard let flow = cleanupFlow, flow.phase == .preview else { return }
        cleanupFlow = nil
    }

    private func cleanupFinished(_ flow: CleanupFlowModel, _ result: CleanupResult) {
        completion = CompletionModel(origin: flow.origin, plan: flow.plan, result: result, engine: engine)
        cleanupFlow = nil
        let failed = Set(result.failures.map(\.path))
        switch flow.origin {
        case .appRemoval:
            inspector = nil
            appList.reload()
        case .orphans:
            orphans.removeCleaned(paths: Set(flow.plan.items.map(\.path)).subtracting(failed))
        }
    }

    // MARK: S4

    /// "완료" — 앱 목록(또는 고아 목록)으로
    func finishCompletion() {
        completion = nil
    }

    func undoCompletion() {
        guard let completion else { return }
        Task {
            await completion.undo()
            appList.reload()
        }
    }

    // MARK: 고아

    /// 메뉴 막대 정리 › 고아 잔여물 스캔 (⌘⇧O) → S5 + 스캔 시작
    func startOrphanScan() {
        route = .orphans
        if completion?.origin == .orphans { completion = nil }
        orphans.startScan(includeDotfiles: settings.includeDotfiles)
    }

    // MARK: ⌘Z

    var canUndo: Bool {
        if let completion, isCompletionVisible { return completion.canUndo }
        if route == .history { return history.sessions.contains { !history.restorableItems(of: $0).isEmpty } }
        return false
    }

    var isCompletionVisible: Bool {
        guard let completion else { return false }
        switch completion.origin {
        case .appRemoval: return route == .apps
        case .orphans: return route == .orphans
        }
    }

    /// 직전 정리 되돌리기 (완료 화면·삭제 기록)
    func undoLastCleanup() {
        if isCompletionVisible { undoCompletion() }
        else if route == .history { history.requestUndoLatest() }
    }

    // MARK: ⌘R

    var revealPath: String? {
        switch route {
        case .apps:
            if let inspector { return inspector.focusedCandidate?.path ?? inspector.identity?.bundleURL.path }
            return appList.focusedApp?.url.path
        case .orphans:
            return orphans.focusedPath
        case .history:
            return history.selectedSession?.items.first.map(\.movedTo)
        case .settings:
            return nil
        }
    }

    func revealInFinder() {
        guard let p = revealPath else { return }
        system.reveal(path: p)
    }

    // MARK: ⌘F

    func focusSearch() {
        if route != .apps || inspector != nil || isCompletionVisible {
            route = .apps
            inspector = nil
            if completion?.origin == .appRemoval { completion = nil }
        }
        searchFocusRequest += 1
    }

    // MARK: Space

    func toggleFocusedRow() {
        switch route {
        case .apps: inspector?.toggleFocused()
        case .orphans: orphans.toggleFocused()
        default: break
        }
    }

    // MARK: 권한·온보딩

    /// 앱이 활성화될 때마다 다시 확인 (시스템 설정에서 돌아온 경우)
    func refreshPermissions() {
        permissions = engine.permissions()
    }

    func finishOnboarding() {
        settings.onboardingCompleted = true
        showOnboarding = false
        refreshPermissions()
    }

    var lacksFullDiskAccess: Bool { permissions.fullDiskAccess != .granted }

    // MARK: 설정

    func refreshKeepList() {
        keepList = engine.keepList().sorted { $0.addedAt > $1.addedAt }
    }

    func removeKeepEntry(_ entry: KeepEntry) {
        engine.removeFromKeepList(id: entry.id)
        refreshKeepList()
    }

    /// 규칙 데이터 "지금 확인"
    func checkRuleData() {
        ruleCheck = .checking
        Task {
            try? await Task.sleep(for: .milliseconds(isDemo ? 700 : 300))
            ruleInfo = engine.ruleDataInfo()
            ruleCheck = .upToDate
        }
    }

    /// S4 고아 연결 카드 (지난 스캔 결과)
    var orphanSummary: (groups: Int, size: Int64)? {
        guard orphans.hasScanned else { return nil }
        return (orphans.groups.count, orphans.groups.reduce(0) { $0 + $1.totalSize })
    }
}
