import Foundation

/// 권한 헬퍼(XPC)로 관리자 작업을 실행한다 (plan.md 5.3 정식 방식).
///
/// - 헬퍼가 상주하므로 세션 안에서 관리자 인증을 다시 묻지 않는다 (헬퍼 등록 시 로그인 항목 승인 1회).
/// - 연결마다 헬퍼 쪽 서명 요구사항을 건다 (같은 Team ID + 헬퍼 식별자). Team ID가 없는 개발 빌드는 요구사항 없이
///   Mach 서비스 이름만 믿는다 — 시스템 도메인 Mach 서비스는 root만 등록할 수 있다.
/// - `runIfReachable`은 먼저 `ping`으로 연결을 확인하고, 실패하면(미설치·미승인·서명 불일치·응답 없음) nil을 돌려준다.
///   작업 요청을 보낸 뒤 연결이 끊기면 결과를 모르므로 대체 경로로 다시 보내지 않고 실패로 보고한다 (중복 이동 방지).
public struct HelperAdminExecutor: AdminExecuting {
    public let identity: PrivilegedHelperIdentity
    /// 헬퍼 쪽 코드 서명 요구사항 (nil이면 검사하지 않음 — Team ID 없는 개발 빌드)
    public let helperRequirement: String?
    public let pingTimeout: TimeInterval
    public let operationTimeout: TimeInterval
    private let makeConnection: @Sendable () -> NSXPCConnection

    public init(identity: PrivilegedHelperIdentity, helperRequirement: String?,
                pingTimeout: TimeInterval = 3, operationTimeout: TimeInterval = 600,
                makeConnection: @escaping @Sendable () -> NSXPCConnection) {
        self.identity = identity
        self.helperRequirement = helperRequirement
        self.pingTimeout = pingTimeout
        self.operationTimeout = operationTimeout
        self.makeConnection = makeConnection
    }

    /// 실제 헬퍼: 시스템 도메인 Mach 서비스(`.privileged`), 요구사항은 이 프로세스의 Team ID로 만든다.
    public static func live(identity: PrivilegedHelperIdentity = .forCurrentProcess(),
                            signing: SigningInfo? = SelfCodeSignature.current()) -> HelperAdminExecutor {
        let requirement = signing?.teamID.flatMap { CodeSigningRequirement.make(teamID: $0, identifiers: [identity.helperLabel]) }
        let name = identity.machServiceName
        return HelperAdminExecutor(identity: identity, helperRequirement: requirement) {
            NSXPCConnection(machServiceName: name, options: .privileged)
        }
    }

    public func run(_ operations: [AdminOperation]) async -> [AdminOperationResult] {
        await runIfReachable(operations) ?? operations.map {
            AdminOperationResult(operation: $0, succeeded: false, message: $0.preflightIssue ?? "helper-unavailable")
        }
    }

    /// 헬퍼에 연결할 수 있으면 실행 결과, 없으면 nil (아무 작업도 보내지 않았음)
    public func runIfReachable(_ operations: [AdminOperation]) async -> [AdminOperationResult]? {
        guard !operations.isEmpty else { return [] }
        var results: [AdminOperationResult?] = operations.map { op in
            op.preflightIssue.map { AdminOperationResult(operation: op, succeeded: false, message: $0) }
        }
        let toRun = operations.indices.filter { results[$0] == nil }
        guard !toRun.isEmpty else { return results.map { $0! } }

        let call = XPCCall(connection: makeConnection(), requirement: helperRequirement)
        defer { call.invalidate() }
        guard let version: Int = await call.send(timeout: pingTimeout, { proxy, reply in proxy.ping(withReply: reply) }),
              version == HelperWireRequest.currentVersion else { return nil }

        let request = HelperWireRequest(operations: toRun.map { HelperWireOperation(operations[$0]) })
        let data = (try? JSONEncoder().encode(request)) ?? Data()
        let replyData: Data? = await call.send(timeout: operationTimeout, { proxy, reply in proxy.perform(data, withReply: reply) })
        let reply = replyData.flatMap { try? JSONDecoder().decode(HelperWireReply.self, from: $0) }
        for (k, i) in toRun.enumerated() {
            let message: String
            let ok: Bool
            if let reply, reply.error == nil, k < reply.results.count {
                (ok, message) = (reply.results[k].ok, reply.results[k].message)
            } else {
                (ok, message) = (false, reply?.error ?? "helper-no-reply")
            }
            results[i] = AdminOperationResult(operation: operations[i], succeeded: ok, message: message)
        }
        return results.map { $0! }
    }
}

/// 헬퍼가 있으면 헬퍼, 없으면 대체 경로(AppleScript 고정 스크립트)로 실행한다 (#17 결정 — docs/development.md).
/// 헬퍼 미설치·미승인·서명 불일치(예: Homebrew로 설치한 CLI)일 때도 기존처럼 관리자 암호로 동작한다.
public struct FallbackAdminExecutor: AdminExecuting {
    public let helper: HelperAdminExecutor
    public let fallback: AdminExecuting

    public init(helper: HelperAdminExecutor, fallback: AdminExecuting) {
        self.helper = helper
        self.fallback = fallback
    }

    public func run(_ operations: [AdminOperation]) async -> [AdminOperationResult] {
        if let results = await helper.runIfReachable(operations) { return results }
        return await fallback.run(operations)
    }
}

/// 관리자 실행기 조립 (엔진·CLI 공통)
public enum AdminExecutors {
    /// 이미 root(`.direct`)면 고정 스크립트를 바로 실행하고, 아니면 헬퍼 → AppleScript(GUI)·sudo(지정 시) 순서.
    public static func live(launcher: AppleScriptAdminExecutor.Launcher? = nil) -> AdminExecuting {
        let launcher = launcher ?? (getuid() == 0 ? .direct : .osascript)
        // 관리자 암호 입력을 기다려야 하므로 긴 시간 제한
        let script = AppleScriptAdminExecutor(runner: ProcessCommandRunner(timeout: 900), launcher: launcher)
        if launcher == .direct { return script }
        return FallbackAdminExecutor(helper: .live(), fallback: script)
    }
}

/// XPC 호출 1회 묶음 — 응답·오류·시간 초과 중 먼저 온 것 하나만 받는다.
final class XPCCall: @unchecked Sendable {
    private let connection: NSXPCConnection

    init(connection: NSXPCConnection, requirement: String?) {
        self.connection = connection
        connection.remoteObjectInterface = PrivilegedHelperInterface.make()
        if let requirement { connection.setCodeSigningRequirement(requirement) }
        connection.resume()
    }

    func invalidate() { connection.invalidate() }

    func send<T: Sendable>(timeout: TimeInterval,
                           _ body: (PrivilegedHelperXPC, @escaping @Sendable (T) -> Void) -> Void) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let once = Once(cont)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(nil) }
            guard let helper = proxy as? PrivilegedHelperXPC else { once.resume(nil); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
            body(helper) { once.resume($0) }
        }
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<T?, Never>?
        init(_ cont: CheckedContinuation<T?, Never>) { self.cont = cont }
        func resume(_ value: T?) {
            let c: CheckedContinuation<T?, Never>? = lock.withLock {
                defer { cont = nil }
                return cont
            }
            c?.resume(returning: value)
        }
    }
}
