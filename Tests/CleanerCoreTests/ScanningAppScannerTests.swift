import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

@Suite struct ScanningAppScannerTests {
    /// Slack과 비슷한 가짜 앱 전체 검사 (plan.md 9장 픽스처 테스트)
    @Test func slackLikeEndToEnd() async throws {
        let fx = try Fixture()
        let bid = "com.tinyspeck.slackmacgap"
        let app = try fx.makeApp(name: "Slack", bundleID: bid, embedded: [
            .init("Contents/Frameworks/Slack Helper.app", bundleID: "\(bid).helper"),
            .init("Contents/Frameworks/Slack Helper (Renderer).app", bundleID: "\(bid).helper.Renderer"),
        ])
        let sig = StubSignatureReader()
        sig.set(SigningInfo(teamID: "BQR82RBBHL", appGroups: ["BQR82RBBHL.\(bid)"]), for: app)

        let container = try fx.makeContainer(bundleID: bid)
        let caches = try fx.file(fx.home("Library/Caches/\(bid)/Cache.db"), bytes: 4096).deletingLastPathComponent()
        let shipIt = try fx.dir(fx.home("Library/Caches/\(bid).ShipIt"))
        let support = try fx.file(fx.home("Library/Application Support/Slack/Local Storage/leveldb/000003.log"), bytes: 2048)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let prefs = try fx.file(fx.home("Library/Preferences/\(bid).plist"))
        let byHost = try fx.file(fx.home("Library/Preferences/ByHost/\(bid).ShipIt.6F3A-11AA.plist"))
        let saved = try fx.dir(fx.home("Library/Saved Application State/\(bid).savedState"))
        let http = try fx.dir(fx.home("Library/HTTPStorages/\(bid)"))
        let logs = try fx.dir(fx.home("Library/Logs/Slack"))
        let group = try fx.dir(fx.home("Library/Group Containers/BQR82RBBHL.\(bid)/Library/Caches"))
            .deletingLastPathComponent().deletingLastPathComponent()
        let agent = try fx.makeLaunchPlist(at: fx.home("Library/LaunchAgents/\(bid).helper.plist"), label: "\(bid).helper",
                                           arguments: [app.appendingPathComponent("Contents/MacOS/Slack").path, "--startup"], keepAlive: true)
        let diag = try fx.file(fx.home("Library/Logs/DiagnosticReports/Slack-2026-10-01-120000.ips"))
        let unrelated = try fx.dir(fx.home("Library/Caches/com.tinyspeck.slackmacgapx"))

        let runner = StubCommandRunner()
        let downloadsCopy = fx.home("Downloads/Slack.app")
        runner.on("mdfind", stdout: "\(app.path)\n\(downloadsCopy.path)\n\(app.path)/Contents/Frameworks/Slack Helper.app\n")
        runner.on("systemextensionsctl", stdout: """
        1 extension(s)
        --- com.apple.system_extension.network_extension
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tBQR82RBBHL\t\(bid).netext (4.0/400)\tSlack Network\t[activated enabled]
        *\t*\tZZZZZ99999\tcom.other.netext (1.0/1)\tOther\t[activated enabled]
        """)
        let slackCask = try #require(ScanKit.bundled.casks.first { $0.token == "slack" })
        let inventory = InventorySnapshot(apps: [
            ScanKit.inventoryApp("Slack", bundleID: bid, teamID: "BQR82RBBHL", groups: ["BQR82RBBHL.\(bid)"], in: fx),
            ScanKit.inventoryApp("Microsoft Excel", bundleID: "com.microsoft.Excel", teamID: "UBF8T346G9", groups: ["UBF8T346G9.Office"], in: fx),
        ])
        let scanner = ScanKit.scanner(fx, runner: runner, signatures: sig, casks: [slackCask],
                                      isRunning: { $0 == "com.tinyspeck.slackmacgap.helper" }, hasFullDiskAccess: { false })

        let started = Date()
        let report = try await scanner.scan(appAt: app, inventory: inventory)
        let elapsed = Date().timeIntervalSince(started)
        // 성능 목표(plan.md 8.3, 앱 1개 2초)는 병렬 테스트 부하에서 벽시계로 판정하면 흔들린다.
        // `APPCLEANER_PERF=1 ./scripts/test.sh --filter slackLikeEndToEnd`처럼 단독 실행할 때만 확인한다.
        if ProcessInfo.processInfo.environment["APPCLEANER_PERF"] == "1" {
            #expect(elapsed < 2.0, "앱 1개 검사 2초 목표 (plan.md 8.3)")
        }
        let c = report.candidates

        func expectItem(_ url: URL, _ category: ItemCategory, _ confidence: Confidence, selected: Bool,
                        sourceLocation: SourceLocation = #_sourceLocation) throws -> Candidate {
            let item = try #require(c.item(url), "\(url.lastPathComponent)", sourceLocation: sourceLocation)
            #expect(item.category == category, "\(url.lastPathComponent)", sourceLocation: sourceLocation)
            #expect(item.confidence == confidence, "\(url.lastPathComponent)", sourceLocation: sourceLocation)
            #expect(item.isSelected == selected, "\(url.lastPathComponent)", sourceLocation: sourceLocation)
            return item
        }

        let bundle = try expectItem(app, .appBundle, .high, selected: true)
        #expect(c.first?.url == bundle.url, "앱 본체가 맨 앞")
        let cont = try expectItem(container, .container, .high, selected: true)
        #expect(!cont.children.isEmpty)
        #expect(cont.children.allSatisfy { $0.isSelected })
        let cache = try expectItem(caches, .caches, .high, selected: true)
        #expect(Set(cache.evidence.map(\.source)) == [.bundleIdentifier, .homebrewZap], "zap Medium + BID High 병합")
        #expect((cache.size ?? 0) > 0)
        #expect(cache.fileCount == 1)
        _ = try expectItem(shipIt, .caches, .high, selected: true)
        _ = try expectItem(support, .applicationSupport, .medium, selected: true)
        let p = try expectItem(prefs, .preferences, .high, selected: true)
        #expect(p.preferencesDomain == bid)
        _ = try expectItem(byHost, .byHostPreferences, .high, selected: true)
        _ = try expectItem(saved, .savedState, .high, selected: true)
        _ = try expectItem(http, .httpStorage, .high, selected: true)
        _ = try expectItem(logs, .logs, .medium, selected: true)
        let g = try expectItem(group, .groupContainer, .high, selected: true)
        #expect(!g.share.isShared, "인벤토리의 Slack 자신은 공유자로 세지 않는다")
        let a = try expectItem(agent, .launchAgent, .high, selected: true)
        #expect(a.launchService == LaunchServiceRef(label: "\(bid).helper", domain: .user, plistURL: a.url))
        #expect(a.nature == .settings)
        _ = try expectItem(diag, .diagnosticReports, .low, selected: false)
        #expect(c.item(unrelated) == nil)

        // 모든 항목은 픽스처 안
        #expect(c.paths.allSatisfy { $0.hasPrefix(fx.base.standardizedFileURL.path) })

        // 경고 (S2 배너)
        #expect(report.warnings.contains(.appRunning))
        #expect(report.warnings.contains(.otherCopies([downloadsCopy.standardizedFileURL])))
        #expect(report.warnings.contains(.noFullDiskAccess))
        #expect(!report.warnings.contains(.inventoryUnavailable))
        // 안내 (S4)
        #expect(report.advisories.contains(.loginItems))
        #expect(report.advisories.contains(.keychain(searchTerm: "Slack")))
        #expect(report.advisories.contains(.systemExtension(identifier: "\(bid).netext")))
        #expect(!report.advisories.contains(.systemExtension(identifier: "com.other.netext")))
        #expect(report.ruleDataVersion == "test-rules")
        #expect(report.identity.teamID == "BQR82RBBHL")

        // mdfind 질의는 BID 하나만 담은 인자
        let md = try #require(runner.calls.first { $0.executable == "/usr/bin/mdfind" })
        #expect(md.arguments == ["kMDItemCFBundleIdentifier == '\(bid)'"])

        // 검사는 아무것도 옮기지 않는다
        for u in [app, container, caches, prefs, agent] { #expect(fx.exists(u)) }
    }

    @Test func inventoryUnavailableWarningAndDefaults() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Foo", bundleID: "com.example.foo")
        let sig = StubSignatureReader()
        sig.set(SigningInfo(teamID: "ABCDE12345", appGroups: ["ABCDE12345.foo"]), for: app)
        let group = try fx.dir(fx.home("Library/Group Containers/ABCDE12345.foo"))
        let caches = try fx.dir(fx.home("Library/Caches/com.example.foo"))
        let report = try await ScanKit.scanner(fx, signatures: sig).scan(appAt: app, inventory: nil)
        #expect(report.warnings.contains(.inventoryUnavailable))
        #expect(report.candidates.item(group)?.isSelected == false)
        #expect(report.candidates.item(group)?.notes.contains(SelectionPolicy.Notes.inventoryUnknown) == true)
        #expect(report.candidates.item(caches)?.isSelected == true)
    }

    @Test func safetyVerdictsDropOrProtect() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Foo", bundleID: "com.example.foo")
        let blockedDir = try fx.dir(fx.home("Library/Caches/com.example.foo"))
        let appleish = try fx.dir(fx.home("Library/Application Support/com.example.foo"))
        let fine = try fx.dir(fx.home("Library/HTTPStorages/com.example.foo"))
        let safety = BlockingSafety(protectedPrefix: blockedDir, appleBundlePath: appleish)
        let report = try await ScanKit.scanner(fx, safety: safety).scan(appAt: app, inventory: InventorySnapshot(apps: []))
        #expect(report.candidates.item(blockedDir) == nil)
        let p = try #require(report.candidates.item(appleish))
        #expect(p.protection == .appleBundle)
        #expect(!p.isSelected)
        #expect(p.notes.contains(.verbatim("Apple 항목이라 옮기지 않습니다")))
        #expect(report.candidates.item(fine)?.isSelected == true)
    }

    @Test func refusesAppleAndSelfApps() async throws {
        let fx = try Fixture()
        let apple = try fx.makeApp(name: "iMovie", bundleID: "com.apple.iMovieApp")
        await #expect(throws: ScanError.appleApp(bundleID: "com.apple.iMovieApp")) {
            try await ScanKit.scanner(fx).scan(appAt: apple, inventory: nil)
        }
        let me = try fx.makeApp(name: "AppCleaner", bundleID: fx.paths.selfBundleID)
        await #expect(throws: ScanError.selfApp(bundleID: fx.paths.selfBundleID)) {
            try await ScanKit.scanner(fx).scan(appAt: me, inventory: nil)
        }
    }

    @Test func homebrewInstalledAppGetsZapAdvisoryAndUserAppsDir() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", in: fx.home("Applications"))
        try fx.dir(fx.root("opt/homebrew/Caskroom/slack/4.41"))
        let slackCask = try #require(ScanKit.bundled.casks.first { $0.token == "slack" })
        let report = try await ScanKit.scanner(fx, casks: [slackCask]).scan(appAt: app, inventory: InventorySnapshot(apps: []))
        #expect(report.identity.source == .homebrew)
        #expect(report.advisories.contains(.homebrewZap(token: "slack")))
        let bundle = try #require(report.candidates.item(app))
        #expect(bundle.domain == .user)
    }

    @Test func kernelExtensionAdvisory() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Driverly", bundleID: "com.example.driverly")
        let kext = try fx.plist(fx.root("Library/Extensions/Driverly.kext/Contents/Info.plist"),
                                ["CFBundleIdentifier": "com.example.driverly.kext"])
            .deletingLastPathComponent().deletingLastPathComponent()
        let report = try await ScanKit.scanner(fx).scan(appAt: app, inventory: InventorySnapshot(apps: []))
        let k = try #require(report.candidates.item(kext))
        #expect(!k.isSelected)
        #expect(!k.isSelectable)
        #expect(report.advisories.contains(.kernelExtension(path: k.url.path)))
    }

    @Test func nestedCandidatesAreNotMovedTwice() {
        let parent = Candidate(url: URL(fileURLWithPath: "/x/Library/Application Support/Vendor"), category: .applicationSupport,
                               confidence: .medium, isSelected: true)
        let child = Candidate(url: URL(fileURLWithPath: "/x/Library/Application Support/Vendor/App"), category: .applicationSupport,
                              confidence: .medium, isSelected: true)
        let out = AppScanner.deselectNestedSelections([parent, child])
        #expect(out[0].isSelected)
        #expect(!out[1].isSelected)
        #expect(out[1].notes.first == EngineText(.movedWithParent, "Vendor"))

        let low = Candidate(url: parent.url, category: .applicationSupport, confidence: .low)
        let kept = AppScanner.removeCoveredDescendants([low, child])
        #expect(kept.count == 2, "상위가 더 낮은 신뢰도면 하위를 남긴다")
        let high = Candidate(url: parent.url, category: .applicationSupport, confidence: .high)
        #expect(AppScanner.removeCoveredDescendants([high, child]).count == 1)
    }
}

@Suite struct ScanningWithSafetyGuardTests {
    /// 실제 SafetyGuard와 조립했을 때: 일반 항목·영수증 허용, iCloud는 보호 항목으로 남고, 링크 우회는 제외
    @Test func realSafetyGuardVerdicts() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Foo", bundleID: "com.example.foo")
        let caches = try fx.dir(fx.home("Library/Caches/com.example.foo"))
        let icloud = try fx.dir(fx.home("Library/Mobile Documents/iCloud~com~example~foo"))
        try fx.dir(fx.root("System/Library/Secret/com.example.foo"))
        // 상위 구성요소가 링크라 실제로는 보호 위치(/System) 안을 가리키는 후보
        try fx.symlink(fx.home("Library/Application Support/Vendorish"), to: fx.root("System/Library/Secret"))
        let escaped = fx.home("Library/Application Support/Vendorish/com.example.foo")
        let receipt = try fx.file(fx.root("private/var/db/receipts/com.example.foo.pkg.bom"))
        let runner = StubCommandRunner()
        runner.on("pkgutil") { args in
            switch args.first {
            case "--file-info": return CommandOutput(status: 0, stdout: Data("pkgid: com.example.foo.pkg\n".utf8))
            case "--pkg-info": return CommandOutput(status: 0, stdout: Data("volume: /\nlocation: \n".utf8))
            case "--files": return CommandOutput(status: 0, stdout: Data("Applications/Foo.app\n".utf8))
            default: return CommandOutput(status: 1, stdout: Data())
            }
        }
        let cask = HomebrewCask(token: "foo", apps: ["Foo.app"], bundleIDs: ["com.example.foo"],
                                zap: ["~/Library/Application Support/Vendorish/com.example.foo"])
        let report = try await ScanKit.scanner(fx, runner: runner, casks: [cask], safety: SafetyGuard(paths: fx.paths))
            .scan(appAt: app, inventory: InventorySnapshot(apps: []))
        let c = report.candidates
        #expect(c.item(app)?.isSelected == true)
        #expect(c.item(caches)?.isSelected == true)
        let i = try #require(c.item(icloud))
        #expect(i.protection == .iCloudData)
        #expect(!i.isSelected)
        #expect(c.item(escaped) == nil, "링크를 따라가면 보호 위치인 후보는 제외")
        let r = try #require(c.item(receipt))
        #expect(r.category == .receipt)
        #expect(r.isSelected)
    }
}
