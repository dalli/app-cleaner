import CleanerCore
import Foundation

/// 가짜 데이터로 동작하는 엔진 (`--demo`, 테스트).
///
/// 파일을 읽거나 옮기지 않는다. 정리·복원은 메모리 안의 기록만 바꾼다.
/// `delayScale`로 인공 지연을 조절한다 (테스트는 0).
final class DemoCleanerEngine: CleanerEngine, @unchecked Sendable {
    struct Options: Sendable {
        var delayScale: Double = 1
        var fullDiskAccess: PermissionStatus.State = .granted
        /// 실행 중인 앱이 종료 요청에 응답하지 않는 상황을 흉내 낸다
        var simulateUnresponsiveApp = true
        /// 고아 스캔에서 Spotlight 색인이 불완전한 상황
        var spotlightIncomplete = true
    }

    private struct State {
        var apps: [DemoData.DemoApp]
        var removedApps: [String: DemoData.DemoApp] = [:]
        var keepList: [KeepEntry]
        var sessions: [JournalSession]
        var orphanCleaned: Set<String> = []
    }

    private let lock = NSLock()
    private var state: State
    let options: Options

    init(options: Options = Options(), now: Date = Date()) {
        self.options = options
        state = State(apps: DemoData.installedApps(now: now),
                      keepList: DemoData.initialKeepList(now: now),
                      sessions: DemoData.sessions(now: now))
    }

    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    private func pause(_ seconds: Double) async throws {
        let s = seconds * options.delayScale
        if s > 0 { try await Task.sleep(for: .milliseconds(Int(s * 1000))) }
        try Task.checkCancellation()
    }

    // MARK: S1

    func installedApps() async -> [InstalledApp] {
        try? await pause(0.4)
        return withState { $0.apps.map(\.app) }
    }

    func size(of url: URL) async -> Int64? {
        let app = withState { s in s.apps.first { $0.app.url.path == url.path } }
        try? await pause(Double.random(in: 0.6...2.4))
        return app?.lazySize
    }

    // MARK: S2

    func scan(appAt url: URL) async throws -> ScanReport {
        try await pause(1.0)
        let apps = withState { $0.apps + Array($0.removedApps.values) }
        return DemoData.scanReport(for: url, apps: apps)
    }

    // MARK: S3

    func makePlan(for report: ScanReport, selectedPaths: Set<String>, resetPrivacy: Bool) -> CleanupPlan {
        let (items, kept) = Self.split(report.candidates, selected: selectedPaths)
        let id = report.identity
        let appSelected = items.contains { $0.category == .appBundle }
        let services = items.compactMap(\.launchService)
        let prefs = items.compactMap(\.preferencesDomain)
        return CleanupPlan(
            kind: .appRemoval, targetName: id.title, targetBundleID: id.bundleID,
            items: items, keptItems: kept, servicesToStop: services,
            bundleIDsToTerminate: appSelected || report.warnings.contains(.appRunning) ? [id.bundleID] : [],
            bundlePathsToTerminate: appSelected ? [id.bundleURL] : [],
            preferencesDomains: prefs, receiptsToForget: id.packageIDs, resetPrivacy: resetPrivacy,
            advisories: report.advisories, ruleDataVersion: report.ruleDataVersion)
    }

    func makePlan(for report: OrphanScanReport, selectedPaths: Set<String>) -> CleanupPlan {
        let (items, kept) = Self.split(report.groups.flatMap(\.items), selected: selectedPaths)
        let groupsWithItems = report.groups.filter { g in g.items.contains { selectedPaths.contains($0.path) } }
        let name: String
        switch groupsWithItems.count {
        case 0: name = "고아 잔여물"
        case 1: name = groupsWithItems[0].displayName
        default: name = "\(groupsWithItems[0].displayName) 외 \(groupsWithItems.count - 1)개"
        }
        return CleanupPlan(kind: .orphanCleanup, targetName: name, items: items, keptItems: kept,
                           servicesToStop: items.compactMap(\.launchService),
                           ruleDataVersion: report.ruleDataVersion)
    }

    /// 선택 경로를 이동 단위(가장 위 경로)와 남겨둘 항목(잎)으로 나눈다
    static func split(_ roots: [Candidate], selected: Set<String>) -> (items: [Candidate], kept: [Candidate]) {
        var items: [Candidate] = []
        var kept: [Candidate] = []
        func visit(_ c: Candidate) {
            if selected.contains(c.path) && c.isSelectable {
                items.append(c)
                return
            }
            if c.children.isEmpty { kept.append(c) } else { c.children.forEach(visit) }
        }
        roots.forEach(visit)
        return (items, kept)
    }

    // MARK: 실행

    func execute(_ plan: CleanupPlan, progress: @escaping @Sendable (CleanupProgress) -> Void,
                 onUnresponsive: @escaping @Sendable (UnresponsiveApp) async -> UnresponsiveDecision) async -> CleanupResult {
        let sessionID = UUID()
        let started = Date()
        var moved: [Candidate] = []
        var failures: [CleanupFailure] = []
        var cancelled = false

        stepLoop: for step in plan.steps {
            progress(.stepStarted(step))
            try? await pause(0.7)
            switch step {
            case .terminateApps:
                let running = withState { s in
                    s.apps.filter { $0.app.isRunning && plan.bundleIDsToTerminate.contains($0.app.bundleID) }.map(\.app)
                }
                if options.simulateUnresponsiveApp, let app = running.first {
                    try? await pause(0.8)
                    let decision = await onUnresponsive(UnresponsiveApp(bundleID: app.bundleID, name: app.name, pid: 4242))
                    switch decision {
                    case .cancel:
                        cancelled = true
                        break stepLoop
                    case .forceQuit, .skip:
                        break
                    }
                }
            case .moveItems:
                for item in plan.items {
                    try? await pause(0.15)
                    if item.category == .privilegedHelper {
                        let f = CleanupFailure(path: item.path, reason: "관리자 권한 요청이 거부되었습니다")
                        failures.append(f)
                        progress(.itemFailed(path: f.path, reason: f.reason))
                    } else {
                        moved.append(item)
                        progress(.itemMoved(path: item.path, completed: moved.count, total: plan.items.count))
                    }
                }
            default:
                break
            }
            progress(.stepFinished(step))
        }

        let journalItems = moved.map { c -> JournalItem in
            let dest: MoveDestination = c.domain == .system && c.category != .appBundle ? .holding : .trash
            let movedTo = dest == .trash
                ? DemoData.home + "/.Trash/" + c.url.lastPathComponent
                : DemoData.holdingDir + "/\(sessionID.uuidString)" + c.path
            return JournalItem(originalPath: c.path, movedTo: movedTo, destination: dest, size: c.size, category: c.category,
                               confidence: c.confidence, share: c.share, nature: c.nature, sources: c.evidence.map(\.source))
        }
        if !journalItems.isEmpty {
            let session = JournalSession(
                id: sessionID, kind: plan.kind, targetName: plan.targetName, targetBundleID: plan.targetBundleID,
                startedAt: started, finishedAt: Date(), ruleDataVersion: plan.ruleDataVersion,
                steps: plan.steps.map(\.rawValue), items: journalItems, stoppedServices: plan.servicesToStop,
                failures: failures, status: .restorable)
            withState { s in
                s.sessions.insert(session, at: 0)
                if plan.kind == .appRemoval, let bid = plan.targetBundleID,
                   moved.contains(where: { $0.category == .appBundle }),
                   let i = s.apps.firstIndex(where: { $0.app.bundleID == bid }) {
                    s.removedApps[bid] = s.apps.remove(at: i)
                }
                if plan.kind == .orphanCleanup { s.orphanCleaned.formUnion(moved.map(\.path)) }
            }
        }
        return CleanupResult(
            sessionID: sessionID, movedCount: journalItems.count, movedSize: journalItems.reduce(0) { $0 + ($1.size ?? 0) },
            movedToTrash: journalItems.filter { $0.destination == .trash }.count,
            movedToHolding: journalItems.filter { $0.destination == .holding }.count,
            failures: failures, cancelled: cancelled, advisories: cancelled ? [] : plan.advisories)
    }

    // MARK: S5

    func scanOrphans(options scanOptions: OrphanScanOptions, progress: @escaping @Sendable (OrphanScanEvent) -> Void) async throws -> OrphanScanReport {
        let started = Date()
        progress(.phase(.buildingInventory))
        try await pause(1.2)
        progress(.phase(.collectingCandidates))
        let (keep, cleaned, appCount) = withState { s in (s.keepList, s.orphanCleaned, s.apps.count) }
        let keptGroupKeys = Set(keep.filter { $0.kind == .group }.map(\.key))
        let keptItemKeys = Set(keep.filter { $0.kind == .item }.map(\.key))
        var hidden = 0
        var groups: [OrphanGroup] = []
        for var g in DemoData.orphanGroups() {
            if keptGroupKeys.contains(g.id) { hidden += 1; continue }
            hidden += g.items.filter { keptItemKeys.contains($0.path) }.count
            g.items.removeAll { keptItemKeys.contains($0.path) || cleaned.contains($0.path) }
            if g.items.isEmpty { continue }
            try await pause(0.45)
            progress(.groupFound(g))
            groups.append(g)
        }
        progress(.phase(.judging))
        try await pause(0.8)
        progress(.phase(.finished))
        let spotlight = options.spotlightIncomplete
            ? SpotlightStatus(indexingEnabled: true, complete: false, missingApps: ["/Volumes/Media/Applications/DaVinci Resolve.app"])
            : SpotlightStatus(indexingEnabled: true, complete: true)
        var warnings: [ScanWarning] = []
        if options.fullDiskAccess != .granted { warnings.append(.noFullDiskAccess) }
        return OrphanScanReport(groups: groups, spotlight: spotlight, inventoryAppCount: appCount + 200,
                                duration: Date().timeIntervalSince(started),
                                hiddenByKeepList: hidden, warnings: warnings, ruleDataVersion: DemoData.ruleVersion)
    }

    func keepList() -> [KeepEntry] { withState { $0.keepList } }

    func addToKeepList(_ entry: KeepEntry) {
        withState { s in
            if !s.keepList.contains(where: { $0.id == entry.id }) { s.keepList.append(entry) }
        }
    }

    func removeFromKeepList(id: String) {
        withState { s in s.keepList.removeAll { $0.id == id } }
    }

    // MARK: S6

    func sessions() async -> [JournalSession] {
        try? await pause(0.3)
        return withState { $0.sessions }
    }

    /// 원래 위치에 같은 이름이 있는 상황을 흉내 낸다 (충돌 선택 UI 확인용)
    static func simulatedConflict(_ path: String) -> Bool {
        path.hasSuffix("/Preferences/com.microsoft.Word.plist")
    }

    func restore(sessionID: UUID, itemPaths: Set<String>?, options restoreOptions: RestoreOptions) async -> RestoreResult {
        try? await pause(0.9)
        return withState { s in
            guard let si = s.sessions.firstIndex(where: { $0.id == sessionID }) else { return RestoreResult() }
            var session = s.sessions[si]
            var result = RestoreResult()
            let now = Date()
            for (i, item) in session.items.enumerated() where itemPaths?.contains(item.originalPath) ?? true {
                guard item.restoredAt == nil else { continue }
                if session.missingItems.contains(item.originalPath) { result.missing.append(item.originalPath); continue }
                if Self.simulatedConflict(item.originalPath) && restoreOptions.conflictPolicy(for: item.originalPath) == .skip {
                    result.skipped.append(item.originalPath)
                    continue
                }
                session.items[i].restoredAt = now
                result.restored.append(item.originalPath)
                if item.category == .appBundle, let bid = session.targetBundleID, let app = s.removedApps.removeValue(forKey: bid) {
                    s.apps.append(app)
                }
                s.orphanCleaned.remove(item.originalPath)
            }
            session.status = Self.status(of: session)
            s.sessions[si] = session
            return result
        }
    }

    func restorePreview(sessionID: UUID, itemPaths: Set<String>?) async -> RestorePreview? {
        try? await pause(0.1)
        return withState { s in
            guard let session = s.sessions.first(where: { $0.id == sessionID }) else { return nil }
            var preview = RestorePreview()
            for item in session.items where itemPaths?.contains(item.originalPath) ?? true {
                if item.restoredAt != nil { preview.alreadyRestored.append(item.originalPath) }
                else if session.missingItems.contains(item.originalPath) { preview.missing.append(item.originalPath) }
                else if Self.simulatedConflict(item.originalPath) { preview.conflicts.append(item.originalPath) }
                else { preview.ready.append(item.originalPath) }
            }
            return preview
        }
    }

    var holdingFolderURL: URL { URL(filePath: DemoData.holdingDir, directoryHint: .isDirectory) }

    static func status(of session: JournalSession) -> SessionStatus {
        let remaining = session.items.filter { $0.restoredAt == nil }
        if remaining.isEmpty { return .restored }
        let missing = remaining.filter { session.missingItems.contains($0.originalPath) }
        if missing.count == remaining.count {
            return remaining.count == session.items.count ? .notRestorable : .partiallyRestorable
        }
        return missing.isEmpty ? .restorable : .partiallyRestorable
    }

    func holdingUsage(retentionDays: Int) async -> HoldingUsage {
        try? await pause(0.2)
        return withState { s in
            let limit = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
            var total: Int64 = 0
            var oldest: Date?
            var expired: [UUID] = []
            for session in s.sessions {
                let held = session.items.filter {
                    $0.destination == .holding && $0.restoredAt == nil && !session.missingItems.contains($0.originalPath)
                }
                guard !held.isEmpty else { continue }
                total += held.reduce(0) { $0 + ($1.size ?? 0) }
                oldest = min(oldest ?? session.startedAt, session.startedAt)
                if session.startedAt < limit { expired.append(session.id) }
            }
            return HoldingUsage(totalSize: total, oldestItemDate: oldest, expiredSessionIDs: expired)
        }
    }

    func purgeHolding(sessionIDs: [UUID]) async -> [CleanupFailure] {
        try? await pause(0.8)
        withState { s in
            for i in s.sessions.indices where sessionIDs.contains(s.sessions[i].id) {
                let held = s.sessions[i].items.filter { $0.destination == .holding && $0.restoredAt == nil }.map(\.originalPath)
                s.sessions[i].missingItems.append(contentsOf: held.filter { !s.sessions[i].missingItems.contains($0) })
                s.sessions[i].status = Self.status(of: s.sessions[i])
            }
        }
        return []
    }

    func exportSession(id: UUID) async -> Data? {
        guard let session = withState({ s in s.sessions.first { $0.id == id } }) else { return nil }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try? enc.encode(session)
    }

    // MARK: S7 · S8

    func permissions() -> PermissionStatus {
        PermissionStatus(fullDiskAccess: options.fullDiskAccess, appManagement: .granted)
    }

    func ruleDataInfo() -> RuleDataInfo {
        RuleDataInfo(version: DemoData.ruleVersion, updatedAt: Date().addingTimeInterval(-3 * 86_400),
                     signatureVerified: true, caskCount: 7_412)
    }
}
