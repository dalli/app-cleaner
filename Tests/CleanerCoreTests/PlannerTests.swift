import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

@Suite struct PlannerTests {
    let home = URL(fileURLWithPath: "/fx/home")
    let root = URL(fileURLWithPath: "/fx/root")

    func h(_ rel: String) -> URL { home.appendingPathComponent(rel) }
    func r(_ rel: String) -> URL { root.appendingPathComponent(rel) }

    var identity: AppIdentity {
        AppIdentity(bundleURL: r("Applications/Foo.app"), bundleID: "com.example.foo", name: "Foo",
                    embeddedBundleIDs: ["com.example.foo.helper"],
                    embeddedLaunchServices: [LaunchServiceRef(label: "com.example.foo.daemon", domain: .system,
                                                              plistURL: r("Applications/Foo.app/Contents/Library/LaunchDaemons/d.plist"))])
    }

    func container() -> Candidate {
        let base = h("Library/Containers/com.example.foo")
        return Candidate(url: base, category: .container, confidence: .high, isSelected: true, children: [
            Candidate(url: base.appendingPathComponent("Data/Library/Caches"), category: .containerItem, confidence: .high,
                      nature: .regenerable, isSelected: true),
            Candidate(url: base.appendingPathComponent("Data/Library/Preferences"), category: .containerItem, confidence: .high,
                      isSelected: true),
            Candidate(url: base.appendingPathComponent("Data/Documents"), category: .containerItem, confidence: .high,
                      nature: .userData, isSelected: false),
        ])
    }

    func report(_ candidates: [Candidate], advisories: [Advisory] = []) -> ScanReport {
        ScanReport(identity: identity, candidates: candidates, advisories: advisories, ruleDataVersion: "rules-7")
    }

    @Test func partialContainerSelectionMovesOnlySelectedChildren() {
        let c = container()
        let selected: Set<String> = [c.path, c.children[0].path, c.children[1].path]
        let plan = CleanupPlanner.plan(for: report([c]), selectedPaths: selected, resetPrivacy: false)
        #expect(plan.items.map(\.path) == [c.children[0].path, c.children[1].path])
        #expect(plan.keptItems.map(\.path) == [c.children[2].path])
    }

    @Test func fullySelectedContainerMovesAsOneItem() {
        let c = container()
        let all = Set(c.flattened.map(\.path))
        let plan = CleanupPlanner.plan(for: report([c]), selectedPaths: all, resetPrivacy: false)
        #expect(plan.items.map(\.path) == [c.path])
        #expect(plan.items[0].children.isEmpty)
        #expect(plan.keptItems.isEmpty)

        // 상위 경로만 넘어온 경우도 통째로
        let parentOnly = CleanupPlanner.plan(for: report([c]), selectedPaths: [c.path], resetPrivacy: false)
        #expect(parentOnly.items.map(\.path) == [c.path])

        // 상위는 선택 안 했지만 하위 하나만 선택
        let childOnly = CleanupPlanner.plan(for: report([c]), selectedPaths: [c.children[0].path], resetPrivacy: false)
        #expect(childOnly.items.map(\.path) == [c.children[0].path])
        #expect(childOnly.keptItems.count == 2)
    }

    @Test func protectedItemsAreNeverPlanned() {
        let icloud = Candidate(url: h("Library/Mobile Documents/iCloud~com~example~foo"), category: .iCloudContainer,
                               confidence: .high, isSelected: true)
        let locked = Candidate(url: h("Library/Caches/com.apple.x"), category: .caches, confidence: .high,
                               protection: .appleBundle, isSelected: true)
        // 보호된 하위 항목이 있는 컨테이너는 통째로 옮기지 않는다
        var c = container()
        c.children.append(Candidate(url: c.url.appendingPathComponent("Data/Link"), category: .containerItem, confidence: .high,
                                    protection: .symlinkEscape, isSelected: true))
        let selected = Set([icloud.path, locked.path] + c.flattened.map(\.path))
        let plan = CleanupPlanner.plan(for: report([icloud, locked, c]), selectedPaths: selected, resetPrivacy: false)
        #expect(!plan.items.contains { $0.path == icloud.path || $0.path == locked.path || $0.path == c.path })
        #expect(!plan.items.contains { $0.protection != nil || !$0.isSelectable })
        #expect(plan.items.map(\.path) == c.children.prefix(3).map(\.path))
        #expect(plan.keptItems.map(\.path).contains(icloud.path))
        #expect(plan.keptItems.map(\.path).contains(locked.path))
        #expect(plan.keptItems.map(\.path).contains(c.children[3].path))
    }

    @Test func receiptsBecomePkgForgetAndAreNotMoved() {
        let bom = Candidate(url: r("private/var/db/receipts/com.example.foo.pkg.bom"), category: .receipt, domain: .system,
                            confidence: .high, isSelected: true)
        let plist = Candidate(url: r("private/var/db/receipts/com.example.foo.pkg.plist"), category: .receipt, domain: .system,
                              confidence: .high, isSelected: true)
        let apple = Candidate(url: r("private/var/db/receipts/com.apple.pkg.X.bom"), category: .receipt, domain: .system,
                              confidence: .high, isSelected: true)
        let plan = CleanupPlanner.plan(for: report([bom, plist, apple]), selectedPaths: [bom.path, plist.path, apple.path],
                                       resetPrivacy: false)
        #expect(plan.receiptsToForget == ["com.example.foo.pkg"])
        #expect(plan.items.isEmpty)
        #expect(plan.requiresAdmin)
        #expect(plan.steps.contains(.postProcess))
    }

    @Test func servicesDomainsAndStepsForAppRemoval() {
        let app = Candidate(url: identity.bundleURL, category: .appBundle, domain: .system, confidence: .high, isSelected: true)
        let agentService = LaunchServiceRef(label: "com.example.foo.agent", domain: .user, plistURL: h("Library/LaunchAgents/a.plist"))
        let agent = Candidate(url: h("Library/LaunchAgents/a.plist"), category: .launchAgent, confidence: .high, isSelected: true,
                              launchService: agentService)
        let prefs = Candidate(url: h("Library/Preferences/com.example.foo.plist"), category: .preferences, confidence: .high,
                              isSelected: true, preferencesDomain: "com.example.foo")
        let kept = Candidate(url: h("Library/Caches/com.example.foo"), category: .caches, confidence: .low, isSelected: false)
        let rep = report([app, agent, prefs, kept], advisories: [.keychain(searchTerm: "Foo"), .loginItems])

        let plan = CleanupPlanner.plan(for: rep, selectedPaths: [app.path, agent.path, prefs.path], resetPrivacy: true)
        #expect(plan.kind == .appRemoval)
        #expect(plan.targetName == "Foo" && plan.targetBundleID == "com.example.foo")
        #expect(plan.servicesToStop.map(\.label) == ["com.example.foo.agent", "com.example.foo.daemon"])
        #expect(plan.bundleIDsToTerminate == ["com.example.foo", "com.example.foo.helper"])
        #expect(plan.bundlePathsToTerminate == [identity.bundleURL])
        #expect(plan.preferencesDomains == ["com.example.foo"])
        #expect(plan.resetPrivacy)
        #expect(plan.advisories == [.keychain(searchTerm: "Foo"), .loginItems])
        #expect(plan.ruleDataVersion == "rules-7")
        #expect(plan.keptItems.map(\.path) == [kept.path])
        #expect(plan.steps == [.stopServices, .terminateApps, .flushPreferences, .moveItems, .postProcess])

        // 앱 번들을 남기면 내장 SMAppService 서비스는 중지하지 않는다
        let noApp = CleanupPlanner.plan(for: rep, selectedPaths: [agent.path], resetPrivacy: false)
        #expect(noApp.servicesToStop.map(\.label) == ["com.example.foo.agent"])
        #expect(noApp.steps == [.stopServices, .terminateApps, .moveItems])
    }

    @Test func orphanPlanSkipsTerminationAndPrivacy() {
        let broken = LaunchServiceRef(label: "com.gone.updater", domain: .user, plistURL: h("Library/LaunchAgents/com.gone.updater.plist"))
        let g1 = OrphanGroup(id: "com.gone", displayName: "Gone", nameIsGuess: false, items: [
            Candidate(url: h("Library/LaunchAgents/com.gone.updater.plist"), category: .launchAgent, confidence: .high,
                      isSelected: true, launchService: broken),
            Candidate(url: h("Library/Preferences/com.gone.plist"), category: .preferences, confidence: .medium,
                      isSelected: false, preferencesDomain: "com.gone"),
        ], confidence: .high)
        let rep = OrphanScanReport(groups: [g1], spotlight: .unknown, inventoryAppCount: 10, duration: 1, ruleDataVersion: "o-1")
        let plan = CleanupPlanner.plan(for: rep, selectedPaths: [g1.items[0].path])
        #expect(plan.kind == .orphanCleanup)
        #expect(plan.targetName == CleanupPlanner.orphanTargetName)
        #expect(plan.items.map(\.path) == [g1.items[0].path])
        #expect(plan.servicesToStop == [broken])
        #expect(plan.bundleIDsToTerminate.isEmpty && plan.bundlePathsToTerminate.isEmpty)
        #expect(plan.preferencesDomains.isEmpty)       // 선택하지 않은 plist의 도메인은 지우지 않는다
        #expect(!plan.resetPrivacy)
        #expect(plan.steps == [.stopServices, .moveItems])
        #expect(plan.ruleDataVersion == "o-1")
    }

    @Test func nestedSelectionsAreDeduplicated() {
        let parent = Candidate(url: h("Library/Application Support/Foo"), category: .applicationSupport, confidence: .medium,
                               isSelected: true)
        let nested = Candidate(url: h("Library/Application Support/Foo/Cache"), category: .caches, confidence: .high, isSelected: true)
        let plan = CleanupPlanner.plan(for: report([parent, nested, parent]), selectedPaths: [parent.path, nested.path + "/"],
                                       resetPrivacy: false)
        #expect(plan.items.map(\.path) == [parent.path])
    }
}
