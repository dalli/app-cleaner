import CleanerCore
import Foundation
import Testing
@testable import AppCleanerGUI

@MainActor
@Suite("Cleanup preview (S3/S4)")
struct CleanupFlowTests {
    @Test func previewSummaryNumbers() throws {
        let engine = fastEngine()
        let vm = InspectorViewModel(report: DemoData.word(wordURL), engine: engine)
        let plan = try #require(vm.makePlan(resetPrivacy: false))
        let flow = CleanupFlowModel(origin: .appRemoval, plan: plan, engine: engine,
                                    rebuild: { vm.makePlan(resetPrivacy: $0) ?? plan })
        #expect(flow.moveCount == 10)
        #expect(flow.reclaimSize == vm.selectedSize)
        #expect(flow.keptCount == 7)
        #expect(flow.keptSummary.shared == 2)
        // 공유 LaunchAgent는 선택되지 않았으므로 서비스 중지 단계는 없다
        #expect(flow.steps == [.terminateApps, .flushPreferences, .moveItems])
        #expect(flow.requiresAdmin)
        #expect(flow.adminItems.map(\.category) == [.appBundle])
        #expect(flow.riskyItems.isEmpty)

        flow.resetPrivacy = true
        #expect(flow.plan.resetPrivacy)
        #expect(flow.steps.last == .postProcess)
    }

    @Test func riskyItemsShownSeparately() throws {
        let engine = fastEngine()
        let vm = InspectorViewModel(report: DemoData.word(wordURL), engine: engine)
        let office = vm.allLeaves.first { $0.path.hasSuffix("UBF8T346G9.Office") }!
        vm.toggle(office)
        let plan = try #require(vm.makePlan(resetPrivacy: false))
        let flow = CleanupFlowModel(origin: .appRemoval, plan: plan, engine: engine)
        #expect(flow.riskyItems.map(\.path) == [office.path])
        #expect(!flow.canResetPrivacy)
    }

    @Test func executeWithUnresponsiveAppThenComplete() async throws {
        let engine = fastEngine(unresponsive: true)
        let vm = InspectorViewModel(report: DemoData.word(wordURL), engine: engine)
        let flow = CleanupFlowModel(origin: .appRemoval, plan: try #require(vm.makePlan(resetPrivacy: false)), engine: engine)
        var finished: CleanupResult?
        flow.onFinished = { _, r in finished = r }
        flow.start()
        #expect(await waitUntil { if case .unresponsive = flow.phase { return true }; return false })
        flow.respond(.skip)
        #expect(await waitUntil { flow.phase == .finished })
        let result = try #require(finished)
        #expect(result.movedCount == 10)
        #expect(flow.completedSteps.contains(.moveItems))

        let completion = CompletionModel(origin: .appRemoval, plan: flow.plan, result: result, engine: engine)
        #expect(completion.advisories.count == 2)
        #expect(completion.canUndo)
        await completion.undo()
        #expect(completion.undoState == .done(restored: 10, skipped: 0, missing: 0, failed: 0))
    }

    @Test func cancelFromUnresponsiveMovesNothing() async throws {
        let engine = fastEngine(unresponsive: true)
        let vm = InspectorViewModel(report: DemoData.word(wordURL), engine: engine)
        let flow = CleanupFlowModel(origin: .appRemoval, plan: try #require(vm.makePlan(resetPrivacy: false)), engine: engine)
        flow.start()
        _ = await waitUntil { if case .unresponsive = flow.phase { return true }; return false }
        flow.respond(.cancel)
        #expect(await waitUntil { flow.phase == .finished })
        #expect(flow.result?.cancelled == true)
        #expect(flow.result?.movedCount == 0)
    }

    @Test func appModelRoutesPreviewAndCompletion() async throws {
        let model = AppModel(engine: fastEngine(), settings: .inMemory(), isDemo: true)
        model.openApp(at: wordURL)
        #expect(await waitUntil { model.inspector?.phase == .loaded })
        #expect(model.canOpenPreview)
        model.openPreview()
        let flow = try #require(model.cleanupFlow)
        model.dismissPreview()
        #expect(model.cleanupFlow == nil)
        model.openPreview()
        model.cleanupFlow?.start()
        #expect(await waitUntil { model.completion != nil })
        #expect(model.inspector == nil)
        #expect(model.isCompletionVisible)
        #expect(model.canUndo)
        _ = flow
    }

    @Test func dropOnlyAcceptsApps() {
        let model = AppModel(engine: fastEngine(), settings: .inMemory())
        #expect(!model.handleDrop([URL(filePath: "/tmp/readme.txt")]))
        #expect(model.inspector == nil)
        #expect(model.handleDrop([URL(filePath: "/tmp/readme.txt"), slackURL]))
        #expect(model.inspector?.appURL == slackURL)
        #expect(model.route == .apps)
    }

    @Test func settingsPersistThroughStore() {
        let store = InMemorySettingsStore()
        let s = AppSettings(defaults: store)
        #expect(s.holdingRetentionDays == 30)
        #expect(!s.onboardingCompleted)
        s.holdingRetentionDays = 14
        s.lastRoute = .history
        let again = AppSettings(defaults: store)
        #expect(again.holdingRetentionDays == 14)
        #expect(again.lastRoute == .history)
    }
}

@MainActor
@Suite("History (S6)")
struct HistoryViewModelTests {
    @Test func loadAndRestoreWithPerItemConflictChoice() async throws {
        let engine = fastEngine()
        let vm = HistoryViewModel(engine: engine, pathExists: { DemoCleanerEngine.simulatedConflict($0) })
        await vm.load(retentionDays: 30)
        #expect(vm.sessions.count == 5)
        #expect(vm.selectedSession?.targetName == "Microsoft Word")
        #expect(vm.expiredSessionIDs.count == 1)

        vm.requestRestoreAll()
        var req = try #require(vm.restoreRequest)
        #expect(req.items.count == 5)
        #expect(req.conflicts.count == 1)
        #expect(req.reregisterServices)
        let conflict = try #require(req.conflicts.first)
        req.policies[conflict] = .skip
        vm.restoreRequest = req
        await vm.performRestore()
        let r = try #require(vm.lastRestore)
        #expect(r.restored.count == 4)
        #expect(r.skipped == [conflict])
        #expect(vm.selectedSession?.status == .restorable)   // 건너뛴 1개가 남아 있음
    }

    @Test func restoreCheckedItemsOnly() async throws {
        let vm = HistoryViewModel(engine: fastEngine(), pathExists: { _ in false })
        await vm.load(retentionDays: 30)
        let session = try #require(vm.selectedSession)
        vm.toggleChecked(session.items[0])
        vm.requestRestoreChecked()
        #expect(vm.restoreRequest?.items.count == 1)
        await vm.performRestore()
        #expect(vm.lastRestore?.restored.count == 1)
        #expect(vm.checkedItems.isEmpty)
    }

    @Test func missingItemsAreNotRestorable() async throws {
        let vm = HistoryViewModel(engine: fastEngine(), pathExists: { _ in false })
        await vm.load(retentionDays: 30)
        let docker = try #require(vm.sessions.first { $0.targetName == "Docker" })
        #expect(docker.status == .partiallyRestorable)
        #expect(vm.restorableItems(of: docker).count == 3)
        let zoom = try #require(vm.sessions.first { $0.targetName == "Zoom" })
        #expect(vm.restorableItems(of: zoom).isEmpty)
    }

    @Test func purgeOnlyAfterExplicitCall() async {
        let vm = HistoryViewModel(engine: fastEngine(), pathExists: { _ in false })
        await vm.load(retentionDays: 30)
        #expect(!vm.expiredSessionIDs.isEmpty)
        _ = await vm.purgeExpired(retentionDays: 30)
        #expect(vm.expiredSessionIDs.isEmpty)
    }
}

@Suite("Korean particles")
struct JosaTests {
    @Test func finalConsonant() {
        #expect(Josa.hasFinalConsonant("Excel"))
        #expect(Josa.hasFinalConsonant("Chrome"))
        #expect(Josa.hasFinalConsonant("Outlook"))
        #expect(!Josa.hasFinalConsonant("Word"))
        #expect(!Josa.hasFinalConsonant("PowerPoint"))
        #expect(Josa.hasFinalConsonant("슬랙"))
        #expect(!Josa.hasFinalConsonant("워드"))
        #expect(Josa.endsWithRieul("“Excel”"))
    }
}
