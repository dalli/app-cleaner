import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

@Suite struct PreflightTests {
    /// plan.md 9장 Pre-flight 테스트: KeepAlive 에이전트가 있는 앱에서 bootout → 종료 순서, plist는 bootout 후에 이동.
    @Test func keepAliveAgentIsBootedOutBeforeTerminationAndMovedAfter() async throws {
        let h = try Harness()
        let fx = h.fx
        let app = try fx.makeApp(name: "Foo", bundleID: "com.example.foo",
                                 embedded: [.init("Contents/Library/LoginItems/FooHelper.app", bundleID: "com.example.foo.helper")])
        let agent = try fx.makeLaunchPlist(at: fx.home("Library/LaunchAgents/com.example.foo.agent.plist"),
                                           label: "com.example.foo.agent",
                                           arguments: [app.appendingPathComponent("Contents/MacOS/Foo").path], keepAlive: true)
        let cache = try fx.file(fx.home("Library/Caches/com.example.foo/c.db"))
        // GUI 앱 + LaunchServices에 등록되지 않은 헬퍼 프로세스
        h.table.add(RunningProcess(pid: 501, executablePath: app.appendingPathComponent("Contents/MacOS/Foo").path,
                                   bundleID: "com.example.foo", name: "Foo", isApplication: true))
        let helperExe = app.appendingPathComponent("Contents/Library/LoginItems/FooHelper.app/Contents/MacOS/FooHelper").path
        h.table.add(RunningProcess(pid: 777, executablePath: helperExe, name: "FooHelper", isApplication: false))
        // 무관한 프로세스 (경로 접두사만 같은 다른 앱)
        h.table.add(RunningProcess(pid: 888, executablePath: fx.root("Applications/Foo.app2/Contents/MacOS/x").path,
                                   name: "x", isApplication: false))

        let identity = AppIdentity(bundleURL: app, bundleID: "com.example.foo", name: "Foo",
                                   embeddedBundleIDs: ["com.example.foo.helper"])
        let service = LaunchServiceRef(label: "com.example.foo.agent", domain: .user, plistURL: agent)
        let report = ScanReport(identity: identity, candidates: [
            Candidate(url: app, category: .appBundle, confidence: .high, isSelected: true),
            Candidate(url: agent, category: .launchAgent, confidence: .high, isSelected: true, launchService: service),
            Candidate(url: cache.deletingLastPathComponent(), category: .caches, confidence: .high, isSelected: true),
        ], ruleDataVersion: "t")
        let plan = CleanupPlanner.plan(for: report, selectedPaths: Set(report.candidates.map(\.path)), resetPrivacy: false)
        #expect(plan.steps == [.stopServices, .terminateApps, .moveItems])

        let (result, _) = await h.execute(plan)
        #expect(result.failures.isEmpty, "\(result.failures)")

        let bootout = try #require(h.log.index(of: "launchctl bootout gui/\(fx.paths.uid)/com.example.foo.agent"))
        let terminateApp = try #require(h.log.index(of: "terminate 501"))
        let sigtermHelper = try #require(h.log.index(of: "sigterm 777"))
        let movePlist = try #require(h.log.index(of: "trash com.example.foo.agent.plist"))
        #expect(bootout < terminateApp)
        #expect(bootout < sigtermHelper)
        #expect(bootout < movePlist)
        #expect(sigtermHelper < movePlist)
        #expect(h.log.index(of: "sigterm 888") == nil)
        #expect(!fx.exists(agent))
    }

    @Test func terminatorFindsNonLaunchServicesHelpersByExecutablePath() throws {
        let fx = try Fixture()
        let log = EventLog()
        let table = FakeProcessTable(log: log)
        let app = fx.root("Applications/My App.app")
        table.add(RunningProcess(pid: 10, executablePath: app.path + "/Contents/Helpers/cli", name: "cli", isApplication: false))
        table.add(RunningProcess(pid: 11, executablePath: app.path + " Copy/Contents/MacOS/x", name: "x", isApplication: false))
        table.add(RunningProcess(pid: 12, executablePath: "/usr/bin/other", name: "other", isApplication: false))
        table.add(RunningProcess(pid: 13, executablePath: nil, bundleID: "com.example.my", name: "My App", isApplication: true))
        let t = ProcessTerminator(table: table, timeout: 0.1)
        let targets = t.targets(bundleIDs: ["com.example.my"], bundlePaths: [app])
        #expect(Set(targets.map(\.pid)) == [10, 13])
    }

    @Test func unresponsiveProcessDecisions() async throws {
        let fx = try Fixture()
        let app = fx.root("Applications/Hang.app")
        func makeTable(_ log: EventLog) -> FakeProcessTable {
            let table = FakeProcessTable(log: log)
            table.add(RunningProcess(pid: 42, executablePath: app.path + "/Contents/MacOS/Hang", bundleID: "com.example.hang",
                                     name: "Hang", isApplication: true), ignoresTerm: true)
            return table
        }
        // 강제 종료
        let log1 = EventLog()
        let r1 = await ProcessTerminator(table: makeTable(log1), timeout: 0.05, forceTimeout: 0.1, pollInterval: 0.01)
            .terminate(bundleIDs: ["com.example.hang"], bundlePaths: [app]) { app in
                #expect(app.pid == 42 && app.name == "Hang")
                return .forceQuit
            }
        #expect(r1.forced.map(\.pid) == [42])
        #expect(log1.events == ["terminate 42", "kill 42"])
        // 건너뛰기
        let r2 = await ProcessTerminator(table: makeTable(EventLog()), timeout: 0.05, pollInterval: 0.01)
            .terminate(bundleIDs: ["com.example.hang"], bundlePaths: [app]) { _ in .skip }
        #expect(r2.remaining.map(\.pid) == [42] && !r2.cancelled)
        // 취소
        let r3 = await ProcessTerminator(table: makeTable(EventLog()), timeout: 0.05, pollInterval: 0.01)
            .terminate(bundleIDs: ["com.example.hang"], bundlePaths: [app]) { _ in .cancel }
        #expect(r3.cancelled)
    }

    @Test func cancelDuringTerminationMovesNothing() async throws {
        let h = try Harness(terminationTimeout: 0.05)
        let fx = h.fx
        let app = try fx.makeApp(name: "Hang", bundleID: "com.example.hang")
        h.table.add(RunningProcess(pid: 42, executablePath: app.appendingPathComponent("Contents/MacOS/Hang").path,
                                   bundleID: "com.example.hang", name: "Hang", isApplication: true), ignoresTerm: true)
        let cache = try fx.file(fx.home("Library/Caches/com.example.hang/x"))
        let plan = CleanupPlan(kind: .appRemoval, targetName: "Hang", targetBundleID: "com.example.hang",
                               items: [Candidate(url: app, category: .appBundle, confidence: .high, isSelected: true),
                                       Candidate(url: cache, category: .caches, confidence: .high, isSelected: true)],
                               bundleIDsToTerminate: ["com.example.hang"], bundlePathsToTerminate: [app], ruleDataVersion: "t")
        let (result, events) = await h.execute(plan, decision: .cancel)
        #expect(result.cancelled)
        #expect(result.movedCount == 0)
        #expect(fx.exists(app) && fx.exists(cache))
        #expect(stepEvents(events) == ["start:terminateApps"])
        let session = try #require(await h.journal.session(id: result.sessionID))
        #expect(session.steps.contains("cancelled"))
    }

    @Test func preferencesAreBackedUpBeforeDomainIsDeleted() throws {
        let fx = try Fixture()
        let plist = try fx.plist(fx.home("Library/Preferences/com.example.foo.plist"), ["k": "v"])
        let backupDir = fx.base.appendingPathComponent("backup")
        let runner = StubCommandRunner()
        let sawBackup = OpsCapture()
        runner.on("defaults") { args in
            if args.first == "delete" {
                sawBackup.set(FileManager.default.fileExists(atPath: backupDir.appendingPathComponent("com.example.foo.plist").path) ? "yes" : "no")
                try? FileManager.default.removeItem(at: plist)
            }
            return CommandOutput(status: 0, stdout: Data())
        }
        let flusher = CFPreferencesFlusher(paths: fx.paths, runner: runner)
        let backup = try #require(try flusher.flush(domain: "com.example.foo", backupDirectory: backupDir))
        #expect(sawBackup.value == "yes")
        #expect(NSDictionary(contentsOfFile: backup.backupPath)?["k"] as? String == "v")
        #expect(runner.calls.map(\.arguments) == [["delete", "com.example.foo"]])

        try flusher.restore(backup)
        #expect(runner.calls.last?.arguments == ["import", "com.example.foo", backup.backupPath])

        #expect(throws: CleanupError.self) { try flusher.flush(domain: "com.apple.finder", backupDirectory: backupDir) }
        #expect(throws: CleanupError.self) { try flusher.flush(domain: "foo; rm -rf ~", backupDirectory: backupDir) }
        #expect(runner.calls.count == 2)
    }

    @Test func serviceControllerUsesUserDomainAndAdminForSystem() async throws {
        let fx = try Fixture()
        let runner = StubCommandRunner()
        runner.on("launchctl") { args in
            CommandOutput(status: args.last?.hasSuffix("gone") == true ? 113 : 0, stdout: Data())
        }
        let admin = RecordingAdmin(paths: fx.paths)
        let ctl = LaunchctlServiceController(paths: fx.paths, runner: runner, admin: admin)
        let daemonPlist = fx.root("Library/LaunchDaemons/com.example.d.plist")
        let results = await ctl.bootout([
            LaunchServiceRef(label: "com.example.a", domain: .user),
            LaunchServiceRef(label: "com.example.gone", domain: .user),
            LaunchServiceRef(label: "com.example.d", domain: .system, plistURL: daemonPlist),
            LaunchServiceRef(label: "com.example.e", domain: .system),
            LaunchServiceRef(label: "bad label", domain: .user),
            LaunchServiceRef(label: "com.apple.Finder", domain: .user),
        ])
        #expect(results.map(\.succeeded) == [true, true, true, true, false, false])
        #expect(runner.calls.map(\.arguments) == [["bootout", "gui/\(fx.paths.uid)/com.example.a"],
                                                  ["bootout", "gui/\(fx.paths.uid)/com.example.gone"]])
        // 시스템 서비스 두 개는 한 번의 관리자 배치로
        #expect(admin.batches == [[.bootoutSystem(label: "com.example.d"), .bootoutSystem(label: "com.example.e")]])

        _ = await ctl.bootstrap([LaunchServiceRef(label: "com.example.d", domain: .system, plistURL: daemonPlist),
                                 LaunchServiceRef(label: "com.example.a", domain: .user, plistURL: fx.home("Library/LaunchAgents/a.plist"))])
        #expect(admin.batches.last == [.bootstrapSystem(plistPath: "/Library/LaunchDaemons/com.example.d.plist")])
        #expect(runner.calls.last?.arguments == ["bootstrap", "gui/\(fx.paths.uid)", fx.home("Library/LaunchAgents/a.plist").path])
    }
}
