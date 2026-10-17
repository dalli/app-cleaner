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
    let homebrew: HomebrewViewModel
    let history: HistoryViewModel
    @ObservationIgnored let system: SystemActions
    @ObservationIgnored let sentinel: any SentinelServicing
    /// 관리자 헬퍼 설치 (S7)
    @ObservationIgnored let helper: any HelperInstalling

    var route: SidebarRoute {
        didSet { if route != oldValue { settings.lastRoute = route } }
    }

    /// S2 (nil이면 S1)
    var inspector: InspectorViewModel?
    /// S3 시트
    var cleanupFlow: CleanupFlowModel?
    /// S4 (정리를 시작한 화면에 표시)
    var completion: CompletionModel?
    /// 설치 파일 정리 시트
    var installerCleanup: InstallerCleanupModel?

    private(set) var permissions: PermissionStatus
    private(set) var helperState: HelperInstallState
    /// 헬퍼 설치·제거 실패 문구 (설정 화면에 표시)
    private(set) var helperError: String?
    private(set) var helperBusy = false
    private(set) var ruleInfo: RuleDataInfo
    private(set) var keepList: [KeepEntry] = []
    private(set) var ruleCheck: RuleCheckState = .idle
    /// Sentinel 로그인 항목 상태와 Sentinel이 기록한 상태 (S7 — ui-ux.md S10)
    private(set) var sentinelRegistration: SentinelRegistration = .unavailable
    private(set) var sentinelStatus = SentinelPreferences()
    /// 등록·해제 실패 문장
    private(set) var sentinelError: String?

    var showOnboarding: Bool
    var isDropTargeted = false
    /// ⌘F 요청 (값이 바뀌면 검색 칸에 포커스)
    private(set) var searchFocusRequest = 0
    /// 설정 화면에서 권한 섹션으로 스크롤 요청
    var settingsAnchor: String?

    init(engine: any CleanerEngine, settings: AppSettings, isDemo: Bool = false,
         system: SystemActions = SystemActions(), sentinel: (any SentinelServicing)? = nil,
         helper: any HelperInstalling = UnavailableHelperInstaller()) {
        self.engine = engine
        self.settings = settings
        self.isDemo = isDemo
        self.system = system
        self.sentinel = sentinel ?? InMemorySentinelService()
        self.helper = helper
        self.helperState = helper.state()
        self.appList = AppListViewModel(engine: engine)
        self.orphans = OrphanViewModel(engine: engine)
        self.homebrew = HomebrewViewModel(engine: engine)
        self.history = HistoryViewModel(engine: engine)
        self.route = settings.lastRoute
        self.permissions = engine.permissions()
        self.ruleInfo = engine.ruleDataInfo()
        self.showOnboarding = !settings.onboardingCompleted
        self.keepList = engine.keepList()
        refreshSentinel()
        reregisterSentinelIfBuildChanged()
        if InstallerLeftoverScanner.currentAppBundle != nil { checkInstallerLeftovers() }
    }

    // MARK: 설치 파일 정리

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    /// 새 버전을 처음 실행했을 때 한 번(`manual`이면 메뉴에서 언제든) 남은 설치 파일·이전 사본을 찾아 시트를 연다.
    /// 자동 확인은 정리할 것이 없으면 조용히 끝낸다. 응용 프로그램 폴더 밖에서 실행 중이면 확인한 것으로 기록하지 않는다 (옮긴 뒤 다시 확인).
    func checkInstallerLeftovers(manual: Bool = false) {
        guard installerCleanup == nil, cleanupFlow == nil else { return }
        let version = Self.appVersion
        if !manual {
            guard !isDemo, !showOnboarding, settings.installerCleanupCheckedVersion != version else { return }
        }
        Task {
            let report = await engine.installerLeftovers()
            if !manual && !report.runningOutsideApplications { settings.installerCleanupCheckedVersion = version }
            guard manual || !report.isEmpty || report.runningOutsideApplications, installerCleanup == nil else { return }
            let model = InstallerCleanupModel(report: report, engine: engine)
            let appList = self.appList
            model.onFinished = { appList.reload() }
            installerCleanup = model
        }
    }

    func dismissInstallerCleanup() {
        guard installerCleanup?.phase != .running else { return }
        installerCleanup = nil
    }

    // MARK: 사이드바

    func select(_ r: SidebarRoute) {
        route = r
        if r == .settings { refreshKeepList(); refreshSentinel() }
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

    /// 앱 열기 요청: Sentinel 링크(`com.dallisoft.appcleaner://`), Dock 아이콘 드롭, Finder "다음으로 열기"
    @discardableResult
    func handleOpen(_ urls: [URL]) -> Bool {
        if let link = urls.lazy.compactMap(SentinelLink.init(url:)).first {
            open(link)
            return true
        }
        return handleDrop(urls)
    }

    /// Sentinel 알림·메뉴 → S2 / S5 / S7 (ui-ux.md S10). 정리가 진행 중이면 화면을 바꾸지 않는다.
    func open(_ link: SentinelLink) {
        if let flow = cleanupFlow, flow.phase != .preview { return }
        switch link {
        case .inspect(let path):
            // 알림을 누르기 전에 휴지통을 비웠으면 앱 검사를 할 수 없다 → 남은 파일은 이제 고아 잔여물
            if FileManager.default.fileExists(atPath: path) {
                openApp(at: URL(filePath: path, directoryHint: .isDirectory))
            } else {
                cleanupFlow = nil
                startOrphanScan()
            }
        case .orphans:
            cleanupFlow = nil
            if !orphans.isScanning { startOrphanScan() } else { route = .orphans }
        case .settings:
            select(.settings)
        }
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
        else if route == .history { Task { await history.requestUndoLatest() } }
    }

    // MARK: ⌘R

    var revealPath: String? {
        switch route {
        case .apps:
            if let inspector { return inspector.focusedCandidate?.path ?? inspector.identity?.bundleURL.path }
            return appList.focusedApp?.url.path
        case .orphans:
            return orphans.focusedPath
        case .homebrew:
            return homebrew.focusedItem?.location.path
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
        helperState = helper.state()
    }

    // MARK: 관리자 헬퍼 (S7)

    /// 등록 후 대부분 "승인 필요" 상태가 되므로 로그인 항목 설정을 바로 연다 (데모는 설정 화면의 안내만).
    func installHelper() {
        helperError = nil
        do {
            try helper.install()
        } catch {
            helperError = L("헬퍼를 설치하지 못했습니다: %@", EngineText.describing(error).localized)
        }
        helperState = helper.state()
        if helperState == .requiresApproval && !(helper is DemoHelperInstaller) { system.openLoginItemsSettings() }
    }

    func uninstallHelper() {
        helperError = nil
        helperBusy = true
        Task {
            do {
                try await helper.uninstall()
            } catch {
                helperError = L("헬퍼를 제거하지 못했습니다: %@", EngineText.describing(error).localized)
            }
            helperState = helper.state()
            helperBusy = false
        }
    }

    /// 시스템 설정 › 일반 › 로그인 항목 (돌아오면 앱 활성화 시 상태를 다시 확인한다)
    func openHelperApproval() {
        if let demo = helper as? DemoHelperInstaller {
            demo.approve()
            helperState = helper.state()
            return
        }
        system.openLoginItemsSettings()
    }

    func finishOnboarding() {
        settings.onboardingCompleted = true
        showOnboarding = false
        refreshPermissions()
        if InstallerLeftoverScanner.currentAppBundle != nil { checkInstallerLeftovers() }
    }

    var lacksFullDiskAccess: Bool { permissions.fullDiskAccess != .granted }

    /// S7 "휴지통을 읽을 수 없음". 로그인 항목으로 실행된 Sentinel은 본 앱의 전체 디스크 접근을 함께 쓴다 (#18 실기기 확인) —
    /// 본 앱에 권한이 있으면 Sentinel이 전에 기록한 "읽을 수 없음"은 Sentinel이 다시 읽기 전의 지난 값이다.
    var sentinelNeedsFullDiskAccess: Bool {
        settings.trashWatchEnabled && sentinelStatus.trashReadable == false && lacksFullDiskAccess
    }

    // MARK: 설정

    func refreshKeepList() {
        keepList = engine.keepList().sorted { $0.addedAt > $1.addedAt }
    }

    func removeKeepEntry(_ entry: KeepEntry) {
        engine.removeFromKeepList(id: entry.id)
        refreshKeepList()
    }

    // MARK: Sentinel (S7 — ui-ux.md S10)

    func setTrashWatch(_ on: Bool) {
        settings.trashWatchEnabled = on
        applySentinelSettings()
    }

    func setPeriodicScan(_ interval: PeriodicScanInterval) {
        settings.periodicScan = interval
        applySentinelSettings()
    }

    /// 휴지통 감시·정기 스캔 중 하나라도 켜져 있으면 Sentinel을 로그인 항목으로 등록, 둘 다 꺼지면 해제
    func applySentinelSettings() {
        sentinelError = nil
        let wanted = settings.trashWatchEnabled || settings.periodicScan != .off
        let current = sentinel.registration
        if wanted {
            if current == .disabled {
                do {
                    try sentinel.register()
                    settings.sentinelRegisteredBuild = sentinel.buildID
                } catch { sentinelError = L10n.describe(error) }
            } else {
                sentinel.launchIfNeeded()
            }
            sentinel.notifySettingsChanged()
            refreshSentinel()
        } else {
            // 실행 중인 Sentinel은 설정을 다시 읽고 스스로 종료한다
            sentinel.notifySettingsChanged()
            guard current == .enabled || current == .requiresApproval else {
                refreshSentinel()
                return
            }
            Task {
                do { try await sentinel.unregister() } catch { sentinelError = L10n.describe(error) }
                refreshSentinel()
            }
        }
    }

    /// 등록돼 있는 Sentinel이 다른 빌드(업데이트·재빌드)로 등록됐으면 해제 → 다시 등록한다.
    /// 그대로 두면 launchd가 실행에 실패(`spawn failed`, EX_CONFIG)해도 S7은 "켜짐"으로 보인다 (#50).
    /// 등록 빌드를 기록하기 전 버전(기록 없음)에서 올라온 경우도 한 번 다시 등록한다.
    func reregisterSentinelIfBuildChanged() {
        let wanted = settings.trashWatchEnabled || settings.periodicScan != .off
        guard wanted, sentinel.registration == .enabled, let build = sentinel.buildID,
              build != settings.sentinelRegisteredBuild else { return }
        Task {
            do {
                try await sentinel.unregister()
                try sentinel.register()
                settings.sentinelRegisteredBuild = build
            } catch { sentinelError = L10n.describe(error) }
            refreshSentinel()
        }
    }

    func refreshSentinel() {
        sentinelRegistration = sentinel.registration
        sentinelStatus = settings.sentinelPreferences()
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
