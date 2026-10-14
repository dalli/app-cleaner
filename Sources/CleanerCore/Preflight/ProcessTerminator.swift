import Foundation
import AppKit
import Darwin

/// 실행 중 프로세스 1개
public struct RunningProcess: Sendable, Hashable {
    public var pid: Int32
    /// 실행 파일의 실제 경로 (`proc_pidpath`)
    public var executablePath: String?
    public var bundleID: String?
    public var name: String
    /// LaunchServices에 등록된 앱(`NSRunningApplication`)인지
    public var isApplication: Bool

    public init(pid: Int32, executablePath: String?, bundleID: String? = nil, name: String, isApplication: Bool) {
        self.pid = pid
        self.executablePath = executablePath
        self.bundleID = bundleID
        self.name = name
        self.isApplication = isApplication
    }

    var asUnresponsive: UnresponsiveApp { UnresponsiveApp(bundleID: bundleID, name: name, pid: pid) }
}

/// 프로세스 조회·신호 전송 추상화. 테스트는 가짜 테이블을 써서 실제 프로세스를 건드리지 않는다.
public protocol ProcessTable: Sendable {
    /// LaunchServices 등록 앱 (`NSRunningApplication.runningApplications(withBundleIdentifier:)`)
    func applications(bundleID: String) -> [RunningProcess]
    /// 모든 프로세스 (`proc_listpids` + `proc_pidpath`)
    func allProcesses() -> [RunningProcess]
    /// 정상 종료 요청 (`terminate()` 또는 SIGTERM)
    func requestQuit(_ process: RunningProcess) -> Bool
    /// 강제 종료 (`forceTerminate()` 또는 SIGKILL)
    func forceQuit(_ process: RunningProcess) -> Bool
    func isRunning(_ pid: Int32) -> Bool
}

/// 종료 단계 결과
public struct TerminationReport: Sendable, Hashable {
    /// 종료 요청 후 끝난 프로세스
    public var terminated: [UnresponsiveApp]
    /// 강제 종료한 프로세스
    public var forced: [UnresponsiveApp]
    /// 사용자가 건너뛰었거나 강제 종료에도 남은 프로세스
    public var remaining: [UnresponsiveApp]
    public var cancelled: Bool

    public init(terminated: [UnresponsiveApp] = [], forced: [UnresponsiveApp] = [], remaining: [UnresponsiveApp] = [],
                cancelled: Bool = false) {
        self.terminated = terminated
        self.forced = forced
        self.remaining = remaining
        self.cancelled = cancelled
    }
}

/// 실행 중 프로세스 종료 (plan.md 4.4 2단계)
public protocol ProcessTerminating: Sendable {
    func terminate(
        bundleIDs: [String],
        bundlePaths: [URL],
        onUnresponsive: @escaping @Sendable (UnresponsiveApp) async -> UnresponsiveDecision
    ) async -> TerminationReport
}

/// 1) BID로 GUI 앱을 찾아 `terminate()` 2) 실행 파일이 대상 번들 안에 있는 모든 프로세스(LaunchServices 미등록 헬퍼·CLI)에
/// SIGTERM 3) 시간 초과 시 `onUnresponsive`로 강제 종료/건너뛰기/취소를 묻는다.
public struct ProcessTerminator: ProcessTerminating {
    public let table: ProcessTable
    public let timeout: TimeInterval
    public let forceTimeout: TimeInterval
    public let pollInterval: TimeInterval

    public init(table: ProcessTable = LiveProcessTable(), timeout: TimeInterval = 10, forceTimeout: TimeInterval = 3,
                pollInterval: TimeInterval = 0.1) {
        self.table = table
        self.timeout = timeout
        self.forceTimeout = forceTimeout
        self.pollInterval = pollInterval
    }

    /// 종료 대상 수집 (중복 pid 제거, 자기 자신·launchd 제외)
    public func targets(bundleIDs: [String], bundlePaths: [URL]) -> [RunningProcess] {
        let selfPID = getpid()
        var byPID: [Int32: RunningProcess] = [:]
        var order: [Int32] = []
        func add(_ p: RunningProcess) {
            guard p.pid > 1, p.pid != selfPID else { return }
            if byPID[p.pid] == nil { order.append(p.pid); byPID[p.pid] = p }
        }
        for bid in bundleIDs where !bid.isEmpty {
            table.applications(bundleID: bid).forEach(add)
        }
        let prefixes = bundlePaths.flatMap { url -> [String] in
            let lexical = SafetyGuard.normalize(url.path)
            let real = SafetyGuard.realpathOfExistingPrefix(lexical)
            return Set([lexical, real]).map { SafetyGuard.key($0) + "/" }
        }
        if !prefixes.isEmpty {
            for p in table.allProcesses() {
                guard let exe = p.executablePath else { continue }
                let k = SafetyGuard.key(exe)
                if prefixes.contains(where: { k.hasPrefix($0) }) { add(p) }
            }
        }
        return order.compactMap { byPID[$0] }
    }

    public func terminate(
        bundleIDs: [String],
        bundlePaths: [URL],
        onUnresponsive: @escaping @Sendable (UnresponsiveApp) async -> UnresponsiveDecision
    ) async -> TerminationReport {
        let targets = targets(bundleIDs: bundleIDs, bundlePaths: bundlePaths)
        var report = TerminationReport()
        guard !targets.isEmpty else { return report }

        for p in targets { _ = table.requestQuit(p) }
        var alive = await waitForExit(targets, timeout: timeout)
        report.terminated = targets.filter { t in !alive.contains { $0.pid == t.pid } }.map(\.asUnresponsive)

        for p in alive {
            guard table.isRunning(p.pid) else { report.terminated.append(p.asUnresponsive); continue }
            switch await onUnresponsive(p.asUnresponsive) {
            case .cancel:
                report.remaining.append(contentsOf: alive.filter { table.isRunning($0.pid) }.map(\.asUnresponsive))
                report.cancelled = true
                return report
            case .skip:
                report.remaining.append(p.asUnresponsive)
            case .forceQuit:
                _ = table.forceQuit(p)
                let still = await waitForExit([p], timeout: forceTimeout)
                if still.isEmpty { report.forced.append(p.asUnresponsive) } else { report.remaining.append(p.asUnresponsive) }
            }
        }
        alive.removeAll()
        return report
    }

    private func waitForExit(_ processes: [RunningProcess], timeout: TimeInterval) async -> [RunningProcess] {
        let deadline = Date().addingTimeInterval(timeout)
        var alive = processes.filter { table.isRunning($0.pid) }
        while !alive.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(max(pollInterval, 0.01) * 1_000_000_000))
            alive = alive.filter { table.isRunning($0.pid) }
        }
        return alive
    }
}

/// 실제 프로세스 테이블 (`NSRunningApplication`, `proc_listpids`, `proc_pidpath`, `kill`)
public struct LiveProcessTable: ProcessTable {
    public init() {}

    public func applications(bundleID: String) -> [RunningProcess] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map {
            RunningProcess(pid: $0.processIdentifier, executablePath: $0.executableURL?.path, bundleID: $0.bundleIdentifier,
                           name: $0.localizedName ?? $0.bundleURL?.deletingPathExtension().lastPathComponent ?? bundleID,
                           isApplication: true)
        }
    }

    public func allProcesses() -> [RunningProcess] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size + 32)
        let bytes = pids.withUnsafeMutableBytes { buf in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buf.baseAddress, Int32(buf.count))
        }
        guard bytes > 0 else { return [] }
        let n = Int(bytes) / MemoryLayout<pid_t>.size
        var out: [RunningProcess] = []
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(n) where pid > 0 {
            let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            guard len > 0 else { continue }
            let path = String(decoding: pathBuf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            out.append(RunningProcess(pid: pid, executablePath: path, name: (path as NSString).lastPathComponent,
                                      isApplication: false))
        }
        return out
    }

    public func requestQuit(_ process: RunningProcess) -> Bool {
        if process.isApplication, let app = NSRunningApplication(processIdentifier: process.pid) {
            return app.terminate()
        }
        return kill(process.pid, SIGTERM) == 0
    }

    public func forceQuit(_ process: RunningProcess) -> Bool {
        if process.isApplication, let app = NSRunningApplication(processIdentifier: process.pid) {
            if app.forceTerminate() { return true }
        }
        return kill(process.pid, SIGKILL) == 0
    }

    public func isRunning(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
