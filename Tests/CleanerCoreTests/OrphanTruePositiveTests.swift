import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

/// 고아로 찾아야 하는 케이스 (plan.md 9장 "고아 스캔 정탐 테스트"의 픽스처 버전)
@Suite struct OrphanTruePositiveTests {
    @Test func brokenLaunchAgentIsHighSelectedWithService() async throws {
        let h = try OrphanHarness()
        let agent = try h.fx.makeLaunchPlist(at: h.fx.home("Library/LaunchAgents/com.gonecorp.gone.agent.plist"),
                                             label: "com.gonecorp.gone.agent",
                                             arguments: ["/Applications/Gone.app/Contents/MacOS/agent", "--background"],
                                             keepAlive: true)
        let daemon = try h.fx.makeLaunchPlist(at: h.fx.root("Library/LaunchDaemons/com.gonecorp.gone.helper.plist"),
                                              label: "com.gonecorp.gone.helper",
                                              program: "/Library/PrivilegedHelperTools/com.gonecorp.gone.helper")
        let report = try await h.scan()
        let a = try #require(report.item(agent))
        #expect(a.confidence == .high)
        #expect(a.isSelected)
        #expect(a.category == .launchAgent)
        #expect(a.launchService == LaunchServiceRef(label: "com.gonecorp.gone.agent", domain: .user, plistURL: agent))
        #expect(a.evidence.contains { $0.detail == "실행 파일 /Applications/Gone.app/Contents/MacOS/agent 없음" })

        let d = try #require(report.item(daemon))
        #expect(d.confidence == .high)
        #expect(d.domain == .system)
        #expect(d.launchService?.domain == .system)
        #expect(d.requiresAdmin)

        let g = try #require(report.group(containing: agent))
        #expect(g.displayName == "Gone")
        #expect(!g.nameIsGuess)
        #expect(g.confidence == .high)
        #expect(g.items.count == 2)   // 같은 BID 접두사(com.gonecorp.gone)로 묶임
    }

    @Test func shellWrappedBrokenAgentIsUnwrapped() async throws {
        let h = try OrphanHarness()
        let agent = try h.fx.makeLaunchPlist(at: h.fx.home("Library/LaunchAgents/com.example.wrapped.plist"),
                                             label: "com.example.wrapped",
                                             arguments: ["/bin/sh", "-c", "exec '/Applications/Wrapped App.app/Contents/MacOS/w' --x"])
        let report = try await h.scan()
        let a = try #require(report.item(agent))
        #expect(a.confidence == .high)
        #expect(report.group(containing: agent)?.displayName == "Wrapped App")
    }

    @Test func containerWithUninstalledMetadataBundleIDIsHigh() async throws {
        let h = try OrphanHarness()
        let container = try h.fx.makeContainer(bundleID: "com.example.sandboxed")
        let report = try await h.scan()
        let c = try #require(report.item(container))
        #expect(c.confidence == .high)
        #expect(c.isSelected)
        #expect(c.category == .container)
        #expect(c.evidence.contains { $0.source == .containerMetadata })
    }

    @Test func containerMetadataBeatsFolderName() async throws {
        let h = try OrphanHarness()
        try h.fx.makeApp(name: "Installed", bundleID: "com.example.installed")
        // 폴더명은 설치 앱 BID지만 메타데이터는 삭제된 앱
        let c = h.fx.home("Library/Containers/com.example.installed")
        try h.fx.plist(c.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"),
                       ["MCMMetadataIdentifier": "com.example.removed"])
        let report = try await h.scan()
        #expect(report.item(c)?.confidence == .high)
    }

    @Test func preferencePlistOfUninstalledBundleIDIsMediumUnselected() async throws {
        let h = try OrphanHarness()
        let prefs = try h.fx.file(h.fx.home("Library/Preferences/com.example.uninstalled.plist"))
        let byHost = try h.fx.file(h.fx.home("Library/Preferences/ByHost/com.example.uninstalled.0A1B2C3D-4E5F-6789-ABCD-EF0123456789.plist"))
        let report = try await h.scan()
        let p = try #require(report.item(prefs))
        #expect(p.confidence == .medium)
        #expect(!p.isSelected)
        #expect(p.preferencesDomain == "com.example.uninstalled")
        let b = try #require(report.item(byHost))
        #expect(b.category == .byHostPreferences)
        #expect(report.group(containing: byHost)?.id == report.group(containing: prefs)?.id)
    }

    @Test func slackLikeLeftoversAreGroupedWithCaskName() async throws {
        let h = try OrphanHarness()
        let urls = [
            try h.fx.dir(h.fx.home("Library/Application Support/Slack")),
            try h.fx.dir(h.fx.home("Library/Caches/com.tinyspeck.slackmacgap")),
            try h.fx.dir(h.fx.home("Library/Caches/com.tinyspeck.slackmacgap.ShipIt")),
            try h.fx.file(h.fx.home("Library/Preferences/com.tinyspeck.slackmacgap.plist")),
            try h.fx.dir(h.fx.home("Library/Saved Application State/com.tinyspeck.slackmacgap.savedState")),
            try h.fx.dir(h.fx.home("Library/HTTPStorages/com.tinyspeck.slackmacgap")),
            try h.fx.dir(h.fx.home("Library/Logs/Slack")),
        ]
        let report = try await h.scan()
        #expect(report.groups.count == 1)
        let g = try #require(report.groups.first)
        #expect(g.displayName == "Slack")
        #expect(g.bundleID == "com.tinyspeck.slackmacgap")
        #expect(g.id == "bid:com.tinyspeck.slackmacgap")
        #expect(Set(g.items.map(\.path)) == Set(urls.map(\.standardizedFileURL.path)))
        // BID 근거만 있으므로 보통, 이름 기반은 낮음 — 고아 스캔에서는 기본 선택하지 않는다
        #expect(g.confidence == .medium)
        #expect(g.items.allSatisfy { !$0.isSelected })
        #expect(report.item(urls[0])?.confidence == .low)
    }

    @Test func leftoversWithBrokenAgentArePromotedAndNamed() async throws {
        let h = try OrphanHarness()
        let agent = try h.fx.makeLaunchPlist(at: h.fx.home("Library/LaunchAgents/com.foocorp.editor.updater.plist"),
                                             label: "com.foocorp.editor.updater",
                                             arguments: ["/Applications/Foo Editor.app/Contents/MacOS/updater"])
        let caches = try h.fx.dir(h.fx.home("Library/Caches/com.foocorp.editor"))
        let prefs = try h.fx.file(h.fx.home("Library/Preferences/com.foocorp.editor.plist"))
        let support = try h.fx.dir(h.fx.home("Library/Application Support/Foo Editor"))
        let report = try await h.scan()
        #expect(report.groups.count == 1)
        let g = try #require(report.groups.first)
        #expect(g.displayName == "Foo Editor")
        #expect(g.confidence == .high)
        #expect(report.item(agent)?.isSelected == true)
        for url in [caches, prefs] {
            let item = try #require(report.item(url))
            #expect(item.confidence == .high)
            #expect(item.isSelected)
            #expect(item.evidence.contains { $0.detail == "같은 앱의 다른 항목에서 높은 근거 발견" })
        }
        // 이름 기반은 승격하지 않는다
        #expect(report.item(support)?.confidence == .low)
        #expect(report.item(support)?.isSelected == false)
    }

    @Test func receiptWhoseAppIsGoneIsHigh() async throws {
        let h = try OrphanHarness()
        try h.addPackage("com.example.tool.pkg", files: [
            "Applications/Tool.app", "Applications/Tool.app/Contents", "Applications/Tool.app/Contents/Info.plist",
            "Library/LaunchDaemons/com.example.tool.helper.plist",
            "Library/Application Support/ToolCo", "Library/Application Support/ToolCo/data.db",
            "Library/Application Support/SharedVendor/common.db",
        ])
        try h.addPackage("com.example.other.pkg", files: [
            "Applications/Other.app", "Applications/Other.app/Contents/Info.plist",
            "Library/Application Support/SharedVendor/common.db",
        ])
        try h.fx.makeApp(name: "Other", bundleID: "com.example.other")
        let daemon = try h.fx.makeLaunchPlist(at: h.fx.root("Library/LaunchDaemons/com.example.tool.helper.plist"),
                                              label: "com.example.tool.helper", program: "/usr/local/bin/still-here")
        try h.fx.file(h.fx.root("usr/local/bin/still-here"))
        let support = try h.fx.file(h.fx.root("Library/Application Support/ToolCo/data.db")).deletingLastPathComponent()
        let shared = try h.fx.file(h.fx.root("Library/Application Support/SharedVendor/common.db")).deletingLastPathComponent()
        let report = try await h.scan()

        let receipt = h.fx.root("private/var/db/receipts/com.example.tool.pkg.plist")
        let r = try #require(report.item(receipt))
        #expect(r.category == .receipt)
        #expect(r.confidence == .high)
        #expect(r.isSelected)
        #expect(r.evidence.contains { $0.source == .receipt && $0.detail.contains("/Applications/Tool.app") })
        let d = try #require(report.item(daemon))
        #expect(d.confidence == .high)
        #expect(d.launchService == LaunchServiceRef(label: "com.example.tool.helper", domain: .system, plistURL: daemon))
        #expect(report.item(support)?.confidence == .high)
        // 다른 패키지와 공유하는 파일은 영수증 근거로 잡지 않는다
        #expect(report.item(shared)?.evidence.contains { $0.source == .receipt } != true)
        // 앱이 남아 있는 패키지는 판정하지 않는다
        #expect(!report.contains(h.fx.root("private/var/db/receipts/com.example.other.pkg.plist")))

        let g = try #require(report.group(containing: receipt))
        #expect(g.displayName == "Tool")
        #expect(g.items.contains { $0.path == support.standardizedFileURL.path })
        #expect(g.items.contains { $0.path == daemon.standardizedFileURL.path })
    }

    @Test func homebrewCaskroomRecordWithoutAppIsHighWithAdvisory() async throws {
        let h = try OrphanHarness()
        let caskroom = h.fx.root("opt/homebrew/Caskroom/time-out")
        let receipt: [String: Any] = [
            "uninstall_artifacts": [
                ["uninstall": [["quit": "com.dejal.timeout"]]],
                ["app": ["Time Out.app"]],
                ["zap": [["trash": ["~/Library/Caches/com.dejal.timeout", "~/Library/Preferences/com.dejal.timeout.plist"]]]],
            ],
        ]
        try h.fx.file(caskroom.appendingPathComponent(".metadata/INSTALL_RECEIPT.json"),
                      text: String(decoding: try JSONSerialization.data(withJSONObject: receipt), as: UTF8.self))
        try h.fx.symlink(caskroom.appendingPathComponent("3.0.4/Time Out.app"), to: URL(fileURLWithPath: "/Applications/Time Out.app"))
        let caches = try h.fx.dir(h.fx.home("Library/Caches/com.dejal.timeout"))
        // 앱이 남아 있는 cask는 판정하지 않는다
        let kept = h.fx.root("opt/homebrew/Caskroom/iterm2")
        try h.fx.symlink(kept.appendingPathComponent("3.5/iTerm.app"), to: URL(fileURLWithPath: "/Applications/iTerm.app"))
        try h.fx.makeApp(name: "iTerm", bundleID: "com.googlecode.iterm2")
        // 앱이 없는 cask(폰트 등)는 판정하지 않는다
        try h.fx.dir(h.fx.root("opt/homebrew/Caskroom/font-foo/1.0"))

        let report = try await h.scan()
        let record = try #require(report.item(caskroom))
        #expect(record.confidence == .high)
        #expect(record.isSelected)
        #expect(record.evidence.contains { $0.source == .homebrewRecord })
        let g = try #require(report.group(containing: caskroom))
        #expect(g.advisories == [.homebrewZap(token: "time-out")])
        #expect(g.displayName == "Time Out")
        #expect(g.bundleID == "com.dejal.timeout")
        #expect(g.items.contains { $0.path == caches.standardizedFileURL.path })
        #expect(report.item(caches)?.confidence == .high)   // 같은 그룹의 High 근거로 승격
        #expect(!report.contains(kept))
        #expect(!report.contains(h.fx.root("opt/homebrew/Caskroom/font-foo")))
    }

    @Test func groupContainerAndScriptsOfUninstalledApp() async throws {
        let h = try OrphanHarness()
        let group = try h.fx.dir(h.fx.home("Library/Group Containers/ABCDE12345.com.example.gonesuite"))
        let scripts = try h.fx.dir(h.fx.home("Library/Application Scripts/com.example.gonesuite"))
        let report = try await h.scan()
        let g = try #require(report.item(group))
        #expect(g.confidence == .medium)
        #expect(!g.isSelected)
        #expect(report.group(containing: group)?.id == report.group(containing: scripts)?.id)
        #expect(report.group(containing: group)?.teamID == "ABCDE12345")
    }

    @Test func tempFolderItemsAreFound() async throws {
        let h = try OrphanHarness()
        let c = try h.fx.dir(h.fx.paths.userCacheDir.appendingPathComponent("com.example.tempy"))
        let t = try h.fx.dir(h.fx.paths.userTempDir.appendingPathComponent("com.example.tempy"))
        let skip = try h.fx.dir(h.fx.paths.userTempDir.appendingPathComponent("TemporaryItems"))
        let report = try await h.scan()
        #expect(report.item(c)?.category == .tempFiles)
        #expect(report.item(t)?.nature == .regenerable)
        #expect(!report.contains(skip))
    }

    @Test func privilegedHelperGroupsWithItsDaemon() async throws {
        let h = try OrphanHarness()
        let helper = try h.fx.file(h.fx.root("Library/PrivilegedHelperTools/com.example.vpn.helper"))
        let daemon = try h.fx.makeLaunchPlist(at: h.fx.root("Library/LaunchDaemons/com.example.vpn.helper.plist"),
                                              label: "com.example.vpn.helper",
                                              program: "/Library/PrivilegedHelperTools/com.example.vpn.helper.missing")
        let report = try await h.scan()
        let g = try #require(report.group(containing: helper))
        #expect(g.items.contains { $0.path == daemon.standardizedFileURL.path })
        #expect(report.item(helper)?.confidence == .high)   // 깨진 데몬과 같은 그룹이라 승격
        #expect(report.item(helper)?.requiresAdmin == true)
    }
}
