import CleanerCore
import Foundation
@testable import AppCleanerGUI

/// 지연 없는 데모 엔진 (파일을 건드리지 않는다)
func fastEngine(unresponsive: Bool = false) -> DemoCleanerEngine {
    var o = DemoCleanerEngine.Options()
    o.delayScale = 0
    o.simulateUnresponsiveApp = unresponsive
    return DemoCleanerEngine(options: o)
}

let wordURL = URL(filePath: "/Applications/Microsoft Word.app")
let slackURL = URL(filePath: "/Applications/Slack.app")

func candidate(_ path: String, _ confidence: Confidence = .high, nature: DataNature = .settings,
               share: ShareStatus = .exclusive, protection: ProtectionReason? = nil, selected: Bool = true,
               size: Int64 = 100, children: [Candidate] = []) -> Candidate {
    Candidate(url: URL(filePath: path), category: children.isEmpty ? .preferences : .container,
              confidence: confidence, nature: nature, share: share, protection: protection,
              isSelected: selected, size: size, children: children)
}

/// 조건이 참이 될 때까지 기다린다 (MainActor 작업이 돌 수 있게 양보)
@MainActor
/// CI 러너는 병렬 테스트 부하로 느릴 수 있어 넉넉히 기다린다.
func waitUntil(timeout: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// 데모 엔진에 위임하면서 복원 관련 호출을 기록한다
final class CountingEngine: CleanerEngine, @unchecked Sendable {
    let base: DemoCleanerEngine
    private let lock = NSLock()
    private var _previewCalls = 0
    private var _restoreOptions: [RestoreOptions] = []

    init(base: DemoCleanerEngine) { self.base = base }

    var previewCalls: Int { lock.withLock { _previewCalls } }
    var restoreOptions: [RestoreOptions] { lock.withLock { _restoreOptions } }

    func installedApps() async -> [InstalledApp] { await base.installedApps() }
    func size(of url: URL) async -> Int64? { await base.size(of: url) }
    func scan(appAt url: URL) async throws -> ScanReport { try await base.scan(appAt: url) }
    func makePlan(for report: ScanReport, selectedPaths: Set<String>, resetPrivacy: Bool) -> CleanupPlan {
        base.makePlan(for: report, selectedPaths: selectedPaths, resetPrivacy: resetPrivacy)
    }
    func makePlan(for report: OrphanScanReport, selectedPaths: Set<String>) -> CleanupPlan {
        base.makePlan(for: report, selectedPaths: selectedPaths)
    }
    func execute(_ plan: CleanupPlan, progress: @escaping @Sendable (CleanupProgress) -> Void,
                 onUnresponsive: @escaping @Sendable (UnresponsiveApp) async -> UnresponsiveDecision) async -> CleanupResult {
        await base.execute(plan, progress: progress, onUnresponsive: onUnresponsive)
    }
    func scanOrphans(options: OrphanScanOptions, progress: @escaping @Sendable (OrphanScanEvent) -> Void) async throws -> OrphanScanReport {
        try await base.scanOrphans(options: options, progress: progress)
    }
    func keepList() -> [KeepEntry] { base.keepList() }
    func addToKeepList(_ entry: KeepEntry) { base.addToKeepList(entry) }
    func removeFromKeepList(id: String) { base.removeFromKeepList(id: id) }
    func sessions() async -> [JournalSession] { await base.sessions() }
    func restore(sessionID: UUID, itemPaths: Set<String>?, options: RestoreOptions) async -> RestoreResult {
        lock.withLock { _restoreOptions.append(options) }
        return await base.restore(sessionID: sessionID, itemPaths: itemPaths, options: options)
    }
    func restorePreview(sessionID: UUID, itemPaths: Set<String>?) async -> RestorePreview? {
        lock.withLock { _previewCalls += 1 }
        return await base.restorePreview(sessionID: sessionID, itemPaths: itemPaths)
    }
    var holdingFolderURL: URL { base.holdingFolderURL }
    func holdingUsage(retentionDays: Int) async -> HoldingUsage { await base.holdingUsage(retentionDays: retentionDays) }
    func purgeHolding(sessionIDs: [UUID]) async -> [CleanupFailure] { await base.purgeHolding(sessionIDs: sessionIDs) }
    func exportSession(id: UUID) async -> Data? { await base.exportSession(id: id) }
    func permissions() -> PermissionStatus { base.permissions() }
    func ruleDataInfo() -> RuleDataInfo { base.ruleDataInfo() }
}
