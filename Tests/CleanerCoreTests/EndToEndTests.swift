import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

/// 픽스처(`/var/folders`)와 엔진(`/private/var/folders`)의 표기 차이를 없앤다
private func realPath(_ path: String) -> String {
    guard let r = realpath(path, nil) else { return path }
    defer { free(r) }
    return String(cString: r)
}

/// 통합 시나리오: 인벤토리 → 앱 검사 → 계획 → 실행 → 되돌리기 → 고아 스캔.
/// 모든 동작은 픽스처 안에서만 일어난다 (휴지통은 픽스처의 `~/.Trash`).
@Suite struct EndToEndTests {
    struct World {
        let h: Harness
        let fx: Fixture
        let rules: StaticRuleDataProvider
        let signatures: StubSignatureReader
        let inventory: AppInventory
        let scanner: AppScanner
        let slack: URL

        init() throws {
            let fx = try Fixture()
            let h = try Harness(fx: fx)
            let rules = StaticRuleDataProvider(BundledRuleData.load())
            let signatures = StubSignatureReader()

            // 제거 대상: Slack 유사 앱 + 잔여물
            let slack = try fx.makeApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                                       embedded: [.init("Contents/Frameworks/Slack Helper.app", bundleID: "com.tinyspeck.slackmacgap.helper")])
            signatures.set(SigningInfo(teamID: "BQR82RBBHL", appGroups: ["BQR82RBBHL.com.tinyspeck.slackmacgap"]), for: slack)
            try fx.file(fx.home("Library/Caches/com.tinyspeck.slackmacgap/Cache.db"), bytes: 4096)
            try fx.file(fx.home("Library/Caches/com.tinyspeck.slackmacgap.ShipIt/update.zip"), bytes: 2048)
            try fx.plist(fx.home("Library/Preferences/com.tinyspeck.slackmacgap.plist"), ["a": 1])
            try fx.file(fx.home("Library/Saved Application State/com.tinyspeck.slackmacgap.savedState/data.data"), bytes: 64)
            try fx.file(fx.home("Library/Application Support/Slack/Local Storage/leveldb.ldb"), bytes: 512)
            try fx.file(fx.home("Library/Group Containers/BQR82RBBHL.com.tinyspeck.slackmacgap/x.plist"), bytes: 32)
            try fx.makeLaunchPlist(at: fx.home("Library/LaunchAgents/com.tinyspeck.slackmacgap.ShipIt.plist"),
                                   label: "com.tinyspeck.slackmacgap.ShipIt",
                                   arguments: [slack.appendingPathComponent("Contents/Frameworks/Squirrel.framework/Resources/ShipIt").path],
                                   keepAlive: true)

            // 남아 있어야 하는 다른 앱 (Office 공유 그룹 컨테이너)
            let word = try fx.makeApp(name: "Microsoft Word", bundleID: "com.microsoft.Word")
            let excel = try fx.makeApp(name: "Microsoft Excel", bundleID: "com.microsoft.Excel")
            for app in [word, excel] {
                signatures.set(SigningInfo(teamID: "UBF8T346G9", appGroups: ["UBF8T346G9.Office"]), for: app)
            }
            try fx.file(fx.home("Library/Group Containers/UBF8T346G9.Office/MeContact.plist"), bytes: 128)

            let inventory = AppInventory(paths: fx.paths, runner: h.runner, signatureReader: signatures,
                                         isRunning: { _ in false }, isMounted: { _ in true }, lastUsed: { _ in nil },
                                         launchServices: { _ in [] })
            let scanner = AppScanner.standard(paths: fx.paths, runner: h.runner, signatureReader: signatures, rules: rules,
                                              safety: SafetyGuard(paths: fx.paths))
            self.h = h
            self.fx = fx
            self.rules = rules
            self.signatures = signatures
            self.inventory = inventory
            self.scanner = scanner
            self.slack = slack
        }
    }

    @Test func removeThenRestoreRoundTrip() async throws {
        let w = try World()
        let snapshot = try await w.inventory.build()
        #expect(snapshot.apps.contains { $0.bundleID == "com.microsoft.Excel" })

        let report = try await w.scanner.scan(appAt: w.slack, inventory: snapshot)
        let selected = Set(report.candidates.selectedItems.map(\.path))
        let selectedReal = Set(selected.map(realPath))
        #expect(selectedReal.contains(realPath(w.slack.path)))
        #expect(selectedReal.contains(realPath(w.fx.home("Library/Caches/com.tinyspeck.slackmacgap").path)))
        #expect(!selectedReal.contains(realPath(w.fx.home("Library/Group Containers/UBF8T346G9.Office").path)))

        let plan = CleanupPlanner.plan(for: report, selectedPaths: selected, resetPrivacy: false)
        #expect(plan.steps.first == .stopServices)
        #expect(plan.servicesToStop.contains { $0.label == "com.tinyspeck.slackmacgap.ShipIt" })

        let (result, _) = await w.h.execute(plan)
        #expect(result.failures.isEmpty, "\(result.failures)")
        #expect(!w.fx.exists(w.slack))
        #expect(!w.fx.exists(w.fx.home("Library/Caches/com.tinyspeck.slackmacgap")))
        #expect(w.fx.exists(w.fx.home("Library/Group Containers/UBF8T346G9.Office/MeContact.plist")))
        // bootout이 이동보다 먼저
        let bootout = try #require(w.h.log.index(of: "launchctl bootout"))
        let firstTrash = try #require(w.h.log.index(of: "trash"))
        #expect(bootout < firstTrash)

        // 되돌리기
        let sessions = await w.h.journal.sessions()
        #expect(sessions.first?.id == result.sessionID)
        let restore = await w.h.journal.restore(sessionID: result.sessionID, itemPaths: nil, options: RestoreOptions(reregisterServices: false))
        #expect(restore.failures.isEmpty, "\(restore.failures)")
        #expect(w.fx.exists(w.slack.appendingPathComponent("Contents/Info.plist")))
        #expect(w.fx.exists(w.fx.home("Library/Caches/com.tinyspeck.slackmacgap/Cache.db")))
        #expect(await w.h.journal.sessions().first?.status == .restored)
    }

    @Test func orphanScanFindsLeftoversOfAppDeletedByHand() async throws {
        let w = try World()
        // 사용자가 .app만 휴지통에 버린 상황
        try FileManager.default.removeItem(at: w.slack)

        let orphans = OrphanScanner(paths: w.fx.paths, runner: w.h.runner, inventory: w.inventory, rules: w.rules,
                                    safety: SafetyGuard(paths: w.fx.paths), classifier: DataNatureClassifier(),
                                    keepList: InMemoryKeepList(), launchServices: { _ in [] }, isMounted: { _ in true },
                                    now: { Date().addingTimeInterval(30 * 24 * 3600) })
        let report = try await orphans.scan(options: OrphanScanOptions(useCachedInventory: false), progress: { _ in })
        let slackGroup = try #require(report.groups.first { $0.bundleID?.hasPrefix("com.tinyspeck.slackmacgap") == true })
        #expect(slackGroup.confidence == .high)
        // 깨진 LaunchAgent는 높음 + 기본 선택 + bootout 대상
        let agent = try #require(slackGroup.items.first { $0.category == .launchAgent })
        #expect(agent.isSelected)
        #expect(agent.launchService?.label == "com.tinyspeck.slackmacgap.ShipIt")
        // 설치된 Office 데이터는 고아가 아니다
        #expect(!report.groups.flatMap(\.items).contains { $0.path.contains("UBF8T346G9.Office") })

        let selected = Set(report.groups.flatMap(\.items).flatMap(\.flattened).filter(\.isSelected).map(\.path))
        let plan = CleanupPlanner.plan(for: report, selectedPaths: selected)
        let (result, _) = await w.h.execute(plan)
        #expect(result.failures.isEmpty, "\(result.failures)")
        #expect(!w.fx.exists(w.fx.home("Library/LaunchAgents/com.tinyspeck.slackmacgap.ShipIt.plist")))
    }
}
