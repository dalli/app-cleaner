import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

@Suite struct IdentityResolverTests {
    @Test func basicInfoPlistAndSigning() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Foo", bundleID: "com.example.foo", displayName: "Foo Pro", executable: "foo-bin", version: "2.1")
        let sig = StubSignatureReader()
        sig.set(SigningInfo(teamID: "ABCDE12345", appGroups: ["ABCDE12345.group.foo"], identifier: "com.example.foo"), for: app)
        let id = try ScanKit.resolver(fx, signatures: sig).resolve(appAt: app)
        #expect(id.bundleID == "com.example.foo")
        #expect(id.name == "Foo")
        #expect(id.displayName == "Foo Pro")
        #expect(id.executableName == "foo-bin")
        #expect(id.version == "2.1")
        #expect(id.teamID == "ABCDE12345")
        #expect(id.appGroups == ["ABCDE12345.group.foo"])
        #expect(id.source == .direct)
        #expect(id.packageIDs.isEmpty)
    }

    @Test func embeddedBundlesAndLaunchServices() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(
            name: "Foo", bundleID: "com.example.foo",
            embedded: [
                .init("Contents/Library/LoginItems/FooLauncher.app", bundleID: "com.example.foo.launcher"),
                .init("Contents/PlugIns/Share.appex", bundleID: "com.example.foo.share"),
                .init("Contents/Library/SystemExtensions/com.example.foo.netext.systemextension", bundleID: "com.example.foo.netext"),
                .init("Contents/Helpers/Foo Agent.app", bundleID: "com.example.foo.agent"),
                .init("Contents/Frameworks/Foo Helper (Renderer).app", bundleID: "com.example.foo.helper.renderer"),
                // 서드파티 프레임워크 BID는 제외 (다른 앱 잔여물과 겹침)
                .init("Contents/Frameworks/Autoupdate.app", bundleID: "org.sparkle-project.Sparkle.Autoupdate"),
                // Frameworks 아래 .app이 아닌 번들은 대상 아님
                .init("Contents/Frameworks/Foo Core.framework", bundleID: "com.example.foo.core"),
            ],
            launchPlists: [
                (relativePath: "Contents/Library/LaunchAgents/com.example.foo.agent.plist", label: "com.example.foo.agent",
                 bundleProgram: "Contents/MacOS/agent"),
                (relativePath: "Contents/Library/LaunchDaemons/com.example.foo.daemon.plist", label: "com.example.foo.daemon",
                 bundleProgram: "Contents/MacOS/daemon"),
            ])
        // LaunchServices의 권한 헬퍼는 번들이 아닌 실행 파일 (파일명 = BID)
        try fx.file(app.appendingPathComponent("Contents/Library/LaunchServices/com.example.foo.privhelper"), bytes: 32)
        try fx.file(app.appendingPathComponent("Contents/Library/LaunchServices/not-a-bid"), bytes: 32)

        let sig = StubSignatureReader()
        sig.set(SigningInfo(teamID: "ABCDE12345", appGroups: ["ABCDE12345.main"]), for: app)
        sig.set(SigningInfo(teamID: "ABCDE12345", appGroups: ["ABCDE12345.share"]),
                for: app.appendingPathComponent("Contents/PlugIns/Share.appex"))

        let id = try ScanKit.resolver(fx, signatures: sig).resolve(appAt: app)
        #expect(Set(id.embeddedBundleIDs) == [
            "com.example.foo.launcher", "com.example.foo.share", "com.example.foo.netext", "com.example.foo.agent",
            "com.example.foo.helper.renderer", "com.example.foo.privhelper",
        ])
        #expect(Set(id.appGroups) == ["ABCDE12345.main", "ABCDE12345.share"])
        let labels = Dictionary(uniqueKeysWithValues: id.embeddedLaunchServices.map { ($0.label, $0.domain) })
        #expect(labels["com.example.foo.agent"] == .user)
        #expect(labels["com.example.foo.daemon"] == .system)
        #expect(id.embeddedLaunchServices.allSatisfy { $0.plistURL?.isInside(app) == true })
    }

    @Test func wrappedIOSApp() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Game", bundleID: "com.example.game.mac", wrappedBundleID: "com.example.game")
        let id = try ScanKit.resolver(fx).resolve(appAt: app)
        #expect(id.wrappedBundleID == "com.example.game")
        #expect(id.allBundleIDs.contains("com.example.game"))
        #expect(id.allBundleIDs.contains("com.example.game.mac"))
    }

    @Test func wrapperOnlyIOSAppFromAppStore() throws {
        let fx = try Fixture()
        // 실제 iOS 앱 래퍼처럼 바깥 Contents/Info.plist 없이 Wrapper/*.app만 있는 경우
        let app = fx.root("Applications/Puzzle.app")
        try fx.plist(app.appendingPathComponent("Wrapper/Puzzle.app/Info.plist"),
                     ["CFBundleIdentifier": "com.example.puzzle", "CFBundleName": "Puzzle", "CFBundleExecutable": "Puzzle"])
        try fx.plist(app.appendingPathComponent("Wrapper/iTunesMetadata.plist"), ["itemId": 1])
        try fx.symlink(app.appendingPathComponent("WrappedBundle"), to: URL(fileURLWithPath: "Wrapper/Puzzle.app"))
        let id = try ScanKit.resolver(fx).resolve(appAt: app)
        #expect(id.bundleID == "com.example.puzzle")
        #expect(id.wrappedBundleID == "com.example.puzzle")
        #expect(id.source == .appStore)
    }

    @Test func appStoreReceiptSource() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Notely", bundleID: "com.example.notely")
        try fx.file(app.appendingPathComponent("Contents/_MASReceipt/receipt"), bytes: 128)
        let id = try ScanKit.resolver(fx).resolve(appAt: app)
        #expect(id.source == .appStore)
    }

    @Test func packageIDsFromPkgutil() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Pkgd", bundleID: "com.example.pkgd")
        let runner = StubCommandRunner()
        runner.on("pkgutil") { args in
            guard args == ["--file-info", "/Applications/Pkgd.app"] else { return CommandOutput(status: 1, stdout: Data()) }
            return CommandOutput(status: 0, stdout: Data("""
            volume: /
            path: /Applications/Pkgd.app

            pkgid: com.example.pkgd.app
            pkg-version: 1.0
            install-time: 1700000000
            uid: 0
            gid: 80
            mode: 755

            pkgid: com.example.pkgd.extras
            """.utf8))
        }
        let id = try ScanKit.resolver(fx, runner: runner).resolve(appAt: app)
        #expect(id.packageIDs == ["com.example.pkgd.app", "com.example.pkgd.extras"])
        #expect(id.source == .package)
        #expect(runner.calls.allSatisfy { $0.executable == "/usr/sbin/pkgutil" })
    }

    @Test func homebrewCaskDetection() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        try fx.dir(fx.root("opt/homebrew/Caskroom/slack/4.41.105"))
        let casks = [HomebrewCask(token: "slack", names: ["Slack"], apps: ["Slack.app"], bundleIDs: ["com.tinyspeck.slackmacgap"])]
        let id = try ScanKit.resolver(fx, casks: casks).resolve(appAt: app)
        #expect(id.homebrewCask == "slack")
        #expect(id.source == .homebrew)

        // Caskroom 기록이 없으면 Homebrew 설치로 보지 않는다
        let fx2 = try Fixture()
        let app2 = try fx2.makeApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        let id2 = try ScanKit.resolver(fx2, casks: casks).resolve(appAt: app2)
        #expect(id2.homebrewCask == nil)
        #expect(id2.source == .direct)
    }

    @Test func homebrewCaskByConventionalTokenInUsrLocal() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Google Chrome", bundleID: "com.google.Chrome")
        try fx.dir(fx.root("usr/local/Caskroom/google-chrome/latest"))
        let id = try ScanKit.resolver(fx).resolve(appAt: app)
        #expect(id.homebrewCask == "google-chrome")
    }

    @Test func refusesAppleAppsSelfAndNonApps() throws {
        let fx = try Fixture()
        let apple = try fx.makeApp(name: "GarageBand", bundleID: "com.apple.garageband10")
        #expect(throws: ScanError.appleApp(bundleID: "com.apple.garageband10")) { try ScanKit.resolver(fx).resolve(appAt: apple) }

        let me = try fx.makeApp(name: "AppCleaner", bundleID: SystemPaths.defaultSelfBundleID)
        #expect(throws: ScanError.selfApp(bundleID: SystemPaths.defaultSelfBundleID)) { try ScanKit.resolver(fx).resolve(appAt: me) }

        let folder = try fx.dir(fx.root("Applications/NotAnApp"))
        #expect(throws: ScanError.notAnApp(folder)) { try ScanKit.resolver(fx).resolve(appAt: folder) }

        let missing = fx.root("Applications/Missing.app")
        #expect(throws: ScanError.notAnApp(missing)) { try ScanKit.resolver(fx).resolve(appAt: missing) }

        let noBID = fx.root("Applications/NoBID.app")
        try fx.plist(noBID.appendingPathComponent("Contents/Info.plist"), ["CFBundleName": "NoBID"])
        #expect(throws: ScanError.missingBundleID(noBID)) { try ScanKit.resolver(fx).resolve(appAt: noBID) }
    }
}
