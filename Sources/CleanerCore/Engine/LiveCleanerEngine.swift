import Foundation

/// 실제 구성 요소를 조립한 엔진 (plan.md 8.2). GUI·CLI가 같은 인스턴스 구성을 쓴다.
public final class LiveCleanerEngine: CleanerEngine, @unchecked Sendable {
    public let paths: SystemPaths
    public let rules: RuleDataStore
    public let inventory: AppInventory
    public let scanner: AppScanner
    public let orphans: OrphanScanner
    public let packages: PackageScanner
    public let keep: KeepListStore
    public let journal: JournalStore
    public let executor: CleanupExecutor

    private let inventoryTask = InventoryRefresher()

    /// - Parameter adminLauncher: 헬퍼가 없을 때의 대체 경로. GUI·CLI 모두 기본은 관리자 인증 대화상자,
    ///   이미 root로 실행 중이면 `.direct`(헬퍼를 쓰지 않음).
    public init(paths: SystemPaths = .live(), runner: CommandRunning = ProcessCommandRunner(),
                adminLauncher: AppleScriptAdminExecutor.Launcher? = nil) {
        self.paths = paths
        let rules = RuleDataStore(paths: paths)
        self.rules = rules
        let safety = SafetyGuard(paths: paths)
        let inventory = AppInventory(paths: paths, runner: runner)
        self.inventory = inventory
        let fdaPaths = paths
        scanner = AppScanner.standard(
            paths: paths, runner: runner, rules: rules, safety: safety,
            isRunning: LiveAppHooks.isRunning,
            hasFullDiskAccess: { PermissionProbe.fullDiskAccess(paths: fdaPaths) != .denied }
        )
        packages = PackageScanner(paths: paths, rules: rules, safety: safety)
        let keep = KeepListStore(paths: paths)
        self.keep = keep
        orphans = OrphanScanner(paths: paths, runner: runner, inventory: inventory, rules: rules, safety: safety,
                                classifier: DataNatureClassifier(), keepList: keep)

        // 권한 헬퍼가 설치·허용되어 있으면 헬퍼(XPC), 아니면 관리자 암호(고정 스크립트) — plan.md 5.3
        let admin = AdminExecutors.live(launcher: adminLauncher)
        let services = LaunchctlServiceController(paths: paths, runner: runner, admin: admin)
        let prefs = CFPreferencesFlusher(paths: paths, runner: runner)
        let journal = JournalStore(paths: paths, admin: admin, services: services, preferences: prefs)
        self.journal = journal
        executor = CleanupExecutor(paths: paths, runner: runner, safety: safety, services: services,
                                   terminator: ProcessTerminator(), preferences: prefs, trash: FileManagerTrash(),
                                   admin: admin, journal: journal)
    }

    /// GUI 시작 시 호출: 첫 검사가 기다리지 않도록 인벤토리 캐시를 미리 만든다.
    public func prewarm() {
        if inventory.cached() == nil { inventoryTask.refresh(inventory) }
    }

    // MARK: S1

    public func installedApps() async -> [InstalledApp] {
        await inventory.installedApps()
    }

    public func size(of url: URL) async -> Int64? {
        await Task.detached(priority: .utility) { FileStatsCalculator.stats(at: url)?.size }.value
    }

    // MARK: S2

    public func scan(appAt url: URL) async throws -> ScanReport {
        // 캐시가 없으면 먼저 인벤토리를 만든다 (첫 실행 1~2초). 실패하면 공유 판정 대상만 미선택 처리한다 (plan.md 8.2).
        var snapshot = inventory.cached()
        if snapshot == nil { snapshot = try? await inventory.build() }
        return try await scanner.scan(appAt: url, inventory: snapshot)
    }

    // MARK: S3

    public func makePlan(for report: ScanReport, selectedPaths: Set<String>, resetPrivacy: Bool) -> CleanupPlan {
        CleanupPlanner.plan(for: report, selectedPaths: selectedPaths, resetPrivacy: resetPrivacy)
    }

    public func makePlan(for report: OrphanScanReport, selectedPaths: Set<String>) -> CleanupPlan {
        CleanupPlanner.plan(for: report, selectedPaths: selectedPaths)
    }

    public func execute(
        _ plan: CleanupPlan,
        progress: @escaping @Sendable (CleanupProgress) -> Void,
        onUnresponsive: @escaping @Sendable (UnresponsiveApp) async -> UnresponsiveDecision
    ) async -> CleanupResult {
        // 실행 중인 Sentinel이 이 앱의 휴지통 유입을 알리지 않도록 (ui-ux.md S10)
        SentinelSignal.postAppRemovalIfNeeded(plan)
        let result = await executor.execute(plan, progress: progress, onUnresponsive: onUnresponsive)
        // 앱 본체를 옮겼으면 인벤토리가 바뀌었으므로 다시 만든다.
        if plan.kind == .appRemoval { inventoryTask.refresh(inventory) }
        return result
    }

    // MARK: S5

    public func scanOrphans(options: OrphanScanOptions, progress: @escaping @Sendable (OrphanScanEvent) -> Void) async throws -> OrphanScanReport {
        try await orphans.scan(options: options, progress: progress)
    }

    public func keepList() -> [KeepEntry] { keep.entries() }
    public func addToKeepList(_ entry: KeepEntry) { keep.add(entry) }
    public func removeFromKeepList(id: String) { keep.remove(id: id) }

    // MARK: 패키지

    public func scanPackages(options: PackageScanOptions) async throws -> PackageScanReport {
        await packages.scan(options: options)
    }

    // MARK: Homebrew

    public func homebrewItems() async -> [HomebrewItem] {
        let paths = self.paths
        return await Task.detached(priority: .userInitiated) { HomebrewInventory(paths: paths).items() }.value
    }

    // MARK: S6

    public func sessions() async -> [JournalSession] { await journal.sessions() }

    public func restore(sessionID: UUID, itemPaths: Set<String>?, options: RestoreOptions) async -> RestoreResult {
        let result = await journal.restore(sessionID: sessionID, itemPaths: itemPaths, options: options)
        inventoryTask.refresh(inventory)
        return result
    }

    public func restorePreview(sessionID: UUID, itemPaths: Set<String>?) async -> RestorePreview? {
        await journal.restorePreview(sessionID: sessionID, itemPaths: itemPaths)
    }

    public var holdingFolderURL: URL { paths.holdingDir }

    public func holdingUsage(retentionDays: Int) async -> HoldingUsage { await journal.holdingUsage(retentionDays: retentionDays) }
    public func purgeHolding(sessionIDs: [UUID]) async -> [CleanupFailure] { await journal.purgeHolding(sessionIDs: sessionIDs) }
    public func exportSession(id: UUID) async -> Data? { await journal.exportJSON(sessionID: id) }

    // MARK: S7 · S8

    public func permissions() -> PermissionStatus {
        PermissionStatus(fullDiskAccess: PermissionProbe.fullDiskAccess(paths: paths))
    }

    public func ruleDataInfo() -> RuleDataInfo { rules.info() }
}

/// 백그라운드 인벤토리 구축을 한 번에 하나만 돌린다.
final class InventoryRefresher: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    func refresh(_ inventory: AppInventory) {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        Task.detached(priority: .background) { [self] in
            _ = try? await inventory.build()
            self.finish()
        }
    }

    private func finish() {
        lock.withLock { running = false }
    }
}
