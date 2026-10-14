import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

// MARK: - 공용 가짜 구현 (이 테스트 모듈 전체에서 사용)
//
// 모든 가짜는 픽스처 안에서만 동작한다. 실제 휴지통·launchctl·defaults·tccutil·kill·osascript는 호출하지 않는다.

/// 여러 가짜 구현이 함께 쓰는 순서 기록
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    func append(_ e: String) {
        lock.lock(); defer { lock.unlock() }
        _events.append(e)
    }

    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    func index(of prefix: String) -> Int? { events.firstIndex { $0.hasPrefix(prefix) } }
}

/// 프로세스 테이블 가짜. `ignoresTerm`이면 종료 요청을 무시한다 (응답 없음 재현).
final class FakeProcessTable: ProcessTable, @unchecked Sendable {
    private struct Entry { var process: RunningProcess; var alive: Bool; var ignoresTerm: Bool }
    private let lock = NSLock()
    private var entries: [Int32: Entry] = [:]
    let log: EventLog

    init(log: EventLog) { self.log = log }

    func add(_ p: RunningProcess, ignoresTerm: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        entries[p.pid] = Entry(process: p, alive: true, ignoresTerm: ignoresTerm)
    }

    func applications(bundleID: String) -> [RunningProcess] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.filter { $0.alive && $0.process.isApplication && $0.process.bundleID == bundleID }
            .map(\.process).sorted { $0.pid < $1.pid }
    }

    func allProcesses() -> [RunningProcess] {
        lock.lock(); defer { lock.unlock() }
        // proc_pidpath 결과처럼 LaunchServices 정보 없이 경로만
        return entries.values.filter(\.alive).map {
            RunningProcess(pid: $0.process.pid, executablePath: $0.process.executablePath, name: $0.process.name, isApplication: false)
        }.sorted { $0.pid < $1.pid }
    }

    func requestQuit(_ p: RunningProcess) -> Bool {
        log.append(p.isApplication ? "terminate \(p.pid)" : "sigterm \(p.pid)")
        lock.lock(); defer { lock.unlock() }
        if entries[p.pid]?.ignoresTerm == false { entries[p.pid]?.alive = false }
        return true
    }

    func forceQuit(_ p: RunningProcess) -> Bool {
        log.append("kill \(p.pid)")
        lock.lock(); defer { lock.unlock() }
        entries[p.pid]?.alive = false
        return true
    }

    func isRunning(_ pid: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[pid]?.alive ?? false
    }
}

/// 휴지통 이동을 기록하는 래퍼 (실제 휴지통 대신 픽스처의 `~/.Trash`)
struct LoggingTrash: TrashProviding {
    let inner: DirectoryTrash
    let log: EventLog

    func trash(_ url: URL) async throws -> URL {
        log.append("trash \(url.lastPathComponent)")
        return try await inner.trash(url)
    }
}

/// 관리자 실행기 가짜: 작업을 기록하고 보류 폴더 이동·복원을 Swift로 흉내 낸다.
final class RecordingAdmin: AdminExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var _batches: [[AdminOperation]] = []
    let paths: SystemPaths
    let log: EventLog?

    init(paths: SystemPaths, log: EventLog? = nil) {
        self.paths = paths
        self.log = log
    }

    var batches: [[AdminOperation]] {
        lock.lock(); defer { lock.unlock() }
        return _batches
    }

    func run(_ operations: [AdminOperation]) async -> [AdminOperationResult] {
        lock.withLock { _batches.append(operations) }
        let fm = FileManager.default
        return operations.map { op in
            log?.append("admin \(op.arguments.joined(separator: " "))")
            switch op {
            case .moveToHolding(let s, let p):
                let src = AdminPaths.fullURL(logical: p, root: paths.root)
                let dst = AdminPaths.holdingURL(session: s, logical: p, holdingDir: paths.holdingDir)
                do {
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: src, to: dst)
                    return AdminOperationResult(operation: op, succeeded: true, message: dst.path)
                } catch {
                    return AdminOperationResult(operation: op, succeeded: false, message: "move-failed")
                }
            case .restoreFromHolding(let s, let p, let to):
                let src = AdminPaths.holdingURL(session: s, logical: p, holdingDir: paths.holdingDir)
                let dst = AdminPaths.fullURL(logical: to ?? p, root: paths.root)
                do {
                    try fm.moveItem(at: src, to: dst)
                    return AdminOperationResult(operation: op, succeeded: true, message: dst.path)
                } catch {
                    return AdminOperationResult(operation: op, succeeded: false, message: "move-failed")
                }
            default:
                return AdminOperationResult(operation: op, succeeded: true, message: "ok")
            }
        }
    }
}

/// 환경 변수를 넘겨 실제 프로세스를 실행하는 러너 (privileged-op.sh를 테스트 모드로 실행할 때만 사용)
struct EnvCommandRunner: CommandRunning {
    let environment: [String: String]
    let workingDirectory: URL

    func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        p.currentDirectoryURL = workingDirectory
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return CommandOutput(status: p.terminationStatus, stdout: o, stderr: String(decoding: e, as: UTF8.self))
    }
}

/// 실제 privileged-op.sh를 테스트 모드(`APPCLEANER_TEST_ROOT` = 픽스처 루트)로 실행하는 관리자 실행기
func scriptAdmin(_ fx: Fixture) -> AppleScriptAdminExecutor {
    AppleScriptAdminExecutor(
        runner: EnvCommandRunner(environment: ["APPCLEANER_TEST_ROOT": fx.paths.root.path], workingDirectory: fx.base),
        scriptURL: PrivilegedScriptTests.sourceScriptURL,
        launcher: .direct,
        workDirectory: fx.base)
}

/// 실행기 조립 (가짜 프로세스 테이블, 기록하는 launchctl/defaults/tccutil 스텁, 픽스처 휴지통)
struct Harness {
    let fx: Fixture
    let log: EventLog
    let runner: StubCommandRunner
    let table: FakeProcessTable
    let admin: AdminExecuting
    let journal: JournalStore
    let executor: CleanupExecutor

    init(fx: Fixture? = nil, admin: AdminExecuting? = nil, safety: SafetyChecking? = nil, terminationTimeout: TimeInterval = 0.2) throws {
        let fx = try fx ?? Fixture()
        let log = EventLog()
        let runner = StubCommandRunner()
        let paths = fx.paths
        runner.on("launchctl") { args in
            log.append("launchctl \(args.joined(separator: " "))")
            return CommandOutput(status: 0, stdout: Data())
        }
        runner.on("defaults") { args in
            log.append("defaults \(args.joined(separator: " "))")
            // cfprefsd처럼 도메인을 지우면 plist 파일도 사라진다.
            if args.first == "delete", args.count > 1 {
                try? FileManager.default.removeItem(at: paths.userLibrary.appendingPathComponent("Preferences/\(args[1]).plist"))
            }
            return CommandOutput(status: 0, stdout: Data())
        }
        runner.on("tccutil") { args in
            log.append("tccutil \(args.joined(separator: " "))")
            return CommandOutput(status: 0, stdout: Data())
        }
        let table = FakeProcessTable(log: log)
        let admin = admin ?? RecordingAdmin(paths: paths, log: log)
        let services = LaunchctlServiceController(paths: paths, runner: runner, admin: admin)
        let prefs = CFPreferencesFlusher(paths: paths, runner: runner)
        let journal = JournalStore(paths: paths, admin: admin, services: services, preferences: prefs)
        self.fx = fx
        self.log = log
        self.runner = runner
        self.table = table
        self.admin = admin
        self.journal = journal
        self.executor = CleanupExecutor(
            paths: paths, runner: runner, safety: safety ?? SafetyGuard(paths: paths), services: services,
            terminator: ProcessTerminator(table: table, timeout: terminationTimeout, forceTimeout: 0.2, pollInterval: 0.01),
            preferences: prefs, trash: LoggingTrash(inner: DirectoryTrash(directory: paths.trash), log: log),
            admin: admin, journal: journal)
    }

    func execute(_ plan: CleanupPlan, decision: UnresponsiveDecision = .forceQuit) async -> (CleanupResult, [CleanupProgress]) {
        let events = ProgressBox()
        let result = await executor.execute(plan, progress: { events.append($0) }, onUnresponsive: { _ in decision })
        return (result, events.items)
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [CleanupProgress] = []
    func append(_ p: CleanupProgress) { lock.lock(); _items.append(p); lock.unlock() }
    var items: [CleanupProgress] { lock.lock(); defer { lock.unlock() }; return _items }
}

func stepEvents(_ events: [CleanupProgress]) -> [String] {
    events.compactMap {
        switch $0 {
        case .stepStarted(let s): return "start:\(s.rawValue)"
        case .stepFinished(let s): return "end:\(s.rawValue)"
        default: return nil
        }
    }
}

// MARK: - 실행기 테스트

@Suite struct ExecutionTests {
    @Test func safetyIsRecheckedRightBeforeMove() async throws {
        let h = try Harness()
        let fx = h.fx
        let target = try fx.file(fx.home("Library/Caches/com.example.foo/cache.db"))
        let plan = CleanupPlan(kind: .orphanCleanup, targetName: "x",
                               items: [Candidate(url: target, category: .caches, confidence: .high, isSelected: true)],
                               ruleDataVersion: "t")
        // 계획 이후 상위 폴더를 보호 영역(~/.ssh)을 가리키는 심볼릭 링크로 바꾼다.
        let ssh = try fx.dir(fx.home(".ssh"))
        try fx.file(ssh.appendingPathComponent("cache.db"), text: "secret")
        try FileManager.default.removeItem(at: fx.home("Library/Caches/com.example.foo"))
        try fx.symlink(fx.home("Library/Caches/com.example.foo"), to: ssh)

        let (result, _) = await h.execute(plan)
        #expect(result.movedCount == 0)
        #expect(result.failures.count == 1)
        #expect(result.failures[0].reason.contains("보호된 항목"))
        #expect(fx.exists(ssh.appendingPathComponent("cache.db")))
    }

    @Test func continuesPastPerItemFailures() async throws {
        let h = try Harness()
        let fx = h.fx
        let missing = fx.home("Library/Caches/com.example.gone")
        let present = try fx.file(fx.home("Library/Caches/com.example.here/data"))
        let plan = CleanupPlan(kind: .orphanCleanup, targetName: "x", items: [
            Candidate(url: missing, category: .caches, confidence: .high, isSelected: true),
            Candidate(url: present.deletingLastPathComponent(), category: .caches, confidence: .high, isSelected: true, size: 16),
        ], ruleDataVersion: "t")
        let (result, events) = await h.execute(plan)
        #expect(result.movedCount == 1)
        #expect(result.movedToTrash == 1)
        #expect(result.movedSize == 16)
        #expect(result.failures.map(\.path) == [missing.path])
        #expect(result.failures[0].reason == "항목을 찾을 수 없습니다")
        #expect(!fx.exists(present))
        #expect(fx.exists(fx.paths.trash.appendingPathComponent("com.example.here/data")))
        #expect(events.contains { if case .itemFailed = $0 { return true }; return false })
        #expect(stepEvents(events) == ["start:moveItems", "end:moveItems"])
    }

    @Test func fullPipelineRunsStepsInMandatoryOrder() async throws {
        let h = try Harness()
        let fx = h.fx
        let app = try fx.makeApp(name: "Foo", bundleID: "com.example.foo")
        let agent = try fx.makeLaunchPlist(at: fx.home("Library/LaunchAgents/com.example.foo.agent.plist"),
                                           label: "com.example.foo.agent",
                                           arguments: [app.appendingPathComponent("Contents/MacOS/Foo").path], keepAlive: true)
        let prefs = try fx.plist(fx.home("Library/Preferences/com.example.foo.plist"), ["k": "v"])
        h.table.add(RunningProcess(pid: 501, executablePath: app.appendingPathComponent("Contents/MacOS/Foo").path,
                                   bundleID: "com.example.foo", name: "Foo", isApplication: true))
        let plan = CleanupPlan(
            kind: .appRemoval, targetName: "Foo", targetBundleID: "com.example.foo",
            items: [
                Candidate(url: agent, category: .launchAgent, confidence: .high, isSelected: true,
                          launchService: LaunchServiceRef(label: "com.example.foo.agent", domain: .user, plistURL: agent)),
                Candidate(url: prefs, category: .preferences, confidence: .high, isSelected: true, preferencesDomain: "com.example.foo"),
                Candidate(url: app, category: .appBundle, confidence: .high, isSelected: true),
            ],
            servicesToStop: [LaunchServiceRef(label: "com.example.foo.agent", domain: .user, plistURL: agent)],
            bundleIDsToTerminate: ["com.example.foo"], bundlePathsToTerminate: [app],
            preferencesDomains: ["com.example.foo"], receiptsToForget: ["com.example.foo.pkg"], resetPrivacy: true,
            ruleDataVersion: "rules-42")

        let (result, events) = await h.execute(plan)
        #expect(result.failures.isEmpty, "\(result.failures)")
        #expect(result.movedCount == 3)
        #expect(stepEvents(events) == [
            "start:stopServices", "end:stopServices", "start:terminateApps", "end:terminateApps",
            "start:flushPreferences", "end:flushPreferences", "start:moveItems", "end:moveItems",
            "start:postProcess", "end:postProcess",
        ])
        let log = h.log
        let bootout = try #require(log.index(of: "launchctl bootout gui/\(fx.paths.uid)/com.example.foo.agent"))
        let terminate = try #require(log.index(of: "terminate 501"))
        let flush = try #require(log.index(of: "defaults delete com.example.foo"))
        let movePlist = try #require(log.index(of: "trash com.example.foo.agent.plist"))
        let pkg = try #require(log.index(of: "admin pkg-forget com.example.foo.pkg"))
        let tcc = try #require(log.index(of: "tccutil reset All com.example.foo"))
        #expect(bootout < terminate && terminate < flush && flush < movePlist && movePlist < pkg && pkg < tcc)

        // 기록: 규칙 데이터 버전·수행 단계·중지한 서비스·cfprefs 사본
        let session = try #require(await h.journal.session(id: result.sessionID))
        #expect(session.ruleDataVersion == "rules-42")
        #expect(session.steps == ["stopServices", "terminateApps", "flushPreferences", "moveItems", "postProcess"])
        #expect(session.stoppedServices.map(\.label) == ["com.example.foo.agent"])
        #expect(session.preferencesBackups.map(\.domain) == ["com.example.foo"])
        #expect(session.items.count == 3)
        #expect(session.finishedAt != nil)
    }

    @Test func flushedPreferencesPlistIsStillRestorable() async throws {
        let h = try Harness()
        let fx = h.fx
        let prefs = try fx.plist(fx.home("Library/Preferences/com.example.bar.plist"), ["answer": 42])
        let plan = CleanupPlan(kind: .orphanCleanup, targetName: "x",
                               items: [Candidate(url: prefs, category: .preferences, confidence: .high, isSelected: true,
                                                 preferencesDomain: "com.example.bar")],
                               preferencesDomains: ["com.example.bar"], ruleDataVersion: "t")
        let (result, _) = await h.execute(plan)
        // 스텁 `defaults delete`가 cfprefsd처럼 파일을 지웠지만, 보관한 사본으로 휴지통 항목을 만든다.
        #expect(result.movedCount == 1, "\(result.failures)")
        let session = try #require(await h.journal.session(id: result.sessionID))
        let backup = try #require(session.preferencesBackups.first)
        #expect(FileManager.default.fileExists(atPath: backup.backupPath))
        #expect(session.items.first?.movedTo.hasPrefix(fx.paths.trash.path) == true)

        let restore = await h.journal.restore(sessionID: result.sessionID, itemPaths: nil, options: RestoreOptions())
        #expect(restore.restored == [prefs.path])
        let dict = try #require(NSDictionary(contentsOf: prefs))
        #expect(dict["answer"] as? Int == 42)
        #expect(h.log.events.contains("defaults import com.example.bar \(backup.backupPath)"))
    }

    @Test func receiptsAndHoldingShareOneAdminBatch() async throws {
        let fx = try Fixture()
        let admin = RecordingAdmin(paths: fx.paths)
        let h = try Harness(fx: fx, admin: admin)
        let daemon = try fx.makeLaunchPlist(at: fx.root("Library/LaunchDaemons/com.example.helper.plist"), label: "com.example.helper")
        let helper = try fx.file(fx.root("Library/PrivilegedHelperTools/com.example.helper"))
        let plan = CleanupPlan(kind: .orphanCleanup, targetName: "x", items: [
            Candidate(url: daemon, category: .launchDaemon, domain: .system, confidence: .high, isSelected: true),
            Candidate(url: helper, category: .privilegedHelper, domain: .system, confidence: .high, isSelected: true),
        ], receiptsToForget: ["com.example.pkg"], ruleDataVersion: "t")
        let (result, _) = await h.execute(plan)
        #expect(result.failures.isEmpty, "\(result.failures)")
        #expect(result.movedToHolding == 2)
        // 이동 두 건 + pkg-forget 한 건이 한 번의 인증(배치)으로
        #expect(admin.batches.count == 1)
        #expect(admin.batches[0].map { $0.arguments[0] } == ["move-to-holding", "move-to-holding", "pkg-forget"])
        #expect(admin.batches[0][0].arguments[2] == "/Library/LaunchDaemons/com.example.helper.plist")
    }

    @Test func endToEndWithRealScriptInTestMode() async throws {
        let fx = try Fixture()
        let h = try Harness(fx: fx, admin: scriptAdmin(fx))
        let daemon = try fx.makeLaunchPlist(at: fx.root("Library/LaunchDaemons/com.example.helper.plist"), label: "com.example.helper")
        let support = try fx.file(fx.root("Library/Application Support/com.example.foo/state.bin"))
        let plan = CleanupPlan(kind: .orphanCleanup, targetName: "x", items: [
            Candidate(url: daemon, category: .launchDaemon, domain: .system, confidence: .high, isSelected: true),
            Candidate(url: support.deletingLastPathComponent(), category: .applicationSupport, domain: .system, confidence: .high, isSelected: true),
        ], servicesToStop: [LaunchServiceRef(label: "com.example.helper", domain: .system, plistURL: daemon)],
        receiptsToForget: ["com.example.pkg"], ruleDataVersion: "t")
        let (result, _) = await h.execute(plan)
        #expect(result.failures.isEmpty, "\(result.failures)")
        #expect(result.movedToHolding == 2)
        let held = AdminPaths.holdingURL(session: result.sessionID, logical: "/Library/Application Support/com.example.foo/state.bin",
                                         holdingDir: fx.paths.holdingDir)
        #expect(fx.exists(held))
        #expect(!fx.exists(daemon))

        let restore = await h.journal.restore(sessionID: result.sessionID, itemPaths: nil, options: RestoreOptions())
        #expect(restore.failures.isEmpty, "\(restore.failures)")
        #expect(fx.exists(daemon) && fx.exists(support))
        let s = try #require(await h.journal.session(id: result.sessionID))
        #expect(s.status == .restored)
    }

    @Test func liveFactoryWiresRealComponents() throws {
        let fx = try Fixture()
        // 조립만 확인한다 (실행하지 않음 — 실제 휴지통·osascript 사용 금지)
        let executor = CleanupExecutor.live(paths: fx.paths, runner: StubCommandRunner())
        #expect(executor.safety is SafetyGuard)
        #expect(executor.trash is FileManagerTrash)
        #expect(executor.admin is AppleScriptAdminExecutor)
        #expect(executor.terminator is ProcessTerminator)
        let journal = JournalStore.live(paths: fx.paths, runner: StubCommandRunner())
        #expect(journal.directory.path.hasPrefix(fx.base.path))
    }
}
