import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

@Suite struct DiscoveryLaunchPlistTests {
    @Test func matchesByNameLabelAndExecutable() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Foo", bundleID: "com.example.foo")
        let id = AppIdentity(bundleURL: app, bundleID: "com.example.foo", name: "Foo",
                             embeddedLaunchServices: [LaunchServiceRef(label: "com.example.foo.smagent", domain: .user)])
        let agents = fx.home("Library/LaunchAgents")
        let byName = try fx.makeLaunchPlist(at: agents.appendingPathComponent("com.example.foo.updater.plist"),
                                            label: "com.example.foo.updater", program: "/usr/local/bin/foo-updater")
        let byExe = try fx.makeLaunchPlist(at: agents.appendingPathComponent("org.unrelated-name.plist"), label: "org.unrelated-name",
                                           arguments: ["/bin/sh", "-c", "exec '\(app.path)/Contents/MacOS/Foo' --background"],
                                           keepAlive: true)
        let byEmbeddedLabel = try fx.makeLaunchPlist(at: agents.appendingPathComponent("x.plist"), label: "com.example.foo.smagent",
                                                     program: "/opt/x")
        let shellFailed = try fx.makeLaunchPlist(at: agents.appendingPathComponent("com.example.foo.sync.plist"),
                                                 label: "com.example.foo.sync", arguments: ["/bin/bash", "-c", "foo-cli --sync"])
        let unrelated = try fx.makeLaunchPlist(at: agents.appendingPathComponent("com.example.foobar.plist"), label: "com.example.foobar",
                                               program: "/Applications/FooBar.app/Contents/MacOS/FooBar")
        let systemAgent = try fx.makeLaunchPlist(at: fx.root("Library/LaunchAgents/com.example.foo.menu.plist"),
                                                 label: "com.example.foo.menu", program: app.appendingPathComponent("Contents/MacOS/Foo").path)

        let found = try LaunchPlistSource(paths: fx.paths).candidates(for: id)
        let n = try #require(found.item(byName))
        #expect(n.confidence == .high)
        #expect(n.category == .launchAgent)
        #expect(n.launchService == LaunchServiceRef(label: "com.example.foo.updater", domain: .user, plistURL: n.url))
        let e = try #require(found.item(byExe))
        #expect(e.confidence == .high)
        #expect(e.evidence.contains { $0.source == .launchPlist })
        #expect(found.item(byEmbeddedLabel)?.evidence.contains { $0.source == .embeddedLaunchPlist } == true)
        let s = try #require(found.item(shellFailed))
        #expect(s.confidence == .low)
        #expect(found.item(unrelated) == nil)
        let sys = try #require(found.item(systemAgent))
        #expect(sys.domain == .system)
        // /Library/LaunchAgents는 사용자 GUI 세션에서 실행되므로 bootout은 gui/<uid> 도메인
        #expect(sys.launchService?.domain == .user)
    }

    @Test func privilegedHelperPairsWithLaunchDaemon() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Foo", bundleID: "com.example.foo")
        let id = AppIdentity(bundleURL: app, bundleID: "com.example.foo", name: "Foo")
        let helper = try fx.file(fx.root("Library/PrivilegedHelperTools/com.example.foo.helper"), bytes: 64)
        // 데몬 파일명·Label이 BID와 달라도 이 앱의 헬퍼를 실행하면 High
        let daemon = try fx.makeLaunchPlist(at: fx.root("Library/LaunchDaemons/foo-privileged.plist"), label: "foo-privileged",
                                            program: helper.path)
        let otherHelper = try fx.file(fx.root("Library/PrivilegedHelperTools/com.other.helper"), bytes: 8)

        let found = try LaunchPlistSource(paths: fx.paths).candidates(for: id)
        let d = try #require(found.item(daemon))
        #expect(d.category == .launchDaemon)
        #expect(d.confidence == .high)
        #expect(d.launchService?.domain == .system)
        let h = try #require(found.item(helper))
        #expect(h.category == .privilegedHelper)
        #expect(h.domain == .system)
        #expect(h.launchService?.label == "foo-privileged")
        #expect(found.item(otherHelper) == nil)
    }
}

@Suite struct DiscoveryReceiptTests {
    /// 가짜 pkgutil: --pkg-info, --files, --file-info
    static func pkgutil(files: [String], owners: [String: [String]], location: String = "") -> StubCommandRunner {
        let runner = StubCommandRunner()
        runner.on("pkgutil") { args in
            switch args.first {
            case "--pkg-info":
                return CommandOutput(status: 0, stdout: Data("package-id: \(args[1])\nversion: 1.0\nvolume: /\nlocation: \(location)\ninstall-time: 1\n".utf8))
            case "--files":
                return CommandOutput(status: 0, stdout: Data(files.joined(separator: "\n").utf8))
            case "--file-info":
                let path = args[1]
                let ids = owners[path] ?? ["com.example.pkgd"]
                return CommandOutput(status: 0, stdout: Data((["volume: /", "path: \(path)", ""] + ids.map { "pkgid: \($0)" }).joined(separator: "\n").utf8))
            default:
                return CommandOutput(status: 1, stdout: Data())
            }
        }
        return runner
    }

    @Test func onlyExclusivelyOwnedItems() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Pkgd", bundleID: "com.example.pkgd")
        try fx.file(fx.root("Library/Application Support/Pkgd/data.bin"))
        try fx.file(fx.root("Library/Application Support/SharedVendor/pkgd-only.dat"))
        try fx.file(fx.root("Library/Application Support/SharedVendor/common.dat"))
        try fx.makeLaunchPlist(at: fx.root("Library/LaunchDaemons/com.example.pkgd.daemon.plist"), label: "com.example.pkgd.daemon",
                               program: "/Library/PrivilegedHelperTools/com.example.pkgd.helper")
        try fx.file(fx.root("usr/local/bin/pkgd"))
        try fx.file(fx.root("usr/local/bin/shared-tool"))
        try fx.file(fx.root("private/var/db/receipts/com.example.pkgd.bom"))
        try fx.file(fx.root("private/var/db/receipts/com.example.pkgd.plist"))

        let files = [
            "Applications", "Applications/Pkgd.app", "Applications/Pkgd.app/Contents", "Applications/Pkgd.app/Contents/Info.plist",
            "Library", "Library/Application Support", "Library/Application Support/Pkgd", "Library/Application Support/Pkgd/data.bin",
            "Library/Application Support/SharedVendor", "Library/Application Support/SharedVendor/pkgd-only.dat",
            "Library/Application Support/SharedVendor/common.dat",
            "Library/LaunchDaemons", "Library/LaunchDaemons/com.example.pkgd.daemon.plist",
            "usr", "usr/local", "usr/local/bin", "usr/local/bin/pkgd", "usr/local/bin/shared-tool",
            "Library/Application Support/Pkgd/../../../etc/passwd", "usr/local/bin/missing-on-disk",
        ]
        let owners: [String: [String]] = [
            "/usr/local/bin/shared-tool": ["com.example.pkgd", "com.other.tools"],
            "/Library/Application Support/SharedVendor": ["com.example.pkgd", "com.other.vendor"],
            "/Library/Application Support/SharedVendor/common.dat": ["com.example.pkgd", "com.other.vendor"],
        ]
        let runner = Self.pkgutil(files: files, owners: owners)
        let id = AppIdentity(bundleURL: app, bundleID: "com.example.pkgd", name: "Pkgd", packageIDs: ["com.example.pkgd"])
        let found = try ReceiptSource(paths: fx.paths, runner: runner).candidates(for: id)

        #expect(found.item(app)?.category == .appBundle)
        #expect(found.item(fx.root("Library/Application Support/Pkgd"))?.confidence == .high)
        #expect(found.item(fx.root("Library/Application Support/SharedVendor/pkgd-only.dat")) != nil)
        let daemon = try #require(found.item(fx.root("Library/LaunchDaemons/com.example.pkgd.daemon.plist")))
        #expect(daemon.category == .launchDaemon)
        #expect(daemon.launchService?.label == "com.example.pkgd.daemon")
        #expect(found.item(fx.root("usr/local/bin/pkgd")) != nil)
        // 공용 디렉토리·다른 영수증과 공유하는 항목은 제외
        for excluded in ["Library/Application Support", "Library/Application Support/SharedVendor",
                         "Library/Application Support/SharedVendor/common.dat", "usr/local/bin/shared-tool", "usr/local/bin",
                         "Library/LaunchDaemons", "Applications", "Library", "etc/passwd"] {
            #expect(found.item(fx.root(excluded)) == nil, "\(excluded)")
        }
        // 영수증 자체
        for ext in ["bom", "plist"] {
            let r = try #require(found.item(fx.root("private/var/db/receipts/com.example.pkgd.\(ext)")))
            #expect(r.category == .receipt)
            #expect(r.domain == .system)
        }
        #expect(found.allSatisfy { $0.evidence.contains { $0.source == .receipt } })
        #expect(runner.calls.allSatisfy { $0.executable == "/usr/sbin/pkgutil" })
    }

    @Test func installLocationIsJoined() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Loc", bundleID: "com.example.loc")
        let runner = Self.pkgutil(files: ["Loc.app", "Loc.app/Contents"], owners: [:], location: "Applications")
        let id = AppIdentity(bundleURL: app, bundleID: "com.example.loc", name: "Loc", packageIDs: ["com.example.pkgd"])
        let found = try ReceiptSource(paths: fx.paths, runner: runner).candidates(for: id)
        #expect(found.item(app)?.category == .appBundle)
    }
}

@Suite struct DiscoveryHomebrewZapTests {
    static let cask = HomebrewCask(
        token: "foo", names: ["Foo"], apps: ["Foo.app"], bundleIDs: ["com.example.foo", "com.example.keystone.agent"],
        zap: [
            "~/Library/Application Support/Foo",
            "~/Library/Caches/com.example.foo*",
            "~/Library/Preferences/com.example.{foo,foo.helper}.plist",
            "~/Library/Caches/*",
            "~/Library/Logs/../../.ssh",
            "~/Library/Saved Application State/com.example.foo.savedState",
            "~/Documents/Foo Projects",
            "/Library/Application Support/Foo",
        ])

    @Test func zapPathsAreCappedAtMediumAndWildcardsLow() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Foo", bundleID: "com.example.foo")
        let id = AppIdentity(bundleURL: app, bundleID: "com.example.foo", name: "Foo")
        try fx.dir(fx.home("Library/Application Support/Foo"))
        try fx.dir(fx.home("Library/Caches/com.example.foo"))
        try fx.dir(fx.home("Library/Caches/com.example.foo.ShipIt"))
        try fx.dir(fx.home("Library/Caches/com.unrelated"))
        try fx.dir(fx.home("Library/Caches/com.example.foox"))
        try fx.file(fx.home("Library/Preferences/com.example.foo.plist"))
        try fx.file(fx.home("Library/Preferences/com.example.foo.helper.plist"))
        try fx.dir(fx.home(".ssh"))
        try fx.dir(fx.home("Documents/Foo Projects"))
        try fx.dir(fx.root("Library/Application Support/Foo"))
        try fx.makeLaunchPlist(at: fx.home("Library/LaunchAgents/com.example.keystone.agent.plist"), label: "com.example.keystone.agent")
        try fx.makeLaunchPlist(at: fx.root("Library/LaunchDaemons/com.example.keystone.agent.plist"), label: "com.example.keystone.agent")

        let found = try HomebrewZapSource(paths: fx.paths, rules: ScanKit.provider(casks: [Self.cask])).candidates(for: id)
        #expect(found.allSatisfy { $0.confidence <= .medium })
        #expect(found.allSatisfy { $0.evidence.allSatisfy { $0.source == .homebrewZap } })
        #expect(found.item(fx.home("Library/Application Support/Foo"))?.confidence == .medium)
        #expect(found.item(fx.home("Library/Caches/com.example.foo"))?.confidence == .low)
        #expect(found.item(fx.home("Library/Caches/com.example.foo.ShipIt"))?.confidence == .low)
        #expect(found.item(fx.home("Library/Caches/com.unrelated")) == nil)
        // `com.example.foo*`라도 점 경계 밖(`com.example.foox`)은 잡지 않는다
        #expect(found.item(fx.home("Library/Caches/com.example.foox")) == nil)
        // 중괄호 펼치기는 와일드카드가 아니다
        #expect(found.item(fx.home("Library/Preferences/com.example.foo.plist"))?.confidence == .medium)
        #expect(found.item(fx.home("Library/Preferences/com.example.foo.plist"))?.preferencesDomain == "com.example.foo")
        #expect(found.item(fx.home("Library/Preferences/com.example.foo.helper.plist")) != nil)
        #expect(found.item(fx.home(".ssh")) == nil)
        // Library 밖 사용자 폴더는 Low
        #expect(found.item(fx.home("Documents/Foo Projects"))?.confidence == .low)
        let sys = try #require(found.item(fx.root("Library/Application Support/Foo")))
        #expect(sys.domain == .system)
        // launchctl 항목 → plist (서비스 정보 포함)
        let agent = try #require(found.item(fx.home("Library/LaunchAgents/com.example.keystone.agent.plist")))
        #expect(agent.category == .launchAgent)
        #expect(agent.confidence == .medium)
        #expect(agent.launchService?.label == "com.example.keystone.agent")
        #expect(found.item(fx.root("Library/LaunchDaemons/com.example.keystone.agent.plist"))?.launchService?.domain == .system)
    }

    @Test func appNameMatchRequiresCompatibleBundleID() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Foo", bundleID: "com.someoneelse.foo")
        try fx.dir(fx.home("Library/Application Support/Foo"))
        let id = AppIdentity(bundleURL: app, bundleID: "com.someoneelse.foo", name: "Foo")
        let found = try HomebrewZapSource(paths: fx.paths, rules: ScanKit.provider(casks: [Self.cask])).candidates(for: id)
        #expect(found.isEmpty)

        let nameOnly = HomebrewCask(token: "foo-legacy", apps: ["Foo.app"], zap: ["~/Library/Application Support/Foo"])
        let found2 = try HomebrewZapSource(paths: fx.paths, rules: ScanKit.provider(casks: [nameOnly])).candidates(for: id)
        #expect(found2.item(fx.home("Library/Application Support/Foo"))?.confidence == .medium)
    }

    /// 묶음·pkg cask: uninstall에만 나오는 BID로는 매칭하지 않고, 다른 앱 BID가 든 zap 경로는 쓰지 않는다
    @Test func suiteCaskDoesNotLeakOtherAppsData() throws {
        let fx = try Fixture()
        let suite = HomebrewCask(token: "microsoft-word", names: ["Microsoft Word"], apps: [],
                                 bundleIDs: ["com.microsoft.autoupdate2", "com.microsoft.package.Microsoft_Word.app"],
                                 zap: ["~/Library/Preferences/com.microsoft.Word.plist", "~/Library/Containers/com.microsoft.Excel",
                                       "~/Library/Application Support/Microsoft",
                                       "~/Library/Application Support/com.apple.sharedfilelist/x/com.microsoft.word.sfl*"])
        try fx.file(fx.home("Library/Preferences/com.microsoft.Word.plist"))
        try fx.dir(fx.home("Library/Containers/com.microsoft.Excel"))
        try fx.dir(fx.home("Library/Application Support/Microsoft"))
        try fx.file(fx.home("Library/Application Support/com.apple.sharedfilelist/x/com.microsoft.word.sfl3"))
        let source = HomebrewZapSource(paths: fx.paths, rules: ScanKit.provider(casks: [suite]))

        let au = try fx.makeApp(name: "Microsoft AutoUpdate", bundleID: "com.microsoft.autoupdate2")
        let auID = AppIdentity(bundleURL: au, bundleID: "com.microsoft.autoupdate2", name: "Microsoft AutoUpdate")
        #expect(try source.candidates(for: auID).isEmpty)
        #expect(!HomebrewZapSource.caskMatches(suite, auID))

        let word = try fx.makeApp(name: "Microsoft Word", bundleID: "com.microsoft.Word")
        let wordID = AppIdentity(bundleURL: word, bundleID: "com.microsoft.Word", name: "Microsoft Word")
        let found = try source.candidates(for: wordID)
        #expect(found.item(fx.home("Library/Preferences/com.microsoft.Word.plist"))?.confidence == .medium)
        #expect(found.item(fx.home("Library/Application Support/Microsoft")) != nil)
        #expect(found.item(fx.home("Library/Containers/com.microsoft.Excel")) == nil)
        #expect(found.items(named: "com.microsoft.word.sfl3").isEmpty)
    }

    @Test func braceExpansion() {
        #expect(HomebrewZapSource.expandBraces("a{b,c}d") == ["abd", "acd"])
        #expect(HomebrewZapSource.expandBraces("x{1,{2,3}}") == ["x1", "x2", "x3"])
        #expect(HomebrewZapSource.expandBraces("plain") == ["plain"])
        #expect(HomebrewZapSource.expandBraces("{only}") == ["{only}"])
    }
}
