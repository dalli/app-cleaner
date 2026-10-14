import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

/// 호출 횟수를 세는 서명 리더 (캐시 적중 검증용)
final class CountingSignatureReader: CodeSignatureReading, @unchecked Sendable {
    private let lock = NSLock()
    private var infos: [String: SigningInfo] = [:]
    private var counts: [String: Int] = [:]

    func set(_ info: SigningInfo, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        infos[url.standardizedFileURL.path] = info
    }

    func count(_ url: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[url.standardizedFileURL.path] ?? 0
    }

    var total: Int {
        lock.lock(); defer { lock.unlock() }
        return counts.values.reduce(0, +)
    }

    func signingInfo(for bundleURL: URL) -> SigningInfo? {
        lock.lock(); defer { lock.unlock() }
        let key = bundleURL.standardizedFileURL.path
        counts[key, default: 0] += 1
        return infos[key]
    }
}

/// 인벤토리 테스트용 공통 스텁: Spotlight가 주어진 앱들을 돌려주고 색인은 켜져 있음
func spotlightStub(_ runner: StubCommandRunner, apps: @escaping @Sendable () -> [URL], indexing: String = "Indexing enabled.") {
    runner.on("mdfind") { _ in CommandOutput(status: 0, stdout: Data(apps().map(\.path).joined(separator: "\n").utf8)) }
    runner.on("mdutil") { args in CommandOutput(status: 0, stdout: Data("\(args.last ?? "/"):\n\t\(indexing) \n".utf8)) }
}

func makeInventory(_ fx: Fixture, runner: StubCommandRunner, reader: CodeSignatureReading = StubSignatureReader(),
                   isRunning: @escaping @Sendable (String) -> Bool = { _ in false },
                   launchServices: @escaping LaunchServicesLookup = LaunchServicesRegistry.none) -> AppInventory {
    AppInventory(paths: fx.paths, runner: runner, signatureReader: reader, isRunning: isRunning,
                 lastUsed: { _ in nil }, launchServices: launchServices)
}

@Suite struct InventoryTests {
    @Test func recursesIntoSubfoldersButNotIntoBundles() async throws {
        let fx = try Fixture()
        let setapp = try fx.makeApp(name: "Foo", bundleID: "com.example.foo", in: fx.root("Applications/Setapp"))
        let idea = try fx.makeApp(name: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij",
                                  in: fx.home("Applications/JetBrains Toolbox"))
        let util = try fx.makeApp(name: "Disk Thing", bundleID: "com.example.disk", in: fx.root("Applications/Utilities"))
        let core = try fx.makeApp(name: "Finder", bundleID: "com.apple.finder", in: fx.root("System/Library/CoreServices"))
        // 번들 내부의 .app(헬퍼)은 별도 앱으로 잡히면 안 된다
        let host = try fx.makeApp(name: "Host", bundleID: "com.example.host",
                                  embedded: [.init("Contents/Library/LoginItems/HostHelper.app", bundleID: "com.example.host.helper")])
        // 프레임워크 폴더 안으로는 내려가지 않는다
        try fx.makeApp(name: "Hidden", bundleID: "com.example.hidden", in: fx.root("Applications/Some.framework"))

        let runner = StubCommandRunner()
        spotlightStub(runner) { [setapp, idea, util, host] in [setapp, idea, util, host] }
        let snap = try await makeInventory(fx, runner: runner).build()
        let paths = Set(snap.apps.map(\.url.standardizedFileURL.path))
        for url in [setapp, idea, util, core, host] { #expect(paths.contains(url.standardizedFileURL.path)) }
        #expect(!snap.apps.contains { $0.bundleID == "com.example.host.helper" })
        #expect(!snap.apps.contains { $0.bundleID == "com.example.hidden" })
        #expect(snap.containsBundleID("com.example.host.helper"))
    }

    @Test func collectsEmbeddedBundleIDsLaunchLabelsAndWrappedID() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp(
            name: "Suite", bundleID: "com.example.suite",
            embedded: [
                .init("Contents/PlugIns/Share.appex", bundleID: "com.example.suite.share"),
                .init("Contents/Library/LoginItems/Launcher.app", bundleID: "com.example.suite.launcher"),
                .init("Contents/Helpers/Agent.app", bundleID: "com.example.suite.agent"),
                .init("Contents/Frameworks/Suite Helper.app", bundleID: "com.example.suite.helper"),
            ],
            launchPlists: [("Contents/Library/LaunchAgents/com.example.suite.daemon.plist", "com.example.suite.daemon",
                            "Contents/MacOS/daemon")]
        )
        try fx.file(app.appendingPathComponent("Contents/Library/LaunchServices/com.example.suite.privhelper"), bytes: 8)
        let ios = try fx.makeApp(name: "Game", bundleID: "com.example.game.wrapper", wrappedBundleID: "com.example.game")

        let runner = StubCommandRunner()
        spotlightStub(runner) { [app, ios] in [app, ios] }
        let snap = try await makeInventory(fx, runner: runner).build()
        let suite = try #require(snap.apps.first { $0.bundleID == "com.example.suite" })
        #expect(Set(suite.embeddedBundleIDs) == ["com.example.suite.share", "com.example.suite.launcher", "com.example.suite.agent",
                                                  "com.example.suite.helper", "com.example.suite.privhelper"])
        #expect(suite.launchLabels == ["com.example.suite.daemon"])
        let game = try #require(snap.apps.first { $0.bundleID == "com.example.game.wrapper" })
        #expect(game.wrappedBundleID == "com.example.game")
        #expect(snap.allBundleIDs.contains("com.example.game"))
    }

    @Test func signingInfoIsCachedByPathAndModificationDate() async throws {
        let fx = try Fixture()
        let a = try fx.makeApp(name: "Alpha", bundleID: "com.example.alpha",
                               embedded: [.init("Contents/PlugIns/Widget.appex", bundleID: "com.example.alpha.widget")])
        let b = try fx.makeApp(name: "Beta", bundleID: "com.example.beta")
        let old = Date(timeIntervalSinceNow: -86400 * 30)
        for url in [a, b, a.appendingPathComponent("Contents/Info.plist"), b.appendingPathComponent("Contents/Info.plist")] {
            try fx.setModified(url, old)
        }
        let reader = CountingSignatureReader()
        reader.set(SigningInfo(teamID: "ABCDE12345", appGroups: ["ABCDE12345.shared"]), for: a)
        reader.set(SigningInfo(teamID: "ABCDE12345", appGroups: ["group.com.example.widget"]),
                   for: a.appendingPathComponent("Contents/PlugIns/Widget.appex"))

        let runner = StubCommandRunner()
        spotlightStub(runner) { [a, b] in [a, b] }
        let inv = makeInventory(fx, runner: runner, reader: reader)
        let first = try await inv.build()
        let alpha = try #require(first.apps.first { $0.bundleID == "com.example.alpha" })
        #expect(alpha.teamID == "ABCDE12345")
        #expect(Set(alpha.appGroups) == ["ABCDE12345.shared", "group.com.example.widget"])
        #expect(reader.count(a) == 1 && reader.count(b) == 1)

        // 같은 인스턴스로 재구축: 읽지 않음
        _ = try await inv.build()
        #expect(reader.count(a) == 1 && reader.count(b) == 1)

        // 새 인스턴스(디스크 캐시)로 재구축: 읽지 않음
        let inv2 = makeInventory(fx, runner: runner, reader: reader)
        #expect(inv2.cached()?.apps.count == 2)
        let again = try await inv2.build()
        #expect(reader.count(a) == 1 && reader.count(b) == 1)
        #expect(again.apps.first { $0.bundleID == "com.example.alpha" }?.teamID == "ABCDE12345")

        // 앱이 바뀌면(수정일 변경) 다시 읽는다
        try fx.setModified(b.appendingPathComponent("Contents/Info.plist"), Date())
        _ = try await inv2.build()
        #expect(reader.count(b) == 2)
        #expect(reader.count(a) == 1)
    }

    @Test func parsesMdutilStatus() {
        #expect(AppInventory.parseMdutilStatus("/:\n\tIndexing enabled. \n") == true)
        #expect(AppInventory.parseMdutilStatus("/:\n\tIndexing enabled. \n/System/Volumes/Data:\n\tIndexing enabled.\n") == true)
        #expect(AppInventory.parseMdutilStatus("/:\n\tIndexing disabled.\n") == false)
        #expect(AppInventory.parseMdutilStatus("/:\n\tIndexing enabled.\n/Volumes/X:\n\tIndexing disabled.\n") == false)
        #expect(AppInventory.parseMdutilStatus("/Volumes/X:\n\tError: unknown indexing state.\n") == false)
        #expect(AppInventory.parseMdutilStatus("") == nil)
    }

    @Test func spotlightCrossCheckDetectsMissingApps() async throws {
        let fx = try Fixture()
        let indexed = try fx.makeApp(name: "Indexed", bundleID: "com.example.indexed")
        let missing = try fx.makeApp(name: "Unindexed", bundleID: "com.example.unindexed", in: fx.root("Applications/Tools"))
        let runner = StubCommandRunner()
        spotlightStub(runner) { [indexed] in [indexed] }
        let snap = try await makeInventory(fx, runner: runner).build()
        #expect(snap.spotlight.indexingEnabled)
        #expect(!snap.spotlight.complete)
        #expect(!snap.spotlight.isReliable)
        #expect(snap.spotlight.missingApps == [missing.path])
        // 인벤토리에는 표준 위치 탐색으로 포함된다
        #expect(snap.containsBundleID("com.example.unindexed"))
    }

    @Test func spotlightDisabledIsUnreliable() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Indexed", bundleID: "com.example.indexed")
        let runner = StubCommandRunner()
        spotlightStub(runner, apps: { [app] in [app] }, indexing: "Indexing disabled.")
        let snap = try await makeInventory(fx, runner: runner).build()
        #expect(!snap.spotlight.indexingEnabled)
        #expect(!snap.spotlight.isReliable)
    }

    @Test func spotlightAddsNonStandardLocations() async throws {
        let fx = try Fixture()
        let odd = try fx.makeApp(name: "Portable", bundleID: "com.example.portable", in: fx.home("Tools"))
        let inner = try fx.makeApp(name: "Inner", bundleID: "com.example.inner", in: odd.appendingPathComponent("Contents/Helpers"))
        let trashed = try fx.makeApp(name: "Trashed", bundleID: "com.example.trashed", in: fx.paths.trash)
        let runner = StubCommandRunner()
        spotlightStub(runner) { [odd, inner, trashed] in [odd, inner, trashed] }
        let snap = try await makeInventory(fx, runner: runner).build()
        #expect(snap.containsBundleID("com.example.portable"))
        #expect(!snap.apps.contains { $0.bundleID == "com.example.inner" })
        #expect(!snap.containsBundleID("com.example.trashed"))
        #expect(snap.spotlight.isReliable)
    }

    @Test func collectsHomebrewAndPackages() async throws {
        let fx = try Fixture()
        try fx.dir(fx.root("opt/homebrew/Caskroom/slack/4.0"))
        try fx.dir(fx.root("opt/homebrew/Caskroom/firefox/120.0"))
        try fx.file(fx.root("opt/homebrew/bin/brew"), text: "#!/bin/sh\n")
        let runner = StubCommandRunner()
        spotlightStub(runner) { [] }
        runner.on("brew", stdout: "firefox\niterm2\n")
        runner.on("pkgutil", stdout: "com.apple.pkg.Core\ncom.example.driver\n")
        let snap = try await makeInventory(fx, runner: runner).build()
        #expect(snap.homebrewCasks == ["firefox", "iterm2", "slack"])
        #expect(snap.packageIDs == ["com.apple.pkg.Core", "com.example.driver"])
        #expect(runner.calls.contains { $0.executable.hasSuffix("opt/homebrew/bin/brew") && $0.arguments == ["list", "--cask"] })
    }

    @Test func recordsOfflineVolumeApps() async throws {
        let fx = try Fixture()
        let volume = fx.root("Volumes/External")
        let ext = try fx.makeApp(name: "Big", bundleID: "com.example.big", in: volume.appendingPathComponent("Apps"))
        let runner = StubCommandRunner()
        spotlightStub(runner) { [ext] in FileManager.default.itemExists(ext) ? [ext] : [] }
        let inv = makeInventory(fx, runner: runner)
        let mounted = try await inv.build()
        #expect(mounted.containsBundleID("com.example.big"))
        #expect(mounted.offlineVolumeBundleIDs.isEmpty)

        // 볼륨 연결 해제 (마운트 지점이 사라짐)
        try FileManager.default.removeItem(at: volume)
        let offline = try await inv.build()
        #expect(!offline.apps.contains { $0.bundleID == "com.example.big" })
        #expect(offline.offlineVolumeBundleIDs == ["com.example.big"])
    }

    @Test func unindexedExternalVolumeIsWalkedDirectly() async throws {
        let fx = try Fixture()
        let ext = try fx.makeApp(name: "OnDisk", bundleID: "com.example.ondisk", in: fx.root("Volumes/USB/Applications"))
        let runner = StubCommandRunner()
        runner.on("mdfind", stdout: "")
        runner.on("mdutil") { args in
            let disabled = args.last?.hasSuffix("Volumes/USB") == true
            return CommandOutput(status: 0, stdout: Data("x:\n\t\(disabled ? "Indexing disabled." : "Indexing enabled.")\n".utf8))
        }
        let snap = try await makeInventory(fx, runner: runner).build()
        #expect(snap.apps.contains { $0.url.standardizedFileURL == ext.standardizedFileURL })
        #expect(snap.spotlight.indexingEnabled)
    }

    @Test func installedAppsForAppList() async throws {
        let fx = try Fixture()
        let mas = try fx.makeApp(name: "Store App", bundleID: "com.example.store", version: "2.1")
        try fx.file(mas.appendingPathComponent("Contents/_MASReceipt/receipt"), bytes: 10)
        try fx.makeApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        try fx.dir(fx.root("opt/homebrew/Caskroom/slack/4.0"))
        try fx.symlink(fx.root("opt/homebrew/Caskroom/slack/4.0/Slack.app"), to: URL(fileURLWithPath: "/Applications/Slack.app"))
        try fx.makeApp(name: "Driver", bundleID: "com.example.driver")
        try fx.makeApp(name: "Plain", bundleID: "com.example.plain", in: fx.home("Applications"))
        try fx.makeApp(name: "GarageBand", bundleID: "com.apple.garageband10")
        try fx.makeApp(name: "Calculator", bundleID: "com.example.notreallyapple", in: fx.root("System/Applications"))

        let runner = StubCommandRunner()
        runner.on("pkgutil", stdout: "com.example.driver.pkg\n")
        let used = Date(timeIntervalSince1970: 1_700_000_000)
        let inv = AppInventory(paths: fx.paths, runner: runner, signatureReader: StubSignatureReader(),
                               isRunning: { $0 == "com.example.plain" }, lastUsed: { $0.lastPathComponent == "Plain.app" ? used : nil },
                               launchServices: LaunchServicesRegistry.none)
        let apps = await inv.installedApps()
        let byBID = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleID, $0) })
        #expect(Set(byBID.keys) == ["com.example.store", "com.tinyspeck.slackmacgap", "com.example.driver", "com.example.plain"])
        #expect(byBID["com.example.store"]?.source == .appStore)
        #expect(byBID["com.example.store"]?.version == "2.1")
        #expect(byBID["com.tinyspeck.slackmacgap"]?.source == .homebrew)
        #expect(byBID["com.example.driver"]?.source == .package)
        #expect(byBID["com.example.plain"]?.source == .direct)
        #expect(byBID["com.example.plain"]?.isRunning == true)
        #expect(byBID["com.example.plain"]?.lastUsed == used)
        #expect(byBID["com.example.store"]?.size == nil)
    }

    @Test func launchServicesRegistrationIsRecheckedForExistence() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Here", bundleID: "com.example.here", in: fx.home("Downloads"))
        let lookup: LaunchServicesLookup = { bid in
            switch bid {
            case "com.example.here": return [app]
            case "com.example.gone": return [URL(fileURLWithPath: "/Applications/Gone.app")]
            case "com.example.ext": return [URL(fileURLWithPath: "/Volumes/Offline/Ext.app")]
            default: return []
            }
        }
        let paths = fx.paths
        #expect(LaunchServicesRegistry.registration(for: "com.example.here", lookup: lookup, paths: paths) == .installed(app))
        #expect(LaunchServicesRegistry.registration(for: "com.example.gone", lookup: lookup, paths: paths) == .notRegistered)
        #expect(LaunchServicesRegistry.registration(for: "com.example.ext", lookup: lookup, paths: paths)
                == .offlineVolume(fx.root("Volumes/Offline/Ext.app")))
        #expect(LaunchServicesRegistry.registration(for: "com.example.none", lookup: lookup, paths: paths) == .notRegistered)
    }

    @Test func bundleIDHeuristics() {
        #expect(BundleIDHeuristics.isBundleIDShaped("com.tinyspeck.slackmacgap"))
        #expect(BundleIDHeuristics.isBundleIDShaped("org.videolan"))
        #expect(!BundleIDHeuristics.isBundleIDShaped("zoom.us"))
        #expect(!BundleIDHeuristics.isBundleIDShaped("Slack"))
        #expect(!BundleIDHeuristics.isBundleIDShaped("foo.log"))
        #expect(!BundleIDHeuristics.isBundleIDShaped("1.2.3"))
        #expect(!BundleIDHeuristics.isBundleIDShaped("My App.data"))
        #expect(BundleIDHeuristics.vendorPrefix("com.google.Chrome") == "com.google")
        #expect(BundleIDHeuristics.vendorPrefix("com.todesktop.230313mzl4w4u92") == nil)
        #expect(BundleIDHeuristics.vendorPrefix("com.github.user.App") == "com.github.user")
        #expect(BundleIDHeuristics.teamPrefix("UBF8T346G9.Office") == "UBF8T346G9")
        #expect(BundleIDHeuristics.teamPrefix("group.com.foo") == nil)
        #expect(BundleIDHeuristics.matchesAny("com.foo.app.ShipIt", in: ["com.foo.app"]))
        #expect(BundleIDHeuristics.matchesAny("com.foo.app", in: ["com.foo.app.helper"]))
        #expect(!BundleIDHeuristics.matchesAny("com.foo.other", in: ["com.foo.app"]))
        // 실제 환경에서 발견한 경계 사례
        #expect(BundleIDHeuristics.isBundleIDShaped("com.cmuxterm.app"))
        #expect(!BundleIDHeuristics.isBundleIDShaped("warp.log.old.0"))
        #expect(!BundleIDHeuristics.isBundleIDShaped("rn-core-v0.10.11-p1.I2u27X"))
        #expect(!BundleIDHeuristics.isBundleIDShaped("default.store"))
        #expect(BundleIDHeuristics.matchesAny("org.tabby.ShipIt", in: ["org.tabby"]))
    }

    @Test func nestedAppsOutsideStandardHelperFolders() async throws {
        let fx = try Fixture()
        let docker = try fx.makeApp(name: "Docker", bundleID: "com.docker.docker", embedded: [
            .init("Contents/MacOS/Docker Desktop.app", bundleID: "com.electron.dockerdesktop"),
            .init("Contents/MacOS/Docker Desktop.app/Contents/Frameworks/Docker Desktop Helper.app",
                  bundleID: "com.electron.dockerdesktop.helper"),
            .init("Contents/Library/SecretsEngine/docker-pass.app", bundleID: "com.docker.pass"),
            .init("Contents/Resources/Updater.app", bundleID: "com.docker.updater"),
        ])
        let runner = StubCommandRunner()
        spotlightStub(runner) { [docker] in [docker] }
        let snap = try await makeInventory(fx, runner: runner).build()
        let app = try #require(snap.apps.first { $0.bundleID == "com.docker.docker" })
        for bid in ["com.electron.dockerdesktop", "com.electron.dockerdesktop.helper", "com.docker.pass", "com.docker.updater"] {
            #expect(app.embeddedBundleIDs.contains(bid), "\(bid)")
        }
    }
}
