import Foundation
import Testing
@testable import appcleaner
import CleanerCore

/// 실행/복원을 기록만 하는 가짜 엔진
final class RecordingEngine: CleanerEngine, @unchecked Sendable {
    var report: ScanReport
    var orphanReport: OrphanScanReport
    var executedPlans: [CleanupPlan] = []
    var apps: [InstalledApp]
    var journal: [JournalSession] = []
    var preview: RestorePreview?
    var restoredSessions: [UUID] = []

    init(report: ScanReport, orphanReport: OrphanScanReport, apps: [InstalledApp] = []) {
        self.report = report
        self.orphanReport = orphanReport
        self.apps = apps
    }

    func installedApps() async -> [InstalledApp] { apps }
    func size(of url: URL) async -> Int64? { nil }
    func scan(appAt url: URL) async throws -> ScanReport { report }
    func makePlan(for report: ScanReport, selectedPaths: Set<String>, resetPrivacy: Bool) -> CleanupPlan {
        let all = report.candidates.flatMap(\.flattened)
        return CleanupPlan(kind: .appRemoval, targetName: report.identity.name, items: all.filter { selectedPaths.contains($0.path) },
                           keptItems: all.filter { !selectedPaths.contains($0.path) }, resetPrivacy: resetPrivacy, ruleDataVersion: "t")
    }
    func makePlan(for report: OrphanScanReport, selectedPaths: Set<String>) -> CleanupPlan {
        let all = report.groups.flatMap(\.items)
        return CleanupPlan(kind: .orphanCleanup, targetName: "고아 잔여물", items: all.filter { selectedPaths.contains($0.path) },
                           ruleDataVersion: "t")
    }
    func execute(_ plan: CleanupPlan, progress: @escaping @Sendable (CleanupProgress) -> Void,
                 onUnresponsive: @escaping @Sendable (UnresponsiveApp) async -> UnresponsiveDecision) async -> CleanupResult {
        executedPlans.append(plan)
        return CleanupResult(sessionID: UUID(), movedCount: plan.items.count, movedSize: plan.totalSize, movedToTrash: plan.items.count,
                             movedToHolding: 0, failures: [])
    }
    func scanOrphans(options: OrphanScanOptions, progress: @escaping @Sendable (OrphanScanEvent) -> Void) async throws -> OrphanScanReport { orphanReport }
    func keepList() -> [KeepEntry] { [] }
    func addToKeepList(_ entry: KeepEntry) {}
    func removeFromKeepList(id: String) {}
    func sessions() async -> [JournalSession] { journal }
    func restore(sessionID: UUID, itemPaths: Set<String>?, options: RestoreOptions) async -> RestoreResult {
        restoredSessions.append(sessionID)
        return RestoreResult(restored: preview?.restorable ?? [])
    }
    func restorePreview(sessionID: UUID, itemPaths: Set<String>?) async -> RestorePreview? { preview }
    var holdingFolderURL: URL { URL(fileURLWithPath: "/tmp/Holding") }
    func holdingUsage(retentionDays: Int) async -> HoldingUsage { HoldingUsage() }
    func purgeHolding(sessionIDs: [UUID]) async -> [CleanupFailure] { [] }
    func exportSession(id: UUID) async -> Data? { nil }
    func permissions() -> PermissionStatus { PermissionStatus(fullDiskAccess: .granted) }
    func ruleDataInfo() -> RuleDataInfo { RuleDataInfo(version: "t", updatedAt: nil, signatureVerified: true, caskCount: 0) }
}

private func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

private func sampleEngine() -> RecordingEngine {
    let identity = AppIdentity(bundleURL: url("/Applications/Foo.app"), bundleID: "com.example.foo", name: "Foo")
    let candidates = [
        Candidate(url: url("/Applications/Foo.app"), category: .appBundle, confidence: .high, isSelected: true, size: 100),
        Candidate(url: url("/u/Library/Caches/com.example.foo"), category: .caches, confidence: .high, isSelected: true, size: 10),
        Candidate(url: url("/u/Library/Group Containers/T.shared"), category: .groupContainer, confidence: .high,
                  share: .shared(usedBy: ["Bar"], reason: "group"), isSelected: false),
        Candidate(url: url("/u/.foo"), category: .dotfile, confidence: .low, isSelected: false),
    ]
    let report = ScanReport(identity: identity, candidates: candidates, ruleDataVersion: "t")
    let orphans = OrphanScanReport(groups: [
        OrphanGroup(id: "com.gone", displayName: "Gone", nameIsGuess: false, items: [
            Candidate(url: url("/u/Library/Caches/com.gone"), category: .caches, confidence: .high, isSelected: true, size: 5),
            Candidate(url: url("/u/Library/Preferences/com.gone.plist"), category: .preferences, confidence: .medium, isSelected: false),
            Candidate(url: url("/u/Library/Application Support/Gone"), category: .applicationSupport, confidence: .medium,
                      nature: .userData, isSelected: false),
        ], confidence: .high),
    ], spotlight: SpotlightStatus(indexingEnabled: true, complete: true), inventoryAppCount: 10, duration: 1, ruleDataVersion: "t")
    return RecordingEngine(report: report, orphanReport: orphans,
                           apps: [InstalledApp(url: url("/Applications/Foo.app"), bundleID: "com.example.foo", name: "Foo")])
}

@Suite struct ArgumentParserTests {
    @Test func parsesCommands() throws {
        #expect(try ArgumentParser.parse([]) == .help)
        #expect(try ArgumentParser.parse(["scan", "Foo", "--json"]) == .scan(app: "Foo", json: true, showAll: false))
        #expect(try ArgumentParser.parse(["remove", "/Applications/Foo.app", "--dry-run"])
                == .remove(app: "/Applications/Foo.app", dryRun: true, yes: false, json: false, resetPrivacy: false))
        if case let .orphans(opts, json) = try ArgumentParser.parse(["orphans", "--min-confidence", "high", "--include-dotfiles", "--json"]) {
            #expect(opts.minimumConfidence == .high)
            #expect(opts.includeDotfiles)
            #expect(json)
        } else { Issue.record("orphans not parsed") }
        if case let .orphansClean(_, dryRun, _, _, includeMedium) = try ArgumentParser.parse(["orphans", "clean", "--dry-run"]) {
            #expect(dryRun && !includeMedium)
        } else { Issue.record("orphans clean not parsed") }
    }

    @Test func rejectsUnknownAndInvalid() {
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["scan"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["scan", "Foo", "--force"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["orphans", "--min-confidence", "very"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["restore", "not-a-uuid"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["rm", "-rf"]) }
    }
}

@Suite struct CLIRunTests {
    @Test func dryRunNeverExecutesAndUsesDefaultSelection() async throws {
        let engine = sampleEngine()
        var output = ""
        let cli = CLI(engine: engine, out: { output += $0 + "\n" }, err: { _ in }, confirm: { _ in true })
        let status = await cli.run(.remove(app: "Foo", dryRun: true, yes: false, json: false, resetPrivacy: false))
        #expect(status == 0)
        #expect(engine.executedPlans.isEmpty)
        #expect(output.contains("\"itemCount\" : 2"))
    }

    @Test func removeRequiresConfirmation() async {
        let engine = sampleEngine()
        let cli = CLI(engine: engine, out: { _ in }, err: { _ in }, confirm: { _ in false })
        let status = await cli.run(.remove(app: "Foo", dryRun: false, yes: false, json: false, resetPrivacy: false))
        #expect(status == 1)
        #expect(engine.executedPlans.isEmpty)
    }

    @Test func removeWithYesMovesOnlyDefaultSelection() async {
        let engine = sampleEngine()
        let cli = CLI(engine: engine, out: { _ in }, err: { _ in }, confirm: { _ in false })
        _ = await cli.run(.remove(app: "Foo", dryRun: false, yes: true, json: true, resetPrivacy: false))
        let plan = engine.executedPlans.first
        #expect(Set(plan?.items.map(\.path) ?? []) == ["/Applications/Foo.app", "/u/Library/Caches/com.example.foo"])
    }

    @Test func orphanCleanDefaultsToHighOnlyAndNeverUserData() async {
        let engine = sampleEngine()
        let cli = CLI(engine: engine, out: { _ in }, err: { _ in }, confirm: { _ in true })
        _ = await cli.run(.orphansClean(options: OrphanScanOptions(), dryRun: false, yes: true, json: true, includeMedium: false))
        #expect(engine.executedPlans.last?.items.map(\.path) == ["/u/Library/Caches/com.gone"])
        _ = await cli.run(.orphansClean(options: OrphanScanOptions(), dryRun: false, yes: true, json: true, includeMedium: true))
        #expect(Set(engine.executedPlans.last?.items.map(\.path) ?? [])
                == ["/u/Library/Caches/com.gone", "/u/Library/Preferences/com.gone.plist"])
    }

    @Test func restoreAnnouncesConflictsFromEnginePreview() async {
        let engine = sampleEngine()
        let session = JournalSession(kind: .appRemoval, targetName: "Foo", ruleDataVersion: "t")
        engine.journal = [session]
        engine.preview = RestorePreview(ready: ["/u/a"], conflicts: ["/u/b"], missing: ["/u/c"])
        var output = ""
        var question = ""
        let cli = CLI(engine: engine, out: { output += $0 + "\n" }, err: { _ in }, confirm: { question = $0; return true })
        #expect(await cli.run(.restore(sessionID: session.id, yes: false)) == 0)
        #expect(output.contains("복원할 수 없는 항목 1개"))
        #expect(output.contains("복원할 항목 1개:\n  /u/b"))
        #expect(question.contains("항목 2개"))
        #expect(engine.restoredSessions == [session.id])

        // 되돌릴 항목이 없으면 복원을 호출하지 않는다
        engine.preview = RestorePreview(missing: ["/u/a"], alreadyRestored: ["/u/b"])
        #expect(await cli.run(.restore(sessionID: session.id, yes: true)) == 0)
        #expect(engine.restoredSessions == [session.id])
        // 세션이 없으면 실패
        engine.preview = nil
        #expect(await cli.run(.restore(sessionID: session.id, yes: true)) == 1)
    }

    @Test func appNameResolutionIsExactOnly() async throws {
        let engine = sampleEngine()
        let cli = CLI(engine: engine, out: { _ in }, err: { _ in })
        #expect(try await cli.resolveApp("foo").path == "/Applications/Foo.app")
        await #expect(throws: UsageError.self) { try await cli.resolveApp("Fo") }
    }
}
